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
///
/// 注入架构：解释器（~64KB）与 program 全部走 loadHTMLString 进页面，
/// evaluateJavaScript 只发小指令。实测 Catalyst 的 evaluateJavaScript 对
/// 超大脚本会**静默不执行**（返回成功但一行都没跑），loadHTMLString 没这问题。
@MainActor
final class PoTokenMinter {

    static let shared = PoTokenMinter()

    // MARK: - 缓存

    private struct Cached {
        let poToken: String
        let visitorData: String
        let binding: String
        let mintedAt: Date
    }
    private var cache: Cached?
    private let ttl: TimeInterval = 1200   // 20 分钟

    /// 当前可用的 (poToken, visitorData)。缓存过期会自动重铸。
    /// 铸造失败返回 nil —— 调用方应退回无 Token 请求（部分客户端仍能播）。
    /// binding 是内容绑定：BgUtils 实测 Web 端对视频请求用**视频 ID**绑定铸 token。
    func token(for binding: String) async -> (poToken: String, visitorData: String)? {
        if let c = cache, c.binding == binding, Date().timeIntervalSince(c.mintedAt) < ttl {
            return (c.poToken, c.visitorData)
        }
        do {
            let visitor = try await fetchVisitorData()
            let poToken = try await mint(binding: binding)
            cache = Cached(poToken: poToken, visitorData: visitor, binding: binding, mintedAt: Date())
            Diagnostics.mark("poToken: minted ok (\(poToken.count) chars, visitor \(visitor.count), bind=\(binding))")
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

    func fetchVisitorData() async throws -> String {
        // 打一个极轻量的 browse 请求，从 responseContext.visitorData 拿访客 ID。
        // 这个 ID 是 PO Token 的绑定标识，发送 player 请求时要放在 X-Goog-Visitor-Id 头里。
        let body: [String: Any] = [
            "context": ["client": [
                "clientName": "WEB_REMIX",
                "clientVersion": "1.20241127.01.00",
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

    struct Challenge {
        let interpreter: String
        let program: String
        let globalName: String
    }

    private static let challengeKey = "O43z0dpjhgX20SCx4KAo"
    private static let waaKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"

    private var webView: WKWebView?

    func mint(binding: String) async throws -> String {
        // 1) BotGuard 挑战
        let challenge = try await createChallenge()
        // 2) 解释器 + program 走 HTML 注入，页面里跑挑战 → botguardResponse
        try await prepareWebView(challenge: challenge)
        let botguardResponse = try await run("await window.__meloSnapshot()")
        guard !botguardResponse.isEmpty else { throw MinterError.js("empty botguardResponse") }
        Diagnostics.mark("poToken: snapshot ok (\(botguardResponse.count) chars)")
        // 3) 换 integrityToken
        let integrity = try await generateIT(botguardResponse)
        Diagnostics.mark("poToken: integrity ok (\(integrity.count) chars)")
        // 4) 用 window.__meloPoSignal + integrityToken + 内容绑定 → 铸 PO Token
        let call = "await window.__meloMint({integrityToken: \(Self.jsString(integrity)), identifier: \(Self.jsString(binding))})"
        let minted = try await run(call)
        guard !minted.isEmpty else { throw MinterError.mintEmpty }
        return minted
    }

    func createChallenge() async throws -> Challenge {
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
        // 2025 起 Create 响应是加扰的 `[null, base64]`（解扰 → 位置数组），
        // 旧格式是带字段名的字典 —— WaaChallenge 两种都认
        guard let node = WaaChallenge.parse(json) else {
            throw MinterError.noChallenge
        }
        Diagnostics.mark("poToken: challenge ok (js \(node.interpreter.count), vm \(node.globalName))")
        return Challenge(interpreter: node.interpreter, program: node.program, globalName: node.globalName)
    }

    func generateIT(_ botguardResponse: String) async throws -> String {
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
        guard let token = WaaChallenge.parseLooseString(json) else {
            throw MinterError.noIntegrityToken
        }
        return token
    }

    // MARK: - WKWebView（解释器走 HTML 注入）

    /// 把解释器、program 和快照/铸造函数一次写进页面。
    /// loadHTMLString 对内容大小不敏感，绕开 evaluateJavaScript 大脚本被静默丢弃的问题。
    func prepareWebView(challenge: Challenge) async throws {
        // 尺寸给到 200×200、近乎透明但不 hidden：WebKit 对 1×1/隐藏页会冻结
        // rAF 与定时器，BotGuard 解算就永远挂起。
        if webView == nil {
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 200),
                                 configuration: WKWebViewConfiguration())
            view.alpha = 0.02
            // 必须挂进窗口层级：脱离层级的 WKWebView 被 WebKit 当后台页挂起
            var host: UIWindow?
            if let key = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) {
                host = key
            } else if let any = UIApplication.shared.windows.first {
                host = any
            }
            if let host = host {
                host.addSubview(view)
            }
            Diagnostics.mark("poToken: webview attached=\(host != nil)")
            webView = view
        }
        guard let view = webView else { throw MinterError.noWebView }

        let html = Self.pageHTML(interpreter: challenge.interpreter,
                                 program: challenge.program,
                                 globalName: challenge.globalName)
        view.loadHTMLString(html, baseURL: nil)

        // 等解释器把 VM 装到全局（readyState 之外还要看 vm 在不在）
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let raw = try? await js("typeof window[\(Self.jsString(challenge.globalName))]"),
               let state = raw as? String,
               state == "object" || state == "function" {
                return
            }
        }
        Diagnostics.mark("poToken: VM 未就绪（继续尝试）")
    }

    /// 页面骨架：解释器 + program + 快照/铸造辅助函数
    static func pageHTML(interpreter: String, program: String, globalName: String) -> String {
        // </ 会提前收掉 <script>；U+2028/U+2029 在 JS 源码里算换行。都转义掉。
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "</", with: "<\\/")
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }
        return """
        <!doctype html><html><head><script>\(esc(interpreter))</script><script>
        window.__meloProgram = \(jsString(program));
        window.__meloGlobal = \(jsString(globalName));
        window.__meloSnapshot = async function () {
          const vm = window[window.__meloGlobal];
          if (!vm || !vm.a) { throw new Error("VM not loaded"); }
          let fns = null;
          await vm.a(window.__meloProgram, function (snap, shut, pass, cam) {
            fns = { snap: snap, shut: shut, pass: pass, cam: cam };
          }, true, undefined, function () {}, [[], []]);
          if (!fns || typeof fns.snap !== "function") { throw new Error("snapshot fn missing"); }
          const signal = [];
          const response = await new Promise(function (resolve, reject) {
            try {
              fns.snap(function (r) { resolve(r); }, [undefined, undefined, signal, undefined]);
            } catch (e) { reject(e); }
          });
          window.__meloPoSignal = signal;
          return String(response);
        };
        window.__meloMint = async function (p) {
          const signal = window.__meloPoSignal;
          if (!signal || !signal[0]) { throw new Error("signal missing"); }
          // BgUtils 契约：integrityToken 先 base64url 解码成字节，绑定标识也走 UTF-8 字节
          function b64uToU8(s) {
            s = s.replace(/-/g, "+").replace(/_/g, "/");
            while (s.length % 4) s += "=";
            const bin = atob(s);
            const out = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
            return out;
          }
          const mint = signal[0](b64uToU8(p.integrityToken));
          if (typeof mint !== "function") { throw new Error("mint failed"); }
          const bytes = mint(new TextEncoder().encode(p.identifier));
          if (!(bytes instanceof Uint8Array)) { throw new Error("token type " + Object.prototype.toString.call(bytes)); }
          let text = "";
          for (let i = 0; i < bytes.length; i++) { text += String.fromCharCode(bytes[i]); }
          return btoa(text).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "");
        };
        </script></head><body></body></html>
        """
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

    /// 跑一句页面内的 async 表达式（体积极小），结果写 window.__meloResult 轮询取回。
    /// 不用 callAsyncJavaScript / WKContentWorld（iOS 16+ 才有，本项目要跑 iOS 15）。
    func run(_ call: String) async throws -> String {
        let wrapper = """
        window.__meloResult = null;
        window.__meloError = null;
        (async function () {
          try {
            const value = await (\(call));
            window.__meloResult = (value === undefined || value === null) ? "" : String(value);
          } catch (e) {
            window.__meloError = String(e && e.message ? e.message : e);
          }
        })();
        0
        """
        do {
            _ = try await js(wrapper)
        } catch {
            throw MinterError.js("wrapper: \(error.localizedDescription)")
        }
        for _ in 0..<600 {
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

    /// 安全的 JS 字符串字面量
    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[]".utf8)
        var text = String(data: data, encoding: .utf8) ?? "[]"
        // 去掉外层数组括号，只剩字符串字面量
        if text.hasPrefix("[") { text.removeFirst() }
        if text.hasSuffix("]") { text.removeLast() }
        return text
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

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
