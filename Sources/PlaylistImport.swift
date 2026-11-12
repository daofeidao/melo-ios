import Foundation

// MARK: - 平台

enum PlaylistPlatform: String, CaseIterable, Identifiable, Codable {
    case netease
    case qq
    case kugou
    /// 酷我：直链最容易拿到的一家（antiserver 不需要签名），当兜底音源用
    case kuwo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .netease: return L("NetEase Cloud Music")
        case .qq: return L("QQ Music")
        case .kugou: return L("Kugou Music")
        case .kuwo: return L("Kuwo Music")
        }
    }

    var shortLabel: String {
        switch self {
        case .netease: return "网易云"
        case .qq: return "QQ音乐"
        case .kugou: return "酷狗"
        case .kuwo: return "酷我"
        }
    }
}

struct RemoteSong {
    var title: String
    var artist: String
    var album: String?
    var duration: Int
    var source: PlaylistPlatform
    var sourceID: String
    /// 原平台封面（能拿到就用，拿不到界面上是占位图）
    var artwork: String? = nil
    /// 网易云 VIP / 付费专辑曲目：外链必然拿不到直链，列表上要标出来
    var isVip: Bool = false
}

struct RemotePlaylist {
    var name: String
    var platform: PlaylistPlatform
    var cover: String?
    var songs: [RemoteSong]
    /// 补齐失败、没能拿回来的曲目数。>0 时界面要提示，不能静默吞掉。
    var failedCount: Int = 0
}

enum PlaylistImportError: LocalizedError {
    case unsupportedLink
    case notFound
    case empty
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLink: return L("No playlist found in this link")
        case .notFound: return L("Playlist not found")
        case .empty: return L("Playlist is empty")
        case .remote(let message): return message
        }
    }
}

// MARK: - 链接识别

enum PlaylistLink {

    /// 从分享文本里识别平台与歌单 ID
    static func parse(_ text: String) -> (platform: PlaylistPlatform, id: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for url in extractURLs(from: trimmed) {
            if let hit = match(url.absoluteString) { return hit }
        }

        // 文本本身就是链接（可能不带 scheme）
        if let hit = match(trimmed) { return hit }
        return nil
    }

    static func extractURLs(from text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: range).compactMap { $0.url }
    }

    static func isShortLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "163cn.tv"
            || host == "c6.y.qq.com"
            || host == "url.cn"
            || host == "t1.kugou.com"
            || host == "m.kugou.com"
    }

    /// 纯字符串匹配，避免 URLComponents 对畸形链接解析失败
    static func match(_ raw: String) -> (PlaylistPlatform, String)? {
        let text = raw.lowercased()

        if text.contains("music.163.com") || text.contains("163cn.tv") || text.contains("y.music.163.com") {
            if let id = firstGroup(#"[?&]id=(\d+)"#, in: raw) { return (.netease, id) }
            if let id = firstGroup(#"/playlist/(\d+)"#, in: raw) { return (.netease, id) }
            if let id = firstGroup(#"playlist[/?].*?(\d{5,})"#, in: raw) { return (.netease, id) }
            return nil
        }

        if text.contains("y.qq.com") || text.contains("i.y.qq.com") || text.contains("qq.com") {
            if let id = firstGroup(#"[?&]id=(\d+)"#, in: raw) { return (.qq, id) }
            if let id = firstGroup(#"/playlist/(\d+)"#, in: raw) { return (.qq, id) }
            if let id = firstGroup(#"/taoge/[^0-9]*(\d{5,})"#, in: raw) { return (.qq, id) }
            return nil
        }

        if text.contains("kugou.com") {
            if let id = firstGroup(#"/single/(\d+)"#, in: raw) { return (.kugou, id) }
            if let id = firstGroup(#"specialid=(\d+)"#, in: raw) { return (.kugou, id) }
            if let id = firstGroup(#"/plist/list/(\d+)"#, in: raw) { return (.kugou, id) }
            if let id = firstGroup(#"/songlist/gcid_([0-9a-z_]+)"#, in: raw) { return (.kugou, id) }
            return nil
        }

        if text.contains("kuwo.cn") {
            // 链接形如 /newh5app/playlist_detail/3739396498 —— 中间有斜杠，
            // 早期正则要求 playlist_detail 后面紧跟数字，所以整条识别不了
            if let id = firstGroup(#"(?:playlist_detail/?|playlist/detail/?|pid=)(\d{2,})"#, in: raw) {
                return (.kuwo, id)
            }
            return nil
        }

        return nil
    }

    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captured])
    }

    /// 短链先跟一次跳转，再重新识别
    static func resolveShortLink(_ url: URL) async -> URL? {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 15_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.6 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 15
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return response.url
    }
}

// MARK: - 抓取

enum PlaylistFetcher {

    private static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"

    static func fetch(platform: PlaylistPlatform, id: String, isRank: Bool = false) async throws -> RemotePlaylist {
        switch platform {
        case .netease:
            return try await fetchNetEase(id: id)
        case .qq:
            return try await fetchQQ(id: id)
        case .kugou:
            return isRank ? try await fetchKugouRank(id: id) : try await fetchKugou(id: id)
        case .kuwo:
            return try await fetchKuwo(id: id)
        }
    }

    /// 酷狗榜单曲目：优先 mobilecdn（http，实测 0.4 秒回 30 首），
    /// 失败再退回 m.kugou.com 那套慢接口。
    private static func fetchKugouRank(id: String) async throws -> RemotePlaylist {
        if let fast = try? await fetchKugouRankMobile(id: id) {
            return fast
        }
        return try await fetchKugouRankLegacy(id: id)
    }

    private static func fetchKugouRankMobile(id: String) async throws -> RemotePlaylist {
        var songs: [RemoteSong] = []
        var page = 1

        while page <= 2 {
            guard let root = try await getJSON(
                "http://mobilecdn.kugou.com/api/v3/rank/song?rankid=\(id)&page=\(page)&pagesize=100&version=8000",
                headers: ["Referer": "https://m.kugou.com/", "User-Agent": mobileUA]
            ) else {
                if page == 1 { throw PlaylistImportError.notFound }
                break
            }

            let data = JS.dict(root["data"])
            let batch = (JS.array(data?["info"]) ?? []).compactMap { JS.dict($0) }.compactMap(kugouSong)
            if batch.isEmpty { break }
            songs.append(contentsOf: batch)

            let total = JS.int(data?["total"]) ?? 0
            if total > 0, songs.count >= total { break }
            if batch.count < 100 { break }
            page += 1
        }

        guard !songs.isEmpty else { throw PlaylistImportError.empty }
        return RemotePlaylist(name: L("Kugou Music"), platform: .kugou, cover: nil, songs: songs)
    }

    private static func fetchKugouRankLegacy(id: String) async throws -> RemotePlaylist {
        var name = L("Kugou Music")
        var cover: String?
        var songs: [RemoteSong] = []
        var page = 1

        while page <= 3 {
            guard let root = try await getJSON(
                "https://m.kugou.com/rank/info/?rankid=\(id)&page=\(page)&json=true",
                headers: ["Referer": "https://m.kugou.com/", "User-Agent": mobileUA]
            ) else {
                if page == 1 { throw PlaylistImportError.notFound }
                break
            }

            let rankNode = JS.dict(root["rank"])
            let info = JS.dict(rankNode?["info"]) ?? JS.dict(root["info"])
            if let value = JS.string(info?["rankname"]) ?? JS.string(root["rankname"]), !value.isEmpty {
                name = value
            }
            if cover == nil {
                cover = JS.string(info?["imgurl"]) ?? JS.string(root["imgurl"])
            }

            let batch = (JS.array(root["songs"])
                ?? JS.array(rankNode?["songs"])
                ?? JS.array(JS.dict(root["data"])?["songs"])
                ?? [])
                .compactMap { JS.dict($0) }
                .compactMap(kugouSong)

            if batch.isEmpty { break }
            songs.append(contentsOf: batch)

            let total = JS.int(root["total"]) ?? JS.int(rankNode?["total"]) ?? 0
            if total > 0, songs.count >= total { break }
            if batch.count < 30 { break }
            page += 1
        }

        guard !songs.isEmpty else { throw PlaylistImportError.empty }
        return RemotePlaylist(name: name, platform: .kugou, cover: cover, songs: songs)
    }

    // MARK: 网易云

    private static func fetchNetEase(id: String) async throws -> RemotePlaylist {
        let headers = [
            "Referer": "https://music.163.com/",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            // 境外出口不带这个头会拿到加密体 {"result":"<hex>"}，整单解析失败
            "X-Real-IP": DomesticSource.declaredIP
        ]

        // v6 详情接口在未登录时只返回前 10 首曲目（trackIds 却是完整的），
        // 必须显式带 n 参数才会给全量，否则大歌单会被静默截成 10 首。
        if let root = try? await getJSON("https://music.163.com/api/v6/playlist/detail?id=\(id)&n=1000&s=0", headers: headers),
           let playlist = JS.dict(root["playlist"]) {
            let name = JS.string(playlist["name"]) ?? L("Playlist")
            let cover = JS.string(playlist["coverImgUrl"])

            // trackIds 是完整清单（元素可能是数字，也可能是带 id 的对象）
            let trackIds = (JS.array(playlist["trackIds"]) ?? []).compactMap { item -> String? in
                if let value = JS.int(item) { return String(value) }
                return JS.dict(item).flatMap { JS.int($0["id"]) }.map(String.init)
            }

            var songs = (JS.array(playlist["tracks"]) ?? [])
                .compactMap { JS.dict($0) }
                .compactMap(netEaseSong)

            // 超过 1000 首时 trackIds 仍比 tracks 多：按缺失的 ID 补齐，再按歌单顺序还原
            var failed = 0
            if trackIds.count > songs.count {
                var byID: [String: RemoteSong] = [:]
                for song in songs where !song.sourceID.isEmpty {
                    byID[song.sourceID] = song
                }
                let missing = trackIds.filter { byID[$0] == nil }
                let outcome = await netEaseSongs(ids: missing, headers: headers)
                failed = outcome.failed
                for song in outcome.songs {
                    byID[song.sourceID] = song
                }
                let ordered = trackIds.compactMap { byID[$0] }
                if ordered.count > songs.count { songs = ordered }
            }

            guard !songs.isEmpty else { throw PlaylistImportError.empty }
            return RemotePlaylist(
                name: name,
                platform: .netease,
                cover: cover,
                songs: songs,
                failedCount: failed
            )
        }

        guard let root = try await getJSON("https://music.163.com/api/playlist/detail?id=\(id)", headers: headers) else {
            throw PlaylistImportError.notFound
        }
        guard let result = JS.dict(root["result"]) else { throw PlaylistImportError.notFound }
        let songs = (JS.array(result["tracks"]) ?? []).compactMap { JS.dict($0) }
        guard !songs.isEmpty else { throw PlaylistImportError.empty }
        return RemotePlaylist(
            name: JS.string(result["name"]) ?? L("Playlist"),
            platform: .netease,
            cover: JS.string(result["coverImgUrl"]),
            songs: songs.compactMap(netEaseSong)
        )
    }

    /// 按 ID 批量取曲目（每批 100），用于补齐超过 1000 首的歌单。
    /// 返回补到的曲目和失败条数：以前用 `try?` 静默跳过，一批失败就永久少一批歌。
    private static func netEaseSongs(ids: [String], headers: [String: String]) async -> (songs: [RemoteSong], failed: Int) {
        guard !ids.isEmpty else { return ([], 0) }

        var result: [RemoteSong] = []
        var failed = 0
        var index = 0
        while index < ids.count {
            let upper = min(index + 100, ids.count)
            let payload = "[" + ids[index..<upper].joined(separator: ",") + "]"
            let encoded = payload.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? payload

            if let root = try? await getJSON("https://music.163.com/api/song/detail?ids=\(encoded)", headers: headers),
               let raw = JS.array(root["songs"]) {
                result.append(contentsOf: raw.compactMap { JS.dict($0) }.compactMap(netEaseSong))
            } else {
                failed += upper - index
            }
            index = upper
        }
        return (result, failed)
    }

    /// 字段名两套都要认：v6 详情用 ar/al/dt，song/detail 用 artists/album/duration。
    /// 注意空数组不是 nil，不能用 `??` 回退 —— 否则 v6 下艺人名会整段丢掉。
    private static func netEaseSong(_ raw: [String: Any]) -> RemoteSong? {
        guard let title = JS.string(raw["name"]), !title.isEmpty else { return nil }

        let legacyArtists = JS.array(raw["artists"]) ?? []
        let modernArtists = JS.array(raw["ar"]) ?? []
        let artistNodes = legacyArtists.isEmpty ? modernArtists : legacyArtists

        let artists = artistNodes
            .compactMap { JS.dict($0) }
            .compactMap { JS.string($0["name"]) }
            .joined(separator: ", ")

        let album = [JS.dict(raw["album"]), JS.dict(raw["al"])]
            .compactMap { $0.flatMap { JS.string($0["name"]) } }
            .first { !$0.isEmpty }
        let ms = JS.int(raw["duration"]) ?? JS.int(raw["dt"]) ?? 0
        let songID = JS.int(raw["id"]).map(String.init) ?? ""
        let fee = JS.int(raw["fee"]) ?? 0
        let cover = [JS.dict(raw["al"]), JS.dict(raw["album"])]
            .compactMap { $0.flatMap { JS.string($0["picUrl"]) } }
            .first { !$0.isEmpty }
        return RemoteSong(
            title: title, artist: artists, album: album,
            duration: max(0, ms / 1000), source: .netease, sourceID: songID,
            artwork: cover, isVip: fee == 1 || fee == 4
        )
    }

    // MARK: QQ音乐

    private static func fetchQQ(id: String) async throws -> RemotePlaylist {
        let headers = [
            "Referer": "https://y.qq.com/",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        ]

        // musicu 的 songlist 一次最多给 30 首，必须按 song_begin 翻页。
        // 先取第一页拿到总数，剩下的页并发取（4 路一批），60 首的歌单
        // 从十几秒压到两三秒。
        if let first = try? await qqPage(id: id, begin: 0, size: 30, headers: headers),
           !first.songs.isEmpty {
            let total = first.total
            let lastBegin = min(total, 600) - 1
            let begins = stride(from: 30, through: lastBegin, by: 30).map { $0 }

            var pages: [(begin: Int, songs: [RemoteSong])] = [(0, first.songs)]
            if !begins.isEmpty {
                for chunk in begins.chunked(4) {
                    let fetched = await withTaskGroup(of: (begin: Int, songs: [RemoteSong]).self) { group -> [(begin: Int, songs: [RemoteSong])] in
                        for begin in chunk {
                            group.addTask {
                                let page = try? await qqPage(id: id, begin: begin, size: 30, headers: headers)
                                return (begin, page?.songs ?? [])
                            }
                        }
                        var out: [(begin: Int, songs: [RemoteSong])] = []
                        for await item in group { out.append(item) }
                        return out
                    }
                    pages.append(contentsOf: fetched)
                }
            }

            let songs = pages.sorted { $0.begin < $1.begin }.flatMap { $0.songs }
            return RemotePlaylist(
                name: first.name.isEmpty ? L("Playlist") : first.name,
                platform: .qq,
                cover: first.cover,
                songs: songs
            )
        }

        // 老接口兜底
        let url = "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&disstid=\(id)&format=json&g_tk=5381&loginUin=0&hostUin=0&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0"
        guard let root = try await getJSON(url, headers: headers),
              let cd = (JS.array(root["cdlist"]) ?? []).compactMap({ JS.dict($0) }).first else {
            throw PlaylistImportError.notFound
        }
        let list = (JS.array(cd["songlist"]) ?? []).compactMap { JS.dict($0) }
        guard !list.isEmpty else { throw PlaylistImportError.empty }
        return RemotePlaylist(
            name: JS.string(cd["dissname"]) ?? L("Playlist"),
            platform: .qq,
            cover: JS.string(cd["logo"]),
            songs: list.compactMap(qqSong)
        )
    }

    /// QQ 歌单的一页
    private struct QQPage {
        var name: String
        var cover: String?
        var total: Int
        var songs: [RemoteSong]
    }

    private static func qqPage(id: String, begin: Int, size: Int,
                               headers: [String: String]) async throws -> QQPage {
        let body: [String: Any] = [
            "comm": ["ct": 24, "cv": 0],
            "req_0": [
                "module": "music.srfDissInfo.aiDissInfo",
                "method": "uniform_get_Dissinfo",
                "param": [
                    "disstid": Int(id) ?? 0,
                    "enc_host_uin": "",
                    "tag": 1,
                    "userinfo": 1,
                    "song_begin": begin,
                    "song_num": size
                ]
            ]
        ]
        guard let root = try await postJSON("https://u.y.qq.com/cgi-bin/musicu.fcg", body: body, headers: headers),
              let data = JS.dict(JS.dict(root["req_0"])?["data"]) else {
            throw PlaylistImportError.notFound
        }
        let info = JS.dict(data["dirinfo"])
        let rawList = JS.array(data["songlist"]) ?? []
        return QQPage(
            name: JS.string(info?["title"]) ?? "",
            cover: JS.string(info?["picurl"]),
            total: JS.int(info?["songnum"]) ?? 0,
            songs: rawList.compactMap { JS.dict($0) }.compactMap(qqSong)
        )
    }

    private static func qqSong(_ raw: [String: Any]) -> RemoteSong? {
        guard let title = JS.string(raw["songname"]) ?? JS.string(raw["name"]), !title.isEmpty else {
            return nil
        }
        let artist = (JS.array(raw["singer"]) ?? [])
            .compactMap { JS.dict($0) }
            .compactMap { JS.string($0["name"]) }
            .joined(separator: ", ")
        let albumNode = JS.dict(raw["album"])
        let album = albumNode.flatMap { JS.string($0["name"]) } ?? JS.string(raw["albumname"])
        let songID = JS.string(raw["mid"]) ?? JS.string(raw["songmid"]) ?? ""
        // QQ 的封面只能靠 albummid 拼
        let albumMid = JS.string(raw["albummid"])
            ?? albumNode.flatMap { JS.string($0["mid"]) }
            ?? ""
        let cover = albumMid.isEmpty
            ? nil
            : "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg"
        return RemoteSong(
            title: title,
            artist: artist,
            album: album,
            duration: JS.int(raw["interval"]) ?? 0,
            source: .qq,
            sourceID: songID,
            artwork: cover
        )
    }

    // MARK: 酷狗

    /// 酷我歌单：nplserver 匿名可用（实测一次返回 51 首，字段 id/name/artist/album/duration 齐）。
    private static func fetchKuwo(id: String) async throws -> RemotePlaylist {
        let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        let url = "https://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=\(id)&pn=0&rn=500"
            + "&encode=utf8&keyset=pl2012&identity=kuwo&pcmp4=1&vipver=MUSIC_9.1.0"
        guard let root = try await getJSON(url, headers: [
            "Referer": "https://www.kuwo.cn/",
            "User-Agent": desktopUA
        ]) else {
            throw PlaylistImportError.notFound
        }

        let name = JS.string(root["title"]).flatMap { $0.isEmpty ? nil : $0 } ?? L("Playlist")
        let cover = JS.string(root["pic"])
        let list = (JS.array(root["musiclist"]) ?? []).compactMap { JS.dict($0) }
        let songs = list.compactMap { item -> RemoteSong? in
            guard let title = JS.string(item["name"]), !title.isEmpty,
                  let rid = JS.int(item["id"]).map(String.init) else { return nil }
            return RemoteSong(
                title: title,
                artist: JS.string(item["artist"]) ?? L("Unknown Artist"),
                album: JS.string(item["album"]),
                duration: JS.int(item["duration"]) ?? 0,
                source: .kuwo,
                sourceID: rid
            )
        }

        guard !songs.isEmpty else { throw PlaylistImportError.empty }
        return RemotePlaylist(name: name, platform: .kuwo, cover: cover, songs: songs)
    }

    private static func fetchKugou(id: String) async throws -> RemotePlaylist {
        let headers = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        ]

        var name = L("Playlist")
        var cover: String?
        if let info = try? await getJSON("http://mobilecdn.kugou.com/api/v3/special/info?specialid=\(id)&version=8000", headers: headers) {
            let node = JS.dict(info["data"]) ?? info
            if let value = JS.string(node["specialname"]), !value.isEmpty { name = value }
            cover = JS.string(node["imgurl"]) ?? JS.string(node["banner"])
        }

        var songs: [RemoteSong] = []
        var page = 1
        let pageSize = 300

        while page <= 6 {
            let url = "http://mobilecdn.kugou.com/api/v3/special/song?specialid=\(id)&page=\(page)&pagesize=\(pageSize)&version=8000"
            guard let root = try? await getJSON(url, headers: headers) else { break }
            let data = JS.dict(root["data"])
            if name == L("Playlist"), let value = JS.string(data?["specialname"]), !value.isEmpty {
                name = value
            }
            let batch = (JS.array(data?["info"]) ?? []).compactMap { JS.dict($0) }
            if batch.isEmpty { break }
            songs.append(contentsOf: batch.compactMap(kugouSong))
            let total = JS.int(data?["total"]) ?? 0
            if songs.count >= total || batch.count < pageSize { break }
            page += 1
        }

        guard !songs.isEmpty else {
            throw (page == 1 ? PlaylistImportError.notFound : PlaylistImportError.empty)
        }
        return RemotePlaylist(name: name, platform: .kugou, cover: cover, songs: songs)
    }

    private static func kugouSong(_ raw: [String: Any]) -> RemoteSong? {
        var title = JS.string(raw["songname"]) ?? ""
        var artist = JS.string(raw["singername"]) ?? ""
        if artist.isEmpty {
            // mobilecdn 的榜单接口把艺人放在 authors[].author_name
            artist = (JS.array(raw["authors"]) ?? [])
                .compactMap { JS.dict($0) }
                .compactMap { JS.string($0["author_name"]) }
                .joined(separator: ", ")
        }

        if title.isEmpty {
            // 酷狗只返回 filename，多为「歌手 - 歌名」，且不一定带扩展名
            let filename = JS.string(raw["filename"]) ?? ""
            let base = filename.replacingOccurrences(
                of: #"\.(mp3|flac|m4a|ape|wav|ogg|aac|wma)$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            let parts = base.components(separatedBy: " - ")
            if parts.count >= 2 {
                let head = parts[0].trimmingCharacters(in: .whitespaces)
                let tail = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
                if artist.isEmpty { artist = head }
                title = tail
            } else {
                title = base.trimmingCharacters(in: .whitespaces)
            }
        }

        guard !title.isEmpty else { return nil }
        // timelen 是毫秒（m.kugou），duration 是秒（mobilecdn）
        let ms = JS.int(raw["timelen"]) ?? 0
        let seconds = ms > 0 ? ms / 1000 : (JS.int(raw["duration"]) ?? 0)
        let cover = JS.string(raw["img"]) ?? JS.string(raw["album_sizable_cover"])
        return RemoteSong(
            title: title,
            artist: artist,
            album: JS.string(raw["album_name"]),
            duration: max(0, seconds),
            source: .kugou,
            sourceID: JS.string(raw["hash"]) ?? "",
            artwork: DomesticSource.normalizeArtwork(cover)
        )
    }

    // MARK: 通用 HTTP

    private static func getJSON(_ urlString: String, headers: [String: String]) async throws -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func postJSON(_ urlString: String, body: [String: Any], headers: [String: String]) async throws -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - 匹配到 YouTube Music

enum PlaylistMatcher {

    /// 直接转换，不做 YouTube 匹配。
    /// 这些 Track 的 `videoId` 是空的，播放时靠 `source` + `sourceID` 走国内直链，
    /// 全程不碰 YouTube，也就不需要代理。分类歌单 / 榜单走的就是这条路。
    static func direct(songs: [RemoteSong]) -> [Track] {
        songs.compactMap { song in
            guard !song.sourceID.isEmpty, !song.title.isEmpty else { return nil }
            return Track(
                videoId: "",
                title: song.title,
                artist: song.artist.isEmpty ? L("Unknown Artist") : song.artist,
                album: song.album,
                duration: song.duration,
                artwork: song.artwork,
                source: song.source.rawValue,
                sourceID: song.sourceID,
                isVip: song.isVip
            )
        }
    }

    /// 逐首在 YouTube Music 里搜，取时长最接近的候选
    static func match(
        songs: [RemoteSong],
        onProgress: @escaping (Int, Int) -> Void
    ) async -> [Track] {
        var results: [Track] = []
        let batchSize = 3

        var index = 0
        while index < songs.count {
            let upper = min(index + batchSize, songs.count)
            let slice = Array(songs[index..<upper])

            let batch = await withTaskGroup(of: Track?.self) { group -> [Track?] in
                for song in slice {
                    group.addTask { await matchOne(song) }
                }
                var collected: [Track?] = []
                for await item in group {
                    collected.append(item)
                }
                return collected
            }

            results.append(contentsOf: batch.compactMap { $0 })
            index = upper
            let done = min(index, songs.count)
            DispatchQueue.main.async { onProgress(done, songs.count) }

            // 大批量导入时节流，避免连续请求被限流
            if index < songs.count {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        return results
    }

    private static func matchOne(_ song: RemoteSong) async -> Track? {
        let query = [song.title, song.artist]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let candidates = (try? await InnerTube.shared.searchSongs(query: query)) ?? []

        // 搜不到（YouTube 被拦或本来就没有）时，只要原平台有 ID 就照样能播
        if candidates.isEmpty {
            guard !song.sourceID.isEmpty else { return nil }
            return Track(
                videoId: "",
                title: song.title,
                artist: song.artist.isEmpty ? L("Unknown Artist") : song.artist,
                album: song.album,
                duration: song.duration,
                artwork: song.artwork,
                source: song.source.rawValue,
                sourceID: song.sourceID,
                isVip: song.isVip
            )
        }

        let picked: Track?
        if song.duration > 20,
           let close = candidates.first(where: { abs($0.duration - song.duration) <= 6 }) {
            picked = close
        } else if song.duration > 20,
                  let near = candidates.first(where: { abs($0.duration - song.duration) <= 30 }) {
            picked = near
        } else {
            picked = candidates.first
        }

        guard var track = picked else { return nil }
        // 记住它在原平台的 ID，播放时优先走国内音源
        track.source = song.source.rawValue
        track.sourceID = song.sourceID
        // YouTube 那边没封面时，退回原平台的封面
        if track.artwork == nil { track.artwork = song.artwork }
        return track
    }
}
extension Array {
    /// 按固定大小切块。并发拉歌单时用它把页分批（每批几路并发），
    /// 既能并行，又不会一次开出几十个请求把对方打挂。
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        var out: [[Element]] = []
        var index = 0
        while index < count {
            let end = Swift.min(index + size, count)
            out.append(Array(self[index..<end]))
            index = end
        }
        return out
    }
}
