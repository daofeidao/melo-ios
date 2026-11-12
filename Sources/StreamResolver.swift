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

    /// 2026-11-10 在同一 VPN 出口实测（未登录、无 cookie / PO Token / visitorData）：
    /// ANDROID_VR 两个版本全部 LOGIN_REQUIRED、format=0；
    /// IOS 与 ANDROID 返回 OK，且是明文 AAC 直链，CDN 实测 206 audio/mp4。
    /// 请求体只保留最小字段 —— 多带 deviceMake 等反而偶发被判机器人。
    private static let clients: [Client] = [
        Client(
            id: "ios-20.10.38",
            name: "IOS",
            version: "20.10.38",
            extra: ["hl": "en", "gl": "US"],
            userAgent: "com.google.ios.youtube/20.10.38 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X)"
        ),
        Client(
            id: "ios-20.11.6",
            name: "IOS",
            version: "20.11.6",
            extra: ["hl": "en", "gl": "US"],
            userAgent: "com.google.ios.youtube/20.11.6 (iPhone16,2; U; CPU iOS 18_3 like Mac OS X)"
        ),
        Client(
            id: "android-20.10.38",
            name: "ANDROID",
            version: "20.10.38",
            extra: ["hl": "en", "gl": "US", "androidSdkVersion": 34],
            userAgent: "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip"
        ),
        Client(
            id: "vr-1.61.48",
            name: "ANDROID_VR",
            version: "1.61.48",
            extra: ["hl": "en", "gl": "US", "androidSdkVersion": 32],
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.61.48 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
        )
    ]

    static func resolve(videoId: String, quality: Quality) async throws -> AudioStream {
        // 正常路径：上次成功的身份先单打一次，命中就不必并发打全部
        if let id = winnerID, let client = clients.first(where: { $0.id == id }) {
            if let stream = try? await attempt(videoId: videoId, client: client, quality: quality) {
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
                        return .success(try await attempt(videoId: videoId, client: client, quality: quality))
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

        // 所有客户端都被判机器人：换客户端无用，这是 IP 信誉问题
        if outcome.botChecked, outcome.failures.isEmpty {
            throw ApiError.botCheck("")
        }

        let detail = outcome.failures.first ?? L("Unknown reason")
        throw ApiError.unavailable(String(format: L("Unable to resolve playback URL: %@"), detail))
    }

    private static func attempt(videoId: String, client: Client, quality: Quality) async throws -> AudioStream {
        var clientContext = client.extra
        clientContext["clientName"] = client.name
        clientContext["clientVersion"] = client.version

        let body: [String: Any] = [
            "context": ["client": clientContext],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]

        let root = try await InnerTube.shared.player(body: body, userAgent: client.userAgent)

        if let status = JS.dict(root["playabilityStatus"]),
           let state = JS.string(status["status"]),
           state != "OK" {
            let reason = JS.string(status["reason"]) ?? state
            if state == "LOGIN_REQUIRED" {
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

        // 记下能用的身份：以后起播只打这一个请求
        winnerID = client.id
        return AudioStream(
            url: url,
            itag: JS.int(chosen["itag"]) ?? 0,
            bitrate: JS.int(chosen["bitrate"]) ?? 0,
            mime: JS.string(chosen["mimeType"]) ?? "",
            userAgent: client.userAgent
        )
    }
}
