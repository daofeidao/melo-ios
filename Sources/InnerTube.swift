import Foundation

enum ApiError: LocalizedError {
    case badURL
    case http(Int)
    case parse(String)
    case unavailable(String)
    case botCheck(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return L("Invalid request URL")
        case .http(let code):
            return String(format: L("Network request failed (HTTP %d)"), code)
        case .parse(let message):
            return message
        case .unavailable(let message):
            return message
        case .botCheck:
            return L("YouTube rejected this playback request and no matching version was found on domestic sources. Please retry later or play songs imported from a domestic playlist.")
        }
    }
}

final class InnerTube {
    static let shared = InnerTube()

    let musicKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    let playerKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
    let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)
    }

    // MARK: - Transport

    // MARK: - 传输

    /// 主域名在不少代理规则里没被接管（只写了 youtube.com/www.youtube.com），
    /// 于是连接被直连黑洞、一路等到超时。这里同时打主备两个域名，谁先回用谁。
    static let musicHosts = ["music.youtube.com", "www.youtube.com"]

    private func rawPost(
        host: String,
        endpoint: String,
        key: String,
        body: [String: Any],
        userAgent: String,
        visitorData: String?,
        origin: String? = nil,
        cookie: String? = nil
    ) async throws -> ([String: Any], Data) {
        guard var components = URLComponents(string: "https://\(host)/youtubei/v1/\(endpoint)") else {
            throw ApiError.badURL
        }
        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "prettyPrint", value: "false")
        ]
        guard let url = components.url else { throw ApiError.badURL }

        let originValue = origin ?? "https://music.youtube.com"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(originValue, forHTTPHeaderField: "Origin")
        request.setValue(originValue + "/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        // YouTube 会按「头里的客户端身份」判断给不给内容。
        // 之前不带这两个头时，备用域名 www.youtube.com 上 FEmusic_home 直接回
        // 「你所在的国家/地区还不能使用 YouTube Music」（1.6KB），歌单 browse 回空壳
        // （836B），而带上之后同一个请求是 200KB / 1MB 的正常内容。
        if let client = JS.dict(JS.dict(body["context"])?["client"]) {
            let name = JS.string(client["clientName"]) ?? ""
            if let id = InnerTube.clientNumericId(name) {
                request.setValue(id, forHTTPHeaderField: "X-YouTube-Client-Name")
            }
            if let version = JS.string(client["clientVersion"]), !version.isEmpty {
                request.setValue(version, forHTTPHeaderField: "X-YouTube-Client-Version")
            }
        }
        if let visitorData = visitorData, !visitorData.isEmpty {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        if let cookie = cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiError.parse(L("Invalid response format"))
        }
        guard (200...299).contains(http.statusCode) else {
            throw ApiError.http(http.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = root as? [String: Any] else {
            throw ApiError.parse(L("Unable to parse response"))
        }
        return (dict, data)
    }

    /// X-YouTube-Client-Name 要的是数字 ID，不是 clientName 字符串
    static func clientNumericId(_ name: String) -> String? {
        switch name {
        case "WEB_REMIX": return "67"
        case "WEB": return "1"
        case "MWEB": return "2"
        case "ANDROID": return "3"
        case "IOS": return "5"
        case "TVHTML5_SIMPLY_EMBEDDED_PLAYER": return "85"
        default: return nil
        }
    }

    /// 响应到底有没有内容。
    ///
    /// 这条判据是拿真实缓存反推出来的：坏响应的体积只有 836B~1.6KB，
    /// 要么没有 `contents`（`microformatDataRenderer.noindex` 空壳），
    /// 要么 `contents` 里只有一个 `messageRenderer`（「你所在的国家/地区还不能使用……」）。
    /// 真正的列表页是 200KB~3.5MB，并且直接带 renderer 树。
    static func isUsableResponse(_ root: [String: Any]) -> Bool {
        guard root["contents"] != nil || root["continuationContents"] != nil else { return false }
        if let error = JS.collect("messageRenderer", in: root).first,
           let text = JS.text(error["text"]), !text.isEmpty {
            Diagnostics.mark("innertube: 服务端返回提示「\(text.prefix(40))」")
            return false
        }
        // 列表页/详情页至少得有一个渲染器，纯 trackingParams 的空壳不算
        let rendererKeys = ["musicResponsiveListItemRenderer", "musicTwoRowItemRenderer",
                            "musicCarouselShelfRenderer", "musicShelvesRenderer",
                            "sectionListRenderer", "musicShelfRenderer",
                            "gridRenderer", "singleColumnBrowseResultsRenderer"]
        return rendererKeys.contains { !JS.collect($0, in: root).isEmpty }
    }

    /// 单域名请求（播放接口用，www.youtube.com 一般本来就在代理规则里）
    func post(
        host: String,
        endpoint: String,
        key: String,
        body: [String: Any],
        userAgent: String,
        visitorData: String? = nil
    ) async throws -> [String: Any] {
        try await rawPost(
            host: host, endpoint: endpoint, key: key,
            body: body, userAgent: userAgent, visitorData: visitorData
        ).0
    }

    /// 音乐接口统一入口：主备域名竞速，成功响应落盘
    func postMusic(endpoint: String, body: [String: Any], cacheKey: String? = nil, cookie: String? = nil) async throws -> [String: Any] {
        let hosts = InnerTube.musicHosts
        let primary = hosts[0]
        let fallback = hosts.count > 1 ? hosts[1] : hosts[0]

        let result = try await withThrowingTaskGroup(of: ([String: Any], Data).self) { group -> ([String: Any], Data) in
            group.addTask {
                try await self.rawPost(
                    host: primary, endpoint: endpoint, key: self.musicKey,
                    body: body, userAgent: self.webUserAgent, visitorData: nil, cookie: cookie
                )
            }
            group.addTask {
                // 3.5 秒还没回来就同时打备用域名，不必等主域名超时
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                try Task.checkCancellation()
                return try await self.rawPost(
                    host: fallback, endpoint: endpoint, key: self.musicKey,
                    body: body, userAgent: self.webUserAgent, visitorData: nil, cookie: cookie
                )
            }

            var lastError: Error?
            while true {
                do {
                    guard let value = try await group.next() else { break }
                    // 空壳/地区限制页不能当结果用：它的体积只有几百字节到 1.6KB。
                    // 慢网下备用域名会先回来，以前直接采信，于是整页空白，还被写进缓存，
                    // 之后每次打开都是空白——这就是「歌单专辑全部打不开」的成因。
                    if !InnerTube.isUsableResponse(value.0) {
                        Diagnostics.mark("innertube: \(endpoint) 返回空壳 \(value.1.count)B，等另一个域名")
                        lastError = ApiError.unavailable(
                            L("YouTube Music returned no content. Retry, or check that your proxy covers music.youtube.com."))
                        continue
                    }
                    group.cancelAll()
                    return value
                } catch {
                    lastError = error
                    continue
                }
            }
            throw lastError ?? ApiError.unavailable(L("Unable to parse response"))
        }

        if let cacheKey = cacheKey {
            saveCache(result.1, key: cacheKey)
        }
        return result.0
    }

    // MARK: - 响应缓存

    private var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("responses", isDirectory: true)
    }

    private func cacheURL(for key: String) -> URL {
        cacheDirectory.appendingPathComponent("\(key).json")
    }

    private func saveCache(_ data: Data, key: String) {
        let url = cacheURL(for: key)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func loadCache(_ key: String) -> Data? {
        let url = cacheURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // 旧版本把「地区限制页 / 空壳响应」也落了盘（836B~1.6KB）。读的时候再过一遍，
        // 不合格的当场删掉返回 nil，让上层重新请求，而不是一直展示空白页。
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let hasContents = root["contents"] != nil || root["continuationContents"] != nil
            let hasMessage = !JS.collect("messageRenderer", in: root).isEmpty
            if !hasContents || hasMessage {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        }
        return data
    }

    /// 首页缓存：把几个入口的缓存合并成一份
    func cachedHomeShelves() -> [Shelf]? {
        var merged: [Shelf] = []
        var seenTitles = Set<String>()
        for feed in ["FEmusic_home", "FEmusic_explore", "FEmusic_charts"] {
            guard let shelves = cachedShelves(key: "browse_\(feed)") else { continue }
            for shelf in shelves where !shelf.title.isEmpty && !seenTitles.contains(shelf.title) {
                seenTitles.insert(shelf.title)
                merged.append(shelf)
            }
        }
        return merged.isEmpty ? nil : merged
    }

    /// 冷启动先用上次成功的结果铺满页面，再后台刷新
    func cachedShelves(key: String) -> [Shelf]? {
        guard let data = loadCache(key),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return nil }
        let shelves = InnerTube.shelves(from: root)
        return shelves.isEmpty ? nil : shelves
    }

    /// 内容语言跟随界面语言，否则英文界面下会出现中文分区标题
    static var contentLanguage: String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? "zh-CN" : "en"
    }

    func musicContext() -> [String: Any] {
        [
            "client": [
                "clientName": "WEB_REMIX",
                "clientVersion": "1.20241127.01.00",
                "hl": InnerTube.contentLanguage,
                "gl": "US"
            ]
        ]
    }

    // MARK: - Public API

    /// 分类筛选参数；缺少它只会返回普通视频（没有艺人/专辑字段）
    static let songsFilter = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
    static let albumsFilter = "EgWKAQIYAWoKEAkQChAFEAMQBA%3D%3D"
    static let playlistsFilter = "EgWKAQIoAWoKEAkQChAFEAMQBA%3D%3D"

    private func rawSearch(query: String, filter: String) async throws -> [String: Any] {
        let body: [String: Any] = ["context": musicContext(), "query": query, "params": filter]
        return try await postMusic(endpoint: "search", body: body)
    }

    /// 只查歌曲，供歌单批量匹配使用（单请求，比三路并发轻）
    func searchSongs(query: String) async throws -> [Track] {
        let root = try await rawSearch(query: query, filter: InnerTube.songsFilter)
        return InnerTube.parseSearch(root).tracks
    }

    /// 歌曲 / 专辑 / 歌单三类并发查询后合并
    func search(query: String) async throws -> SearchResults {
        // 这里刻意不用 `async let`：三类查询里只要有一类先抛错，父作用域就会
        // 提前退出，触发 Swift 6 运行时的 asyncLet_finish_after_task_completion
        // fatalError（实测直接 SIGABRT，搜索页必崩）。改成 Task + await 就绕开了，
        // 而且"某一路失败不影响其它两路"的语义也更明确。
        let songsJob = Task { try await self.rawSearch(query: query, filter: InnerTube.songsFilter) }
        let albumsJob = Task { try await self.rawSearch(query: query, filter: InnerTube.albumsFilter) }
        let playlistsJob = Task { try await self.rawSearch(query: query, filter: InnerTube.playlistsFilter) }

        var roots: [[String: Any]] = []
        var lastError: Error?

        do { roots.append(try await songsJob.value) } catch { lastError = error }
        do { roots.append(try await albumsJob.value) } catch { lastError = error }
        do { roots.append(try await playlistsJob.value) } catch { lastError = error }

        guard !roots.isEmpty else {
            throw lastError ?? ApiError.parse(L("Search failed"))
        }

        var merged = SearchResults()
        var seenTracks = Set<String>()
        var seenCollections = Set<String>()

        for root in roots {
            let partial = InnerTube.parseSearch(root)
            for track in partial.tracks where !seenTracks.contains(track.videoId) {
                seenTracks.insert(track.videoId)
                merged.tracks.append(track)
            }
            for collection in partial.collections where !seenCollections.contains(collection.browseId) {
                seenCollections.insert(collection.browseId)
                merged.collections.append(collection)
            }
        }
        return merged
    }

    func home() async throws -> [Shelf] {
        // 未登录的 FEmusic_home 只给 2 个分区，单独用会显得"没内容"。
        // 这里并发把探索/榜单一起取回来合并，既更饱满也能互相兜底。
        let feeds = ["FEmusic_home", "FEmusic_explore", "FEmusic_charts"]

        var gathered: [Int: [Shelf]] = [:]
        await withTaskGroup(of: (Int, [Shelf]).self) { group in
            for (index, feed) in feeds.enumerated() {
                group.addTask { [weak self] in
                    guard let self = self,
                          let root = try? await self.browse(browseId: feed) else {
                        return (index, [])
                    }
                    return (index, InnerTube.shelves(from: root))
                }
            }
            for await (index, shelves) in group {
                gathered[index] = shelves
            }
        }

        var merged: [Shelf] = []
        var seenTitles = Set<String>()
        for index in feeds.indices {
            for shelf in gathered[index] ?? [] {
                guard !shelf.title.isEmpty, !seenTitles.contains(shelf.title) else { continue }
                seenTitles.insert(shelf.title)
                merged.append(shelf)
            }
        }

        guard !merged.isEmpty else {
            throw ApiError.unavailable(L("No content was returned. Check that your proxy also covers music.youtube.com, then retry."))
        }
        return merged
    }

    func charts() async throws -> [Shelf] {
        let root = try await browse(browseId: "FEmusic_charts")
        return InnerTube.shelves(from: root)
    }

    func browse(browseId: String) async throws -> [String: Any] {
        let body: [String: Any] = ["context": musicContext(), "browseId": browseId]
        return try await postMusic(endpoint: "browse", body: body, cacheKey: "browse_\(browseId)")
    }

    func collection(browseId: String) async throws -> CollectionDetail {
        if browseId.hasPrefix("v:") {
            // 直接可播的单曲（来自推荐的 two-row 项）
            let videoId = String(browseId.dropFirst(2))
            return CollectionDetail(title: "", subtitle: "", artwork: nil, tracks: [
                Track(videoId: videoId, title: "", artist: "", album: nil, duration: 0, artwork: nil)
            ])
        }
        let root = try await browse(browseId: browseId)
        return InnerTube.parseCollection(root)
    }

    func player(body: [String: Any], userAgent: String, visitorData: String? = nil, cookie: String? = nil, music: Bool = false) async throws -> [String: Any] {
        // WEB_REMIX（YouTube Music 客户端）必须打 music.youtube.com + musicKey；
        // 其他 Web 客户端走 www.youtube.com + playerKey。
        try await rawPost(
            host: music ? "music.youtube.com" : "www.youtube.com",
            endpoint: "player",
            key: music ? musicKey : playerKey,
            body: body, userAgent: userAgent, visitorData: visitorData, cookie: cookie
        ).0
    }

    /// 从 Innertube 响应里挖 dataSyncId（登录态下 PO Token / GVS 的绑定标识）。
    /// 位置：responseContext.mainAppWebResponseContext.dataSyncId。
    /// 未登录时没有这个字段，返回 nil。
    static func dataSyncId(from root: [String: Any]) -> String? {
        guard let ctx = JS.dict(root["responseContext"]),
              let main = JS.dict(ctx["mainAppWebResponseContext"]),
              let id = JS.string(main["dataSyncId"]), !id.isEmpty else { return nil }
        return id
    }

    // MARK: - 连接诊断

    struct HostProbe {
        let host: String
        let milliseconds: Int?
        let failure: String?
    }

    /// 只看能不能连通，不拉数据，用来判断代理是否覆盖了 music.youtube.com
    func diagnose() async -> [HostProbe] {
        var results: [HostProbe] = []
        for host in InnerTube.musicHosts {
            guard let url = URL(string: "https://\(host)/") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")

            let started = Date()
            do {
                let (_, response) = try await session.data(for: request)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                results.append(HostProbe(
                    host: host,
                    milliseconds: code == 200 ? ms : nil,
                    failure: code == 200 ? nil : "HTTP \(code)"
                ))
            } catch {
                results.append(HostProbe(host: host, milliseconds: nil, failure: error.localizedDescription))
            }
        }
        return results
    }

    // MARK: - Parsing

    static func parseSearch(_ root: [String: Any]) -> SearchResults {
        var results = SearchResults()

        var seenTracks = Set<String>()
        var seenResponsiveCollections = Set<String>()

        for renderer in JS.collect("musicResponsiveListItemRenderer", in: root) {
            if let track = track(from: renderer) {
                guard !seenTracks.contains(track.videoId) else { continue }
                seenTracks.insert(track.videoId)
                results.tracks.append(track)
            } else if let collection = collection(fromResponsive: renderer) {
                // 专辑/歌单搜索结果同样是 responsive 条目，靠 browseEndpoint 区分
                guard !seenResponsiveCollections.contains(collection.browseId) else { continue }
                seenResponsiveCollections.insert(collection.browseId)
                results.collections.append(collection)
            }
        }

        var seenCollections = Set<String>()
        for renderer in JS.collect("musicTwoRowItemRenderer", in: root) {
            guard let item = shelfItem(from: renderer) else { continue }
            switch item {
            case .track(let track):
                guard !seenTracks.contains(track.videoId) else { continue }
                seenTracks.insert(track.videoId)
                results.tracks.append(track)
            case .collection(let collection):
                guard !seenCollections.contains(collection.browseId) else { continue }
                seenCollections.insert(collection.browseId)
                results.collections.append(collection)
            }
        }
        return results
    }

    static func parseCollection(_ root: [String: Any]) -> CollectionDetail {
        let header = JS.collect("musicResponsiveHeaderRenderer", in: root).first
            ?? JS.collect("musicDetailHeaderRenderer", in: root).first

        var title = L("Unknown Album")
        var subtitleParts: [String] = []
        if let header = header {
            if let t = JS.text(header["title"]), !t.isEmpty { title = t }
            for key in ["subtitle", "secondSubtitle", "straplineTextOne"] {
                if let s = JS.text(header[key]), !s.isEmpty { subtitleParts.append(s) }
            }
            if let description = JS.text(header["description"]), !description.isEmpty, subtitleParts.isEmpty {
                subtitleParts.append(description)
            }
        }

        var tracks: [Track] = []
        var seen = Set<String>()
        for renderer in JS.collect("musicResponsiveListItemRenderer", in: root) {
            guard let track = track(from: renderer) else { continue }
            guard !seen.contains(track.videoId) else { continue }
            seen.insert(track.videoId)
            tracks.append(track)
        }

        return CollectionDetail(
            title: title,
            subtitle: subtitleParts.joined(separator: " · "),
            artwork: header.flatMap { bestArtwork(in: $0) } ?? tracks.first?.artwork,
            tracks: tracks
        )
    }

    static func shelves(from root: [String: Any]) -> [Shelf] {
        var result: [Shelf] = []

        let carousels = JS.collect("musicCarouselShelfRenderer", in: root)
        for carousel in carousels {
            let header = JS.dict(carousel["header"])?["musicCarouselShelfBasicHeaderRenderer"]
            let title = JS.text(JS.dict(header)?["title"]) ?? ""
            let items = shelfItems(from: carousel["contents"])
            if !items.isEmpty {
                result.append(Shelf(title: title, items: items))
            }
        }

        if result.isEmpty {
            for shelf in JS.collect("musicShelfRenderer", in: root) {
                let title = JS.text(shelf["title"]) ?? ""
                let items = shelfItems(from: shelf["contents"])
                if !items.isEmpty {
                    result.append(Shelf(title: title, items: items))
                }
            }
        }

        return result
    }

    static func shelfItems(from contents: Any?) -> [ShelfItem] {
        var items: [ShelfItem] = []

        var seen = Set<String>()
        for renderer in JS.collect("musicTwoRowItemRenderer", in: contents) {
            guard let item = shelfItem(from: renderer) else { continue }
            guard !seen.contains(item.id) else { continue }
            seen.insert(item.id)
            items.append(item)
        }

        if items.isEmpty {
            for renderer in JS.collect("musicResponsiveListItemRenderer", in: contents) {
                guard let track = track(from: renderer) else { continue }
                guard !seen.contains("t:" + track.videoId) else { continue }
                seen.insert("t:" + track.videoId)
                items.append(.track(track))
            }
        }
        return items
    }

    static func shelfItem(from renderer: [String: Any]) -> ShelfItem? {
        let title = JS.text(renderer["title"]) ?? ""
        guard !title.isEmpty else { return nil }

        let navigation = JS.dict(renderer["navigationEndpoint"])
        let browseEndpoint = JS.dict(navigation?["browseEndpoint"])
        let browseId = JS.string(browseEndpoint?["browseId"])
        let watchId = JS.string(JS.dict(navigation?["watchEndpoint"])?["videoId"])
        let subtitle = JS.text(renderer["subtitle"]) ?? ""

        // 只有 watchEndpoint、没有 browseEndpoint 的是可直接播放的单曲
        if browseId == nil, let watchId = watchId {
            return .track(Track(
                videoId: watchId,
                title: title,
                artist: subtitle.isEmpty ? L("Unknown Artist") : subtitle,
                album: nil,
                duration: 0,
                artwork: bestArtwork(in: renderer) ?? youtubeFallback(videoId: watchId)
            ))
        }

        guard let id = browseId else { return nil }
        let pageType = JS.string(
            JS.dict(JS.dict(browseEndpoint?["browseEndpointContextSupportedConfigs"])?["browseEndpointContextMusicConfig"])?["pageType"]
        )

        return .collection(MediaCollection(
            browseId: id,
            title: title,
            subtitle: subtitle,
            artwork: bestArtwork(in: renderer),
            isRound: pageType == "MUSIC_PAGE_TYPE_ARTIST"
        ))
    }

    static func collection(fromResponsive renderer: [String: Any]) -> MediaCollection? {
        let columns = JS.collect("musicResponsiveListItemFlexColumnRenderer", in: renderer)
        guard let title = columns.first.flatMap({ JS.text($0["text"]) }), !title.isEmpty else {
            return nil
        }

        var browseId: String?
        var matchedPageType: String?

        for column in columns {
            for run in JS.runs(column["text"]) {
                guard let pageType = run.pageType else { continue }
                if pageType == "MUSIC_PAGE_TYPE_ALBUM" || pageType == "MUSIC_PAGE_TYPE_PLAYLIST" {
                    browseId = run.browseId
                    matchedPageType = pageType
                    break
                }
            }
            if browseId != nil { break }
        }

        if browseId == nil {
            for endpoint in JS.collect("browseEndpoint", in: renderer) {
                guard let candidate = JS.string(endpoint["browseId"]) else { continue }
                if candidate.hasPrefix("MPRE") || candidate.hasPrefix("VL") {
                    browseId = candidate
                    break
                }
            }
        }

        guard let id = browseId else { return nil }

        var subtitle = ""
        if columns.count > 1, let raw = JS.text(columns[1]["text"]) {
            subtitle = raw
                .replacingOccurrences(of: " • ", with: " · ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return MediaCollection(
            browseId: id,
            title: title,
            subtitle: subtitle,
            artwork: bestArtwork(in: renderer),
            isRound: matchedPageType == "MUSIC_PAGE_TYPE_ARTIST"
        )
    }

    static func track(from renderer: [String: Any]) -> Track? {
        guard let videoId = videoId(in: renderer) else { return nil }

        let columns = JS.collect("musicResponsiveListItemFlexColumnRenderer", in: renderer)
        guard let firstColumn = columns.first, let title = JS.text(firstColumn["text"]), !title.isEmpty else {
            return nil
        }

        var artist = ""
        var album: String?

        if columns.count > 1 {
            var artists: [String] = []
            for run in JS.runs(columns[1]["text"]) {
                let value = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty || value == "•" { continue }
                switch run.pageType {
                case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_LIBRARY_ARTIST":
                    artists.append(value)
                case "MUSIC_PAGE_TYPE_ALBUM":
                    album = value
                default:
                    if JS.looksLikeClock(value) { continue }
                    if artists.isEmpty { artists.append(value) }
                }
            }
            artist = artists.joined(separator: ", ")

            if artist.isEmpty {
                let joined = JS.text(columns[1]["text"]) ?? ""
                let parts = joined
                    .split(separator: "•")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !JS.looksLikeClock($0) }
                if let first = parts.first { artist = first }
                if parts.count > 1, album == nil { album = parts[1] }
            }
        }

        var duration = 0
        if let fixed = JS.collect("musicResponsiveListItemFixedColumnRenderer", in: renderer).first,
           let clock = JS.text(fixed["text"]) {
            duration = JS.seconds(fromClock: clock)
        }
        if duration == 0 {
            for column in columns {
                for run in JS.runs(column["text"]) where JS.looksLikeClock(run.text) {
                    duration = JS.seconds(fromClock: run.text)
                    if duration > 0 { break }
                }
                if duration > 0 { break }
            }
        }

        return Track(
            videoId: videoId,
            title: title,
            artist: artist.isEmpty ? L("Unknown Artist") : artist,
            album: album,
            duration: duration,
            artwork: bestArtwork(in: renderer) ?? youtubeFallback(videoId: videoId)
        )
    }

    static func videoId(in renderer: [String: Any]) -> String? {
        if let data = JS.dict(renderer["playlistItemData"]), let value = JS.string(data["videoId"]) {
            return value
        }
        for endpoint in JS.collect("watchEndpoint", in: renderer) {
            if let value = JS.string(endpoint["videoId"]) { return value }
        }
        if let value = JS.string(renderer["videoId"]) { return value }
        return nil
    }

    static func bestArtwork(in root: Any?, width: Int = 544) -> String? {
        var best: (url: String, width: Int)?
        for thumbnails in JS.collectArrays("thumbnails", in: root) {
            for item in JS.array(thumbnails) ?? [] {
                guard let dict = JS.dict(item), let url = JS.string(dict["url"]) else { continue }
                let w = JS.int(dict["width"]) ?? 0
                if best == nil || w > best!.width {
                    best = (url, w)
                }
            }
        }
        guard let found = best else { return nil }
        return resized(url: found.url, width: width)
    }

    static func resized(url: String, width: Int) -> String {
        guard url.contains("googleusercontent.com") || url.contains("ggpht.com") else { return url }
        let patterns = ["=w\\d+-h\\d+", "=s\\d+", "/w\\d+-h\\d+/", "/s\\d+/"]
        var output = url
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            let replacement: String
            if pattern.contains("/") {
                replacement = "/w\(width)-h\(width)/"
            } else if pattern.hasPrefix("=s") {
                replacement = "=s\(width)"
            } else {
                replacement = "=w\(width)-h\(width)"
            }
            output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: replacement)
        }
        return output
    }

    static func youtubeFallback(videoId: String) -> String {
        "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg"
    }
}
