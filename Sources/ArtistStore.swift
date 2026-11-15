import Foundation

/// 搜索页「艺人」模块的数据源。
///
/// 两部分组成：内置一批常见艺人（第一次打开就有内容），加上用户搜过的
/// 艺人（自动记下来、排最前，最多 60 个）。只存名字，专辑和歌曲都是
/// 点进去时按名字实时拉的，不写死离线数据。
enum ArtistStore {

    private static let key = "melo.savedArtists"
    private static let max = 60

    static let builtIn: [String] = [
        "周杰伦", "林俊杰", "陈奕迅", "邓紫棋", "周深",
        "五月天", "薛之谦", "毛不易", "张学友", "Taylor Swift"
    ]

    private static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// 最近保存的排前面，内置补齐，去重。
    ///
    /// 顺手做存量清理：历史版本存过 `孙楠\u0026那英`、`单田芳评书&喜马拉雅`
    /// 这类脏名（转义未还原、合唱拼成一串），它们在旧版已经被写进 UserDefaults，
    /// 光靠入口过滤是清不掉的 —— 这里读一次就洗一遍，洗完写回，之后不会再复活。
    static func all() -> [String] {
        let raw = load()

        // 1) 先把存量洗干净（只洗 saved，builtIn 是代码里的常量，不用动）
        var cleanedSaved: [String] = []
        var seenSaved = Set<String>()
        for name in raw {
            let clean = ArtistName.primary(name)
            guard ArtistName.isPlausible(clean) else { continue }
            // 已被校验判定「不是真人艺人」的（周杰伦微博台这类派生账号）直接丢掉
            guard ArtistResolver.cachedKnown(clean) != false else { continue }
            let id = ArtistName.key(clean)
            guard !id.isEmpty, seenSaved.insert(id).inserted else { continue }
            cleanedSaved.append(clean)
        }
        // 2) 洗出差异就写回，避免每次启动重复洗、也避免脏名一直留在列表里
        if cleanedSaved != raw {
            UserDefaults.standard.set(Array(cleanedSaved.prefix(max)), forKey: key)
        }

        // 3) 合并内置艺人一起展示
        var out = cleanedSaved
        var seen = seenSaved
        for name in builtIn where out.count < max {
            let id = ArtistName.key(name)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            out.append(name)
        }
        return Array(out.prefix(max))
    }

    static func isSaved(_ name: String) -> Bool {
        let target = ArtistName.key(ArtistName.primary(name))
        guard !target.isEmpty else { return false }
        return load().contains { ArtistName.key(ArtistName.primary($0)) == target }
    }

    static func remember(_ name: String) {
        let clean = ArtistName.primary(name)
        guard ArtistName.isPlausible(clean) else { return }
        guard clean.caseInsensitiveCompare(L("Unknown Artist")) != .orderedSame else { return }

        let target = ArtistName.key(clean)
        var list = load().filter { ArtistName.key(ArtistName.primary($0)) != target }
        list.insert(clean, at: 0)
        if list.count > max { list = Array(list.prefix(max)) }
        UserDefaults.standard.set(list, forKey: key)
    }

    /// 存量原始名单（给后台校验用，不做事先过滤）
    static func savedNames() -> [String] { load() }

    /// 把校验判定为「不存在」的艺人从存量里删掉
    static func dropRejected() {
        let raw = load()
        guard !raw.isEmpty else { return }
        let kept = raw.filter { ArtistResolver.cachedKnown($0) != false }
        if kept != raw {
            UserDefaults.standard.set(Array(kept.prefix(max)), forKey: key)
        }
    }
}
