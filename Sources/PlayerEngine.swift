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
    private var streamCache: [String: (stream: AudioStream, date: Date)] = [:]
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
        player.automaticallyWaitsToMinimizeStalling = true
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
        streamCache.removeValue(forKey: track.videoId)
        load(autoPlay: true, resetBudget: false)
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
    }

    func playSingle(_ track: Track) {
        if let existing = queue.firstIndex(of: track) {
            index = existing
            loadCurrent(autoPlay: true)
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
            var candidate = Int.random(in: 0..<queue.count)
            if candidate == index { candidate = (candidate + 1) % queue.count }
            index = candidate
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
                self.retryCurrentTrack()
            }
    }

    // MARK: - Loading

    func loadCurrent(autoPlay: Bool) {
        load(autoPlay: autoPlay, resetBudget: true)
    }

    private func load(autoPlay: Bool, resetBudget: Bool) {
        if resetBudget { retryBudget = 1 }
        guard let track = currentTrack else { return }

        let token = UUID()
        loadToken = token
        isLoading = true
        errorText = nil
        elapsed = 0
        duration = Double(track.duration)
        updateNowPlaying()

        let qualityRaw = UserDefaults.standard.string(forKey: "melo.quality") ?? StreamResolver.Quality.high.rawValue
        let quality = StreamResolver.Quality(rawValue: qualityRaw) ?? .high

        if let cached = streamCache[track.videoId], Date().timeIntervalSince(cached.date) < 3000 {
            start(stream: cached.stream, autoPlay: autoPlay, token: token)
            return
        }

        Task { [weak self] in
            do {
                let stream = try await AudioSource.resolve(track: track, quality: quality)
                DispatchQueue.main.async {
                    guard let self = self, self.loadToken == token else { return }
                    self.streamCache[track.videoId] = (stream, Date())
                    self.start(stream: stream, autoPlay: autoPlay, token: token)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self = self, self.loadToken == token else { return }
                    self.isLoading = false
                    self.isPlaying = false
                    self.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.updateNowPlaying()
                }
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
        item.preferredForwardBufferDuration = 15
        observeItem(item)
        player.replaceCurrentItem(with: item)
        isLoading = false

        Library.shared.addRecent(track)
        loadArtworkIfNeeded()

        if autoPlay {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
        }
        updateNowPlaying()
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
