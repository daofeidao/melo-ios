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
        "Referer": "https://music.163.com/"
    ]

    static func load(name: String) async -> Profile? {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://music.163.com/api/search/get?s=\(encoded)&type=100&limit=5"),
              let searchData = await get(searchURL),
              let searchRoot = (try? JSONSerialization.jsonObject(with: searchData)) as? [String: Any],
              let rawArtists = JS.array(JS.dict(searchRoot["result"])?["artists"]),
              !rawArtists.isEmpty else { return nil }

        let artists = rawArtists.compactMap { JS.dict($0) }
        // 优先取名字完全一致的那条，避免命中「周杰伦.」这种同名账号
        let node = artists.first {
            JS.string($0["name"])?.caseInsensitiveCompare(name) == .orderedSame
        } ?? artists.first
        guard let node, let id = JS.int(node["id"]), id > 0 else { return nil }

        let avatar = (JS.string(node["picUrl"]) ?? JS.string(node["img1v1Url"]))
            .flatMap { $0.hasPrefix("http") ? $0 : nil }
        let resolvedName = JS.string(node["name"]) ?? name

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
