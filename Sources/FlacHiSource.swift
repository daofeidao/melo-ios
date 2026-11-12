import Foundation

/// Hi·FLAC（flac.music.hi.cn）聚合源。
///
/// 它自己是个搜索站：`ajax.php?act=search` 给出结果，每条带服务端签发的
/// `time` + `sign`；再 `act=getUrl` 回传这两个值换一条直链。直链本身落在
/// 酷我 CDN（other-*.kuwo.cn），不带 Referer 也能直接播。
///
/// 之所以值得单独做成一路源：我们自己直连酷我，匿名只能拿到 128k，
/// 320 和 flac 都需要会员态；这个站用它的会员凭据代取，实测能拿到
/// `F00000…flac` 的真无损，等于补上了「无损」这一档。
///
/// 没有公开文档，接口是照着它前端 JS 复刻的，字段可能变；
/// 解析失败一律当作「这一档不可用」，让上层继续降级，不要让整首挂掉。
enum FlacHiSource {

    private static let endpoint = "https://flac.music.hi.cn/ajax.php"
    private static let referer = "https://flac.music.hi.cn/"
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    struct Hit {
        let platform: String
        let id: String
        let title: String
        let artist: String
        let album: String?
        let duration: Int
        let artwork: String?
        let time: Int
        let sign: String
        /// 站点声明可用的 (format, bitrate)，按音质从高到低
        let tiers: [(String, String)]

        var trackID: String { "flachi:\(platform):\(id)" }
        var sourceID: String { "\(platform):\(id)" }
    }

    // MARK: - 搜索

    static func search(keyword: String, limit: Int = 10, platform: String = "kuwo") async -> [Hit] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let params = [
            "platform": platform,
            "keyword": trimmed,
            "page": "1",
            "size": String(limit)
        ]
        guard let data = await postForm(path: "search", params: params),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              JS.int(root["code"]) == 0,
              let payload = JS.dict(root["data"]),
              let list = payload["list"] as? [[String: Any]] else { return [] }

        return list.compactMap { item in
            guard let id = JS.string(item["id"]), !id.isEmpty,
                  let name = JS.string(item["name"]), !name.isEmpty,
                  let sign = JS.string(item["sign"]), !sign.isEmpty else { return nil }

            var tiers: [(String, String)] = []
            if let info = item["minfo"] as? [[String: Any]] {
                for node in info {
                    guard let format = JS.string(node["format"]), !format.isEmpty,
                          let bitrate = JS.string(node["bitrate"]), !bitrate.isEmpty else { continue }
                    tiers.append((format, bitrate))
                }
            }

            return Hit(
                platform: platform,
                id: id,
                title: name,
                artist: JS.string(item["artist"]) ?? "",
                album: JS.string(item["album_name"]).flatMap { $0.isEmpty ? nil : $0 },
                duration: JS.int(item["duration"]) ?? 0,
                artwork: JS.string(item["pic_url"]).flatMap { $0.hasPrefix("http") ? $0 : nil },
                time: JS.int(item["time"]) ?? 0,
                sign: sign,
                tiers: tiers
            )
        }
    }

    /// 搜索结果转 Track，给搜索页用。
    ///
    /// 每条都带 `platform:id`，点播时按 id 精确取流，不会走歌名模糊匹配，
    /// 所以「周杰伦在这个站没有原版」只影响列表里有没有，不会串到翻唱。
    static func searchTracks(query: String, limit: Int = 20) async -> [Track] {
        let hits = await search(keyword: query, limit: limit, platform: "kuwo")
        return hits.map { hit in
            Track(
                videoId: "",
                title: hit.title,
                artist: hit.artist.isEmpty ? L("Unknown Artist") : hit.artist,
                album: hit.album,
                duration: hit.duration,
                artwork: hit.artwork,
                source: "flachi",
                sourceID: hit.sourceID
            )
        }
    }

    // MARK: - 取流

    /// 按当前音质档位排出要依次尝试的 (format, bitrate)
    private static func plan(for hit: Hit, quality: StreamResolver.Quality) -> [(String, String)] {
        let wanted: [(String, String)]
        switch quality {
        case .lossless:
            wanted = [("flac", "2000"), ("flac", "1000"), ("mp3", "320"), ("mp3", "128")]
        case .high:
            wanted = [("mp3", "320"), ("mp3", "128"), ("flac", "2000")]
        case .normal, .low:
            wanted = [("mp3", "128"), ("mp3", "320")]
        }

        // 站点自己列的档位是准的：它没有的档位直接跳过，省一次必然失败的请求
        guard !hit.tiers.isEmpty else { return wanted }
        let available = Set(hit.tiers.map { "\($0.0)/\($0.1)" })
        let filtered = wanted.filter { available.contains("\($0.0)/\($0.1)") }
        return filtered.isEmpty ? wanted : filtered
    }

    static func streamURL(hit: Hit, quality: StreamResolver.Quality) async -> URL? {
        for (format, bitrate) in plan(for: hit, quality: quality) {
            let params = [
                "platform": hit.platform,
                "songid": hit.id,
                "format": format,
                "bitrate": bitrate,
                "time": String(hit.time),
                "sign": hit.sign
            ]
            guard let data = await postForm(path: "getUrl", params: params),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  JS.int(root["code"]) == 0,
                  let payload = JS.dict(root["data"]),
                  let raw = JS.string(payload["url"]),
                  raw.hasPrefix("http"),
                  let url = URL(string: raw) else { continue }
            return url
        }
        return nil
    }

    /// 改编版本标记。用**原始**标题判断：normalize 会把「（Live）」整段吃掉，
    /// 归一化之后就再也看不出这是现场版了。
    private static let versionMarkers = [
        "live", "现场", "翻唱", "cover", "dj", "remix", "变速",
        "伴奏", "纯音乐", "instrumental", "karaoke", "片段", "试听",
        "串烧", "怀念版", "重置版", "钢琴", "吉他版", "消音",
        "女声版", "男声版", "弦乐", "史诗版", "深情版", "纯音"
    ]

    /// 按歌名找这首并取直链。给播放器和「音源」面板用。
    ///
    /// 实测这个站的两个坑：
    /// - 关键词拼上艺人几乎必然返回 0 条（「晴天 周杰伦」→ total 0），只有纯歌名能出结果；
    /// - 纯歌名返回的是全站模糊结果，翻唱 / Live / 变速 / DJ 版混在一起，原唱未必在前面。
    /// 所以只用歌名搜索，再在**本地**用艺人、标题、时长三重筛，一个都对不上就返回 nil
    /// 交给上层降级，绝不「矮子里拔将军」硬选一个错误版本。
    ///
    /// - Parameter preferredID: 曲目自带的 `platform:id`（从这一路导入的歌），
    ///   id 精确命中时直接信任，不必再比标题。
    /// - Parameter manual: 用户手动锁定这个源时放宽艺人要求（有些曲目 artist 为空），
    ///   但版本词和时长仍然是硬过滤。
    static func streamURL(
        title: String,
        artist: String,
        quality: StreamResolver.Quality,
        preferredID: String? = nil,
        duration: Int = 0,
        manual: Bool = false
    ) async -> URL? {
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        guard !cleanTitle.isEmpty else { return nil }

        var platform = "kuwo"
        if let preferredID, let head = preferredID.split(separator: ":").first.map(String.init),
           head == "kuwo" || head == "wyy" {
            platform = head
        }

        // kuwo 找不到合格版本时再试 wyy，两边曲库不一样
        for pf in [platform, platform == "kuwo" ? "wyy" : "kuwo"] {
            let hits = await search(keyword: cleanTitle, limit: 20, platform: pf)
            guard !hits.isEmpty else { continue }

            var target: Hit?
            if let preferredID,
               let wanted = preferredID.split(separator: ":").dropFirst().first.map(String.init) {
                target = hits.first { $0.id == wanted }
            }
            if target == nil {
                target = pickBest(title: cleanTitle, artist: artist,
                                  duration: duration, hits: hits, manual: manual)
            }
            guard let picked = target else { continue }
            if let url = await streamURL(hit: picked, quality: quality) { return url }
        }
        return nil
    }

    private static func pickBest(
        title: String,
        artist: String,
        duration: Int,
        hits: [Hit],
        manual: Bool
    ) -> Hit? {
        let wanted = normalize(title)
        guard wanted.count >= 2 else { return nil }
        let wantedArtist = normalize(artist)
        let wantedHasVersion = versionMarkers.contains { title.lowercased().contains($0) }

        // 多艺人曲目（"A, B" / "A & B"）拆开，任一个能对上就算艺人匹配
        let artistTokens = artist.lowercased()
            .split(whereSeparator: { $0 == "," || $0 == "、" || $0 == "/" || $0 == "&" })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }

        var best: Hit?
        var bestScore = Int.min
        for hit in hits {
            let raw = hit.title.lowercased()
            // 原曲自己就带版本词时不要误伤；否则改编版一律淘汰
            if !wantedHasVersion, versionMarkers.contains(where: { raw.contains($0) }) { continue }

            let candidate = normalize(hit.title)
            let nameScore: Int
            if candidate == wanted {
                nameScore = 100
            } else if (wanted.hasPrefix(candidate) || candidate.hasPrefix(wanted)),
                      abs(candidate.count - wanted.count) <= 6 {
                nameScore = 55
            } else {
                // 「像晴天像雨天-电视剧《难哄》心动曲」也包含「晴天」，这种绝不认
                continue
            }

            let hitArtist = normalize(hit.artist)
            var artistScore = 0
            if !wantedArtist.isEmpty {
                let matched = hitArtist.contains(wantedArtist)
                    || wantedArtist.contains(hitArtist)
                    || artistTokens.contains { hitArtist.contains($0) }
                guard matched else { continue }
                artistScore = 40
            } else if !manual && nameScore < 100 {
                // 曲目没带艺人信息时，只有标题完全一致才敢自动用
                continue
            }

            // 时长差超过 8 秒基本就是另一个版本
            if duration > 0, hit.duration > 0, abs(hit.duration - duration) > 8 { continue }

            let score = nameScore + artistScore - (duration > 0 ? abs(hit.duration - duration) : 0)
            if score > bestScore { bestScore = score; best = hit }
        }
        return best
    }

    private static func normalize(_ value: String) -> String {
        var text = value.lowercased()
        text = text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[-－—]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[（(\\[【].*?[)）\\]】]", with: "", options: .regularExpression)
        return text
    }

    // MARK: - HTTP

    private static func postForm(path: String, params: [String: String]) async -> Data? {
        guard let url = URL(string: "\(endpoint)?act=\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 7
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("https://flac.music.hi.cn", forHTTPHeaderField: "Origin")

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = params
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return data
    }
}
