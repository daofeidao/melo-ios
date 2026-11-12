import SwiftUI
import WebKit

/// 网页登录：把平台的登录页放进应用内的 WKWebView，用户在页面里正常登录，
/// 登录成功后把该域名下的 Cookie 拼成 header 存进 SourcePrefs。
///
/// 为什么不做账号密码表单：这些平台都没有对外的登录 API，
/// 自己拼表单既拿不到会话，又会让用户以为密码被我们保存了。
/// 用它们自己的网页登录，凭据只输在平台页面里，我们只取 Cookie。
struct WebLoginView: View {
    let platform: SourcePrefs.SourceInfo

    @ObservedObject private var prefs = SourcePrefs.shared
    @Environment(\.dismiss) private var dismiss

    @State private var saved = false
    @State private var pageLoading = true

    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                LoginWebView(
                    urlString: prefs.loginURL(platform.id),
                    domain: prefs.cookieDomain(platform.id),
                    hint: prefs.cookieHint(platform.id),
                    onCookieFound: { header in
                        prefs.setCookie(platform.id, header)
                        saved = true
                    },
                    onLoaded: { pageLoading = false }
                )

                if pageLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .padding(.top, 6)
                }

                if saved {
                    VStack(spacing: 6) {
                        Text(L("Sign-in saved"))
                            .font(.system(size: 17, weight: .semibold))
                        Text(L("Requests will carry it automatically from now on."))
                            .font(.system(size: 13))
                            .foregroundColor(Theme.secondaryLabel)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.groupedBackground.opacity(0.94))
                }
            }
            .navigationTitle("\(L("Sign In")) · \(platform.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) {
                        // 手动兜底：有的平台登录后 Cookie 延迟写入，自动检测可能错过
                        LoginWebView.collectCookie(domainSuffix: prefs.cookieDomain(platform.id)) { header in
                            if !header.isEmpty { prefs.setCookie(platform.id, header) }
                        }
                        dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onChange(of: saved) { value in
            guard value else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { dismiss() }
        }
    }
}

private struct LoginWebView: UIViewRepresentable {
    let urlString: String
    let domain: String
    let hint: String?
    let onCookieFound: (String) -> Void
    let onLoaded: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.scrollView.keyboardDismissMode = .interactive

        // QQ 音乐没有移动版登录页（i.y.qq.com 那几个路径全是空白错误页），
        // 只有 PC 版 y.qq.com 右上角提供登录入口；用桌面 UA 打开才能点到。
        if urlString.contains("y.qq.com") {
            web.customUserAgent = Self.desktopUA
            web.scrollView.minimumZoomScale = 0.5
        }

        if let url = URL(string: urlString) {
            web.load(URLRequest(url: url))
        }

        context.coordinator.start(domain: domain, hint: hint, onFound: onCookieFound)
        return web
    }

    private static let desktopUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoaded: onLoaded)
    }

    /// 登录成功后页面通常不动，没有可靠的「跳转完成」信号，
    /// 所以轮询 Cookie：命中关键字段就自动收起。
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onLoaded: () -> Void
        private var timer: Timer?
        private var finished = false

        init(onLoaded: @escaping () -> Void) {
            self.onLoaded = onLoaded
        }

        func start(domain: String, hint: String?, onFound: @escaping (String) -> Void) {
            stop()
            timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
                guard let self, !self.finished else { return }
                LoginWebView.collectCookie(domainSuffix: domain) { header in
                    guard self.timer != nil, !self.finished else { return }
                    guard let hint, header.contains(hint), header.count > hint.count + 4 else { return }
                    self.finished = true
                    self.stop()
                    onFound(header)
                }
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoaded()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoaded()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoaded()
        }
    }

    /// 只收目标域名下的 Cookie，避免把其他平台的凭据混进同一个 header
    static func collectCookie(domainSuffix: String, completion: @escaping (String) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let matched = cookies.filter { cookie in
                domainSuffix.isEmpty || cookie.domain.hasSuffix(domainSuffix)
            }
            let header = matched
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            DispatchQueue.main.async { completion(header) }
        }
    }
}
