import Foundation

private struct ChartCacheFile: Codable {
    var savedAt: Date
    var items: [String: [Track]]
}

/// 排行榜歌单的曲目缓存。
///
/// 目标：进 App 就在后台把热门歌单的内容抓下来，点卡片时直接是歌单列表，
/// 不需要先走「导入」那一步。抓下来的曲目带着原平台 ID，所以点开就能直接播
/// （走国内直链，不必等 YouTube 匹配）。
final class ChartLibrary: ObservableObject {

    static let shared = ChartLibrary()

    @Published private(set) var tracks: [String: [Track]] = [:]

    private let ttl: TimeInterval = 6 * 3600
    private let lock = NSLock()
    private var inflight: [String: Task<[Track], Never>] = [:]
    private var didPrefetch = false
    private let io = DispatchQueue(label: "melo.chart-cache", qos: .utility)

    private init() {
        loadFromDisk()
    }

    // MARK: - 读取

    func cached(_ item: ExternalPlaylist) -> [Track]? {
        lock.lock()
        defer { lock.unlock() }
        guard let list = tracks[item.id], !list.isEmpty else { return nil }
        return list
    }

    // MARK: - 抓取

    @discardableResult
    func load(_ item: ExternalPlaylist) async -> [Track] {
        if let hit = cached(item) { return hit }

        lock.lock()
        if let running = inflight[item.id] {
            lock.unlock()
            return await running.value
        }
        let task = Task { [item] () -> [Track] in
            do {
                let remote = try await PlaylistFetcher.fetch(
                    platform: item.platform,
                    id: item.playlistID,
                    isRank: item.isRank
                )
                return remote.songs.map(ChartLibrary.makeTrack)
            } catch {
                return []
            }
        }
        inflight[item.id] = task
        lock.unlock()

        let result = await task.value

        lock.lock()
        inflight[item.id] = nil
        lock.unlock()

        if !result.isEmpty {
            DispatchQueue.main.async {
                self.tracks[item.id] = result
                self.saveToDisk()
            }
        }
        return result
    }

    /// 后台预热：网易云 + QQ 各取前几个热门歌单，点开就有列表。
    /// 缓存已经热了就跳过 —— 每次冷启动都重抓 12 个歌单没有意义，
    /// 白白拖慢首屏还多耗流量。
    func prefetchHot() async {
        lock.lock()
        let alreadyWarm = didPrefetch || tracks.count >= 8
        didPrefetch = true
        lock.unlock()
        guard !alreadyWarm else { return }

        for platform in [PlaylistPlatform.netease, .qq] {
            if Task.isCancelled { return }
            guard let list = try? await HotPlaylists.fetch(platform), !list.isEmpty else {
                NSLog("SMOKE_CHART \(platform.rawValue) playlists=0")
                continue
            }
            var loaded = 0
            for item in list.prefix(6) {
                if Task.isCancelled { return }
                if !(await load(item)).isEmpty { loaded += 1 }
            }
            NSLog("SMOKE_CHART \(platform.rawValue) playlists=\(list.count) loaded=\(loaded)")
        }
    }

    static func makeTrack(_ song: RemoteSong) -> Track {
        Track(
            videoId: "",
            title: song.title,
            artist: song.artist,
            album: song.album,
            duration: song.duration,
            artwork: song.artwork,
            source: song.source.rawValue,
            sourceID: song.sourceID
        )
    }

    // MARK: - 落盘

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("chart-library.json")
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(ChartCacheFile.self, from: data) else { return }
        guard Date().timeIntervalSince(file.savedAt) < ttl else { return }
        tracks = file.items
    }

    private func saveToDisk() {
        let snapshot = ChartCacheFile(savedAt: Date(), items: tracks)
        let target = fileURL
        io.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: target, options: .atomic)
        }
    }
}
