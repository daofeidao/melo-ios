import Foundation

enum StreamResolver {

    enum Quality: String, CaseIterable, Identifiable {
        case lossless
        case high
        case normal
        case low

        var id: String { rawValue }

        var label: String {
            switch self {
            case .lossless: return L("Lossless")
            case .high: return L("High")
            case .normal: return L("Standard")
            case .low: return L("Data Saver")
            }
        }

        var detail: String {
            switch self {
            case .lossless: return L("FLAC where the source has it. Needs a signed-in membership account.")
            case .high: return L("Up to 320 kbps")
            case .normal: return L("About 128 kbps")
            case .low: return L("About 64 kbps")
            }
        }

        /// 国内源要码率数字：网易云按 br、腾讯按文件名前缀、酷我按 query
        var neteaseBitrates: [Int] {
            switch self {
            case .lossless: return [999_000, 320_000, 128_000]
            case .high: return [320_000, 128_000]
            case .normal, .low: return [128_000]
            }
        }

        var kuwoVariants: [String] {
            switch self {
            case .lossless: return ["format=flac&br=2000kflac", "format=mp3&br=320kmp3", "format=mp3&br=128kmp3"]
            case .high: return ["format=mp3&br=320kmp3", "format=mp3&br=128kmp3"]
            case .normal, .low: return ["format=mp3&br=128kmp3"]
            }
        }

        /// 文件名前缀即码率：C400=m4a 128、M500=mp3 320、F000=flac（付费）
        var qqTiers: [(String, String)] {
            switch self {
            case .lossless: return [("F000", "flac"), ("M500", "mp3"), ("C400", "m4a")]
            case .high: return [("M500", "mp3"), ("C400", "m4a")]
            case .normal, .low: return [("C400", "m4a")]
            }
        }
    }

    private struct Client {
        let id: String
        let name: String
        let version: String
        let extra: [String: Any]
        let userAgent: String
    }

    /// 对外只暴露数量，`Client` 是私有类型
    static var clientCount: Int { clients.count }

    private static let winnerKey = "melo.youtubeClientID"

    /// 上次成功解析用的身份。正常起播只打这一个请求，身份失效时再并发竞速。
    private static var winnerID: String? {
        get { UserDefaults.standard.string(forKey: winnerKey) }
        set {
            if let value = newValue {
                UserDefaults.standard.set(value, forKey: winnerKey)
            } else {
                UserDefaults.standard.removeObject(forKey: winnerKey)
            }
        }
    }

    /// 起播时的 UA 必须跟着解析身份走，否则 googlevideo 返回 403
    static var clientUserAgent: String {
        guard let id = winnerID, let client = clients.first(where: { $0.id == id }) else {
            return clients[0].userAgent
        }
        return client.userAgent
    }

    /// SABR / UMP 是 protobuf 分帧流，AVPlayer 解不了，不能选进格式池
    private static func isSABR(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("/sb/") || lower.contains("sabr") || lower.contains("ump")
    }

    /// 客户端池只保留「浏览器侧」身份（WEB / WEB_REMIX / MWEB / WEB_EMBEDDED_PLAYER）。
    ///
    /// 根本原因（2026-11-17 实测确认）：YouTube 的 PO Token（Proof of Origin）是
    /// **绑定客户端类型**的。本项目里的 PO Token 一直是用 WEB_REMIX 从 BotGuard 铸的
    /// （见 PoTokenMinter.fetchVisitorData 的 clientName = WEB_REMIX），却把它塞进
    /// IOS / ANDROID / TV 的 player 请求 —— token 与 client 错配，等于挂了个假通行证，
    /// YouTube 一眼判 LOGIN_REQUIRED。
    ///
    /// IOS / ANDROID 还需要 DroidGuard / iOSGuard / 设备注册态，本项目没有这些，
    /// 永远过不了；TV / VR 同样要独立鉴权。它们只会拖慢竞速、污染结果，一并移除。
    ///
    /// 现在的原则：**PO Token 铸自哪个 client，player 请求就用哪个 client**，
    /// 身份完全自洽。
    ///
    /// 关键（2026-11-17 Mac 实测，权威对照 yt-dlp + BgUtils 官方代码）：
    /// 1. YouTube 2025-02 起对 **web / mweb** 客户端强制 SABR 分帧流，
    ///    adaptiveFormats 不再给明文 url（AVPlayer 解不了 SABR）。
    /// 2. **ANDROID 客户端不受 SABR 强制**，直接返回带明文 url 的音频格式，
    ///    且**不需要 PO Token、不需要登录、不需要干净出口 IP**（实测 206 + 真 MP4/WebM 数据）。
    ///    所以它排最前，是现在唯一稳定拿到直链的客户端。
    /// 3. 它必须带 `osName` / `osVersion` / `androidSdkVersion`，缺了会被判机器人。
    /// 4. tv / web 系仍作兜底，但它们要么要 TV 平台 token，要么被 SABR 强制。
    private static let clients: [Client] = [
        Client(
            id: "android",
            name: "ANDROID",
            version: "20.10.38",
            extra: [
                "hl": "en", "gl": "US",
                "androidSdkVersion": 34,
                "osName": "Android",
                "osVersion": "14"
            ],
            userAgent: "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip"
        ),
        Client(
            id: "tv",
            name: "TVHTML5",
            version: "7.20241001.00.00",
            extra: ["hl": "en", "gl": "US"],
            userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"
        ),
        Client(
            id: "web-remix",
            name: "WEB_REMIX",
            version: "1.20241127.01.00",
            extra: ["hl": "en", "gl": "US"],
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        ),
        Client(
            id: "web",
            name: "WEB",
            version: "2.20241114.00.00",
            extra: ["hl": "en", "gl": "US"],
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        ),
        Client(
            id: "mweb",
            name: "MWEB",
            version: "2.20241114.05.00",
            extra: ["hl": "en", "gl": "US"],
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
        )
    ]

    static func resolve(videoId: String, quality: Quality) async throws -> AudioStream {
        // ── 路线一（主）：ANDROID 客户端直取明文直链。
        //
        // 实测（2026-11-18，同一 IP，浏览器能播）：
        //  - 不是 IP、不是 pot、不是 range：是匿名 ANDROID 客户端被**概率性风控**。
        //    连续 15 次请求，status 在 OK / LOGIN_REQUIRED("Sign in to confirm
        //    you're not a bot") 之间跳，成功率约 40%。
        //  - 浏览器稳定 OK 只是因为它有完整会话，不被抽样。
        //  - 重试 6 次的累计成功率 = 1-(0.6)^6 ≈ 95%，足够可靠。
        //
        // 关键：不要先铸 PO Token（要 4~20 秒）——ANDROID 直链本来就不带 pot 也能播，
        // 铸 token 只会拖慢起播。拿到直链后按需再铸。
        if let android = clients.first(where: { $0.id == "android" }) {
            for _ in 0..<6 {
                if let stream = try? await attempt(videoId: videoId, client: android,
                                                   quality: quality, po: nil, pot: nil) {
                    Diagnostics.mark("youtube: android resolved (retry ok)")
                    return stream
                }
                try? await Task.sleep(nanoseconds: 200_000_000)  // 0.2s
            }
            Diagnostics.mark("youtube: android failed after 6 tries")
        }

        // ── 路线二：兜底 —— 让真实浏览器（WKWebView）铸 PO Token，Melo 只读。
        // 前面所有客户端都失败时才走：开浏览器要 3~10 秒，作为最后手段。
        if let stream = try? await attemptWithBrowserToken(videoId: videoId, quality: quality) {
            return stream
        }

        // ── 路线三：用户登录了 YouTube，走「浏览器登录态」。
        if let cookie = SourcePrefs.shared.cookie("youtube"),
           let stream = try? await attemptWithCookie(videoId: videoId, quality: quality, cookie: cookie) {
            return stream
        }

        // ── 路线四（兜底）：铸 PO Token + 各客户端竞速。
        // 走到这里说明 ANDROID 连试 6 次都没过（风控冷却），才值得花 4~20 秒铸 token。
        let po = await PoTokenMinter.shared.token(for: videoId)
        let outcome = await withTaskGroup(
            of: Result<AudioStream, Error>.self
        ) { group -> (stream: AudioStream?, botChecked: Bool, failures: [String]) in
            for client in clients {
                group.addTask {
                    do {
                        return .success(try await attempt(videoId: videoId, client: client, quality: quality,
                                                          po: po, pot: po?.poToken))
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var stream: AudioStream?
            var botChecked = false
            var failures: [String] = []

            for await result in group {
                switch result {
                case .success(let value):
                    stream = value
                    group.cancelAll()
                case .failure(let error):
                    if let typed = error as? ApiError, case .botCheck = typed {
                        botChecked = true
                    } else {
                        failures.append((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                    }
                }
                if stream != nil { break }
            }
            return (stream, botChecked, failures)
        }

        if let stream = outcome.stream { return stream }

        // 全部被拒：优先按「机器人判定」报错，方便上层触发熔断与提示
        if outcome.botChecked, outcome.failures.isEmpty {
            throw ApiError.botCheck("")
        }

        let detail = outcome.failures.first ?? L("Unknown reason")
        throw ApiError.unavailable(String(format: L("Unable to resolve playback URL: %@"), detail))
    }

    private static func attempt(
        videoId: String,
        client: Client,
        quality: Quality,
        po: (poToken: String, visitorData: String)?,
        pot: String? = nil
    ) async throws -> AudioStream {
        var clientContext = client.extra
        clientContext["clientName"] = client.name
        clientContext["clientVersion"] = client.version

        var body: [String: Any] = [
            "context": ["client": clientContext],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        // PO Token 是 Web 平台铸的（BotGuard），配 Web 平台客户端（tv/web-remix/web）通用；
        // android/mweb 是别的平台，塞 Web 的 token 反而错配，所以不带。
        if client.id == "tv" || client.id == "web-remix" || client.id == "web", let po = po {
            body["serviceIntegrityDimensions"] = ["poToken": po.poToken]
        }

        let root = try await InnerTube.shared.player(
            body: body,
            userAgent: client.userAgent,
            visitorData: po?.visitorData,
            music: client.id == "web-remix"
        )

        // GVS PO Token 作为 &pot= 附在音频直链上——网页能稳定播的关键（BgUtils 官方示例）。
        // 对 IP 绑定不敏感，动态出口下实测 8/8 206。
        return try parseStream(root: root, client: client, quality: quality, pot: pot)
    }

    /// 路线零：用「真实浏览器铸好的 PO Token」请求 player。
    ///
    /// 关键：token 是浏览器铸的（Web 平台 BotGuard），配 tv 客户端用 —— tv 是 Web 平台
    /// 客户端，而且**不受 SABR 强制**（web/mweb 被强制 SABR，AVPlayer 解不了）。
    /// 所以这里 tv 排第一，拿到明文直链的概率最高。
    private static func attemptWithBrowserToken(videoId: String, quality: Quality) async throws -> AudioStream {
        // 先看页面内联的 player response：如果浏览器拿到的就是明文直链，直接用，
        // 连 player 接口都不用打（这正是「网页能播」的形态）。
        if let inline = try? await BrowserPoTokenProvider.shared.inspectInlineResponse(videoID: videoId) {
            Diagnostics.mark("browserInline: status=\(inline.status) sabr=\(inline.hasSabr) 明文=\(inline.audio.filter { $0.hasURL }.count)/\(inline.audio.count) poToken=\(inline.inlinePoToken.count)")
            for f in inline.audio {
                Diagnostics.mark("browserInline: itag=\(f.itag) \(f.mime) \(f.bitrate) url=\(f.hasURL) cipher=\(f.hasCipher)")
            }
            if let direct = inline.audio.first(where: { $0.hasURL && $0.mime.contains("mp4") }),
               let url = URL(string: direct.fullURL) {
                Diagnostics.mark("browserInline: 直接用明文直链 itag=\(direct.itag)")
                winnerID = "browser-inline"
                return AudioStream(url: url, itag: direct.itag, bitrate: direct.bitrate, mime: direct.mime, userAgent: BrowserPoTokenProvider.desktopUA)
            }
        }

        // 再从渲染后的 DOM 里找 PO Token（yt-dlp webpo provider 的做法）
        if let domToken = try? await BrowserPoTokenProvider.shared.domPoToken(videoID: videoId), !domToken.isEmpty {
            Diagnostics.mark("browserDom: 用 DOM 里的 token \(domToken.count) chars")
            if let stream = try? await attemptWithToken(videoId: videoId, quality: quality, poToken: domToken, visitorData: nil) {
                return stream
            }
        }

        let captured = try await BrowserPoTokenProvider.shared.token(for: videoId)
        Diagnostics.mark("browserPo: token \(captured.poToken.count) chars, page client=\(captured.clientName)")
        return try await attemptWithToken(
            videoId: videoId, quality: quality, poToken: captured.poToken,
            visitorData: captured.visitorData.isEmpty ? nil : captured.visitorData
        )
    }

    /// 用给定的 PO Token 试各客户端。
    /// 顺序「tv → web-remix → web」：tv 不受 SABR 强制，最可能给出明文直链。
    private static func attemptWithToken(
        videoId: String,
        quality: Quality,
        poToken: String,
        visitorData: String?
    ) async throws -> AudioStream {
        let order = ["tv", "web-remix", "web"]
        for id in order {
            guard let client = clients.first(where: { $0.id == id }) else { continue }
            var clientContext = client.extra
            clientContext["clientName"] = client.name
            clientContext["clientVersion"] = client.version

            var body: [String: Any] = [
                "context": ["client": clientContext],
                "videoId": videoId,
                "contentCheckOk": true,
                "racyCheckOk": true
            ]
            body["serviceIntegrityDimensions"] = ["poToken": poToken]

            let root = try await InnerTube.shared.player(
                body: body,
                userAgent: client.userAgent,
                visitorData: visitorData,
                music: client.id == "web-remix"
            )

            do {
                let stream = try parseStream(root: root, client: client, quality: quality)
                Diagnostics.mark("browserPo: resolved via \(client.id)")
                winnerID = client.id
                return stream
            } catch {
                Diagnostics.mark("browserPo: \(client.id) failed – \((error as? LocalizedError)?.errorDescription ?? "?" )")
            }
        }
        throw ApiError.unavailable(L("The browser token was rejected by YouTube"))
    }

    /// 路线一：带用户录好的 YouTube 登录 Cookie 请求 player。
    /// 这是「浏览器登录态」路线 —— 和「网页登录后播放」完全自洽，穿透力最强。
    /// 登录态下 PO Token 绑 dataSyncId（而非 videoId），见 yt-dlp PO Token Guide。
    private static func attemptWithCookie(
        videoId: String,
        quality: Quality,
        cookie: String
    ) async throws -> AudioStream {
        // 用 WEB_REMIX（和登录网页一致），身份自洽
        guard let client = clients.first(where: { $0.id == "web-remix" }) else {
            throw ApiError.unavailable(L("No client available"))
        }
        var clientContext = client.extra
        clientContext["clientName"] = client.name
        clientContext["clientVersion"] = client.version

        var body: [String: Any] = [
            "context": ["client": clientContext],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]

        // 登录态铸 PO Token：带 Cookie 拿 visitorData + dataSyncId，token 绑 dataSyncId
        var visitorData: String?
        if let login = await PoTokenMinter.shared.tokenWithCookie(for: videoId, cookie: cookie) {
            visitorData = login.visitorData
            body["serviceIntegrityDimensions"] = ["poToken": login.poToken]
        }

        let root = try await InnerTube.shared.player(
            body: body,
            userAgent: client.userAgent,
            visitorData: visitorData,
            cookie: cookie
        )
        Diagnostics.mark("player[cookie] resolved")

        let stream = try parseStream(root: root, client: client, quality: quality)
        // cookie 路线成功也记下来，下次可优先走
        winnerID = client.id
        return stream
    }

    /// 从 player 响应里挑出音频流。attempt / attemptWithCookie 共用。
    private static func parseStream(
        root: [String: Any],
        client: Client,
        quality: Quality,
        pot: String? = nil
    ) throws -> AudioStream {
        if let status = JS.dict(root["playabilityStatus"]),
           let state = JS.string(status["status"]),
           state != "OK" {
            let reason = JS.string(status["reason"]) ?? state
            Diagnostics.mark("player[\(client.id)]: \(state) · \(reason)")
            if state == "LOGIN_REQUIRED" {
                // PO Token 可能过期了，下次重铸
                Task { await PoTokenMinter.shared.invalidate() }
                throw ApiError.botCheck(reason)
            }
            throw ApiError.unavailable(reason)
        }

        let formats = JS.array(JS.dict(root["streamingData"])?["adaptiveFormats"]) ?? []
        var aacFormats: [[String: Any]] = []
        var otherAudio: [[String: Any]] = []

        for raw in formats {
            guard let format = JS.dict(raw),
                  let mime = JS.string(format["mimeType"]),
                  mime.hasPrefix("audio/"),
                  let formatURL = JS.string(format["url"]),
                  !isSABR(formatURL) else { continue }
            if mime.contains("mp4") {
                aacFormats.append(format)
            } else {
                otherAudio.append(format)
            }
        }

        // AVPlayer 原生只支持 AAC/MP4；opus(webm) 仅作兜底
        let pool = aacFormats.isEmpty ? otherAudio : aacFormats
        guard !pool.isEmpty else {
            throw ApiError.unavailable(L("No audio stream available for this track"))
        }

        let sorted = pool.sorted { (JS.int($0["bitrate"]) ?? 0) < (JS.int($1["bitrate"]) ?? 0) }
        let chosen: [String: Any]

        switch quality {
        case .lossless, .high:
            chosen = sorted[sorted.count - 1]
        case .low:
            chosen = sorted[0]
        case .normal:
            let target = 128_000
            chosen = sorted.min { lhs, rhs in
                abs((JS.int(lhs["bitrate"]) ?? 0) - target) < abs((JS.int(rhs["bitrate"]) ?? 0) - target)
            } ?? sorted[sorted.count - 1]
        }

        guard var urlString = JS.string(chosen["url"]) else {
            throw ApiError.unavailable(L("Invalid audio URL"))
        }
        // 附加 GVS PO Token（&pot=）——网页播放器的标准做法，让拉流对出口 IP 不敏感。
        // 若直链已带 pot（player 响应自带），先移除再加我们的（避免重复参数）。
        if let pot = pot, !pot.isEmpty {
            if var comps = URLComponents(string: urlString) {
                var items = comps.queryItems ?? []
                items.removeAll { $0.name == "pot" }
                items.append(URLQueryItem(name: "pot", value: pot))
                comps.queryItems = items
                if let built = comps.string { urlString = built }
            }
        }
        guard let url = URL(string: urlString) else {
            throw ApiError.unavailable(L("Invalid audio URL"))
        }

        return AudioStream(
            url: url,
            itag: JS.int(chosen["itag"]) ?? 0,
            bitrate: JS.int(chosen["bitrate"]) ?? 0,
            mime: JS.string(chosen["mimeType"]) ?? "",
            userAgent: client.userAgent
        )
    }
}
