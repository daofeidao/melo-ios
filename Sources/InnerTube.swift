import Foundation

enum ApiError: LocalizedError {
    case badURL
    case http(Int)
    case parse(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "请求地址无效"
        case .http(let code):
            return "网络请求失败（HTTP \(code)）"
        case .parse(let message):
            return message
        case .unavailable(let message):
            return message
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

    func post(
        host: String,
        endpoint: String,
        key: String,
        body: [String: Any],
        userAgent: String
    ) async throws -> [String: Any] {
        guard var components = URLComponents(string: "https://\(host)/youtubei/v1/\(endpoint)") else {
            throw ApiError.badURL
        }
        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "prettyPrint", value: "false")
        ]
        guard let url = components.url else { throw ApiError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("*/*", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiError.parse("响应格式异常")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ApiError.http(http.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = root as? [String: Any] else {
            throw ApiError.parse("返回内容无法解析")
        }
        return dict
    }

    func musicContext() -> [String: Any] {
        [
            "client": [
                "clientName": "WEB_REMIX",
                "clientVersion": "1.20241127.01.00",
                "hl": "zh-CN",
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
        return try await post(
            host: "music.youtube.com", endpoint: "search", key: musicKey,
            body: body, userAgent: webUserAgent
        )
    }

    /// 歌曲 / 专辑 / 歌单三类并发查询后合并
    func search(query: String) async throws -> SearchResults {
        async let songsRoot = rawSearch(query: query, filter: InnerTube.songsFilter)
        async let albumsRoot = rawSearch(query: query, filter: InnerTube.albumsFilter)
        async let playlistsRoot = rawSearch(query: query, filter: InnerTube.playlistsFilter)

        var roots: [[String: Any]] = []
        var lastError: Error?

        do { roots.append(try await songsRoot) } catch { lastError = error }
        do { roots.append(try await albumsRoot) } catch { lastError = error }
        do { roots.append(try await playlistsRoot) } catch { lastError = error }

        guard !roots.isEmpty else {
            throw lastError ?? ApiError.parse("搜索失败")
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
        let root = try await browse(browseId: "FEmusic_home")
        return InnerTube.shelves(from: root)
    }

    func charts() async throws -> [Shelf] {
        let root = try await browse(browseId: "FEmusic_charts")
        return InnerTube.shelves(from: root)
    }

    func browse(browseId: String) async throws -> [String: Any] {
        let body: [String: Any] = ["context": musicContext(), "browseId": browseId]
        return try await post(
            host: "music.youtube.com", endpoint: "browse", key: musicKey,
            body: body, userAgent: webUserAgent
        )
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

    func player(body: [String: Any], userAgent: String) async throws -> [String: Any] {
        try await post(
            host: "www.youtube.com", endpoint: "player", key: playerKey,
            body: body, userAgent: userAgent
        )
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

        var title = "未知专辑"
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
                artist: subtitle.isEmpty ? "未知艺人" : subtitle,
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
            artist: artist.isEmpty ? "未知艺人" : artist,
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
        "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg"
    }
}
