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
    /// 关键（issue #12482，2025-02 起）：YouTube 对 web / mweb 客户端强制 SABR 分帧流，
    /// adaptiveFormats 里不再给明文 url（AVPlayer 解不了 SABR）。**tv 客户端不受影响**，
    /// 能返回明文 url（itag 140 m4a / itag 18 等）。所以 tv 排最前。
    /// tv 是 Web 平台（TVHTML5 走 HTML5），web 铸的 PO Token 对 tv 有效。
    private static let clients: [Client] = [
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
        // ── 路线一（优先）：用户登录了 YouTube，走「浏览器登录态」。
        // 带 Cookie 请求 + 绑 dataSyncId 的 PO Token，和「网页登录后播放」完全自洽，
        // 穿透力最强。用户网页能播（不登录都行），登录后更稳。
        if let cookie = SourcePrefs.shared.cookie("youtube"),
           let stream = try? await attemptWithCookie(videoId: videoId, quality: quality, cookie: cookie) {
            return stream
        }

        // ── 路线二：未登录，走「Web 自洽身份 + 绑 videoId 的 PO Token」。
        // 先拿 PO Token（YouTube 2024+ 对 player 接口强制要求，否则 LOGIN_REQUIRED / format=0）
        // 这个 token 是 WEB_REMIX 铸的，所以只配 Web 系客户端用（见 clients 注释）。
        let po = await PoTokenMinter.shared.token(for: videoId)

        // 正常路径：上次成功的身份先单打一次，命中就不必并发打全部
        if let id = winnerID, let client = clients.first(where: { $0.id == id }) {
            if let stream = try? await attempt(videoId: videoId, client: client, quality: quality, po: po) {
                return stream
            }
        }

        // 身份失效时并发竞速，谁先回可用流用谁；失败也是 1 倍耗时
        let outcome = await withTaskGroup(
            of: Result<AudioStream, Error>.self
        ) { group -> (stream: AudioStream?, botChecked: Bool, failures: [String]) in
            for client in clients {
                group.addTask {
                    do {
                        return .success(try await attempt(videoId: videoId, client: client, quality: quality, po: po))
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
        po: (poToken: String, visitorData: String)?
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
        // PO Token 是 WEB 平台铸的（BotGuard），tv/web-remix/web 都是 Web 平台客户端，
        // token 通用。都带上，mweb 裸试。
        if client.id != "mweb", let po = po {
            body["serviceIntegrityDimensions"] = ["poToken": po.poToken]
        }

        let root = try await InnerTube.shared.player(
            body: body,
            userAgent: client.userAgent,
            visitorData: po?.visitorData,
            music: client.id == "web-remix"
        )

        return try parseStream(root: root, client: client, quality: quality)
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
        quality: Quality
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

        guard let urlString = JS.string(chosen["url"]), let url = URL(string: urlString) else {
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
