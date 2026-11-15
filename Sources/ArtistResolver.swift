import Foundation

/// 艺人准入校验（白名单）。
///
/// 为什么需要：曲目元数据里的「艺人」是自由文本，混着大量派生账号 ——
/// `周杰伦微博台`、`单田芳评书&喜马拉雅`、`宋雨琦（雨琦）` 这种，
/// 名字里含真艺人但不是本人。只靠关键词黑名单永远堵不完。
///
/// 判定标准只有一条：**网易云艺人库里存在一个归一化后完全等于它的艺人**。
/// 找不到就不进艺人区 —— 宁可搜不到，也不给用户点一个假艺人。
///
/// 结果落盘缓存：命中 90 天，未命中 7 天。一次搜索最多校验 6 个候选，
/// 之后都走缓存，不会每次都发请求。
enum ArtistResolver {

    private struct Entry: Codable {
        /// 网易云艺人 id；0 表示「查过，不存在」
        var id: Int
        /// 写入时间（timeIntervalSince1970）
        var ts: Double
    }

    private static let storeKey = "melo.artistIndex.v1"
    private static let positiveTTL: Double = 90 * 24 * 3600
    private static let negativeTTL: Double = 7 * 24 * 3600
    private static let lock = NSLock()

    // MARK: - 缓存

    private static func loadStore() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func saveStore(_ store: [String: Entry]) {
        // 顺手清理过期项，避免无限增长。
        // 注意别用 `store.filter { entry in entry.ts ... }`：字典元素是带标签的元组，
        // `entry.ts` 不成立，编译器会转而尝试 Predicate 重载并报错。
        let now = Date().timeIntervalSince1970
        var fresh: [String: Entry] = [:]
        for (key, entry) in store {
            let ttl = entry.id > 0 ? positiveTTL : negativeTTL
            if now - entry.ts < ttl { fresh[key] = entry }
        }
        if let data = try? JSONEncoder().encode(fresh) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    /// 同步查缓存：true 已知是艺人 / false 已知不是 / nil 没查过
    static func cachedKnown(_ name: String) -> Bool? {
        let key = ArtistName.key(ArtistName.primary(name))
        guard !key.isEmpty else { return false }
        lock.lock()
        let store = loadStore()
        lock.unlock()
        guard let entry = store[key] else { return nil }
        let now = Date().timeIntervalSince1970
        let ttl = entry.id > 0 ? positiveTTL : negativeTTL
        guard now - entry.ts < ttl else { return nil }
        return entry.id > 0
    }

    private static func write(_ name: String, id: Int) {
        let key = ArtistName.key(ArtistName.primary(name))
        guard !key.isEmpty else { return }
        lock.lock()
        var store = loadStore()
        store[key] = Entry(id: id, ts: Date().timeIntervalSince1970)
        saveStore(store)
        lock.unlock()
    }

    // MARK: - 校验

    /// 精确命中才返回 id。`周杰伦微博台` 会被判为不存在（归一化后不等于「周杰伦」）。
    static func resolve(_ name: String) async -> Int? {
        let clean = ArtistName.primary(name)
        guard ArtistName.isPlausible(clean) else { return nil }
        if let known = cachedKnown(clean) {
            if known, let entry = entryFor(clean), entry > 0 { return entry }
            if !known { return nil }
        }
        let id = await ArtistInfo.neteaseArtistID(name: clean)
        write(clean, id: id ?? 0)
        return id
    }

    private static func entryFor(_ name: String) -> Int? {
        let key = ArtistName.key(ArtistName.primary(name))
        lock.lock()
        let store = loadStore()
        lock.unlock()
        guard let entry = store[key] else { return nil }
        return entry.id
    }

    /// 只保留能在艺人库里精确命中的名字（保持原顺序、去重）
    static func filter(_ names: [String]) async -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        // 最多校验 8 个：一次搜索的艺人区本来也不会更多，避免把接口打出限流
        for name in names.prefix(8) {
            let clean = ArtistName.primary(name)
            guard ArtistName.isPlausible(clean) else { continue }
            let key = ArtistName.key(clean)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            if await resolve(clean) != nil { out.append(clean) }
        }
        return out
    }

    /// 后台清洗：把缓存里已知「不存在」的艺人从艺人库删掉
    static func pruneSavedArtists(limit: Int = 12) async {
        let saved = ArtistStore.savedNames()
        guard !saved.isEmpty else { return }
        var checked = 0
        for name in saved {
            if checked >= limit { break }
            if cachedKnown(name) != nil { continue }
            checked += 1
            _ = await resolve(name)
        }
        ArtistStore.dropRejected()
    }
}
