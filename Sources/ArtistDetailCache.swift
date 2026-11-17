import Foundation

/// 艺人详情页的内存缓存。
///
/// 问题：艺人页是 NavigationLink 推出来的，每次「退出再打开」视图会重建，
/// `didLoad` 标记随之重置，于是 profile / 专辑 / 歌曲全量重新拉一遍，
/// 显得「每次进来都加载很慢」。
///
/// 这里把最近看过的艺人的完整结果缓在内存里，二次进入直接秒开，
/// 后台再静默刷新（数据可能已更新）。缓存只留内存、不落盘，避免
/// 专辑封面/简介这类可能过期的数据永久占位；上限 30 个艺人，LRU 淘汰。
enum ArtistDetailCache {

    struct Entry {
        let profile: ArtistInfo.Profile?
        let albums: [DomesticSource.DomesticAlbum]
        let tracks: [Track]
    }

    private static let maxEntries = 30
    private static var store: [String: Entry] = [:]
    private static var order: [String] = []   // 最近访问在前

    private static func key(_ name: String) -> String {
        ArtistName.key(ArtistName.primary(name))
    }

    static func get(_ name: String) -> Entry? {
        let k = key(name)
        guard !k.isEmpty else { return nil }
        return store[k]
    }

    static func set(_ name: String, profile: ArtistInfo.Profile?,
                    albums: [DomesticSource.DomesticAlbum], tracks: [Track]) {
        let k = key(name)
        guard !k.isEmpty else { return }
        store[k] = Entry(profile: profile, albums: albums, tracks: tracks)
        // 提到最前
        order.removeAll { $0 == k }
        order.insert(k, at: 0)
        // 超限淘汰最旧的
        while order.count > maxEntries {
            let victim = order.removeLast()
            store.removeValue(forKey: victim)
        }
    }
}
