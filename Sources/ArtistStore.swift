import Foundation

/// 搜索页「艺人」模块的数据源。
///
/// 两部分组成：内置一批常见艺人（第一次打开就有内容），加上用户搜过的
/// 艺人（自动记下来、排最前，最多 12 个）。只存名字，专辑和歌曲都是
/// 点进去时按名字实时拉的，不写死离线数据。
enum ArtistStore {

    private static let key = "melo.savedArtists"
    private static let max = 12

    static let builtIn: [String] = [
        "周杰伦", "林俊杰", "陈奕迅", "邓紫棋", "周深",
        "五月天", "薛之谦", "毛不易", "张学友", "Taylor Swift"
    ]

    private static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// 最近保存的排前面，内置补齐，去重
    static func all() -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for name in load() + builtIn {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lower = trimmed.lowercased()
            if seen.insert(lower).inserted { out.append(trimmed) }
            if out.count >= max { break }
        }
        return out
    }

    static func isSaved(_ name: String) -> Bool {
        load().contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    static func remember(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2, clean != L("Unknown Artist") else { return }
        var list = load().filter { $0.caseInsensitiveCompare(clean) != .orderedSame }
        list.insert(clean, at: 0)
        if list.count > max { list = Array(list.prefix(max)) }
        UserDefaults.standard.set(list, forKey: key)
    }
}
