import Foundation
import WebKit

/// 「半验证」：证明 App 能不能自己铸出 PO Token，并用它换到音频直链。
///
/// 流程（BotGuard 铸造在 PoTokenMinter 里跑，这里只做分步编排与汇报）：
///   1. 向 Waa/Create 要一份 BotGuard 挑战
///   2. 在 WKWebView 里跑挑战脚本，得到 botguardResponse
///   3. 向 Waa/GenerateIT 换 integrityToken
///   4. 用 integrityToken + visitorData 铸出 PO Token
///   5. 带着 PO Token 发 IOS / ANDROID 的 player 请求，看有没有直链
///
/// 第 5 步是这次验证的唯一目的：`withURL > 0` 就说明方案 B 成立。
@MainActor
final class PoTokenProbe: ObservableObject {

    @Published var lines: [WebProbeLine] = []
    @Published var busy = false

    private static let playerKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"

    // MARK: - 对外

    func run(videoID: String, visitor: String) async {
        busy = true
        lines = []
        defer { busy = false }

        let minter = PoTokenMinter.shared
        var token: String?

        do {
            let challenge = try await minter.createChallenge()
            append(L("Step 1 · BotGuard challenge"),
                   "globalName=\(challenge.globalName) · js=\(challenge.interpreter.count)",
                   !challenge.interpreter.isEmpty)

            try await minter.prepareWebView(challenge: challenge)
            let snapshot = try await minter.run("await window.__meloSnapshot()")
            append(L("Step 2 · BotGuard snapshot"), "\(snapshot.count) chars", !snapshot.isEmpty)

            let integrity = try await minter.generateIT(snapshot)
            append(L("Step 3 · Integrity token"), "\(integrity.count) chars", !integrity.isEmpty)

            let call = "await window.__meloMint({integrityToken: \(PoTokenMinter.jsString(integrity)), identifier: \(PoTokenMinter.jsString(visitor))})"
            let minted = try await minter.run(call)
            token = minted.isEmpty ? nil : minted
            append(L("Step 4 · PO Token"),
                   minted.isEmpty ? "—" : "\(minted.count) chars",
                   !minted.isEmpty)
        } catch {
            append(L("Step 1 · BotGuard challenge"), error.localizedDescription, false)
        }

        // 不管 token 有没有铸出来都跑一遍：没有 token 的那条正好当对照组
        for variant in Self.variants {
            let result = await playerProbe(videoID: videoID, variant: variant, poToken: token, visitor: visitor)
            append(variant.title, result.detail, result.ok)
        }
    }

    // MARK: - player 探测

    private struct Variant {
        let title: String
        let clientName: String
        let clientVersion: String
        let userAgent: String
        let withToken: Bool
    }

    private static let iosUA =
        "com.google.ios.youtube/20.10.38 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X;)"
    private static let androidUA =
        "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip"

    private static let variants: [Variant] = [
        Variant(title: L("Variant · IOS (no token)"),
                clientName: "IOS", clientVersion: "20.10.38", userAgent: PoTokenProbe.iosUA, withToken: false),
        Variant(title: L("Variant · IOS + token"),
                clientName: "IOS", clientVersion: "20.10.38", userAgent: PoTokenProbe.iosUA, withToken: true),
        Variant(title: L("Variant · ANDROID + token"),
                clientName: "ANDROID", clientVersion: "20.10.38", userAgent: PoTokenProbe.androidUA, withToken: true)
    ]

    private struct ProbeResult {
        let detail: String
        let ok: Bool
    }

    private func playerProbe(videoID: String, variant: Variant, poToken: String?, visitor: String) async -> ProbeResult {
        var client: [String: Any] = [
            "clientName": variant.clientName,
            "clientVersion": variant.clientVersion,
            "hl": "en",
            "gl": "US"
        ]
        if variant.clientName == "IOS" {
            client["deviceModel"] = "iPhone16,2"
            client["osName"] = "iPhone"
            client["osVersion"] = "18.1.0.22B83"
        } else {
            client["androidSdkVersion"] = 34
            client["osName"] = "Android"
            client["osVersion"] = "14"
        }
        client["userAgent"] = variant.userAgent

        var body: [String: Any] = [
            "context": ["client": client],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        if variant.withToken, let poToken = poToken {
            body["serviceIntegrityDimensions"] = ["poToken": poToken]
        }

        var request = URLRequest(url: URL(string:
            "https://www.youtube.com/youtubei/v1/player?key=\(Self.playerKey)&prettyPrint=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(variant.userAgent, forHTTPHeaderField: "User-Agent")
        if !visitor.isEmpty {
            request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else { return ProbeResult(detail: "HTTP \(code)", ok: false) }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let status = (json["playabilityStatus"] as? [String: Any])?["status"] as? String ?? "-"
            let reason = (json["playabilityStatus"] as? [String: Any])?["reason"] as? String ?? ""
            let streaming = json["streamingData"] as? [String: Any]
            let adaptive = streaming?["adaptiveFormats"] as? [[String: Any]] ?? []
            let formats = streaming?["formats"] as? [[String: Any]] ?? []
            let all = adaptive + formats
            let withURL = all.filter { ($0["url"] as? String)?.isEmpty == false }
            let audio = withURL.filter {
                (($0["mimeType"] as? String) ?? "").hasPrefix("audio")
            }
            let itags = audio.compactMap { $0["itag"] as? Int }.prefix(4).map(String.init).joined(separator: ",")
            let sabr = streaming?["serverAbrStreamingUrl"] != nil
            let detail = "\(status)\(reason.isEmpty ? "" : " · \(reason)") · 格式 \(all.count) · 带直链 \(withURL.count)"
                + (audio.isEmpty ? "" : " · 音频 itag \(itags)")
                + (sabr ? " · SABR" : "")
            return ProbeResult(detail: detail, ok: !audio.isEmpty)
        } catch {
            return ProbeResult(detail: error.localizedDescription, ok: false)
        }
    }

    // MARK: - 工具

    private func append(_ title: String, _ detail: String, _ ok: Bool) {
        lines.append(WebProbeLine(title: title, detail: detail, ok: ok))
    }
}
