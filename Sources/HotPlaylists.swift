import Foundation

struct ExternalPlaylist: Identifiable, Hashable {
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
        }
    }
}

/// 风格分类。`cat` 是网易云接口用的中文分类名，`titleKey` 是给界面做本地化的英文 key。
struct PlaylistGenre: Identifiable, Hashable {
    let cat: String
    let titleKey: String

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
        PlaylistGenre(cat: "韩语", titleKey: "Korean")
    ]

    static func fetch(_ platform: PlaylistPlatform, cat: String = "全部") async throws -> [ExternalPlaylist] {
        switch platform {
        case .netease:
            return try await netEase(cat: cat)
        case .qq:
            return try await qq()
        case .kugou:
            return try await kugou()
        }
    }

    // MARK: - 酷狗榜单

    /// 移动端榜单接口。`m.kugou.com` 是唯一同时满足「免签名」「有现成 hash」的入口：
    /// 拿到 hash 就能直接走 playInfo 取直链，不必导入、不必匹配 YouTube。
    private static func kugou() async throws -> [ExternalPlaylist] {
        // 这个接口在不同网络/UA 下表现不一致：有的只认 `?json=true`，
        // 有的要 `&json=true`，https 偶尔握手失败但 http 反而通。
        // 依次试，谁先给出非空列表用谁，并把结果打进日志方便排查。
        let endpoints = [
            "https://m.kugou.com/rank/list?json=true",
            "https://m.kugou.com/rank/list&json=true",
            "http://m.kugou.com/rank/list?json=true"
        ]

        var lastError: Error = ApiError.unavailable(L("Kugou charts are not reachable right now."))

        for endpoint in endpoints {
            do {
                let list = try await kugouRankList(endpoint)
                NSLog("SMOKE_KUGOU url=\(endpoint) items=\(list.count)")
                if !list.isEmpty { return list }
            } catch {
                lastError = error
                NSLog("SMOKE_KUGOU url=\(endpoint) failed: \(error.localizedDescription)")
            }
        }

        throw lastError
    }

    private static func kugouRankList(_ endpoint: String) async throws -> [ExternalPlaylist] {
        guard let root = try await getJSON(endpoint, headers: [
            "Referer": "https://m.kugou.com/",
            "User-Agent": mobileUA
        ]) else {
            throw ApiError.unavailable(L("Kugou charts are not reachable right now."))
        }

        // 结构在不同版本里挪过位置，这里按可能性依次找
        let nodes = JS.array(JS.dict(root["rank"])?["list"])
            ?? JS.array(root["list"])
            ?? JS.array(JS.dict(root["data"])?["list"])
            ?? []

        return nodes.compactMap { raw -> ExternalPlaylist? in
            guard let item = JS.dict(raw),
                  let id = JS.int(item["rankid"]).map(String.init) ?? JS.string(item["rankid"]),
                  let name = JS.string(item["rankname"]) ?? JS.string(item["rank_name"]), !name.isEmpty
            else { return nil }

            let cover = https(
                JS.string(item["imgurl"])
                ?? JS.string(item["img_url"])
                ?? JS.string(item["banner"])
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

    private static func getJSON(_ urlString: String, headers: [String: String]) async throws -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
