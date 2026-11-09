import Foundation

enum StreamResolver {

    enum Quality: String, CaseIterable, Identifiable {
        case high
        case normal
        case low

        var id: String { rawValue }

        var label: String {
            switch self {
            case .high: return L("High")
            case .normal: return L("Standard")
            case .low: return L("Data Saver")
            }
        }

        var detail: String {
            switch self {
            case .high: return L("About 128 kbps AAC")
            case .normal: return L("About 128 kbps AAC")
            case .low: return L("About 48 kbps AAC")
            }
        }
    }

    private struct Client {
        let name: String
        let version: String
        let extra: [String: Any]
        let userAgent: String
    }

    /// 播放器起播时也带上同一个 UA，避免个别节点做 UA 校验
    static let clientUserAgent = "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"

    /// 实测：ANDROID_VR 是当前唯一能稳定返回未加密直链的客户端；
    /// IOS 返回 400、ANDROID_MUSIC 要求登录、TVHTML5 已停用、WEB 判定不可播。
    static let clients: [Client] = [
        Client(
            name: "ANDROID_VR",
            version: "1.60.19",
            extra: [
                "deviceMake": "Oculus",
                "deviceModel": "Quest 3",
                "androidSdkVersion": 32,
                "osName": "Android",
                "osVersion": "12L",
                "hl": "en",
                "gl": "US"
            ],
            userAgent: StreamResolver.clientUserAgent
        ),
        Client(
            name: "ANDROID_VR",
            version: "1.61.48",
            extra: [
                "deviceMake": "Oculus",
                "deviceModel": "Quest 3",
                "androidSdkVersion": 32,
                "osName": "Android",
                "osVersion": "12L",
                "hl": "en",
                "gl": "US"
            ],
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.61.48 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
        )
    ]

    static func resolve(videoId: String, quality: Quality) async throws -> AudioStream {
        var failures: [String] = []
        var botChecked = false

        for client in clients {
            do {
                return try await attempt(videoId: videoId, client: client, quality: quality)
            } catch ApiError.botCheck {
                botChecked = true
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                failures.append(message)
            }
        }

        // 所有客户端都被判机器人：换客户端无用，这是 IP 信誉问题
        if botChecked, failures.isEmpty {
            throw ApiError.botCheck("")
        }

        let detail = failures.first ?? L("Unknown reason")
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
                  JS.string(format["url"]) != nil else { continue }
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
        case .high:
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
            mime: JS.string(chosen["mimeType"]) ?? ""
        )
    }
}
