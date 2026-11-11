import Foundation
import SwiftUI
import WebKit

/// YouTube 网页链路验证页。
///
/// 目的只有一个：确认「App 内嵌的 WebKit 里，YouTube 自己的网页能不能跑完反爬校验、
/// 并把可播地址交出来」。这一页不参与正常播放，也不改任何现有解析逻辑。
///
/// 判定标准：
/// - 步骤 A/B 绿 → 网页在 App 内能拿到 player response（T0 成立）
/// - 步骤 D 绿 → 页面确实向 googlevideo 发过音频请求，说明 CDN 链路在 App 内是通的
/// - 有了直链 → 可以交给 AVPlayer（T1 成立，不用做 PO Token）
struct WebProbeLine: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let ok: Bool
}

final class YouTubeWebProbeModel: NSObject, ObservableObject {
    @Published var lines: [WebProbeLine] = []
    @Published var busy = false
    @Published var pageLoaded = false
    @Published var lastRaw = ""
    /// 页面给的 visitorData，铸 PO Token 时当 identifier 用
    @Published var visitor = ""

    let webView: WKWebView

    /// 冒烟测试用：每次探测结果都会经过这里，CI 靠它打日志
    var onResult: ((String) -> Void)?

    /// 用真 Safari 的 UA。WebView 默认 UA 带 app 名，YouTube 会当成"非浏览器"降级。
    /// 真接进播放链路时，交给 AVPlayer 的 UA 必须和这里一致。
    static let safariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 15_6 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/15.6 Mobile/15E148 Safari/604.1"

    override init() {
        let config = WKWebViewConfiguration()
        // 用默认数据存储：cookie / visitorData 跨启动保留，才像"同一个浏览器"
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.customUserAgent = YouTubeWebProbeModel.safariUserAgent
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
    }

    func load(videoID: String) {
        // 用 www.youtube.com 的 watch 页，不是 music.youtube.com：
        // 前者会把 ytInitialPlayerResponse 直接内联进 HTML，后者不会。
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else { return }
        pageLoaded = false
        lines = []
        busy = true
        webView.load(URLRequest(url: url, timeoutInterval: 25))
    }

    /// 反复读页面状态，最多试 `attempts` 次。
    /// 页面 didFinish 之后 YouTube 还会异步填对象，读一次经常是空的。
    func runProbe(videoID: String, attempts: Int = 8) {
        guard attempts > 0 else {
            busy = false
            if lines.isEmpty {
                lines = [WebProbeLine(title: L("Step A · Page loaded"), detail: "timeout", ok: false)]
            }
            return
        }
        webView.evaluateJavaScript(Self.probeScript) { [weak self] result, error in
            guard let self = self else { return }
            if let error = error {
                self.busy = false
                self.lines = [WebProbeLine(title: L("Step B · Player response"), detail: error.localizedDescription, ok: false)]
                return
            }
            let raw = (result as? String) ?? "{}"
            self.lastRaw = raw
            self.onResult?(raw)
            // 页面还没起来，等 1 秒再来
            if raw.contains("\"ready\":false") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.runProbe(videoID: videoID, attempts: attempts - 1)
                }
                return
            }
            self.apply(raw: raw)
        }
    }

    // MARK: - 解析探测结果

    private func apply(raw: String) {
        busy = false
        lines = []
        guard let data = raw.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            lines = [WebProbeLine(title: L("Step B · Player response"), detail: "unparsable", ok: false)]
            return
        }

        let ready = json["ready"] as? Bool ?? false
        lines.append(WebProbeLine(title: L("Step A · Page loaded"), detail: webView.url?.absoluteString ?? "—", ok: ready))

        let hasPR = json["hasPR"] as? Bool ?? false
        let status = json["status"] as? String ?? ""
        let reason = json["reason"] as? String ?? ""
        lines.append(WebProbeLine(
            title: L("Step B · Player response"),
            detail: hasPR ? (reason.isEmpty ? status : "\(status) · \(reason)") : L("Not present on this page"),
            ok: hasPR && status == "OK"
        ))

        let hasCfg = json["hasCfg"] as? Bool ?? false
        let visitor = json["visitor"] as? String ?? ""
        self.visitor = visitor
        lines.append(WebProbeLine(
            title: L("Step C · Page config"),
            detail: hasCfg
                ? "ytcfg ✓ · visitor \(visitor.isEmpty ? "—" : String(visitor.prefix(20)) + "…")"
                : "ytcfg ✗",
            ok: hasCfg && !visitor.isEmpty
        ))

        let hasSD = json["hasSD"] as? Bool ?? false
        let withURL = json["withURL"] as? Int ?? 0
        let audio = json["audio"] as? Int ?? 0
        let itag = json["itag"] as? Int ?? 0
        let mime = json["mime"] as? String ?? ""
        if audio > 0 {
            lines.append(WebProbeLine(
                title: L("Step D · Direct audio URL"),
                detail: "itag \(itag) · \(mime) · \(withURL)/\(withURL + (json["noURL"] as? Int ?? 0)) 条带直链",
                ok: true
            ))
        } else {
            lines.append(WebProbeLine(
                title: L("Step D · Direct audio URL"),
                detail: hasSD ? L("Streaming data present but no direct URL (SABR)") : L("No direct audio URL"),
                ok: false
            ))
        }

        let gv = json["gvCount"] as? Int ?? 0
        let gvHost = json["gvHost"] as? String ?? ""
        let gvPot = json["gvPot"] as? Bool ?? false
        lines.append(WebProbeLine(
            title: L("Step E · Audio CDN"),
            detail: gv > 0 ? "googlevideo ×\(gv) · \(gvHost)\(gvPot ? " · pot" : "")" : L("No googlevideo request seen"),
            ok: gv > 0
        ))
    }

    // MARK: - 注入脚本

    /// 只读页面已有的对象和已发生的请求，不发新请求、不伪造身份。
    static let probeScript = """
    (function () {
      try {
        var out = { ready: false, hasPR: false, status: "", reason: "", hasSD: false,
                    withURL: 0, noURL: 0, audio: 0, itag: 0, mime: "",
                    hasCfg: false, visitor: "", gvCount: 0, gvHost: "", gvPot: false,
                    videoReady: -1, videoPaused: true };
        out.ready = (document.readyState === "complete") || !!document.body;
        try {
          if (window.ytcfg && window.ytcfg.get) {
            out.hasCfg = true;
            out.visitor = window.ytcfg.get("VISITOR_DATA") || "";
          }
        } catch (e) {}
        var r = window.ytInitialPlayerResponse || null;
        if (r) {
          out.hasPR = true;
          var ps = r.playabilityStatus || {};
          out.status = ps.status || "";
          out.reason = ps.reason || "";
          var sd = r.streamingData || null;
          if (sd) {
            out.hasSD = true;
            var all = (sd.adaptiveFormats || []).concat(sd.formats || []);
            var withURL = [];
            for (var i = 0; i < all.length; i++) {
              if (all[i].url) { withURL.push(all[i]); } else { out.noURL++; }
            }
            out.withURL = withURL.length;
            var audio = [];
            for (var j = 0; j < withURL.length; j++) {
              if ((withURL[j].mimeType || "").indexOf("audio") === 0) { audio.push(withURL[j]); }
            }
            out.audio = audio.length;
            if (audio.length) {
              out.itag = audio[0].itag || 0;
              out.mime = (audio[0].mimeType || "").split(";")[0];
            }
          }
        }
        try {
          var res = performance.getEntriesByType("resource") || [];
          var gv = [];
          for (var k = 0; k < res.length; k++) {
            if ((res[k].name || "").indexOf("googlevideo.com") >= 0) { gv.push(res[k].name); }
          }
          out.gvCount = gv.length;
          if (gv.length) {
            out.gvPot = gv[0].indexOf("pot=") >= 0;
            try { out.gvHost = new URL(gv[0]).host; } catch (e) {}
          }
        } catch (e) {}
        try {
          var v = document.querySelector("video");
          if (v) { out.videoReady = v.readyState; out.videoPaused = v.paused; }
        } catch (e) {}
        return JSON.stringify(out);
      } catch (e) {
        return JSON.stringify({ ready: true, error: String(e) });
      }
    })()
    """
}

extension YouTubeWebProbeModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        busy = false
        lines = [WebProbeLine(title: L("Step A · Page loaded"), detail: error.localizedDescription, ok: false)]
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        busy = false
        lines = [WebProbeLine(title: L("Step A · Page loaded"), detail: error.localizedDescription, ok: false)]
    }
}

private struct WebProbeContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct YouTubeWebProbeView: View {
    /// 冒烟测试传 true：进页面就自动跑一次，并把结果打到系统日志
    var autoRun: Bool = false

    @StateObject private var model = YouTubeWebProbeModel()
    @StateObject private var po = PoTokenProbe()
    @State private var videoID: String = SmokeTest.webProbeVideoID ?? "dQw4w9WgXcQ"

    var body: some View {
        VStack(spacing: 0) {
            WebProbeContainer(webView: model.webView)
                .frame(height: 260)
                .background(Color.black)

            Divider()

            List {
                Section {
                    Text(L("Diagnostic only — this page does not affect playback."))
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondaryLabel)
                    Text(L("Verified on 2026-11-10: the YouTube page returns no direct audio URL (all SABR), and the PO Token half-check does not complete. Kept for reference."))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    HStack {
                        Text(L("Video ID"))
                            .font(.system(size: 13))
                            .foregroundColor(Theme.secondaryLabel)
                        TextField("videoId", text: $videoID)
                            .font(.system(size: 13, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    Button {
                        model.load(videoID: videoID)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                            model.runProbe(videoID: videoID)
                        }
                    } label: {
                        HStack {
                            Text(L("Run Check"))
                            Spacer()
                            if model.busy { ProgressView() }
                        }
                    }
                } footer: {
                    Text(L("Checks whether YouTube's own page, running inside the app, hands back a direct audio URL — no client impersonation."))
                }

                Section {
                    Button {
                        Task { await po.run(videoID: videoID, visitor: model.visitor) }
                    } label: {
                        HStack {
                            Text(L("Run Half Check"))
                            Spacer()
                            if po.busy { ProgressView() }
                        }
                    }
                    ForEach(po.lines) { line in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: line.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(line.ok ? .green : .red)
                                Text(line.title)
                                    .font(.system(size: 13))
                            }
                            Text(line.detail)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.secondaryLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text(L("PO Token Half Check"))
                } footer: {
                    Text(L("Mints a PO Token inside a hidden WebView, then asks YouTube for a direct audio URL as IOS / ANDROID."))
                }

                Section {
                    ForEach(model.lines) { line in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: line.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(line.ok ? .green : .red)
                                Text(line.title)
                                    .font(.system(size: 13))
                            }
                            Text(line.detail)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.secondaryLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text(L("Result"))
                }
            }
            .listStyle(InsetGroupedListStyle())
        }
        .navigationTitle(L("Advanced Diagnostics"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.onResult = { raw in
                NSLog("SMOKE_YT_WEB \(raw)")
            }
            model.load(videoID: videoID)
            guard autoRun else { return }
            // 页面 didFinish 之后 YouTube 还要一会儿才填好 player response
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                model.runProbe(videoID: videoID)
            }
            // 半验证要拿页面给的 visitorData 当 identifier，等它出来再跑
            Task {
                for _ in 0..<40 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if !model.visitor.isEmpty { break }
                }
                await po.run(videoID: videoID, visitor: model.visitor)
                for line in po.lines {
                    NSLog("SMOKE_YT_POT \(line.ok ? "OK" : "NO") \(line.title) :: \(line.detail)")
                }
            }
        }
    }
}
