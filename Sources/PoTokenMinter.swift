import Foundation
import WebKit

/// PO Token 铸造器——YouTube player 接口的「通行证」。
///
/// 2024 年起 YouTube 对 player 接口逐步强制要求 PO Token（Proof of Origin），
/// 没有就返回 LOGIN_REQUIRED / format=0。铸造流程（BotGuard 挑战）：
///   1. Waa/Create 要一份 BotGuard 挑战（interpreter JS + program）
///   2. 在 WKWebView 里跑挑战脚本，得到 botguardResponse
///   3. Waa/GenerateIT 换 integrityToken
///   4. integrityToken + visitorData → 铸出 PO Token（base64url）
///
/// 铸出来的 Token 缓存约 20 分钟；铸不出来返回 nil，调用方退回无 Token 请求。
/// WKWebView 必须在主线程，所以整个类标 @MainActor。
@MainActor
final class PoTokenMinter {

    static let shared = PoTokenMinter()

    // MARK: - 缓存

    private struct Cached {
        let poToken: String
        let visitorData: String
        let mintedAt: Date
    }
    private var cache: Cached?
    private let ttl: TimeInterval = 1200   // 20 分钟

    /// 当前可用的 (poToken, visitorData)。缓存过期会自动重铸。
    /// 铸造失败返回 nil —— 调用方应退回无 Token 请求（部分客户端仍能播）。
    func token() async -> (poToken: String, visitorData: String)? {
        if let c = cache, Date().timeIntervalSince(c.mintedAt) < ttl {
            return (c.poToken, c.visitorData)
        }
        do {
            let visitor = try await fetchVisitorData()
            let poToken = try await mint(visitor: visitor)
            cache = Cached(poToken: poToken, visitorData: visitor, mintedAt: Date())
            Diagnostics.mark("poToken: minted ok (\(poToken.count) chars, visitor \(visitor.count))")
            return (poToken, visitor)
        } catch {
            Diagnostics.mark("poToken: mint failed – \(error.localizedDescription)")
            return nil
        }
    }

    /// 强制下次重铸（比如收到 LOGIN_REQUIRED 时）
    func invalidate() {
        cache = nil
    }

    // MARK: - visitorData

    private func fetchVisitorData() async throws -> String {
        // 打一个极轻量的 browse 请求，从 responseContext.visitorData 拿访客 ID。
        // 这个 ID 是 PO Token 的绑定标识，发送 player 请求时要放在 X-Goog-Visitor-Id 头里。
        let body: [String: Any] = [
            "context": ["client": [
                "clientName": "WEB_REMIX",
                "clientVersion": "1.20241111.01.00",
                "hl": "en", "gl": "US"
            ]],
            "browseId": "FEmusic_home"
        ]
        let root = try await InnerTube.shared.postMusic(endpoint: "browse", body: body)
        if let ctx = JS.dict(root["responseContext"]),
           let visitor = JS.string(ctx["visitorData"]), !visitor.isEmpty {
            return visitor
        }
        // 兜底：从原始响应里的任何嵌套位置找 visitorData
        if let found = findVisitorData(root), !found.isEmpty { return found }
        throw MinterError.noVisitor
    }

    private func findVisitorData(_ node: Any) -> String? {
        if let dict = node as? [String: Any] {
            if let v = dict["visitorData"] as? String, !v.isEmpty { return v }
            for val in dict.values { if let f = findVisitorData(val) { return f } }
        } else if let arr = node as? [Any] {
            for item in arr { if let f = findVisitorData(item) { return f } }
        }
        return nil
    }

    // MARK: - BotGuard 铸造

    private struct Challenge {
        let interpreter: String
        let program: String
        let globalName: String
    }

    private static let challengeKey = "O43z0dpjhgX20SCx4KAo"
    private static let waaKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"

    private var webView: WKWebView?
    private var webViewReady = false

    private func mint(visitor: String) async throws -> String {
        // 1) BotGuard 挑战
        let challenge = try await createChallenge()
        // 2) WebView 跑挑战 → 返回 botguardResponse，同时 signal 闭包挂 window.__meloPoSignal
        try await prepareWebView()
        let botguardResponse = try await evaluate(Self.snapshotScript, payload: [
            "interpreter": challenge.interpreter,
            "program": challenge.program,
            "globalName": challenge.globalName
        ]) as? String ?? ""
        guard !botguardResponse.isEmpty else { throw MinterError.js("empty botguardResponse") }
        // 3) 换 integrityToken
        let integrity = try await generateIT(botguardResponse)
        // 4) 用 window.__meloPoSignal + integrityToken + visitorData → 铸 PO Token
        let minted = try await evaluate(Self.mintScript, payload: [
            "integrityToken": integrity,
            "identifier": visitor
        ]) as? String ?? ""
        guard !minted.isEmpty else { throw MinterError.mintEmpty }
        return minted
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
            throw MinterError.http("Create \( (response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let json = try JSONSerialization.jsonObject(with: data)
        guard let node = Self.findChallenge(json) else {
            throw MinterError.noChallenge
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
            throw MinterError.http("GenerateIT \( (response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let json = try JSONSerialization.jsonObject(with: data)
        guard let token = Self.findLongString(json) else {
            throw MinterError.noIntegrityToken
        }
        return token
    }

    // MARK: - WKWebView

    private func prepareWebView() async throws {
        if webViewReady, webView != nil { return }
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView = view
        view.loadHTMLString("<!doctype html><html><head></head><body></body></html>", baseURL: nil)
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let raw = try? await js("document.readyState"),
               let state = raw as? String,
               state == "complete" || state == "interactive" {
                webViewReady = true
                return
            }
        }
        webViewReady = true
    }

    private func js(_ script: String) async throws -> Any? {
        guard let view = webView else { throw MinterError.noWebView }
        return try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// 跑一段 async JS，结果写 window.__meloResult，轮询取回。
    /// 不用 callAsyncJavaScript / WKContentWorld（iOS 16+ 才有，本项目要跑 iOS 15）。
    private func evaluate(_ body: String, payload: [String: Any]) async throws -> Any? {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let wrapper = """
        window.__meloResult = null;
        window.__meloError = null;
        (async function () {
          const payload = \(json);
          try {
            const value = await (async function () {
        \(body)
            })();
            window.__meloResult = (value === undefined || value === null) ? "" : String(value);
          } catch (e) {
            window.__meloError = String(e && e.message ? e.message : e);
          }
        })();
        0
        """
        _ = try? await js(wrapper)
        for _ in 0..<300 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let text = try? await js("window.__meloError || ''") as? String, !text.isEmpty {
                throw MinterError.js(text)
            }
            if let text = try? await js("window.__meloResult") as? String, !text.isEmpty {
                return text
            }
        }
        throw MinterError.jsTimeout
    }

    // MARK: - 递归搜索

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

    // MARK: - BotGuard 脚本

    /// 载入解释器 → 等 VM → 取快照。返回 botguardResponse，
    /// 同时把 signal 闭包挂在 window.__meloPoSignal 上供 mint 脚本用。
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

    // MARK: - 错误

    private enum MinterError: LocalizedError {
        case noVisitor
        case noChallenge
        case noIntegrityToken
        case mintEmpty
        case noWebView
        case js(String)
        case jsTimeout
        case http(String)

        var errorDescription: String? {
            switch self {
            case .noVisitor: return "visitorData not found"
            case .noChallenge: return "BotGuard challenge not found"
            case .noIntegrityToken: return "integrity token not found"
            case .mintEmpty: return "PO Token mint returned empty"
            case .noWebView: return "WKWebView not ready"
            case .js(let msg): return "JS: \(msg)"
            case .jsTimeout: return "JS execution timeout"
            case .http(let info): return "HTTP \(info)"
            }
        }
    }
}
