import Foundation

struct ExternalPlaylist: Identifiable, Hashable, Codable {
    let platform: PlaylistPlatform
    let playlistID: String
    let name: String
    let subtitle: String
    let cover: String?
    /// 酷狗的榜单和歌单是两套接口，用 rankid 还是 specialid 得区分开
    var isRank: Bool = false

    var id: String { "\(platform.rawValue):\(playlistID)" }

    /// 交给导入流程时用的规范链接
    var importURL: String {
        switch platform {
        case .netease: return "https://music.163.com/playlist?id=\(playlistID)"
        case .qq: return "https://y.qq.com/n/ryqq/playlist/\(playlistID)"
        case .kugou: return "https://www.kugou.com/yy/special/single/\(playlistID).html"
        case .kuwo: return "https://www.kuwo.cn/playlist_detail/\(playlistID)"
        }
    }
}

/// 风格分类。`cat` 是网易云接口用的中文分类名，`titleKey` 是给界面做本地化的英文 key。
struct PlaylistGenre: Identifiable, Hashable {
    let cat: String
    let titleKey: String
    /// 网易云没有这个官方分类（古琴 / BPM）：改走歌单关键词搜索，
    /// 否则 cat 参数会被忽略、退回一堆无关的热门歌单
    var keyword: Bool = false

    var id: String { cat }
    var title: String { L(titleKey) }
}

/// 各平台「推荐 / 热门歌单」的发现接口。
/// 酷狗与汽水目前没有可用的公开入口（酷狗返回 Access Deny，汽水无此接口），
/// 所以只返回空数组，界面会自动隐藏对应分区。
enum HotPlaylists {

    /// 只用在国内源上能直接播的分类（酷狗没有公开的分类歌单接口，QQ 拿不到直链）
    static let genres: [PlaylistGenre] = [
        PlaylistGenre(cat: "华语", titleKey: "Mandarin"),
        PlaylistGenre(cat: "欧美", titleKey: "Western"),
        PlaylistGenre(cat: "流行", titleKey: "Pop"),
        PlaylistGenre(cat: "摇滚", titleKey: "Rock"),
        PlaylistGenre(cat: "民谣", titleKey: "Folk"),
        PlaylistGenre(cat: "电子", titleKey: "Electronic"),
        PlaylistGenre(cat: "轻音乐", titleKey: "Easy Listening"),
        PlaylistGenre(cat: "说唱", titleKey: "Hip-Hop"),
        PlaylistGenre(cat: "爵士", titleKey: "Jazz"),
        PlaylistGenre(cat: "古典", titleKey: "Classical"),
        PlaylistGenre(cat: "粤语", titleKey: "Cantonese"),
        PlaylistGenre(cat: "日语", titleKey: "Japanese"),
        PlaylistGenre(cat: "韩语", titleKey: "Korean"),
        // 这两个词没有网易云官方分类，走歌单关键词搜索
        PlaylistGenre(cat: "古琴", titleKey: "古琴", keyword: true),
        PlaylistGenre(cat: "BPM", titleKey: "BPM", keyword: true)
    ]

    static func fetch(_ platform: PlaylistPlatform, cat: String = "全部") async throws -> [ExternalPlaylist] {
        switch platform {
        case .netease:
            return try await netEase(cat: cat)
        case .qq:
            return try await qq()
        case .kugou:
            return try await kugou()
        case .kuwo:
            // 酷我暂时只做搜索和直链，没有公开的榜单/歌单发现接口
            return []
        }
    }

    /// 关键词搜歌单：给没有网易云官方分类的词（古琴 / BPM）用。
    /// 实测「古琴」出纯古琴名曲、「BPM」出 150BPM 夜场 / 180BPM 跑步等。
    static func searchPlaylists(query: String, limit: Int = 30) async throws -> [ExternalPlaylist] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return [] }
        let url = "https://music.163.com/api/search/get?s=\(encoded)&type=1000&limit=\(limit)"
        guard let root = try await getJSON(url, headers: [
            "Referer": "https://music.163.com/",
            "User-Agent": browserUA
        ]) else {
            throw ApiError.unavailable(L("No content was returned. Check that your proxy also covers music.youtube.com, then retry."))
        }

        let list = (JS.array(JS.dict(root["result"])?["playlists"]) ?? []).compactMap { JS.dict($0) }
        return list.compactMap { item in
            guard let id = JS.int(item["id"]).map(String.init),
                  let name = JS.string(item["name"]), !name.isEmpty else { return nil }
            let count = JS.int(item["trackCount"]) ?? 0
            return ExternalPlaylist(
                platform: .netease,
                playlistID: id,
                name: name,
                subtitle: String(format: L("%d songs"), count),
                cover: https(JS.string(item["coverImgUrl"]))
            )
        }
    }

    private static func netEase(cat: String) async throws -> [ExternalPlaylist] {
        let encoded = cat.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cat
        let url = "https://music.163.com/api/playlist/list?cat=\(encoded)&order=hot&offset=0&limit=30&total=true"
        guard let root = try await getJSON(url, headers: [
            "Referer": "https://music.163.com/",
            "User-Agent": browserUA
        ]) else {
            throw ApiError.unavailable(L("No content was returned. Check that your proxy also covers music.youtube.com, then retry."))
        }

        let list = (JS.array(root["playlists"]) ?? []).compactMap { JS.dict($0) }
        return list.compactMap { item in
            guard let id = JS.int(item["id"]).map(String.init),
                  let name = JS.string(item["name"]), !name.isEmpty else { return nil }
            return ExternalPlaylist(
                platform: .netease,
                playlistID: id,
                name: name,
                subtitle: playsText(JS.int(item["playCount"]) ?? 0),
                cover: https(JS.string(item["coverImgUrl"]))
            )
        }
    }

    // MARK: - QQ音乐

    private static func qq() async throws -> [ExternalPlaylist] {
        let url = "https://c.y.qq.com/splcloud/fcgi-bin/fcg_get_diss_by_tag.fcg?picmid=1&rnd=0.1&g_tk=5381&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0&categoryId=10000000&sortId=5&sin=0&ein=17"
        guard let root = try await getJSON(url, headers: [
            "Referer": "https://y.qq.com/",
            "User-Agent": browserUA
        ]) else {
            throw ApiError.unavailable(L("No content was returned. Check that your proxy also covers music.youtube.com, then retry."))
        }

        let list = (JS.array(JS.dict(root["data"])?["list"]) ?? []).compactMap { JS.dict($0) }
        return list.compactMap { item in
            guard let id = JS.string(item["dissid"]),
                  let name = JS.string(item["dissname"]), !name.isEmpty else { return nil }
            return ExternalPlaylist(
                platform: .qq,
                playlistID: id,
                name: name,
                subtitle: playsText(JS.int(item["listennum"]) ?? 0),
                cover: https(JS.string(item["imgurl"]))
            )
        }
    }

    // MARK: - 酷狗榜单

    /// 移动端榜单接口。`m.kugou.com` 是唯一同时满足「免签名」「有现成 hash」的入口：
    /// 拿到 hash 就能直接走 playInfo 取直链，不必导入、不必匹配 YouTube。
    private static func kugou() async throws -> [ExternalPlaylist] {
        // 这个接口在不同网络/UA 下表现不一致：有的只认 `?json=true`，
        // 有的要 `&json=true`，https 偶尔握手失败但 http 反而通。
        // 依次试，谁先给出非空列表用谁，并把结果打进日志方便排查。
        // mobilecdn 走 http：https 证书有问题，而 http 实测 1 秒回 97KB。
        // m.kugou.com 那三个地址实测要 40 秒才读完，只当兜底。
        let endpoints = [
            "http://mobilecdn.kugou.com/api/v3/rank/list?version=8000",
            "http://m.kugou.com/rank/list?json=true",
            "https://m.kugou.com/rank/list?json=true"
        ]

        if let cached = loadKugouCache() {
            NSLog("SMOKE_KUGOU cache items=\(cached.count)")
            return cached
        }

        var lastError: Error = ApiError.unavailable(L("Kugou charts are not reachable right now."))

        for endpoint in endpoints {
            do {
                let list = try await kugouRankList(endpoint)
                NSLog("SMOKE_KUGOU url=\(endpoint) items=\(list.count)")
                if !list.isEmpty {
                    saveKugouCache(list)
                    return list
                }
            } catch {
                lastError = error
                NSLog("SMOKE_KUGOU url=\(endpoint) failed: \(error.localizedDescription)")
            }
        }

        throw lastError
    }

    // MARK: - 榜单列表缓存

    /// 这个接口一次回 150KB+，慢网下十几秒都读不完。列表 12 小时内不会变，
    /// 缓存下来既省流量也避免"每次进排行榜都空白"。
    private static var kugouCacheURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("kugou-ranks.json")
    }

    private static func loadKugouCache() -> [ExternalPlaylist]? {
        let url = kugouCacheURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let saved = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(saved) < 12 * 3600,
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([ExternalPlaylist].self, from: data),
              !list.isEmpty else { return nil }
        return list
    }

    private static func saveKugouCache(_ list: [ExternalPlaylist]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: kugouCacheURL, options: .atomic)
    }

    private static func kugouRankList(_ endpoint: String) async throws -> [ExternalPlaylist] {
        guard let root = try await getJSON(endpoint, headers: [
            "Referer": "https://m.kugou.com/",
            "User-Agent": mobileUA
        ], timeout: 25) else {
            throw ApiError.unavailable(L("Kugou charts are not reachable right now."))
        }

        // mobilecdn 是 data.info，m.kugou 是 rank.list
        let nodes = JS.array(JS.dict(root["data"])?["info"])
            ?? JS.array(JS.dict(root["rank"])?["list"])
            ?? JS.array(root["list"])
            ?? []

        return nodes.compactMap { raw -> ExternalPlaylist? in
            guard let item = JS.dict(raw),
                  let id = JS.int(item["rankid"]).map(String.init) ?? JS.string(item["rankid"]),
                  let name = JS.string(item["rankname"]) ?? JS.string(item["rank_name"]), !name.isEmpty
            else { return nil }

            // 酷狗榜单封面是模板串（含 {size}），不替换就永远加载不出来
            let cover = DomesticSource.normalizeArtwork(
                JS.string(item["imgurl"])
                    ?? JS.string(item["img_url"])
                    ?? JS.string(item["banner"]),
                size: 400
            )
            let frequency = JS.string(item["update_frequency"]) ?? ""
            return ExternalPlaylist(
                platform: .kugou,
                playlistID: id,
                name: name,
                subtitle: frequency.isEmpty ? L("Kugou Music") : frequency,
                cover: cover,
                isRank: true
            )
        }
    }

    // MARK: - 工具

    private static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    private static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"

    private static func playsText(_ count: Int) -> String {
        guard count > 0 else { return "" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let number = formatter.string(from: NSNumber(value: count)) ?? String(count)
        return String(format: L("%@ plays"), number)
    }

    /// 封面统一走 https，避免 ATS 例外被收紧后加载失败
    private static func https(_ url: String?) -> String? {
        guard let url = url else { return nil }
        if url.hasPrefix("http://") {
            return "https://" + url.dropFirst("http://".count)
        }
        return url
    }

    private static func getJSON(
        _ urlString: String,
        headers: [String: String],
        timeout: TimeInterval = 15
    ) async throws -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
