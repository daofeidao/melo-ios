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

    /// 一次铸造的完整身份：visitor + 两枚用途不同的 token。
    struct POIdentity {
        /// 与 player 请求同源的 visitor
        let visitorData: String
        /// 内容绑定（videoId）→ 放进 player 请求的 serviceIntegrityDimensions
        let playerToken: String?
        /// 会话绑定（visitorData）→ 附加到媒体直链的 &pot=
        let gvsToken: String?
        let mintedAt: Date
    }

    private var identityCache: (videoId: String, identity: POIdentity)?
    private var cachedVisitor: (value: String, at: Date)?
    /// BotGuard integrityToken + 已注入的 VM，可复用多次铸造（每次铸造只多花一次 mint）
    private var cachedSession: (integrityToken: String, createdAt: Date)?

    // YouTube 的 GVS PO Token 实测 TTL 12 小时（见 pipepipe-sabr REPORT）。
    // 之前 20 分钟太保守，导致频繁重铸（每次 4~20s）拖慢起播，放宽到 11 小时留余量。
    private let ttl: TimeInterval = 11 * 3600

    /// 给某个视频铸一套身份。
    ///
    /// 为什么是两枚 token（对齐 yt-dlp / bgutil 的做法）：
    /// - **player token** 绑 videoId，随 player 请求一起提交（serviceIntegrityDimensions），
    ///   否则受保护视频会被降级（LOGIN_REQUIRED / 只给 SABR）。
    /// - **gvs token** 附加到 googlevideo 直链的 `&pot=`，否则直链只放第一块，
    ///   后续 Range 全 403 —— 表现就是「播到 20 秒突然没声音」。
    ///
    /// gvs token 的绑定标识：yt-dlp 现在按 **videoId** 绑（YouTube 已把 web 系
    /// GVS token 收敛成内容绑定）。早期文档写过绑 visitorData，两者服务端都收，
    /// 但绑 videoId 才和当前实现一致；`melo.debug.gvsBind=visitor` 可切回去做 A/B。
    ///
    /// 两枚必须来自同一次 BotGuard 会话且用同一个 visitor，否则服务端认不出。
    func identity(for videoId: String) async -> POIdentity? {
        if let c = identityCache, c.videoId == videoId,
           Date().timeIntervalSince(c.identity.mintedAt) < ttl {
            return c.identity
        }
        do {
            let visitor = try await visitorData()
            let integrity = try await ensureSession()
            let bindVisitor = UserDefaults.standard.string(forKey: "melo.debug.gvsBind") == "visitor"
            let player = try? await mintToken(integrity: integrity, binding: videoId)
            let gvs = try? await mintToken(integrity: integrity, binding: bindVisitor ? visitor : videoId)
            Diagnostics.mark("poToken: gvs bind=\(bindVisitor ? "visitor" : "video")")
            guard player != nil || gvs != nil else { return nil }
            let identity = POIdentity(visitorData: visitor, playerToken: player, gvsToken: gvs, mintedAt: Date())
            identityCache = (videoId, identity)
            Diagnostics.mark("poToken: identity ok (visitor \(visitor.count), player \(player?.count ?? 0), gvs \(gvs?.count ?? 0))")
            return identity
        } catch {
            Diagnostics.mark("poToken: identity failed – \(error.localizedDescription)")
            return nil
        }
    }

    /// visitor 是会话级的，缓存起来让 player 请求和 token 铸造共用同一份。
    func visitorData() async throws -> String {
        if let c = cachedVisitor, Date().timeIntervalSince(c.at) < ttl {
            return c.value
        }
        let visitor = try await fetchVisitorData(cookie: nil).visitorData
        cachedVisitor = (visitor, Date())
        return visitor
    }

    /// 当前可用的 (poToken, visitorData)。缓存过期会自动重铸。
    /// 铸造失败返回 nil —— 调用方应退回无 Token 请求（部分客户端仍能播）。
    /// binding 是内容绑定。未登录：player token 绑视频 ID；
    /// 已登录：GVS token 绑账号 Session ID（dataSyncId 第一段），见 yt-dlp PO Token Guide。
    func token(for binding: String) async -> (poToken: String, visitorData: String)? {
        if let c = cache, c.binding == binding, Date().timeIntervalSince(c.mintedAt) < ttl {
            return (c.poToken, c.visitorData)
        }
        do {
            let visitor = try await visitorData()
            let integrity = try await ensureSession()
            let poToken = try await mintToken(integrity: integrity, binding: binding)
            cache = Cached(poToken: poToken, visitorData: visitor, binding: binding, mintedAt: Date())
            Diagnostics.mark("poToken: minted ok (\(poToken.count) chars, visitor \(visitor.count), bind=\(binding))")
            return (poToken, visitor)
        } catch {
            Diagnostics.mark("poToken: mint failed – \(error.localizedDescription)")
            return nil
        }
    }

    /// 登录态铸造：带 Cookie 请求拿 visitorData + dataSyncId，PO Token 绑 dataSyncId。
    /// 返回 (poToken, visitorData, dataSyncId?)。dataSyncId 为空说明未登录，退回无登录态路径。
    func tokenWithCookie(for videoId: String, cookie: String) async -> (poToken: String, visitorData: String, dataSyncId: String?)? {
        do {
            let (visitor, syncID) = try await fetchVisitorData(cookie: cookie)
            // 登录态下 GVS token 绑 dataSyncId；没有 dataSyncId 就退回绑 videoId（未登录路径）
            let binding = syncID ?? videoId
            let poToken = try await mint(binding: binding)
            Diagnostics.mark("poToken[login]: minted ok (\(poToken.count) chars, visitor \(visitor.count), sync=\(syncID?.prefix(16) ?? "无"))")
            return (poToken, visitor, syncID)
        } catch {
            Diagnostics.mark("poToken[login]: mint failed – \(error.localizedDescription)")
            return nil
        }
    }

    /// 调试用：把两种绑定各铸一枚，交给自检做 A/B。
    /// 会话与 visitor 复用缓存，所以第二枚几乎不花时间。
    func mintVariants(videoId: String) async -> [(label: String, token: String)] {
        do {
            let visitor = try await visitorData()
            let integrity = try await ensureSession()
            var out: [(String, String)] = []
            if let t = try? await mintToken(integrity: integrity, binding: videoId) {
                out.append(("bind=video", t))
            }
            if let t = try? await mintToken(integrity: integrity, binding: visitor) {
                out.append(("bind=visitor", t))
            }
            return out
        } catch {
            Diagnostics.mark("poToken: mintVariants failed – \(error.localizedDescription)")
            return []
        }
    }

    /// 强制下次重铸（比如收到 LOGIN_REQUIRED 时）
    func invalidate() {
        cache = nil
        identityCache = nil
        cachedSession = nil
    }

    // MARK: - visitorData

    /// 带 Cookie 打一个轻量 browse，拿 visitorData + dataSyncId。
    /// dataSyncId 是登录态下 PO Token / GVS 的绑定标识（未登录没有）。
    /// 注意：用 WEB 客户端（www.youtube.com）铸 token，这样铸出的 PO Token 才配
    /// `web` 客户端的 player 请求用（yt-dlp 主路径是 web 客户端，不是 web_remix）。
    func fetchVisitorData(cookie: String?) async throws -> (visitorData: String, dataSyncId: String?) {
        // 用 WEB 客户端打 www.youtube.com 的 browse，拿 visitorData。
        // 关键：铸 token 的客户端必须和后续 player 请求的客户端一致（都是 WEB）。
        // 用普通的 browseId（FEwhat_to_watch 首页），不能用 FEmusic_home（那是 Music 专属）。
        let body: [String: Any] = [
            "context": ["client": [
                "clientName": "WEB",
                "clientVersion": "2.20241114.00.00",
                "hl": "en", "gl": "US"
            ]],
            "browseId": "FEwhat_to_watch"
        ]
        let root = try await InnerTube.shared.post(
            host: "www.youtube.com", endpoint: "browse",
            key: InnerTube.shared.playerKey,
            body: body, userAgent: InnerTube.shared.webUserAgent,
            visitorData: nil
        )
        let syncID = InnerTube.dataSyncId(from: root)

        if let ctx = JS.dict(root["responseContext"]),
           let visitor = JS.string(ctx["visitorData"]), !visitor.isEmpty {
            return (visitor, syncID)
        }
        // 兜底：从原始响应里的任何嵌套位置找 visitorData
        if let found = findVisitorData(root), !found.isEmpty { return (found, syncID) }
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
    /// Waa/Create 与 GenerateIT 要求 WebKit UA（其他 UA 产出无效 token）
    private static let webKitUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private var webView: WKWebView?

    /// 取一次 BotGuard 会话（挑战 → WKWebView 解算 → integrityToken），并缓存复用。
    /// 同一会话可以铸多枚 token（不同 content binding），这是 bgutil 的标准做法。
    func ensureSession() async throws -> String {
        if let s = cachedSession, Date().timeIntervalSince(s.createdAt) < ttl {
            return s.integrityToken
        }
        // 1) BotGuard 挑战
        let challenge = try await createChallenge()
        // 2) 解释器 + program 走 HTML 注入，页面里跑挑战 → botguardResponse
        try await prepareWebView(challenge: challenge)
        let botguardResponse = try await run("await window.__meloSetup()")
        guard !botguardResponse.isEmpty else { throw MinterError.js("empty botguardResponse") }
        Diagnostics.mark("poToken: snapshot ok (\(botguardResponse.count) chars)")
        // 3) 换 integrityToken
        let integrity = try await generateIT(botguardResponse)
        Diagnostics.mark("poToken: integrity ok (\(integrity.count) chars)")
        cachedSession = (integrity, Date())
        return integrity
    }

    /// 用已有会话铸一枚 token。binding 就是 content binding（player 用 videoId，gvs 用 visitorData）。
    func mintToken(integrity: String, binding: String) async throws -> String {
        // 4) 用 window.__meloPoSignal + integrityToken + 内容绑定 → 铸 PO Token
        let call = "await window.__meloMint({integrityToken: \(Self.jsString(integrity)), identifier: \(Self.jsString(binding)), _diag: (window.__meloSignalDiag || 'n/a')})"
        let minted = try await run(call)
        guard !minted.isEmpty else { throw MinterError.mintEmpty }
        // 诊断：signal 结构 + token 前缀，定位铸造 bug
        if let diag = try? await js("window.__meloSignalDiag") as? String {
            Diagnostics.mark("poToken: signal=\(diag)")
        }
        Diagnostics.mark("poToken: token head=\(String(minted.prefix(24))) bind=\(binding.prefix(24))")
        return minted
    }

    func mint(binding: String) async throws -> String {
        let integrity = try await ensureSession()
        return try await mintToken(integrity: integrity, binding: binding)
    }

    func createChallenge() async throws -> Challenge {
        var request = URLRequest(url: URL(string: "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/Create")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json+protobuf", forHTTPHeaderField: "content-type")
        request.setValue(Self.waaKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "x-user-agent")
        // 关键：Waa/Create 需要 WebKit UA，其他 UA 会产出无效 token（waxseal/BgUtils 实测结论）
        request.setValue(Self.webKitUA, forHTTPHeaderField: "User-Agent")
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
        // 关键：Waa/GenerateIT 同样需要 WebKit UA
        request.setValue(Self.webKitUA, forHTTPHeaderField: "User-Agent")
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
        //
        // 但「透明」不等于「看不见」：WKWebView 默认是不透明视图，白底会以
        // alpha 0.02 的强度在窗口左上角透出一块 200×200 的浅方块（不仔细看看
        // 不出来，但确实存在）。所以必须同时：关掉 isOpaque、把三层背景刷成
        // clear、页面 body 也设透明，并压到视图层级最底层。
        if webView == nil {
            let config = WKWebViewConfiguration()
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 200),
                                 configuration: config)
            view.alpha = 0.02
            view.isOpaque = false
            view.backgroundColor = .clear
            view.scrollView.backgroundColor = .clear
            view.isUserInteractionEnabled = false
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
                // 放最底层：即使有什么绘制漏出来也被上面的内容盖住
                host.insertSubview(view, at: 0)
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

    /// 页面骨架：解释器 + program + 快照/铸造辅助函数。
    /// 严格对齐 BgUtils BotGuardClient（load + snapshot + WebPoMinter.mint）。
    static func pageHTML(interpreter: String, program: String, globalName: String) -> String {
        // </ 会提前收掉 <script>；U+2028/U+2029 在 JS 源码里算换行。都转义掉。
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "</", with: "<\\/")
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }
        return """
        <!doctype html><html style="background:transparent"><head><script>\(esc(interpreter))</script><script>
        window.__meloProgram = \(jsString(program));
        window.__meloGlobal = \(jsString(globalName));

        // 跑一次完整流程：load VM → snapshot（拿 signal）→ 存下 signal，供 mint 用。
        window.__meloSetup = async function () {
          const vm = window[window.__meloGlobal];
          if (!vm || !vm.a) { throw new Error("VM not loaded"); }

          // 用 callback 拿 asyncSnapshotFunction（实测 syncSnapshotFunction 会挂起）
          let fns = null;
          await vm.a(window.__meloProgram, function (snap, shut, pass, cam) {
            fns = { snap: snap, shut: shut, pass: pass, cam: cam };
          }, true, undefined, function () {}, [[], []]);
          if (!fns || typeof fns.snap !== "function") { throw new Error("snapshot fn missing"); }

          // snapshot：asyncSnapshotFunction(responseCb, [contentBinding, signedTimestamp, webPoSignalOutput, skipPrivacyBuffer])
          const signal = [];   // webPoSignalOutput：snapshot 会往 [0] 填 getMinter
          const response = await new Promise(function (resolve, reject) {
            try {
              fns.snap(function (r) { resolve(r); }, [undefined, undefined, signal, undefined]);
            } catch (e) { reject(e); }
          });
          window.__meloPoSignal = signal;
          try {
            window.__meloSignalDiag = "len=" + signal.length + " [0]=" + typeof signal[0]
              + (signal[0] ? " name=" + (signal[0].name || "?") : "");
          } catch (e) { window.__meloSignalDiag = "diag " + e; }
          return String(response);
        };

        window.__meloMint = async function (p) {
          const signal = window.__meloPoSignal;
          if (!signal || typeof signal[0] !== "function") {
            throw new Error("signal missing, diag=" + (p._diag || "n/a"));
          }
          function b64uToU8(s) {
            s = s.replace(/-/g, "+").replace(/_/g, "/");
            while (s.length % 4) s += "=";
            const bin = atob(s);
            const out = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
            return out;
          }
          // signal[0] 是 WebPoSignalOutputFunction：(bytes) => Promise<mintCallback>
          const mint = await signal[0](b64uToU8(p.integrityToken));
          if (typeof mint !== "function") { throw new Error("mint not fn: " + typeof mint); }
          const bytes = await mint(new TextEncoder().encode(p.identifier));
          if (!(bytes instanceof Uint8Array)) { throw new Error("token type " + Object.prototype.toString.call(bytes)); }
          let text = "";
          for (let i = 0; i < bytes.length; i++) { text += String.fromCharCode(bytes[i]); }
          return btoa(text).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "");
        };
        </script></head><body style="background:transparent"></body></html>
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
