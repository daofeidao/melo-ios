import Foundation

/// 国内音源（网易云）搜索。
///
/// 存在两个动因：
/// 1. YouTube 在相当一部分出口 IP 上会判定机器人，搜索出来也播不了；
/// 2. 网易云「外链」接口不需要任何签名，返回的是可直接播的 mp3，适合做保底。
///
/// 一个关键坑：请求不带中国境内 IP 时，接口会返回 `{"result":"<hex>"}` 加密体，
/// 解析必然失败。加上 `X-Real-IP` 头即可拿到明文 JSON。
enum DomesticSource {

    static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    /// 声明一个境内 IP，绕开「境外 IP 返回加密体」的反爬策略
    static let declaredIP = "116.25.146.177"

    // MARK: - 搜索

    static func search(query: String, limit: Int = 30) async -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://music.163.com/api/search/get/web?s=\(encoded)&type=1&limit=\(limit)&offset=0")
        else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(declaredIP, forHTTPHeaderField: "X-Real-IP")
        request.setValue(declaredIP, forHTTPHeaderField: "X-Forwarded-For")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = JS.dict(root["result"]),
              let songs = JS.array(result["songs"])
        else { return [] }

        return songs.compactMap { raw -> Track? in
            guard let song = JS.dict(raw),
                  let id = JS.int(song["id"]).map(String.init),
                  let title = JS.string(song["name"]), !title.isEmpty
            else { return nil }

            let artists = (JS.array(song["artists"]) ?? [])
                .compactMap { JS.dict($0) }
                .compactMap { JS.string($0["name"]) }
                .joined(separator: ", ")

            let albumNode = JS.dict(song["album"])
            let artwork = JS.string(albumNode?["picUrl"] ?? "")
            let seconds = (JS.int(song["duration"]) ?? 0) / 1000

            return Track(
                videoId: "",
                title: title,
                artist: artists.isEmpty ? L("Unknown Artist") : artists,
                album: albumNode.flatMap { JS.string($0["name"]) },
                duration: seconds,
                artwork: artwork.flatMap { $0.isEmpty ? nil : $0 },
                source: PlaylistPlatform.netease.rawValue,
                sourceID: id
            )
        }
    }

    /// 搜索结果里只保留真正能拉到音频的曲目，避免"看得见点不动"。
    /// 网易云外链对 VIP / 无版权曲目会重定向到 404 网页，必须逐条验证。
    static func playableOnes(from tracks: [Track], limit: Int = 12) async -> [Track] {
        let candidates = Array(tracks.prefix(limit))
        guard !candidates.isEmpty else { return [] }

        var keep = [Bool](repeating: false, count: candidates.count)

        await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, track) in candidates.enumerated() {
                group.addTask {
                    guard let id = track.sourceID else { return (index, false) }
                    return (index, await isPlayable(id: id))
                }
            }
            for await (index, ok) in group {
                keep[index] = ok
            }
        }

        // 保持原有顺序
        return candidates.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    static func isPlayable(id: String) async -> Bool {
        guard let url = URL(string: "https://music.163.com/song/media/outer/url?id=\(id).mp3") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              data.count > 512
        else { return false }

        let mime = http.mimeType ?? ""
        return mime.contains("audio") || mime.contains("mpeg") || mime.contains("octet-stream")
    }

    // MARK: - 按歌名匹配（YouTube 被拦时的保底）

    /// 宁可找不到，也不播翻唱：标题必须同名或包含，艺人必须对得上
    static func match(title: String, artist: String, duration: Int) async -> String? {
        let query = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
        guard !query.isEmpty else { return nil }

        let candidates = await search(query: query, limit: 30)
        guard !candidates.isEmpty else { return nil }

        let wantedTitle = normalize(title)
        let wantedArtist = normalize(artist)
        guard !wantedTitle.isEmpty else { return nil }

        var best: (id: String, score: Int)?

        for candidate in candidates {
            guard let id = candidate.sourceID else { continue }
            let candidateTitle = normalize(candidate.title)
            var score = 0

            if candidateTitle == wantedTitle {
                score += 100
            } else if candidateTitle.contains(wantedTitle) || wantedTitle.contains(candidateTitle) {
                score += 50
            } else {
                continue
            }

            if !wantedArtist.isEmpty {
                let candidateArtist = normalize(candidate.artist)
                let matched = candidateArtist == wantedArtist
                    || candidateArtist.contains(wantedArtist)
                    || wantedArtist.contains(candidateArtist)
                // 艺人没对上基本就是翻唱，直接跳过，避免播成别人的版本
                guard matched else { continue }
                score += 60
            }

            if duration > 20, candidate.duration > 20 {
                let diff = abs(candidate.duration - duration)
                if diff <= 5 {
                    score += 30
                } else if diff <= 15 {
                    score += 10
                } else if diff > 60 {
                    continue
                }
            }

            if score > (best?.score ?? 0) {
                best = (id, score)
            }
        }

        guard let picked = best, picked.score >= 100 else { return nil }
        return picked.id
    }

    /// 小写、去括注与书名号、只留数字/字母/CJK，让「晴天 (Live)」和「晴天」能对上
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let stripped = lowered.replacingOccurrences(
            of: "\\([^)]*\\)|（[^）]*）|\\[[^\\]]*\\]|【[^】]*】|《[^》]*》|〈[^〉]*〉",
            with: "",
            options: .regularExpression
        )
        let cleaned = String(stripped.unicodeScalars.filter { scalar in
            let value = scalar.value
            return (value >= 48 && value <= 57)
                || (value >= 97 && value <= 122)
                || (value >= 0x4E00 && value <= 0x9FA5)
        })
        return cleaned.isEmpty ? lowered.trimmingCharacters(in: .whitespaces) : cleaned
    }
}
