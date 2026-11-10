import Foundation
import WebKit

/// 「半验证」：证明 App 能不能自己铸出 PO Token，并用它换到音频直链。
///
/// 流程（和 SimpMusic 那套一致，只是把 JS 引擎换成 WKWebView）：
///   1. 向 Waa/Create 要一份 BotGuard 挑战
///   2. 在空白 WKWebView 里跑挑战脚本，得到 botguardResponse
///   3. 向 Waa/GenerateIT 换 integrityToken
///   4. 用 integrityToken + visitorData 铸出 PO Token
///   5. 带着 PO Token 发 IOS / ANDROID 的 player 请求，看有没有直链
///
/// 第 5 步是这次验证的唯一目的：`withURL > 0` 就说明方案 B 成立。
@MainActor
final class PoTokenProbe: ObservableObject {

    @Published var lines: [WebProbeLine] = []
    @Published var busy = false

    /// BotGuard 用的挑战请求键，YouTube 网页版当前在用的值
    private static let challengeKey = "O43z0dpjhgX20SCx4KAo"
    private static let waaKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    private static let playerKey = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"

    private var webView: WKWebView?
    private var webViewReady = false

    // MARK: - 对外

    func run(videoID: String, visitor: String) async {
        busy = true
        lines = []
        defer { busy = false }

        var token: String?

        do {
            let challenge = try await createChallenge()
            append(L("Step 1 · BotGuard challenge"),
                   "globalName=\(challenge.globalName) · js=\(challenge.interpreter.count)",
                   !challenge.interpreter.isEmpty)

            try await prepareWebView()
            let snapshot = try await evaluate(Self.snapshotScript, payload: [
                "interpreter": challenge.interpreter,
                "program": challenge.program,
                "globalName": challenge.globalName
            ]) as? String ?? ""
            append(L("Step 2 · BotGuard snapshot"), "\(snapshot.count) chars", !snapshot.isEmpty)

            let integrity = try await generateIT(snapshot)
            append(L("Step 3 · Integrity token"), "\(integrity.count) chars", !integrity.isEmpty)

            let minted = try await evaluate(Self.mintScript, payload: [
                "integrityToken": integrity,
                "identifier": visitor
            ]) as? String ?? ""
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

    // MARK: - 三步网络请求

    private struct Challenge {
        let interpreter: String
        let program: String
        let globalName: String
    }

    private func createChallenge() async throws -> Challenge {
        var request = URLRequest(url: URL(string: "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/Create")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json+protobuf", forHTTPHeaderField: "content-type")
        request.setValue(Self.waaKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "x-user-agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [Self.challengeKey])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProbeError.message("Create HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let json = try JSONSerialization.jsonObject(with: data)
        guard let node = Self.findChallenge(json) else {
            throw ProbeError.message("challenge not found")
        }
        return node
    }

    private func generateIT(_ botguardResponse: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/GenerateIT")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json+protobuf", forHTTPHeaderField: "content-type")
        request.setValue(Self.waaKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "x-user-agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [Self.challengeKey, botguardResponse])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProbeError.message("GenerateIT HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let json = try JSONSerialization.jsonObject(with: data)
        guard let token = Self.findLongString(json) else {
            throw ProbeError.message("integrity token not found")
        }
        return token
    }

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

    // MARK: - WebView

    private func prepareWebView() async throws {
        if webViewReady, webView != nil { return }
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView = view
        view.loadHTMLString("<!doctype html><html><head></head><body></body></html>", baseURL: nil)
        // 等空白页就绪，最多 3 秒
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let raw = try? await view.evaluateJavaScript("document.readyState")
            let state = raw as? String
            if state == "complete" || state == "interactive" {
                webViewReady = true
                return
            }
        }
        webViewReady = true
    }

    private func evaluate(_ body: String, payload: [String: Any]) async throws -> Any? {
        guard let view = webView else { throw ProbeError.message("webview missing") }
        let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}"
        return try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(body, arguments: ["payload": json], in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 工具

    private func append(_ title: String, _ detail: String, _ ok: Bool) {
        lines.append(WebProbeLine(title: title, detail: detail, ok: ok))
    }

    private enum ProbeError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }

    /// Create 的响应嵌套层级不稳定，按特征递归找，别写死路径
    private static func findChallenge(_ node: Any) -> Challenge? {
        if let dict = node as? [String: Any],
           let globalName = dict["globalName"] as? String,
           let program = dict["program"] as? String {
            let js: String?
            if let text = dict["interpreterJavascript"] as? String {
                js = text
            } else if let inner = dict["interpreterJavascript"] as? [String: Any] {
                js = inner["privateDoNotAccessOrElseSafeScriptWrappedValue"] as? String
                    ?? inner.values.compactMap { $0 as? String }.first
            } else {
                js = nil
            }
            if let js = js, !js.isEmpty {
                return Challenge(interpreter: js, program: program, globalName: globalName)
            }
        }
        if let array = node as? [Any] {
            for item in array { if let found = findChallenge(item) { return found } }
        } else if let dict = node as? [String: Any] {
            for value in dict.values { if let found = findChallenge(value) { return found } }
        }
        return nil
    }

    private static func findLongString(_ node: Any) -> String? {
        if let text = node as? String, text.count > 100 { return text }
        if let array = node as? [Any] {
            for item in array { if let found = findLongString(item) { return found } }
        } else if let dict = node as? [String: Any] {
            for value in dict.values { if let found = findLongString(value) { return found } }
        }
        return nil
    }

    // MARK: - 注入脚本

    /// 载入 BotGuard 解释器 → 等 VM 就绪 → 取一次快照。
    /// `webPoSignalOutput` 里是函数，跨不过 JS 桥，所以先挂在 window 上给下一步用。
    private static let snapshotScript = """
    const a = JSON.parse(payload);
    (new Function(a.interpreter))();
    const vm = window[a.globalName];
    if (!vm || !vm.a) { throw new Error("VM not loaded"); }
    let fns = null;
    vm.a(a.program, function (snap, shut, pass, cam) {
      fns = { snap: snap, shut: shut, pass: pass, cam: cam };
    }, true, undefined, function () {}, [[], []]);
    await new Promise(function (resolve, reject) {
      let n = 0;
      const timer = setInterval(function () {
        if (fns && fns.snap) { clearInterval(timer); resolve(); }
        else if (++n > 8000) { clearInterval(timer); reject(new Error("asyncSnapshot timeout")); }
      }, 1);
    });
    const signal = [];
    const response = await new Promise(function (resolve, reject) {
      try {
        fns.snap(function (r) { resolve(r); }, [undefined, undefined, signal, undefined]);
      } catch (e) { reject(e); }
    });
    window.__meloPoSignal = signal;
    return String(response);
    """

    /// 用 integrityToken 铸 PO Token，输出 base64url
    private static let mintScript = """
    const a = JSON.parse(payload);
    const signal = window.__meloPoSignal;
    if (!signal || !signal[0]) { throw new Error("signal missing"); }
    const mint = signal[0](a.integrityToken);
    if (typeof mint !== "function") { throw new Error("mint failed"); }
    const bytes = mint(a.identifier);
    if (!(bytes instanceof Uint8Array)) { throw new Error("token type " + Object.prototype.toString.call(bytes)); }
    let text = "";
    for (let i = 0; i < bytes.length; i++) { text += String.fromCharCode(bytes[i]); }
    return btoa(text).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "");
    """
}
