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
    @Published var repeatMode: RepeatMode = .off
    @Published var isShuffle = false
    /// 点歌后是否直接展开全屏播放页（Apple Music 的行为）
    @Published var opensFullPlayer = false

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?
    private var retryBudget = 1
    private var itemStatusCancellable: AnyCancellable?
    private var loadToken = UUID()
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
    }

    // MARK: - Setup

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
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
    }

    private func retryCurrentTrack() {
        guard retryBudget > 0, let track = currentTrack else { return }
        retryBudget -= 1
        StreamCache.shared.remove(forKey: cacheKey(for: track))
        load(autoPlay: true, resetBudget: false, keepError: true)
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

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
        queue = tracks
        index = min(max(0, startIndex), tracks.count - 1)
        loadCurrent(autoPlay: true)
        // 用户点了歌就直接给播放页，不要让他再点一次迷你播放器
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
        try? AVAudioSession.sharedInstance().setActive(true)
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

    /// 用户点「重试」时重置重试预算，允许再解析一次
    func retryCurrent() {
        retryBudget = 1
        errorText = nil
        loadCurrent(autoPlay: true)
    }

    private func observeItem(_ item: AVPlayerItem) {
        itemStatusCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self, status == .failed else { return }
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

    // MARK: - Loading

    func loadCurrent(autoPlay: Bool) {
        load(autoPlay: autoPlay, resetBudget: true)
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

    private func load(autoPlay: Bool, resetBudget: Bool, keepError: Bool = false) {
        if resetBudget { retryBudget = 1 }
        guard let track = currentTrack else { return }

        let token = UUID()
        loadToken = token
        isLoading = true
        if !keepError { errorText = nil }
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

        // 命中缓存（内存或上次落盘）就直接起播，0 网络等待
        if let cached = StreamCache.shared.stream(forKey: key) {
            start(stream: cached, autoPlay: autoPlay, token: token)
            return
        }

        Task { [weak self] in
            do {
                let stream = try await AudioSource.resolve(track: track, quality: quality)
                DispatchQueue.main.async {
                    guard let self = self, self.loadToken == token else { return }
                    StreamCache.shared.store(stream, forKey: key)
                    self.start(stream: stream, autoPlay: autoPlay, token: token)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self = self, self.loadToken == token else { return }
                    self.isLoading = false
                    self.isPlaying = false
                    self.player.replaceCurrentItem(with: nil)
                    self.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

    private func start(stream: AudioStream, autoPlay: Bool, token: UUID) {
        guard loadToken == token, let track = currentTrack else { return }

        let asset = AVURLAsset(
            url: stream.url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": StreamResolver.clientUserAgent]]
        )
        let item = AVPlayerItem(asset: asset)
        // 攒 15 秒才起播在弱网下就是"点了没反应"；4 秒足够扛住抖动，先出声再继续缓冲
        item.preferredForwardBufferDuration = 4
        observeItem(item)
        player.replaceCurrentItem(with: item)
        isLoading = false
        // 重试成功后要把上一轮的错误文案清掉，否则会一边出声一边挂着红字
        errorText = nil

        Library.shared.addRecent(track)
        loadArtworkIfNeeded()

        if autoPlay {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
        }
        updateNowPlaying()
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
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
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
        if let urlString = track.artwork, let image = artworkCache[urlString] {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtworkIfNeeded() {
        guard let track = currentTrack,
              let urlString = track.artwork,
              artworkCache[urlString] == nil,
              let url = URL(string: urlString) else { return }

        Task { [weak self] in
            guard let image = await ImageLoader.shared.image(for: url) else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.artworkCache[urlString] = image
                self.updateNowPlaying()
            }
        }
    }
}
