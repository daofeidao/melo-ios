import Foundation

/// 艺人详情页缓存（内存 + 磁盘）。
///
/// 艺人页是 NavigationLink 推出来的，每次退出再进来视图都会重建，`didLoad` 标记
/// 随之重置，profile / 专辑 / 歌曲全量重新拉一遍 —— 表现就是「每次进来都转圈」。
///
/// 原来只缓在内存里，App 一重启就清空：冷启动后第一次点任何艺人，包括自己收藏的，
/// 都得重新等一串网络请求。
///
/// 现在同时落盘：
///   - **收藏的艺人永久有效** —— 用户在意的人，任何时候打开都该秒开；
///   - 其余艺人 12 小时过期 —— 简介、专辑这类东西会更新，不能一直拿旧的顶；
///   - 上限 60 个，LRU 淘汰，文件本身也就几十 KB。
///
/// 线程约定：所有读写都在主线程（只有写盘是异步的，用快照，不碰共享状态）。
enum ArtistDetailCache {

    struct Entry: Codable {
        let profile: ArtistInfo.Profile?
        let albums: [DomesticSource.DomesticAlbum]
        let tracks: [Track]
        let savedAt: Date
    }

    /// 写盘用的整体结构
    private struct Snapshot: Codable {
        let entries: [String: Entry]
        let order: [String]
    }

    private static let ttl: TimeInterval = 12 * 3600
    private static let maxEntries = 60

    private static var store: [String: Entry] = [:]
    private static var order: [String] = []   // 最近访问在前
    private static var loaded = false
    private static let io = DispatchQueue(label: "melo.artistcache", qos: .utility)

    private static func key(_ name: String) -> String {
        ArtistName.key(ArtistName.primary(name))
    }

    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Melo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("artist-cache.json")
    }

    /// - Parameter ignoreExpiry: 收藏的艺人传 true，跳过 12 小时期限
    static func get(_ name: String, ignoreExpiry: Bool = false) -> Entry? {
        loadIfNeeded()
        let k = key(name)
        guard !k.isEmpty, let entry = store[k] else { return nil }

        if !ignoreExpiry, Date().timeIntervalSince(entry.savedAt) > ttl {
            store.removeValue(forKey: k)
            order.removeAll { $0 == k }
            scheduleSave()
            return nil
        }
        // 提到最前（LRU 依据）
        order.removeAll { $0 == k }
        order.insert(k, at: 0)
        return entry
    }

    static func set(_ name: String, profile: ArtistInfo.Profile?,
                    albums: [DomesticSource.DomesticAlbum], tracks: [Track]) {
        loadIfNeeded()
        let k = key(name)
        guard !k.isEmpty else { return }
        store[k] = Entry(profile: profile, albums: albums, tracks: tracks, savedAt: Date())
        order.removeAll { $0 == k }
        order.insert(k, at: 0)
        while order.count > maxEntries {
            let victim = order.removeLast()
            store.removeValue(forKey: victim)
        }
        scheduleSave()
    }


    static func clear() {
        store = [:]
        order = []
        loaded = true
        scheduleSave()
    }

    // MARK: - 落盘

    private static func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }

        store = snapshot.entries
        order = snapshot.order.filter { store[$0] != nil }
        // 文件里可能残留已过期的
        let now = Date()
        let expired = store.filter { now.timeIntervalSince($0.value.savedAt) > ttl }.map(\.key)
        if !expired.isEmpty {
            expired.forEach { store.removeValue(forKey: $0) }
            order.removeAll { expired.contains($0) }
            scheduleSave()
        }
    }

    private static func scheduleSave() {
        guard let url = fileURL else { return }
        let snapshot = Snapshot(entries: store, order: order)
        io.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
