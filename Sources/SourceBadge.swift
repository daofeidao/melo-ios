import Foundation

/// 歌曲行右侧的来源角标：让用户一眼看出这首歌是哪个音源给的。
/// 搜索结果页和艺人页共用，VIP 信息并进去，不丢。
func sourceBadge(_ track: Track) -> String? {
    let source: String?
    switch track.source?.lowercased() {
    case "flachi": source = "Hi·FLAC"
    case "kugou": source = "酷狗"
    case "kuwo": source = "酷我"
    case "netease": source = "网易云"
    case "qq": source = "QQ"
    case "youtube": source = "YT"
    case "gequbao": source = "歌曲宝"
    default: source = nil
    }
    let parts = [source, track.isVip ? "VIP" : nil].compactMap { $0 }
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

/// 这条曲目是不是「原唱」版本：标题里没有翻唱 / DJ / Live / 伴奏等标记，且不是灰显占位。
/// 用于在曲目行打【原唱】标，让用户一眼确认放的是正版原唱、不是同名魔改版。
func isOriginalVersion(_ track: Track) -> Bool {
    if track.isUnavailable { return false }
    let title = track.title.lowercased()
    return !nonOriginalMarkers.contains { title.contains($0) }
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
