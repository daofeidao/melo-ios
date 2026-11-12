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
    default: source = nil
    }
    let parts = [source, track.isVip ? "VIP" : nil].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: "·")
}

/// 从本次搜索结果里提出相关艺人：出现次数多的排前，查询词直接命中的顶到最前。
func extractArtists(term: String, tracks: [Track]) -> [String] {
    let normalizedTerm = normalizeArtistKey(term)
    var counts: [(String, Int)] = []
    var index: [String: Int] = [:]
    for track in tracks {
        // 多艺人合唱取第一个，别把 "A, B" 当成一个艺人
        let primary = track.artist
            .components(separatedBy: CharacterSet(charactersIn: "、,，/&"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lower = primary.lowercased()
        guard primary.count >= 2, lower != "unknown artist", primary != "未知艺人" else { continue }
        if let slot = index[lower] {
            counts[slot].1 += 1
        } else {
            index[lower] = counts.count
            counts.append((primary, 1))
        }
    }
    let sorted = counts.sorted { $0.1 > $1.1 }.map(\.0)
    let direct = sorted.first { artistMatches(term: normalizedTerm, artist: $0) }
    var out: [String] = []
    if let direct { out.append(direct) }
    for name in sorted where name != direct {
        if out.count >= 4 { break }
        out.append(name)
    }
    return out
}

func artistMatches(term: String, artist: String) -> Bool {
    let t = normalizeArtistKey(term)
    let a = normalizeArtistKey(artist)
    guard t.count >= 2, a.count >= 2 else { return false }
    return a.contains(t) || t.contains(a)
}

private func normalizeArtistKey(_ value: String) -> String {
    value.lowercased().replacingOccurrences(of: " ", with: "")
}
