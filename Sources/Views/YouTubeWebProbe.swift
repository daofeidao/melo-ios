import Foundation
import SwiftUI
import WebKit

/// YouTube 网页链路验证页。
///
/// 目的只有一个：确认「App 内嵌的 WebKit 里，YouTube 自己的网页能不能跑完反爬校验、
/// 并把可播地址交出来」。这一页不参与正常播放，也不改任何现有解析逻辑。
///
/// 判定标准：
/// - 步骤 A/B/C 绿 → 网页在 App 内是通的（T0 成立）
/// - 步骤 D 绿 → 网页直接给了音频直链，可以交给 AVPlayer（T1 成立，不用做 PO Token）
/// - 步骤 D 红但 C 绿 → 只有 SABR，需要 T2（PO Token 管道）
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
        guard let url = URL(string: "https://music.youtube.com/watch?v=\(videoID)") else { return }
        pageLoaded = false
        lines = []
        busy = true
        webView.load(URLRequest(url: url, timeoutInterval: 25))
    }

    /// 反复读 `ytInitialPlayerResponse`，最多试 `attempts` 次。
    /// 页面 didFinish 之后 YouTube 还会异步填这个对象，读一次经常是空的。
    func runProbe(videoID: String, attempts: Int = 8) {
        guard attempts > 0 else {
            busy = false
            if lines.isEmpty {
                append(title: L("Step A · Page loaded"), detail: "timeout", ok: false)
            }
            return
        }
        webView.evaluateJavaScript(Self.probeScript) { [weak self] result, error in
            guard let self = self else { return }
            if let error = error {
                self.busy = false
                self.append(title: L("Step C · Streaming data"), detail: error.localizedDescription, ok: false)
                return
            }
            let raw = (result as? String) ?? "{}"
            self.lastRaw = raw
            self.onResult?(raw)
            if raw.contains("\"noplayer\"") {
                // 还没填好，等 1 秒再来
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
            append(title: L("Step C · Streaming data"), detail: "unparsable: \(raw.prefix(120))", ok: false)
            return
        }

        append(title: L("Step A · Page loaded"), detail: "music.youtube.com", ok: pageLoaded)

        let status = json["status"] as? String ?? ""
        let reason = json["reason"] as? String ?? ""
        let playable = status == "OK"
        append(
            title: L("Step B · Playability"),
            detail: reason.isEmpty ? status : "\(status) · \(reason)",
            ok: playable
        )

        let hasSD = json["hasSD"] as? Bool ?? false
        let sabr = json["sabr"] as? Bool ?? false
        let total = json["total"] as? Int ?? 0
        let withURL = json["withURL"] as? Int ?? 0
        append(
            title: L("Step C · Streaming data"),
            detail: hasSD
                ? String(format: L("%d formats, %d with URL"), total, withURL) + (sabr ? " · SABR" : "")
                : L("Streaming data missing"),
            ok: hasSD && withURL > 0
        )

        let audio = json["audio"] as? Int ?? 0
        let itag = json["itag"] as? Int ?? 0
        let mime = json["mime"] as? String ?? ""
        let host = json["host"] as? String ?? ""
        let pot = json["pot"] as? Bool ?? false
        if audio > 0 {
            append(
                title: L("Step D · Direct audio URL"),
                detail: "itag \(itag) · \(mime) · \(host)\(pot ? " · pot" : "")",
                ok: true
            )
        } else {
            append(title: L("Step D · Direct audio URL"), detail: L("No direct audio URL"), ok: false)
        }

        let visitor = json["visitor"] as? String ?? ""
        append(
            title: L("Step E · Visitor data"),
            detail: visitor.isEmpty ? "—" : String(visitor.prefix(28)) + "…",
            ok: !visitor.isEmpty
        )
    }

    private func append(title: String, detail: String, ok: Bool) {
        lines.append(WebProbeLine(title: title, detail: detail, ok: ok))
    }

    // MARK: - 注入脚本

    /// 只读 window 上 YouTube 自己挂的对象，不发任何请求、不伪造身份。
    static let probeScript = """
    (function () {
      try {
        var r = window.ytInitialPlayerResponse;
        if (!r) { return JSON.stringify({ stage: "noplayer" }); }
        var ps = r.playabilityStatus || {};
        var sd = r.streamingData || null;
        var out = {
          stage: "ok",
          status: ps.status || "",
          reason: ps.reason || "",
          hasSD: !!sd,
          sabr: !!(sd && sd.serverAbrStreamingUrl),
          total: 0,
          withURL: 0,
          audio: 0,
          itag: 0,
          mime: "",
          host: "",
          pot: false,
          visitor: ""
        };
        try {
          if (window.ytcfg && window.ytcfg.get) {
            out.visitor = window.ytcfg.get("VISITOR_DATA") || "";
          }
        } catch (e) {}
        if (sd) {
          var all = (sd.adaptiveFormats || []).concat(sd.formats || []);
          out.total = all.length;
          var withURL = [];
          for (var i = 0; i < all.length; i++) {
            if (all[i].url) { withURL.push(all[i]); }
          }
          out.withURL = withURL.length;
          var audio = [];
          for (var j = 0; j < withURL.length; j++) {
            if ((withURL[j].mimeType || "").indexOf("audio") === 0) { audio.push(withURL[j]); }
          }
          out.audio = audio.length;
          if (audio.length) {
            var a = audio[0];
            out.itag = a.itag || 0;
            out.mime = (a.mimeType || "").split(";")[0];
            out.pot = (a.url || "").indexOf("pot=") >= 0;
            try { out.host = new URL(a.url).host; } catch (e) { out.host = ""; }
          }
        }
        return JSON.stringify(out);
      } catch (e) {
        return JSON.stringify({ stage: "error", reason: String(e) });
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
    @State private var videoID: String = SmokeTest.webProbeVideoID ?? "dQw4w9WgXcQ"

    var body: some View {
        VStack(spacing: 0) {
            WebProbeContainer(webView: model.webView)
                .frame(height: 280)
                .background(Color.black)

            Divider()

            List {
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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
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
        .navigationTitle(L("YouTube Web Probe"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.onResult = { raw in
                NSLog("SMOKE_YT_WEB \(raw)")
            }
            model.load(videoID: videoID)
            guard autoRun else { return }
            // 页面 didFinish 之后 YouTube 还要一会儿才填好 player response
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                model.runProbe(videoID: videoID)
            }
        }
    }
}
