import Foundation

struct LyricLine: Identifiable, Equatable {
    let id = UUID()
    let time: Double
    let text: String
}

/// 歌词加载。
///
/// 为什么统一走网易云而不是「哪个音源用哪个」：酷狗的 krcs 域名在不少网络下会超时
/// （实测本机 15 秒都读不到响应），而网易云的 lrc 接口免费、稳定、返回标准 LRC。
/// 按「歌名 + 艺人」也能匹配到同一首歌的歌词，和歌本身来自哪个平台无关。
enum LyricsLoader {

    private static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    static func load(for track: Track) async -> [LyricLine] {
        // 网易云的歌本身就有 ID，直接取，不用再搜
        if track.source == PlaylistPlatform.netease.rawValue,
           let id = track.sourceID, !id.isEmpty,
           let lrc = await fetch(id: id),
           let lines = parse(lrc), !lines.isEmpty {
            return lines
        }

        guard let matched = await match(track), let lrc = await fetch(id: matched), let lines = parse(lrc) else {
            return []
        }
        return lines
    }

    // MARK: - 匹配

    private static func match(_ track: Track) async -> String? {
        let query = [track.title, track.artist].filter { !$0.isEmpty }.joined(separator: " ")
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://music.163.com/api/search/get/web?s=\(encoded)&type=1&limit=6&offset=0")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(DomesticSource.declaredIP, forHTTPHeaderField: "X-Real-IP")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let songs = JS.array(JS.dict(root["result"])?["songs"])
        else { return nil }

        let wantedTitle = DomesticSource.normalize(track.title)
        let wantedArtist = DomesticSource.normalize(track.artist)
        guard !wantedTitle.isEmpty else { return nil }

        var best: (id: String, score: Int)?
        for raw in songs {
            guard let song = JS.dict(raw),
                  let title = JS.string(song["name"]),
                  let id = JS.int(song["id"]).map(String.init) else { continue }

            let candidateTitle = DomesticSource.normalize(title)
            var score: Int
            if candidateTitle == wantedTitle {
                score = 100
            } else if candidateTitle.contains(wantedTitle) || wantedTitle.contains(candidateTitle) {
                score = 50
            } else {
                continue
            }

            if !wantedArtist.isEmpty {
                let names = (JS.array(song["artists"]) ?? [])
                    .compactMap { JS.dict($0) }
                    .compactMap { JS.string($0["name"]) }
                    .joined(separator: ",")
                let candidateArtist = DomesticSource.normalize(names)
                if candidateArtist.contains(wantedArtist) || wantedArtist.contains(candidateArtist) {
                    score += 40
                }
            }

            if score > (best?.score ?? 0) {
                best = (id, score)
            }
        }

        return best?.id
    }

    // MARK: - 抓取

    private static func fetch(id: String) async -> String? {
        guard let url = URL(string: "https://music.163.com/api/song/lyric?id=\(id)&lv=-1&kv=-1&tv=-1") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(DomesticSource.declaredIP, forHTTPHeaderField: "X-Real-IP")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let lrc = JS.dict(root["lrc"]),
              let text = JS.string(lrc["lyric"]), !text.isEmpty
        else { return nil }
        return text
    }

    // MARK: - LRC 解析

    /// 支持一行多个时间标签（`[00:12.00][01:20.00]副歌`），毫秒位数 2 或 3 位都认
    static func parse(_ lrc: String) -> [LyricLine]? {
        let pattern = try? NSRegularExpression(pattern: "\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]", options: [])

        var lines: [LyricLine] = []
        for raw in lrc.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard let regex = pattern, !line.isEmpty else { continue }
            let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
            guard let last = matches.last else { continue }

            let textStart = line.index(line.startIndex, offsetBy: last.range.location + last.range.length)
            let text = String(line[textStart...]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            for match in matches {
                guard let minuteText = group(match, 1, in: line), let minute = Int(minuteText),
                      let secondText = group(match, 2, in: line), let second = Int(secondText) else { continue }
                let fractionText = group(match, 3, in: line) ?? ""
                let fraction: Double
                switch fractionText.count {
                case 0: fraction = 0
                case 1: fraction = (Double(fractionText) ?? 0) / 10
                case 2: fraction = (Double(fractionText) ?? 0) / 100
                default: fraction = (Double(fractionText) ?? 0) / 1000
                }
                lines.append(LyricLine(time: Double(minute) * 60 + Double(second) + fraction, text: text))
            }
        }

        guard !lines.isEmpty else { return nil }
        lines.sort { $0.time < $1.time }
        return lines
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else { return nil }
        return String(line[swiftRange])
    }
}
