import Foundation

/// 排行榜「列表层」的缓存（榜单卡片本身，不是歌单内容）。
///
/// 之前每次切回排行榜 tab 都会重新拉一遍：SwiftUI 重建视图时 `@State hasLoaded`
/// 会被重置，于是又打一轮网络。这里把列表落盘 + 内存各存一份，
/// 6 小时内进来直接用缓存，不再发请求。
///
/// 启动预热（后台 Task）、下拉刷新、页面展示会同时读写，所以全部走锁；
/// 这个类不需要 `@Published` —— 页面是主动读缓存，不是被它驱动刷新。
final class ChartFeed: ObservableObject {

    static let shared = ChartFeed()

    private struct Store: Codable {
        var savedAt: Date
        var lists: [String: [ExternalPlaylist]]
    }

    private let lock = NSLock()
    private var lists: [String: [ExternalPlaylist]] = [:]

    /// YouTube 榜单只放内存：ShelfItem 是带关联值的枚举，没有 Codable，
    /// 落盘要手写一整套编解码。同一次 App 会话内切 tab 复用它就够了。
    private var shelves: [Shelf] = []
    /// 即使 YouTube 抓失败也记一次「本次会话已经试过」，
    /// 否则被墙的用户每次切回排行榜都会白等一轮超时。
    private var shelvesAttempted = false

    private let ttl: TimeInterval = 6 * 3600
    private var savedAt: Date?
    private let io = DispatchQueue(label: "melo.chart-feed", qos: .utility)

    private init() {
        loadFromDisk()
    }

    var isFresh: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let savedAt = savedAt else { return false }
        return Date().timeIntervalSince(savedAt) < ttl
    }

    var shelvesReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return shelvesAttempted
    }

    func markShelvesAttempted() {
        lock.lock(); shelvesAttempted = true; lock.unlock()
    }

    func cached(_ platform: PlaylistPlatform) -> [ExternalPlaylist]? {
        lock.lock(); defer { lock.unlock() }
        guard let list = lists[platform.rawValue], !list.isEmpty else { return nil }
        return list
    }

    func cachedShelves() -> [Shelf] {
        lock.lock(); defer { lock.unlock() }
        return shelves
    }

    func storeShelves(_ list: [Shelf]) {
        guard !list.isEmpty else { return }
        lock.lock(); shelves = list; lock.unlock()
    }

    func store(_ list: [ExternalPlaylist], for platform: PlaylistPlatform) {
        guard !list.isEmpty else { return }
        lock.lock()
        lists[platform.rawValue] = list
        savedAt = Date()
        lock.unlock()
        saveToDisk()
    }

    /// 抓过一轮（哪怕整轮失败、只能继续用旧数据）也把有效期续上，
    /// 否则断网时每次切回排行榜都会再白跑一轮请求。
    func touch() {
        lock.lock(); savedAt = Date(); lock.unlock()
        saveToDisk()
    }

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("chart-feed.json")
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let store = try? decoder.decode(Store.self, from: data) else { return }
        lock.lock()
        lists = store.lists
        savedAt = store.savedAt
        lock.unlock()
    }

    private func saveToDisk() {
        lock.lock()
        let snapshot = Store(savedAt: savedAt ?? Date(), lists: lists)
        lock.unlock()
        let target = fileURL
        io.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: target, options: .atomic)
        }
    }
}
