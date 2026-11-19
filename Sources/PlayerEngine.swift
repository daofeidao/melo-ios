import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

enum RepeatMode: String {
    case off
    case all
    case one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var symbolName: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

final class PlayerEngine: ObservableObject {
    static let shared = PlayerEngine()

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorText: String?
    /// 严格模式下被拒的同名版本，播放页用「切换音源」列出来
    @Published private(set) var alternatives: [Track] = []

    /// 这一首实际用的是哪个源（local / cache / kugou / kuwo / netease / qq / youtube）
    @Published private(set) var activeSource: String?
    /// 用户手动点「缓存到本地」时的状态：正在下 / 刚给过什么提示。
    /// 没有这两个，点下去要等几秒才有文件出现，看着就像没反应。
    @Published private(set) var cacheBusy = false
    @Published private(set) var cacheMessage: String?
    /// 用户手动锁定的源；nil 表示按默认顺序自动兜底
    @Published private(set) var preferredSource: String?
    @Published var repeatMode: RepeatMode = .off
    @Published var isShuffle = false
    /// 点歌后是否直接展开全屏播放页（Apple Music 的行为）
    @Published var opensFullPlayer = false
    /// 播放页上的浮层（播放源 / 待播清单）是否打开——Mac 全局双指手势据此决定
    /// 「下滑」是关浮层还是关播放页。
    @Published var sheetOpen = false

    private let player = AVPlayer()

    /// 播放页要拿到同一个 AVPlayer 才能挂 AVPlayerLayer 显示画面
    var avPlayer: AVPlayer { player }

    /// 当前这首是否带着视频画面（受保护视频只有合体的 format 18 可读，
    /// 画面本来就在流里）。为真时播放页把封面区换成动态画面。
    @Published private(set) var showsVideo = false
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?
    private var retryBudget = 1
    private var itemStatusCancellable: AnyCancellable?
    private var loadedRangesCancellable: AnyCancellable?
    private var progressCancellable: AnyCancellable?
    private var loadToken = UUID()
    /// 当前这首正在用的直链和它的来源 —— 手动「缓存到本地」直接复用，
    /// 不必再解析一遍（解析一次又要 1~6 秒）
    private var currentStream: AudioStream?
    private var currentStreamSource: String?
    /// 上一条缓存提示是给哪首歌的：换歌时清掉，别让新歌顶着上一首的「已缓存」
    private var cacheTrackID: String?
    /// 提示的自动消失任务
    private var cacheMessageTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchedIndex: Int?
    private var artworkCache: [String: UIImage] = [:]

    var currentTrack: Track? {
        guard index >= 0, index < queue.count else { return nil }
        return queue[index]
    }

    var hasTrack: Bool { currentTrack != nil }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    private init() {
        configureSession()
        observePlayer()
        observeNotifications()
        setupRemoteCommands()
        UIApplication.shared.beginReceivingRemoteControlEvents()
        // 音量键双击：音量+ 下一曲 / 音量- 上一曲（Mac 上是空壳）
        VolumeShortcut.shared.start(
            onNext: { [weak self] in self?.next() },
            onPrevious: { [weak self] in self?.previous() },
            canTrigger: { [weak self] in self?.hasTrack ?? false }
        )
    }

    // MARK: - Setup

    private func configureSession() {
        // macOS Catalyst 没有 AVAudioSession（音频路由由系统管），跳过会话配置
        #if !targetEnvironment(macCatalyst)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        #endif
    }

    private func observePlayer() {
        // 起播优先：不要等 AVPlayer 自己算"攒多久才够"，先把声音放出来再继续缓冲
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                let playing = status == .playing
                Diagnostics.mark("avplayer: status=\(Self.name(status)) rate=\(self.player.rate)")
                if self.isPlaying != playing {
                    self.isPlaying = playing
                    self.updateNowPlaying()
                }
            }
            .store(in: &cancellables)

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            // 正在解析新歌时，player 里还挂着上一首的 item，别拿它的时间覆盖界面
            if self.isLoading { return }
            let seconds = time.seconds
            if seconds.isFinite {
                self.elapsed = max(0, seconds)
            }
            if let itemDuration = self.player.currentItem?.duration, itemDuration.isNumeric {
                let value = itemDuration.seconds
                if value.isFinite, value > 0, abs(value - self.duration) > 1 {
                    self.duration = value
                    self.updateNowPlaying()
                }
            }
        }
    }

    private func observeNotifications() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            guard let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
            guard !self.isLoading else { return }
            self.handleTrackEnded()
        }

        #if !targetEnvironment(macCatalyst)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.player.pause()
            case .ended:
                try? AVAudioSession.sharedInstance().setActive(true)
                let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: raw)
                if options.contains(.shouldResume), self.hasTrack {
                    self.player.play()
                }
            @unknown default:
                break
            }
        }

        // 拔耳机/断开蓝牙时暂停，符合系统音乐 App 的行为
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            if reason == .oldDeviceUnavailable {
                self.player.pause()
            }
        }
        #endif

        // 直链过期导致播放失败时，静默重新解析一次
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let item = note.object as? AVPlayerItem,
                  item === self.player.currentItem else { return }
            self.retryCurrentTrack()
        }

        // 媒体服务被系统重置（来电、其他 App 抢占等极端情况）：重建会话并续播
        #if !targetEnvironment(macCatalyst)
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let wasPlaying = self.isPlaying
            self.configureSession()
            if self.hasTrack {
                self.load(autoPlay: wasPlaying, resetBudget: true)
            }
        }
        #endif
    }

    private func retryCurrentTrack() {
        guard retryBudget > 0, let track = currentTrack else { return }
        retryBudget -= 1
        StreamCache.shared.remove(forKey: cacheKey(for: track))
        load(autoPlay: true, resetBudget: false, keepError: true)
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        // Mac 的菜单栏 / 控制中心的「正在播放」要求命令显式可用，
        // 否则那一排按钮是灰的（也就是用户说的「状态栏只能看不能点」）
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            DispatchQueue.main.async { self?.seek(to: event.positionTime) }
            return .success
        }
    }

    // MARK: - Public controls

    func play(tracks: [Track], startAt startIndex: Int) {
        guard !tracks.isEmpty else { return }
        // 从列表主动点播：回到自动选源，不沿用上一首的手动锁定
        preferredSource = nil
        queue = tracks
        index = min(max(0, startIndex), tracks.count - 1)
        loadCurrent(autoPlay: true)
        // 用户点了歌就直接给播放页，不要让他再点一次迷你播放器
        // 用户主动点歌是显式操作，总是弹播放页（SafeMode 只降级自动行为）
        if !SmokeTest.suppressesAutoPlayer { opensFullPlayer = true }
    }

    func playSingle(_ track: Track) {
        if let existing = queue.firstIndex(of: track) {
            index = existing
            loadCurrent(autoPlay: true)
            if !SmokeTest.suppressesAutoPlayer { opensFullPlayer = true }
        } else {
            play(tracks: [track], startAt: 0)
        }
    }

    func jump(to target: Int) {
        guard target >= 0, target < queue.count else { return }
        index = target
        loadCurrent(autoPlay: true)
    }

    func toggle() {
        guard hasTrack else { return }
        if player.currentItem == nil {
            loadCurrent(autoPlay: true)
            return
        }
        if isPlaying {
            player.pause()
        } else {
            resume()
        }
    }

    func resume() {
        guard hasTrack else { return }
        if player.currentItem == nil {
            loadCurrent(autoPlay: true)
            return
        }
        #if !targetEnvironment(macCatalyst)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        player.play()
    }

    func pause() {
        player.pause()
    }

    func next() {
        guard !queue.isEmpty else { return }

        if isShuffle, queue.count > 1 {
            // 随机模式下优先用预取过的那一首，否则预取永远命中不了
            if let prefetched = prefetchedIndex, prefetched != index, prefetched >= 0, prefetched < queue.count {
                index = prefetched
            } else {
                var candidate = Int.random(in: 0..<queue.count)
                if candidate == index { candidate = (candidate + 1) % queue.count }
                index = candidate
            }
        } else if index + 1 < queue.count {
            index += 1
        } else if repeatMode == .all {
            index = 0
        } else {
            player.pause()
            seek(to: 0)
            return
        }
        loadCurrent(autoPlay: true)
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if elapsed > 3 {
            seek(to: 0)
            return
        }
        if index - 1 >= 0 {
            index -= 1
        } else if repeatMode == .all {
            index = queue.count - 1
        } else {
            seek(to: 0)
            return
        }
        loadCurrent(autoPlay: true)
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self = self else { return }
            self.elapsed = max(0, seconds)
            self.updateNowPlaying()
        }
    }

    func clearError() {
        errorText = nil
    }

    /**
     * 播放页「播放源」面板：锁定到某个源重新解析，传 nil 回到自动兜底。
     *
     * 手动选源本身已经表达了「就要这个版本」的意图，顺带绕过严格匹配，
     * 否则用户点了却发现还是不放，比不给选更糟。
     */
    func selectSource(_ source: String?) {
        preferredSource = source
        DomesticSource.forceLooseOnce = source != nil
        retryBudget = 1
        errorText = nil
        alternatives = []
        // 切源必须重新解析：StreamCache（直链）和 AudioCache（音频文件）两层都要作废，
        // 否则点完还是放上一首来源留下的那份文件，怎么切都像没反应。
        if let track = currentTrack {
            StreamCache.shared.remove(forKey: cacheKey(for: track))
            AudioCache.shared.invalidate(for: track)
        }
        loadCurrent(autoPlay: true, bypassStreamCache: true)
    }

    /// 换了音质：两层缓存都按新档位重新取
    func reloadForQuality() {
        retryBudget = 1
        errorText = nil
        if let track = currentTrack {
            StreamCache.shared.remove(forKey: cacheKey(for: track))
            AudioCache.shared.invalidate(for: track)
        }
        loadCurrent(autoPlay: true, bypassStreamCache: true)
    }

    /// 用户在「切换音源」里选了某个同名版本：直接单曲播放
    func playAlternative(_ track: Track) {
        DomesticSource.forceLooseOnce = true
        retryBudget = 1
        errorText = nil
        alternatives = []
        queue = [track]
        index = 0
        loadCurrent(autoPlay: true)
    }

    /// 用户点「重试」时重置重试预算，允许再解析一次
    func retryCurrent() {
        retryBudget = 1
        errorText = nil
        loadCurrent(autoPlay: true)
    }

    private func observeItem(_ item: AVPlayerItem) {
        // 诊断：拉了多少数据、报了什么错。AVPlayer 在 Mac 上不走系统代理，
        // 这里能看出是「超时（没走代理）」还是「403（UA 不对）」。
        loadedRangesCancellable = item.publisher(for: \.loadedTimeRanges)
            .receive(on: DispatchQueue.main)
            .sink { ranges in
                let seconds = ranges.reduce(0.0) { sum, range in
                    sum + range.timeRangeValue.duration.seconds
                }
                Diagnostics.mark(String(format: "avplayer: buffered=%.1fs", seconds))
            }
        itemStatusCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                let err = item.error as NSError?
                Diagnostics.mark("avplayer: item.status=\(Self.itemStatusName(status)) code=\(err?.code ?? 0) domain=\(err?.domain ?? "-") err=\(err?.localizedDescription ?? "nil")")
                guard status == .failed else { return }
                let message = item.error?.localizedDescription ?? L("Unknown error")
                self.errorText = String(format: L("Playback failed: %@"), message)
                self.isLoading = false
                // 先把错误留在界面上，再静默重解析一次；重试也失败就直接停住，
                // 不要像以前那样"转圈一整轮再报错"
                // 记下来：下次解析跳过这条直链，直接按歌名去国内源找同一首
                if let track = self.currentTrack {
                    AudioSource.notePlaybackFailure(track)
                }
                if self.retryBudget > 0 {
                    self.retryCurrentTrack()
                } else {
                    self.isPlaying = false
                    self.player.pause()
                    self.player.replaceCurrentItem(with: nil)
                }
            }
    }

    /// 每 10 秒记一次播放进度：确认是真的在出声（currentTime 在涨），而不是卡在 buffering。
    /// 只在进度真的动了的时候记，避免日志被刷爆。
    private func observeProgress() {
        var lastLogged = -1.0
        progressCancellable = Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                let t = self.player.currentTime().seconds
                guard t - lastLogged >= 5 else { return }
                lastLogged = t
                let buffered = self.player.currentItem?.loadedTimeRanges.first?
                    .timeRangeValue.duration.seconds ?? 0
                Diagnostics.mark(String(format: "avplayer: t=%.1f buffered=%.1fs rate=%.2f", t, buffered, self.player.rate))
            }
    }

    // MARK: - Loading

    func loadCurrent(autoPlay: Bool, bypassStreamCache: Bool = false) {
        load(autoPlay: autoPlay, resetBudget: true, bypassStreamCache: bypassStreamCache)
    }

    // MARK: - 手动缓存到本地

    /// 播放页要显示「已缓存」。只看索引，不做失效判断 —— cachedURL 有副作用、也重。
    func isCached(_ track: Track) -> Bool {
        AudioCache.shared.hasEntry(for: track.id)
    }

    /// 手动下这一首：正在播就直接用现成的直链，还没解析就先解析一条再下。
    /// 和「自动缓存」的区别只在触发方式：都是走严格匹配过的那条流，不会存错版本。
    func cacheCurrent() {
        guard let track = currentTrack else { return }
        if AudioCache.shared.hasEntry(for: track.id) {
            flashCacheMessage(L("Already saved on this device"))
            return
        }
        guard AudioCache.shared.isEnabled else {
            flashCacheMessage(L("Audio caching is off. Turn it on in Settings."))
            return
        }
        if cacheBusy { return }

        cacheBusy = true
        flashCacheMessage(nil)
        let quality = self.quality()

        // 正在播、来源也明确：直接下这条流，省掉一次解析
        if let stream = currentStream, let source = currentStreamSource,
           source != "cache", source != "local" {
            AudioCache.shared.store(
                from: stream.url,
                for: track,
                mime: stream.mime,
                userAgent: stream.userAgent ?? StreamResolver.clientUserAgent,
                source: source,
                quality: quality,
                verified: true
            ) { [weak self] ok in
                self?.finishCache(ok)
            }
            return
        }

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let stream = try await AudioSource.resolve(
                    track: track,
                    quality: quality,
                    pinnedSource: self.preferredSource
                )
                let source = AudioSource.lastResolvedSource ?? "kugou"
                guard source != "cache", source != "local" else {
                    await MainActor.run { self.finishCache(true) }
                    return
                }
                await MainActor.run {
                    AudioCache.shared.store(
                        from: stream.url,
                        for: track,
                        mime: stream.mime,
                        userAgent: stream.userAgent ?? StreamResolver.clientUserAgent,
                        source: source,
                        quality: quality,
                        verified: true
                    ) { [weak self] ok in
                        self?.finishCache(ok)
                    }
                }
            } catch {
                await MainActor.run {
                    self.finishCache(false, reason: L("Couldn't find a playable source for this song"))
                }
            }
        }
    }

    private func finishCache(_ ok: Bool, reason: String? = nil) {
        cacheBusy = false
        flashCacheMessage(ok ? L("Saved to this device")
                             : (reason ?? L("Download failed. Try again later.")))
    }

    /// 提示只在屏幕上停 3.5 秒。播放页不该常驻一行「已缓存」——
    /// 图标变实心已经说明了一切，文字只留给「正在做 / 刚失败」。
    private func flashCacheMessage(_ text: String?) {
        cacheMessageTask?.cancel()
        cacheMessage = text
        guard let text = text, !text.isEmpty else { return }
        cacheMessageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, let self = self else { return }
            await MainActor.run { self.cacheMessage = nil }
        }
    }

    private func quality() -> StreamResolver.Quality {
        let raw = UserDefaults.standard.string(forKey: "melo.quality") ?? StreamResolver.Quality.high.rawValue
        return StreamResolver.Quality(rawValue: raw) ?? .high
    }

    /// 缓存键必须唯一到"这首歌"：只拿 videoId 的话，国内音源的歌 videoId 都是空串，
    /// 两首不同的歌会命中同一条缓存，直接播错。
    private func cacheKey(for track: Track) -> String {
        track.id + "|" + quality().rawValue
    }

    private func load(autoPlay: Bool, resetBudget: Bool, keepError: Bool = false, bypassStreamCache: Bool = false) {
        if resetBudget { retryBudget = 1 }
        guard let track = currentTrack else { return }

        // 换歌就把上一首留下的缓存提示清掉
        if cacheTrackID != track.id {
            cacheTrackID = track.id
            flashCacheMessage(nil)
            cacheBusy = false
        }

        Diagnostics.mark("load 《\(track.title)》 / \(track.artist) · src=\(track.source)")
        let token = UUID()
        loadToken = token
        isLoading = true
        if !keepError { errorText = nil }
        alternatives = []
        elapsed = 0
        duration = Double(track.duration)
        updateNowPlaying()

        // 先把旧音频停掉再解析：界面已经换了新歌，耳朵里不能还是上一首。
        // 这里只 pause 不拆 item —— 拆了再建等于两次管线重建，白花 100~200ms。
        // 旧 item 留在 player 里但不再出声，时间观察器和"播完"回调都会用
        // isLoading 挡住，失败时再 replaceCurrentItem(nil) 清状态。
        player.pause()
        prefetchedIndex = nil

        let quality = self.quality()
        let key = cacheKey(for: track)

        // 命中缓存（内存或上次落盘）就直接起播，0 网络等待。
        // 但手动切源 / 换音质时必须跳过：StreamCache 的键是 track.id|quality，
        // 它记的是"上次解析出来的那条直链"，照它播就等于把用户的选择吞掉
        // —— 以前切了源实际还在放老源，就是这个原因。
        if !bypassStreamCache, let cached = StreamCache.shared.stream(forKey: key) {
            // 缓存直链对应的音频文件（如果有）早就在 AudioCache 里了，不要再存一次。
            // 注意要延后一拍再起播：这条路径原来是在「点击手势的回调里」直接跑完
            // start()，中间会改 @Published（recent / isLoading …），等于在 SwiftUI
            // 正在更新视图时改状态，Catalyst 上会直接崩 —— 网络路径因为多了一次
            // async 跳转恰好躲过去了，本地缓存命中时没有这一跳。
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.loadToken == token else { return }
                self.start(stream: cached, autoPlay: autoPlay, token: token, cacheable: false, cacheSource: nil)
            }
            return
        }

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let stream = try await AudioSource.resolve(
                    track: track,
                    quality: quality,
                    pinnedSource: preferredSource
                )
                let resolvedFrom = AudioSource.lastResolvedSource
                let trusted = AudioSource.lastResolveTrusted
                DispatchQueue.main.async {
                    guard self.loadToken == token else { return }
                    self.activeSource = resolvedFrom
                    Diagnostics.mark("resolved by \(resolvedFrom) trusted=\(trusted)")
                    StreamCache.shared.store(stream, forKey: key)
                    self.start(stream: stream, autoPlay: autoPlay, token: token,
                               cacheable: trusted, cacheSource: resolvedFrom)
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.loadToken == token else { return }
                    self.isLoading = false
                    self.isPlaying = false
                    self.player.replaceCurrentItem(with: nil)
                    let near = AudioSource.takeAlternatives()
                    self.alternatives = near
                    let base = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    Diagnostics.mark("resolve failed: \(base)")
                    self.errorText = near.isEmpty ? base
                        : L("Strict matching found no track with the same duration. Pick another source below.")
                    self.updateNowPlaying()
                }
            }
        }
    }

    /// 当前曲目开播后在后台把后面几首的直链也解析好。
    /// 只解析一首的话，用户在列表里连点两下、或者顺序播放切到第三首时还是要等。
    /// 串行解析、不并发：国内源并发多了会被限流。
    private func prefetchUpcoming() {
        prefetchTask?.cancel()
        guard queue.count > 1 else { return }

        var targets: [Int] = []
        if isShuffle {
            targets = [(index + 1 + Int.random(in: 0..<max(1, queue.count - 1))) % queue.count]
        } else {
            for step in 1...3 {
                let candidate = index + step
                if candidate < queue.count {
                    targets.append(candidate)
                } else if repeatMode == .all {
                    targets.append(candidate % queue.count)
                }
            }
        }
        targets = targets.filter { $0 != index }
        guard let first = targets.first else { return }
        prefetchedIndex = first

        let quality = self.quality()
        let jobs = targets
            .map { queue[$0] }
            .map { (track: $0, key: cacheKey(for: $0)) }
            .filter { StreamCache.shared.stream(forKey: $0.key) == nil }
        guard !jobs.isEmpty else { return }

        prefetchTask = Task {
            for job in jobs {
                if Task.isCancelled { return }
                guard let stream = try? await AudioSource.resolve(track: job.track, quality: quality) else { continue }
                StreamCache.shared.store(stream, forKey: job.key)
            }
        }
    }

    /// 列表页拿到曲目后调用：先把前几首解析好，用户翻列表的时间就够用了
    func prewarm(tracks: [Track], limit: Int = 3) {
        let quality = self.quality()
        let jobs = tracks
            .prefix(limit)
            .map { (track: $0, key: cacheKey(for: $0)) }
            .filter { StreamCache.shared.stream(forKey: $0.key) == nil }
        guard !jobs.isEmpty else { return }

        Task.detached(priority: .utility) {
            for job in jobs {
                guard let stream = try? await AudioSource.resolve(track: job.track, quality: quality) else { continue }
                StreamCache.shared.store(stream, forKey: job.key)
            }
        }
    }

    private func start(
        stream: AudioStream,
        autoPlay: Bool,
        token: UUID,
        cacheable: Bool = false,
        cacheSource: String? = nil
    ) {
        guard loadToken == token, let track = currentTrack else { return }

        currentStream = stream
        currentStreamSource = cacheSource ?? activeSource
        // 只有 muxed 流（format 18）才有画面；纯音频流保持封面
        showsVideo = stream.mime.hasPrefix("video")
        Diagnostics.mark("showsVideo=\(showsVideo) mime=\(stream.mime)")

        // YouTube 直链必须经本地代理：AVPlayer 会用自己的 UA 请求 googlevideo，
        // 与签发直链的客户端身份不一致就 403。代理还能替它带上 pot、走系统代理。
        // 这里每次播放都重新登记一次，所以缓存里存的是上游地址，重启也不会指向死端口。
        var itemURL = stream.url
        if stream.viaProxy == true, stream.url.host?.contains("127.0.0.1") != true {
            // key 必须和解析层登记的一致，否则会多建一条没有「重解析补救」的路由
            let idPart = track.videoId.isEmpty ? String(abs(stream.url.absoluteString.hashValue)) : track.videoId
            let key = "yt-\(stream.itag)-\(idPart)"
            if let local = LocalStreamProxy.shared.register(
                upstream: stream.url,
                userAgent: stream.userAgent ?? StreamResolver.clientUserAgent,
                mime: stream.mime, key: key) {
                itemURL = local
                Diagnostics.mark("build item · 经本地代理 \(local.port ?? 0) src=\(currentStreamSource ?? "nil")")
            } else {
                Diagnostics.mark("build item · 代理由启用失败，回落直链")
            }
        }

        // AVURLAsset/AVPlayerItem 创建可能抛 ObjC 异常，Swift 的 try? 接不住。
        // 尤其 `AVURLAssetHTTPHeaderFieldsKey` 是私有键：iOS 侧认，macOS 侧的
        // AVFoundation 有版本会直接抛 unrecognized option —— 这正是「一按播放就退」
        // 这种死法。所以 Mac 侧一律裸 URL，带 header 的尝试只留给 iOS。
        var builtItem: AVPlayerItem?
        #if targetEnvironment(macCatalyst)
        Diagnostics.mark("build item · mac src=\(currentStreamSource ?? "nil")")
        ExceptionGuard.run("AVURLAsset(裸)") {
            builtItem = AVPlayerItem(asset: AVURLAsset(url: itemURL))
        }
        #else
        let userAgent = stream.userAgent ?? StreamResolver.clientUserAgent
        ExceptionGuard.run("AVURLAsset(+headers)") {
            let asset = AVURLAsset(
                url: itemURL,
                options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]]
            )
            builtItem = AVPlayerItem(asset: asset)
        }
        if builtItem == nil {
            ExceptionGuard.run("AVURLAsset(裸)") {
                builtItem = AVPlayerItem(asset: AVURLAsset(url: itemURL))
            }
        }
        #endif
        guard let item = builtItem else {
            Diagnostics.mark("build item failed")
            self.isLoading = false
            self.errorText = String(format: L("Playback failed: %@"), L("Couldn't build the playback item."))
            return
        }
        // 攒 15 秒才起播在弱网下就是"点了没反应"；4 秒足够扛住抖动，先出声再继续缓冲
        item.preferredForwardBufferDuration = 4
        // 注：想过在这里用 mediaSelectionGroup 摘掉视频轨（受保护视频只有合体的 format 18 可读），
        // 但那是**同步** API，会等资源加载完才返回 —— 慢网下实测卡 15 秒才起播，
        // 比省下的 360p 解码开销贵得多，所以不做。
        Diagnostics.mark("build item · \(stream.mime) · \(stream.url.host ?? "-")")
        observeItem(item)
        observeProgress()
        ExceptionGuard.run("replaceCurrentItem") {
            self.player.replaceCurrentItem(with: item)
        }
        isLoading = false
        // 重试成功后要把上一轮的错误文案清掉，否则会一边出声一边挂着红字
        errorText = nil

        Library.shared.addRecent(track)
        PlayHistory.shared.record(track)
        loadArtworkIfNeeded()

        if autoPlay {
            // Catalyst 上没有 AVAudioSession 这回事（音频路由交给系统），
            // 这里以前漏了平台判断：Mac 版一点播放就走到这一行，直接崩。
            #if !targetEnvironment(macCatalyst)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            Diagnostics.mark("player.play()")
            ExceptionGuard.run("player.play") {
                self.player.play()
            }
        }
        updateNowPlaying()
        Diagnostics.mark("start done")
        // 只缓存「能确定就是这首歌」的流（同源 id 直链 / 明确的 videoId）。
        // 按歌名在第三方站搜出来的版本一律不落盘：错配一次，那份文件就会
        // 永久顶着这首歌，之后切源、关音源都绕不过去。
        if cacheable, let source = cacheSource, source != "local", source != "cache" {
            AudioCache.shared.store(
                from: stream.url,
                for: track,
                mime: stream.mime,
                userAgent: stream.userAgent ?? StreamResolver.clientUserAgent,
                source: source,
                quality: quality(),
                verified: true
            )
        }
        prefetchUpcoming()
    }

    private func handleTrackEnded() {
        if repeatMode == .one {
            seek(to: 0)
            resume()
            return
        }
        next()
    }

    // MARK: - Now Playing

    private func updateNowPlaying() {
        guard let track = currentTrack else {
            NowPlayingBridge.clear()
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: max(duration, Double(track.duration)),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let album = track.album, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        // 封面尺寸为 0 时 MPMediaItemArtwork 也会抛异常（网络图偶尔是空图），所以先判
        if let urlString = track.artwork,
           let image = artworkCache[urlString],
           image.size.width > 0, image.size.height > 0 {
            ExceptionGuard.run("MPMediaItemArtwork") {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            }
        }
        // 所有 MediaPlayer 写操作都走桥：Catalyst 上 playbackState 这类 setter
        // 可能不存在，直接调就是 unrecognized selector → 进程当场退出。
        NowPlayingBridge.publish(info, playing: isPlaying)
        Diagnostics.mark("nowPlaying ← \(track.title)")
    }

    private func loadArtworkIfNeeded() {
        guard let track = currentTrack,
              let urlString = track.artwork,
              artworkCache[urlString] == nil,
              let url = URL(string: urlString) else { return }

        Task { [weak self] in
            guard let self = self else { return }
            guard let image = await ImageLoader.shared.image(for: url) else { return }
            DispatchQueue.main.async {
                self.artworkCache[urlString] = image
                self.updateNowPlaying()
            }
        }
    }

    // MARK: - 播放状态观测（诊断用）

    private static func name(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: return "paused"
        case .waitingToPlayAtSpecifiedRate: return "waiting"
        case .playing: return "playing"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private static func itemStatusName(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .readyToPlay: return "readyToPlay"
        case .failed: return "failed"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
