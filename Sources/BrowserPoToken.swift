import Foundation
import WebKit

/// 从「真实浏览器环境」里取 YouTube 铸好的 PO Token。
///
/// 为什么需要它（2026-11-17 实测结论）：
///  - YouTube 2025-02 起对 web / mweb 客户端强制 SABR 分帧流，adaptiveFormats 不再给
///    明文 url（AVPlayer 解不了 SABR），要拿明文直链必须走 player 接口 + 有效 PO Token。
///  - PO Token 是**页面 JS 执行后**才生成的：curl 抓的初始 HTML 里 `poToken` 出现 0 次，
///    只有 VISITOR_DATA / DATASYNC_ID 这类静态字段。
///  - 也就是说「浏览器自动铸」不是比喻，是字面意义：YouTube 的页面脚本跑完 BotGuard
///    后把 token 塞进 player 请求的 serviceIntegrityDimensions.poToken。
///
/// 所以这里不做「自己重写 BotGuard 铸造」（那条路要复刻 BgUtils 的每个字节，很容易失效），
/// 而是**开一个真的 WKWebView，让 YouTube 自己的脚本去铸**，然后把 token 截下来。
///
/// 做法：在 documentStart 注入 hook，拦 fetch / XMLHttpRequest，
/// 只要 body 里带 serviceIntegrityDimensions 就把整个 player 请求上下文回报给 Swift。
@MainActor
final class BrowserPoTokenProvider: NSObject {

    static let shared = BrowserPoTokenProvider()

    /// 截获到的 player 请求上下文
    struct Captured {
        let poToken: String
        let clientName: String
        let clientVersion: String
        let visitorData: String
        let dataSyncId: String?
        let videoId: String
    }

    /// 页面内联 player response 的探针结果
    struct InlineResponse {
        var status: String = ""
        var reason: String = ""
        var hasSabr: Bool = false
        var sabrURL: String = ""
        /// 音频格式摘要：itag / mime / 码率 / 有没有明文 url
        var audio: [AudioFormat] = []
        /// 内联响应里自带的 PO Token（有时会有）
        var inlinePoToken: String = ""
    }

    struct AudioFormat {
        let itag: Int
        let mime: String
        let bitrate: Int
        let hasURL: Bool
        let hasCipher: Bool
        /// 明文 url 或 signatureCipher 前缀（够判断形态）
        let preview: String
        /// 完整的明文 url（只有明文格式才有）
        let fullURL: String
    }

    enum ProviderError: LocalizedError {
        case noWebView
        case timedOut
        case noToken(String)

        var errorDescription: String? {
            switch self {
            case .noWebView: return "WKWebView not ready"
            case .timedOut: return "The page did not send a player request in time"
            case .noToken(let detail): return "No PO Token captured: \(detail)"
            }
        }
    }

    private var webView: WKWebView?
    private var handler: MessageHandler?

    /// 桌面 Safari UA。WebView 默认 UA 带 App 名，YouTube 会当成非浏览器降级。
    static let desktopUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    // MARK: - 对外

    /// 加载 YouTube 页面，读回页面内联的 player response，看它给的是明文直链还是 SABR。
    ///
    /// 这是判断「网页到底靠什么播」的关键：curl 抓到的内联 response 是 SABR（无明文 url），
    /// 但真实浏览器（有 WebKit 指纹、有 cookie）拿到的可能不同。
    func inspectInlineResponse(videoID: String, timeout: TimeInterval = 30) async throws -> InlineResponse {
        let view = try await makeWebView(videoID: videoID)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = try? await evaluate(Self.inlineProbe, in: view),
               let text = raw as? String, !text.isEmpty {
                let parsed = try parseInline(text)
                if !parsed.status.isEmpty {
                    Diagnostics.mark("browserInline: status=\(parsed.status) sabr=\(parsed.hasSabr) audio=\(parsed.audio.count) 明文=\(parsed.audio.filter { $0.hasURL }.count)")
                    return parsed
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ProviderError.timedOut
    }

    /// 在渲染后的 DOM 里搜 PO Token（yt-dlp webpo provider 的做法）。
    func domPoToken(videoID: String, timeout: TimeInterval = 30) async throws -> String {
        let view = try await makeWebView(videoID: videoID)
        let deadline = Date().addingTimeInterval(timeout)
        var lastLen = 0
        while Date() < deadline {
            if let raw = try? await evaluate(Self.domPoTokenProbe, in: view),
               let text = raw as? String, !text.isEmpty,
               let data = text.data(using: .utf8),
               let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                lastLen = (root["len"] as? Int) ?? 0
                let token = root["poToken"] as? String ?? ""
                if !token.isEmpty {
                    Diagnostics.mark("browserDom: poToken \(token.count) chars (DOM \(lastLen) bytes)")
                    return token
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        Diagnostics.mark("browserDom: 没找到 poToken (DOM \(lastLen) bytes)")
        throw ProviderError.noToken("DOM 里没有 poToken（DOM \(lastLen) bytes）")
    }

    /// 加载 YouTube 页面，等页面自己发出 player 请求，取回它带的 PO Token。
    func token(for videoID: String, timeout: TimeInterval = 30) async throws -> Captured {
        let catcher = MessageHandler()
        handler = catcher

        let view = try await makeWebView(videoID: videoID, catcher: catcher)

        // 等页面把 player 请求发出去（页面加载后 1~8 秒）
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let captured = catcher.captured {
                Diagnostics.mark("browserPo: captured \(captured.poToken.count) chars client=\(captured.clientName)/\(captured.clientVersion)")
                return captured
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        Diagnostics.mark("browserPo: timed out (last=\(catcher.lastNote))")
        throw ProviderError.timedOut
    }

    /// 建一个加载了 watch 页的 WKWebView（hook 可选）。
    private func makeWebView(videoID: String, catcher: MessageHandler? = nil) async throws -> WKWebView {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: Self.hookScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        if let catcher = catcher {
            controller.add(catcher, name: "melo")
        }

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        // 用默认数据存储：cookie / visitorData 跨启动保留，才像「同一个浏览器」
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 640), configuration: config)
        view.customUserAgent = Self.desktopUA
        webView = view

        // 挂进窗口层级：脱离层级的 WKWebView 被 WebKit 当后台页挂起，JS 会降频。
        attachToWindow(view)

        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else {
            throw ProviderError.noWebView
        }
        view.load(URLRequest(url: url, timeoutInterval: 30))
        return view
    }

    private func evaluate(_ script: String, in view: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// 解析页面探针返回的 JSON
    private func parseInline(_ text: String) throws -> InlineResponse {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderError.noToken("unparsable")
        }
        var result = InlineResponse()
        result.status = root["status"] as? String ?? ""
        result.reason = root["reason"] as? String ?? ""
        result.hasSabr = (root["sabr"] as? Bool) ?? false
        result.sabrURL = root["sabrUrl"] as? String ?? ""
        result.inlinePoToken = root["poToken"] as? String ?? ""
        for item in (root["audio"] as? [[String: Any]]) ?? [] {
            result.audio.append(AudioFormat(
                itag: (item["itag"] as? Int) ?? 0,
                mime: item["mime"] as? String ?? "",
                bitrate: (item["bitrate"] as? Int) ?? 0,
                hasURL: (item["hasUrl"] as? Bool) ?? false,
                hasCipher: (item["hasCipher"] as? Bool) ?? false,
                preview: item["preview"] as? String ?? "",
                fullURL: item["fullUrl"] as? String ?? ""
            ))
        }
        return result
    }

    // MARK: - WebView 挂载

    private func attachToWindow(_ view: WKWebView) {
        var host: UIWindow?
        if let key = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) {
            host = key
        } else if let any = UIApplication.shared.windows.first {
            host = any
        }
        if let host = host, view.superview == nil {
            view.alpha = 0.02
            view.frame = CGRect(x: 0, y: 0, width: 1024, height: 640)
            host.addSubview(view)
        }
    }

    // MARK: - 注入的 hook

    /// 读页面内联的 player response：看是明文直链还是 SABR。
    private static let inlineProbe = """
    (function () {
      try {
        var r = window.ytInitialPlayerResponse;
        if (!r) { return JSON.stringify({ status: "" }); }
        var ps = r.playabilityStatus || {};
        var sd = r.streamingData || {};
        var all = (sd.adaptiveFormats || []).concat(sd.formats || []);
        var audio = [];
        for (var i = 0; i < all.length; i++) {
          var f = all[i];
          if ((f.mimeType || '').indexOf('audio') !== 0) { continue; }
          var preview = '';
          if (f.url) { preview = String(f.url).slice(0, 150); }
          else if (f.signatureCipher) { preview = String(f.signatureCipher).slice(0, 80); }
          audio.push({
            itag: f.itag || 0,
            mime: (f.mimeType || '').split(';')[0],
            bitrate: f.bitrate || 0,
            hasUrl: !!f.url,
            hasCipher: !!f.signatureCipher,
            preview: preview,
            fullUrl: f.url ? String(f.url) : ''
          });
        }
        var poToken = '';
        try {
          if (r.serviceIntegrityDimensions && r.serviceIntegrityDimensions.poToken) {
            poToken = r.serviceIntegrityDimensions.poToken;
          }
        } catch (e) {}
        return JSON.stringify({
          status: ps.status || '',
          reason: ps.reason || '',
          sabr: !!sd.serverAbrStreamingUrl,
          sabrUrl: sd.serverAbrStreamingUrl ? String(sd.serverAbrStreamingUrl).slice(0, 200) : '',
          poToken: poToken,
          audio: audio
        });
      } catch (e) {
        return JSON.stringify({ status: "", error: String(e) });
      }
    })()
    """

    /// 读页面渲染后的 DOM，搜 PO Token —— 这正是 yt-dlp 的 webpo provider 做法
    /// （它在**渲染后**的 HTML 里正则搜 `"poToken":"..."`；curl 抓的原始 HTML 里没有，
    ///  因为那是 JS 执行前的）。
    private static let domPoTokenProbe = """
    (function () {
      try {
        var html = document.documentElement.outerHTML || '';
        var out = { len: html.length, poToken: '', sid: '', ctx: '' };
        var m = html.match(/"poToken"\\s*:\\s*"([^"]+)"/);
        if (m) { out.poToken = m[1]; }
        var m2 = html.match(/"serviceIntegrityDimensions"\\s*:\\s*\\{[^}]*"poToken"\\s*:\\s*"([^"]+)"/);
        if (!out.poToken && m2) { out.poToken = m2[1]; }
        // 顺带看看 ytcfg 里有没有现成的 token
        try {
          if (window.ytcfg && window.ytcfg.get) {
            var c = window.ytcfg.get('INNERTUBE_CONTEXT') || {};
            out.ctx = JSON.stringify(c).slice(0, 200);
          }
        } catch (e) {}
        return JSON.stringify(out);
      } catch (e) {
        return JSON.stringify({ len: 0, poToken: '', error: String(e) });
      }
    })()
    """

    /// 在页面脚本之前注入，拦 fetch / XHR，捕获带 PO Token 的 player 请求。
    private static let hookScript = """
    (function () {
      if (window.__meloHooked) { return; }
      window.__meloHooked = true;

      function report(obj) {
        try {
          var payload = JSON.stringify(obj);
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.melo) {
            window.webkit.messageHandlers.melo.postMessage(payload);
          }
          window.__meloLastPlayer = payload;
        } catch (e) {}
      }

      function inspect(body) {
        if (typeof body !== 'string') { return; }
        if (body.indexOf('serviceIntegrityDimensions') < 0) { return; }
        try {
          var parsed = JSON.parse(body);
          var ctx = parsed.context || {};
          var client = ctx.client || {};
          var sid = parsed.serviceIntegrityDimensions || {};
          if (!sid.poToken) { return; }
          report({
            kind: 'player',
            poToken: sid.poToken,
            clientName: client.clientName || '',
            clientVersion: client.clientVersion || '',
            visitorData: (ctx.visitorData || ''),
            videoId: parsed.videoId || ''
          });
        } catch (e) {}
      }

      var origFetch = window.fetch;
      window.fetch = function (input, init) {
        try { inspect(init && init.body); } catch (e) {}
        return origFetch.apply(this, arguments);
      };

      try {
        var origSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.send = function (body) {
          try { inspect(body); } catch (e) {}
          return origSend.apply(this, arguments);
        };
      } catch (e) {}
    })();
    """

    // MARK: - 消息回调

    private final class MessageHandler: NSObject, WKScriptMessageHandler {
        private(set) var captured: BrowserPoTokenProvider.Captured?
        private(set) var lastNote = ""

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let text = message.body as? String,
                  let data = text.data(using: .utf8),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                lastNote = "bad payload"
                return
            }
            guard root["kind"] as? String == "player",
                  let token = root["poToken"] as? String, !token.isEmpty else {
                lastNote = "no token field"
                return
            }
            let syncID = (root["visitorData"] as? String) ?? ""
            lastNote = "captured client=\(root["clientName"] as? String ?? "?")"
            captured = BrowserPoTokenProvider.Captured(
                poToken: token,
                clientName: root["clientName"] as? String ?? "",
                clientVersion: root["clientVersion"] as? String ?? "",
                visitorData: syncID,
                dataSyncId: nil,
                videoId: root["videoId"] as? String ?? ""
            )
        }
    }
}
