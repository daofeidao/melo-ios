import Foundation

/// 艺人页的资料：头像、简介、代表作品。
///
/// 网易云这两个接口匿名可直连（实测 200，不需要 Cookie / 签名）：
/// - `api/search/get?type=100` 按名字换 artist id 和头像
/// - `api/artist/introduction?id=` 给 briefDesc、人物简介、代表作品
///
/// 拿不到就返回 nil，艺人页照样能用搜索结果展示歌曲和专辑，只是没有简介。
enum ArtistInfo {

    struct Profile {
        let name: String
        /// 网易云艺人 id：艺人页靠它去拉本人的真专辑和热门歌
        let id: Int
        let avatar: String?
        let brief: String
        let biography: String
        let works: [String]
    }

    private static let headers = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
        "Referer": "https://music.163.com/",
        // 匿名设备标识：不带上时网易云会概率性回 code=-462（限流），艺人资料与头像拉不到
        "Cookie": NeteaseDeviceCookie.value
    ]

    /// 精确解析：返回网易云艺人 id / 官方名 / 头像。
    ///
    /// 只接受「归一化后完全相等」，不做包含匹配 —— 包含匹配会让
    /// `周杰伦微博台`、`周杰伦粉丝团` 这类派生账号蒙混过关。
    static func neteaseMatch(_ name: String) async -> (id: Int, name: String, avatar: String?)? {
        let query = ArtistName.key(ArtistName.primary(name))
        guard !query.isEmpty else { return nil }
        guard let encoded = ArtistName.primary(name)
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://music.163.com/api/search/get?s=\(encoded)&type=100&limit=10"),
              let searchData = await get(searchURL),
              let searchRoot = (try? JSONSerialization.jsonObject(with: searchData)) as? [String: Any],
              let rawArtists = JS.array(JS.dict(searchRoot["result"])?["artists"])
        else { return nil }

        for raw in rawArtists {
            guard let node = JS.dict(raw),
                  let id = JS.int(node["id"]), id > 0,
                  let rawName = JS.string(node["name"]) else { continue }
            let clean = ArtistName.sanitize(rawName)
            guard !clean.isEmpty, ArtistName.key(clean) == query else { continue }
            let avatar = (JS.string(node["picUrl"]) ?? JS.string(node["img1v1Url"]))
                .flatMap { $0.hasPrefix("http") ? $0 : nil }
            return (id, clean, avatar)
        }
        return nil
    }

    /// 手动添加艺人时用的宽松解析。
    ///
    /// 为什么要分两档：白名单校验（`neteaseMatch`）必须严格，否则派生号会混进艺人区；
    /// 但用户手打名字时，库里常是**带别名的官方名**——比如输入「邓紫棋」，
    /// 网易云登记的是「G.E.M.邓紫棋」。严格比对会判「库里没有这位艺人」，
    /// 用户看到的却是「明明就有」，这就是之前那个 bug。
    ///
    /// 所以这里的策略是：
    ///   1. 先严格比一遍（同名优先）；
    ///   2. 再接受「互相包含」且自身合规的结果，并返回**官方名** ——
    ///      加进去的是官方名，之后艺人页按官方名精确解析，不会失效；
    ///   3. 网络失败单独返回 `unavailable`，不能当成「没有这个艺人」。
    enum Lookup {
        case found(id: Int, name: String, avatar: String?)
        case notFound
        case unavailable
    }

    static func lookup(_ name: String) async -> Lookup {
        let query = ArtistName.key(ArtistName.primary(name))
        guard !query.isEmpty else { return .notFound }
        guard let encoded = ArtistName.primary(name)
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://music.163.com/api/search/get?s=\(encoded)&type=100&limit=20") else {
            return .notFound
        }
        // 请求本身失败（超时 / 断网 / 被限流）和「查到了但没有这个人」必须分开，
        // 否则用户在家网差一点就会被判「艺人库里没有」
        guard let searchData = await get(searchURL) else { return .unavailable }
        guard let searchRoot = (try? JSONSerialization.jsonObject(with: searchData)) as? [String: Any] else {
            return .unavailable
        }
        guard let rawArtists = JS.array(JS.dict(searchRoot["result"])?["artists"]) else {
            return .notFound
        }

        var loose: (id: Int, name: String, avatar: String?)?
        for raw in rawArtists {
            guard let node = JS.dict(raw),
                  let id = JS.int(node["id"]), id > 0,
                  let rawName = JS.string(node["name"]) else { continue }
            let clean = ArtistName.sanitize(rawName)
            guard !clean.isEmpty, ArtistName.isPlausible(clean) else { continue }
            let avatar = (JS.string(node["picUrl"]) ?? JS.string(node["img1v1Url"]))
                .flatMap { $0.hasPrefix("http") ? $0 : nil }
            let key = ArtistName.key(clean)
            if key == query {
                return .found(id: id, name: clean, avatar: avatar)
            }
            // 官方名带别名（`G.E.M.邓紫棋` vs `邓紫棋`）时留一个候选，
            // 严格匹配全部走完还空着才用它
            if loose == nil, key.contains(query) || query.contains(key) {
                loose = (id, clean, avatar)
            }
        }
        if let candidate = loose {
            return .found(id: candidate.id, name: candidate.name, avatar: candidate.avatar)
        }
        return .notFound
    }

    /// 只要 id（艺人准入校验用）
    static func neteaseArtistID(name: String) async -> Int? {
        await neteaseMatch(name)?.id
    }

    static func load(name: String) async -> Profile? {
        // 只认精确命中：网易云艺人库里必须存在一个归一化后完全等于 name 的艺人。
        // 「单田芳评书」在库里没有（搜出来的是「一拉帮」）、「周杰伦微博台」也不是本人，
        // 一律返回 nil —— 艺人页宁可不显示资料，也不张冠李戴。
        guard let match = await neteaseMatch(name) else { return nil }
        let id = match.id
        let avatar = match.avatar
        let resolvedName = match.name

        guard let introURL = URL(string: "https://music.163.com/api/artist/introduction?id=\(id)"),
              let introData = await get(introURL),
              let intro = (try? JSONSerialization.jsonObject(with: introData)) as? [String: Any] else {
            return Profile(name: resolvedName, id: id, avatar: avatar, brief: "", biography: "", works: [])
        }

        let brief = clean(JS.string(intro["briefDesc"]) ?? "")
        var biography = ""
        var worksRaw = ""
        for raw in JS.array(intro["introduction"]) ?? [] {
            guard let item = JS.dict(raw) else { continue }
            let title = JS.string(item["ti"]) ?? ""
            let body = clean(JS.string(item["txt"]) ?? "")
            if biography.isEmpty, title.contains("人物简介") || title.contains("艺人简介") {
                biography = body
            }
            if worksRaw.isEmpty, title.contains("代表作品") { worksRaw = body }
        }
        if biography.isEmpty { biography = brief }

        // 「代表作品」常见格式：音乐：七里香、青花瓷、双截棍…（后面可能还跟电影：…）
        let afterLabel: String = {
            if let range = worksRaw.range(of: "：") {
                return String(worksRaw[range.upperBound...])
            }
            return worksRaw
        }()
        var works: [String] = []
        for part in afterLabel.components(separatedBy: CharacterSet(charactersIn: "、,，\n/；")) {
            let title = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count >= 2, title.count <= 18,
                  !title.contains("："), !title.contains(":"),
                  !works.contains(title) else { continue }
            works.append(title)
            if works.count >= 10 { break }
        }

        return Profile(
            name: resolvedName,
            id: id,
            avatar: avatar,
            brief: brief,
            biography: String(biography.prefix(1400)),
            works: works
        )
    }

    private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return data
    }

    private static func clean(_ value: String) -> String {
        let lines = value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}
