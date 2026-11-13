import Foundation

/// 歌曲宝（gequbao.com）：网友维护的「搜歌 + 取流」网页壳。
///
/// 整条链路实测纯 HTTP 就能走通（不需要浏览器、不需要登录）：
///
///  1. `GET /s/<歌名 艺人>`            → 结果页里 `<a href="/music/4190" title="稻香 - 周杰伦">`
///  2. `GET /music/<id>`               → 页面内 `window.appData = JSON.parse('{"mp3_id":..,"play_id":".."}')`
///  3. `POST /member/common-play-url`  → `{"code":1,"data":{"url":"https://kw-er.kuwo.cn/...mp3"}}`
///
/// 第 3 步拿到的是**酷我 CDN 的真歌**（实测 audio/mpeg、约 3.5MB、128kbps、HTTP 206 可播），
/// 所以它不是新曲库，而是「酷我 128k 的第二条取流路径」：同一首歌站内常有 3~5 条记录、
/// 各自映射到不同酷我资源，正好补上「某个 rid 只返回广告」那个缺口。
/// 因此只当所有内置源都失败时的**最后兜底**，不参与正常搜索。
///
/// 站点前面挂着 Cloudflare。实测请求头不是关键（各种 UA 都过），但线路 / 风控会偶发抽风，
/// 所以这里做了三重冗余：移动 UA → 桌面 UA → 只按歌名再搜一次；
/// 候选也从 3 条放宽到 6 条（同一首歌的多条记录互为备份）。
/// 一旦站点要求「人机验证」（code=2），立刻收手 —— 越问限得越久。
enum Gequbao {

    private static let base = "https://www.gequbao.com"

    private static let mobileUA = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"

    private static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    private static func pageHeaders(_ ua: String) -> [String: String] {
        [
            "User-Agent": ua,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9",
            // 少了这几个 Sec-Fetch 头会被 Cloudflare 挑战页拦在外面
            "Sec-Fetch-Dest": "document",
            "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Site": "none",
            "Upgrade-Insecure-Requests": "1"
        ]
    }

    /// 标题里出现这些词的一律不要：宁可没声，也不放片段 / 伴奏 / 翻唱 / DJ 版
    private static let badWords = [
        "片段", "伴奏", "翻唱", "dj", "remix", "live", "现场", "纯音乐", "试听", "铃声", "串烧"
    ]

    /// 按「歌名 + 艺人」取一条可播直链。
    /// 只接受标题严格对得上的条目；宁可返回 nil 也不拿同名翻唱 / 片段 / 伴奏凑数。
    static func playURL(title: String, artist: String, minBytes: Int64 = 500_000) async -> URL? {
        let wanted = normalize(title)
        guard wanted.count >= 2 else { return nil }
        let keyword = "\(title) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return nil }

        // 三重搜索兜底：移动 UA → 桌面 UA → 只按歌名
        var ids = await searchIDs(keyword: keyword, wanted: wanted, artist: artist, ua: mobileUA)
        if ids.isEmpty {
            ids = await searchIDs(keyword: keyword, wanted: wanted, artist: artist, ua: desktopUA)
        }
        if ids.isEmpty, let encoded = encode(title.trimmingCharacters(in: .whitespacesAndNewlines)) {
            ids = await searchIDs(keyword: nil, path: "/s/" + encoded,
                                  wanted: wanted, artist: artist, ua: mobileUA)
        }

        for id in ids.prefix(6) {
            let result = await streamURL(id: id)
            // 站点开始要「人机验证」了：这一轮问下去只会继续被拒，直接收手交给别的源
            if result.captcha { return nil }
            guard let url = result.url else { continue }
            if let size = await DomesticSource.contentLength(url), size < minBytes { continue }
            return url
        }
        return nil
    }

    private static func searchIDs(
        keyword: String?,
        path: String? = nil,
        wanted: String,
        artist: String,
        ua: String
    ) async -> [String] {
        let target: String
        if let path = path {
            target = base + path
        } else if let keyword = keyword, let encoded = encode(keyword) {
            target = base + "/s/" + encoded
        } else {
            return []
        }
        guard let html = await fetchText(target, ua: ua) else { return [] }
        return parseSearch(html, wanted: wanted, artist: artist)
    }

    /// 从结果页挑出标题严格一致的条目（同一首歌常有多条，互为备份）
    private static func parseSearch(_ html: String, wanted: String, artist: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"href="/music/(\d+)"[^>]*title="([^"]*)""#
        ) else { return [] }
        let artistKey = normalize(artist)
        let range = NSRange(html.startIndex..., in: html)
        var scored: [(Int, String)] = []

        for match in regex.matches(in: html, range: range) {
            guard let idRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { continue }
            let id = String(html[idRange])
            let raw = decodeEntities(String(html[titleRange]))
            let parts = raw.components(separatedBy: " - ")
            let song = parts.first ?? ""
            let who = parts.count > 1 ? parts[1] : ""
            guard normalize(song) == wanted else { continue }
            let lower = song.lowercased()
            guard !badWords.contains(where: { lower.contains($0) }) else { continue }

            // 艺人：两边都有信息时要求能对上，避免同名不同歌手
            let whoKey = normalize(who)
            let prefix = String(artistKey.prefix(4))
            let consistent = artistKey.isEmpty || whoKey.isEmpty
                || whoKey.contains(prefix)
                || artistKey.contains(String(whoKey.prefix(4)))
            guard consistent else { continue }

            let hit = !prefix.isEmpty && whoKey.contains(prefix) ? 0 : 1
            scored.append((hit, id))
        }

        var seen = Set<String>()
        var out: [String] = []
        for (_, id) in scored.sorted(by: { $0.0 < $1.0 }) where !seen.contains(id) {
            seen.insert(id)
            out.append(id)
        }
        return out
    }

    /// 取流结果：拿到直链 / 被要求人机验证 / 这条不行
    private struct StreamResult {
        let url: URL?
        let captcha: Bool

        init(url: URL?, captcha: Bool = false) {
            self.url = url
            self.captcha = captcha
        }
    }

    /// 详情页 → play_id → 取流接口 → 直链
    private static func streamURL(id: String) async -> StreamResult {
        var html = await fetchText(base + "/music/" + id, ua: mobileUA)
        if html == nil {
            html = await fetchText(base + "/music/" + id, ua: desktopUA)
        }
        guard let html = html else { return StreamResult(url: nil) }
        guard let regex = try? NSRegularExpression(
            pattern: #"window\.appData\s*=\s*JSON\.parse\('(.+?)'\)"#,
            options: [.dotMatchesLineSeparators]
        ), let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let bodyRange = Range(match.range(at: 1), in: html) else { return StreamResult(url: nil) }

        // 页面里是 \u0022 / \/ 转义过的伪 JSON，先还原再解析
        let json = String(html[bodyRange])
            .replacingOccurrences(of: "\\u0022", with: "\"")
            .replacingOccurrences(of: "\\/", with: "/")
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let playID = JS.string(root["play_id"]), !playID.isEmpty else {
            return StreamResult(url: nil)
        }

        guard let url = URL(string: base + "/member/common-play-url") else {
            return StreamResult(url: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        request.setValue(base + "/music/" + id, forHTTPHeaderField: "Referer")
        request.setValue(base, forHTTPHeaderField: "Origin")
        request.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        let form = "id=\(encode(playID) ?? playID)&purpose=play"
        request.httpBody = form.data(using: .utf8)

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return StreamResult(url: nil)
        }

        // code=2：接口回「请完成人机验证后继续」，这一轮再怎么试都是这个结果
        if JS.int(root["code"]) == 2 { return StreamResult(url: nil, captcha: true) }

        guard let payload = JS.dict(root["data"]),
              let raw = JS.string(payload["url"]), raw.hasPrefix("http") else {
            return StreamResult(url: nil)
        }
        // 酷我直链参数偶尔是 ?bitrate$128，$ 换成 = 才是合法查询串
        return StreamResult(url: URL(string: raw.replacingOccurrences(of: "$", with: "=")))
    }

    private static func fetchText(_ urlString: String, ua: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        for (key, value) in pageHeaders(ua) { request.setValue(value, forHTTPHeaderField: key) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    private static func encode(_ value: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    /// 比较用的归一化：小写、去空格、去括号里的补充说明
    private static func normalize(_ value: String) -> String {
        var text = value.lowercased()
        if let regex = try? NSRegularExpression(pattern: #"[（(\[【].*?[)）\]】]"#) {
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
            )
        }
        return text.replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ value: String) -> String {
        var text = value
        let entities = [
            "&nbsp;": " ", "&apos;": "'", "&#39;": "'", "&quot;": "\"",
            "&lt;": "<", "&gt;": ">", "&amp;": "&"
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
