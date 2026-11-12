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

    /// 按「歌名 + 艺人」找到这首并取直链。给播放器和「音源」面板用。
    ///
    /// - Parameter preferredID: 曲目自带的 `platform:id`（从这一路导入的歌），
    ///   能直接命中就不必再比标题，省掉一次搜索里挑错的风险。
    static func streamURL(
        title: String,
        artist: String,
        quality: StreamResolver.Quality,
        preferredID: String? = nil,
        duration: Int = 0
    ) async -> URL? {
        let keyword = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return nil }

        var platform = "kuwo"
        if let preferredID, let head = preferredID.split(separator: ":").first.map(String.init),
           head == "kuwo" || head == "wyy" {
            platform = head
        }

        let hits = await search(keyword: keyword, limit: 10, platform: platform)
        guard !hits.isEmpty else { return nil }

        var target: Hit?
        if let preferredID, let wanted = preferredID.split(separator: ":").dropFirst().first.map(String.init) {
            target = hits.first { $0.id == wanted }
        }
        if target == nil { target = pickBest(title: title, duration: duration, hits: hits) }
        guard let picked = target else { return nil }
        return await streamURL(hit: picked, quality: quality)
    }

    private static func pickBest(title: String, duration: Int, hits: [Hit]) -> Hit? {
        let wanted = normalize(title)
        guard wanted.count >= 2 else { return hits.first }
        let matched = hits.filter {
            let candidate = normalize($0.title)
            return candidate.contains(wanted) || wanted.contains(candidate)
        }
        guard !matched.isEmpty else { return nil }
        // 同名版本有时候是翻唱 / 现场：有已知时长就选最接近的
        if duration > 0 {
            return matched.min { abs($0.duration - duration) < abs($1.duration - duration) }
        }
        return matched.first
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
