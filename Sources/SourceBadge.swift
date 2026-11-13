import Foundation

/// 歌曲行右侧的来源角标：让用户一眼看出这首歌是哪个音源给的。
/// 搜索结果页和艺人页共用，VIP 信息并进去，不丢。
/// 记录每首歌「实际播放时命中的音源」。列表角标以前只读 track.source（曲库出处），
/// 周杰伦的歌强制走歌曲宝后角标还写着「网易云」就是这个错。解析成功时记一笔，
/// sourceBadge 优先读这里，没播过的退回强制规则 / 曲库出处。
enum ResolvedSources {
    private static var map: [String: String] = [:]
    static func record(_ id: String, _ source: String) {
        if !id.isEmpty { map[id] = source }
    }
    static func of(_ id: String) -> String? { map[id] }
    static func clear() { map.removeAll() }
}

/// 指定艺人的歌一律优先走的音源。用户要求周杰伦全部用歌曲宝（国内源对这批歌
/// 基本只给 VIP 死链或 KTV / 翻唱，歌曲宝按「歌名 + 艺人」实搜比对对上就是原唱）。
/// 不硬锁：歌曲宝被风控 / 站内没有时仍回退原链路，避免整批没声。
enum ForcedSource {
    private static let gequbaoArtists = ["周杰伦"]

    static func forTrack(_ track: Track) -> String? {
        let primary = track.artist
            .components(separatedBy: CharacterSet(charactersIn: ",，/、&·"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = Zh.simplified(primary)
        guard !normalized.isEmpty else { return nil }
        return gequbaoArtists.first(where: { normalized.contains($0) }).map { _ in "gequbao" }
    }

    static func displaySource(_ track: Track) -> String? { forTrack(track) }
}

func sourceBadge(_ track: Track) -> String? {
    let effective = ResolvedSources.of(track.id)
        ?? ForcedSource.displaySource(track)
        ?? track.source
    let source: String?
    switch effective?.lowercased() {
    case "flachi": source = "Hi·FLAC"
    case "kugou": source = "酷狗"
    case "kuwo": source = "酷我"
    case "netease": source = "网易云"
    case "qq": source = "QQ"
    case "youtube": source = "YT"
    case "gequbao": source = "歌曲宝"
    default: source = nil
    }
    // 已确定是歌曲宝就别再挂「VIP」：那是曲库出处带来的标记，容易误导
    let vip = (track.isVip && source != "歌曲宝") ? "VIP" : nil
    let parts = [source, vip].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: "·")
}

/// 非原唱（翻唱 / DJ / Live / 伴奏 / 纯音乐 …）的标题标记词，命中任何一个就不打「原唱」标。
/// 与艺人页的过滤词保持一致，避免两边各一套。
private let nonOriginalMarkers = [
    "翻唱", "cover", "dj", "remix", "混音", "伴奏", "纯音乐", "纯享", "ktv",
    "live", "演唱会", "现场", "串烧", "合唱", "对唱", "铃声", "片段", "试听",
    "钢琴版", "吉他版", "小提琴版", "古筝版", "女声版", "男声版", "抖音", "车载",
    "慢摇", "的士高", "disco", "纯人声", "acoustic", "instrumental",
    // 标题里自己写着「原唱 某某」的，是别人翻录的版本（实测搜「晴天」第一条
    // 「晴天 (原唱 周杰伦) / RyaVocal」就被错误地打了原唱标）
    "原唱", "翻自", "原曲", "改编", "重制", "重置",
    "弦乐版", "钢琴曲", "piano", "ver."
]

/// 这条曲目是不是「原唱」版本。
///
/// 以前只看标题里有没有翻唱 / DJ / Live 等标记，于是「标题写得很干净、其实是别人
/// 翻唱的版本」也被打了【原唱】——这是误标来源。现在加上艺人校验：有上下文艺人
/// （搜索词命中的艺人、艺人页名字、专辑艺人）时，必须这位艺人才算原唱；没有上下文
/// 时退回只看标题。
func isOriginalVersion(_ track: Track, contextArtist: String? = nil) -> Bool {
    if track.isUnavailable { return false }
    let title = track.title.lowercased()
    guard !nonOriginalMarkers.contains(where: { title.contains($0) }) else { return false }

    if let ctx = contextArtist?.trimmingCharacters(in: .whitespacesAndNewlines), ctx.count >= 2 {
        let wanted = Zh.simplified(ctx.lowercased())
        let actual = Zh.simplified(track.artist.lowercased())
        let primary = actual
            .components(separatedBy: CharacterSet(charactersIn: ",，/、&·"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !primary.isEmpty && !primary.contains(wanted) && !wanted.contains(primary) {
            return false
        }
    }
    return true
}

/// 从本次搜索结果里提出相关艺人：只保留与查询词真正相关的（名字 token 对得上），
/// 翻唱者、合唱另一方的名字不再混进来 —— 这是「搜周杰出现周杰伦」那个 bug 的修法。
func extractArtists(term: String, tracks: [Track]) -> [String] {
    var counts: [(String, Int)] = []
    var index: [String: Int] = [:]
    for track in tracks {
        // 多艺人合唱取第一个，别把 "A, B" 当成一个艺人
        let primary = track.artist
            .components(separatedBy: CharacterSet(charactersIn: "、,，/&"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lower = primary.lowercased()
        guard !primary.isEmpty, lower != "unknown artist", primary != "未知艺人" else { continue }
        if let slot = index[lower] {
            counts[slot].1 += 1
        } else {
            index[lower] = counts.count
            counts.append((primary, 1))
        }
    }
    let sorted = counts.sorted { $0.1 > $1.1 }.map(\.0)
    // 只用「查询词对得上」的艺人，避免把翻唱者当成搜索结果里的艺人
    let related = sorted.filter { artistMatches(term: term, artist: $0) }
    return Array(related.prefix(6))
}

/// 艺人名匹配。
///
/// 以前是「互相包含」，所以查「周杰」会把「周杰伦」也收进来，点进去看到的却是周杰伦的专辑。
/// 现在按分隔符拆成 token 后**整段相等**才算匹配；只有单字查询（「李」）才用前缀匹配，
/// 否则「李」永远搜不到李健 / 李荣浩。
func artistMatches(term: String, artist: String) -> Bool {
    let t = normalizeArtistKey(term)
    let a = normalizeArtistKey(artist)
    guard !t.isEmpty, !a.isEmpty else { return false }
    let separators = CharacterSet(charactersIn: "/,、&()（） ")
    let termTokens = t.components(separatedBy: separators).filter { !$0.isEmpty }
    let artistTokens = a.components(separatedBy: separators).filter { !$0.isEmpty }
    guard !termTokens.isEmpty, !artistTokens.isEmpty else { return false }

    let singleCharQuery = termTokens.count == 1 && termTokens[0].count == 1
    for termToken in termTokens {
        for artistToken in artistTokens {
            if termToken == artistToken { return true }
            if singleCharQuery, termToken.count == 1, artistToken.hasPrefix(termToken) { return true }
        }
    }
    return false
}

/// 第一顺位就是查询词本人（用于把「本人的歌」和「跟别人的合唱 / 助阵」分开排序）
func primaryArtistMatches(term: String, artist: String) -> Bool {
    let first = artist
        .components(separatedBy: CharacterSet(charactersIn: ",，、/& "))
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return !first.isEmpty && artistMatches(term: term, artist: first)
}

private func normalizeArtistKey(_ value: String) -> String {
    value.lowercased().replacingOccurrences(of: " ", with: "")
}
