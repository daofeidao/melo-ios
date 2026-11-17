import Foundation
import WebKit

/// 「半验证」：证明 App 能不能自己铸出 PO Token，并用它换到音频直链。
///
/// 流程（BotGuard 铸造在 PoTokenMinter 里跑，这里只做分步编排与汇报）：
///   1. 向 Waa/Create 要一份 BotGuard 挑战
///   2. 在 WKWebView 里跑挑战脚本，得到 botguardResponse
///   3. 向 Waa/GenerateIT 换 integrityToken
///   4. 用 integrityToken + visitorData 铸出 PO Token
///   5. 带着 PO Token 发 Web 系（WEB_REMIX / WEB）的 player 请求，看有没有直链
///
/// 第 5 步是这次验证的唯一目的：`withURL > 0` 就说明方案成立。
/// 注意：PO Token 是 WEB_REMIX 铸的，只配 Web 系客户端；配 IOS/ANDROID 是错配的假结果。
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
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    private static let mwebUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"

    /// 只测 Web 系客户端：PO Token 是 WEB_REMIX 铸的，只对同 client 有效，
    /// IOS / ANDROID 要 DroidGuard / iOSGuard，本项目没有，测了也是错配的假结果。
    private static let variants: [Variant] = [
        Variant(title: L("Variant · WEB_REMIX (no token)"),
                clientName: "WEB_REMIX", clientVersion: "1.20241127.01.00", userAgent: PoTokenProbe.iosUA, withToken: false),
        Variant(title: L("Variant · WEB_REMIX + token"),
                clientName: "WEB_REMIX", clientVersion: "1.20241127.01.00", userAgent: PoTokenProbe.iosUA, withToken: true),
        Variant(title: L("Variant · WEB (no token)"),
                clientName: "WEB", clientVersion: "2.20241114.00.00", userAgent: PoTokenProbe.iosUA, withToken: false)
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
