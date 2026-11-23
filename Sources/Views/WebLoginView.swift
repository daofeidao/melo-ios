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

    private enum Mode { case web, paste }

    @ObservedObject private var prefs = SourcePrefs.shared
    @Environment(\.dismiss) private var dismiss

    /// 默认走网页登录；「粘贴 Cookie」是备用入口。
    /// 以前这两种方式是「弹菜单二选一」，iOS 15 上在菜单收起时再 present sheet
    /// 会被丢掉 —— 现在合并进同一个页面，用顶部按钮切换，不会再出现点了没反应。
    @State private var mode: Mode = .web
    @State private var saved = false
    /// 验证型平台：验证通过后给成功提示，但不自动退出（还要留着页面供重新验证）
    @State private var verified = false
    @State private var pageLoading = true
    @State private var pasted = ""

    var body: some View {
        NavigationView {
            Group {
                if mode == .web { webContent } else { pasteContent }
            }
            .navigationTitle("\(platform.login == .verify ? L("Verify") : L("Sign In")) · \(platform.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 14) {
                        Button(mode == .web ? L("Paste Cookie") : L("Use the web page")) {
                            mode = (mode == .web) ? .paste : .web
                        }
                        Button(L("Done")) { finish() }
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

    private var webContent: some View {
        ZStack(alignment: .top) {
            LoginWebView(
                urlString: prefs.loginURL(platform.id),
                domain: prefs.cookieDomain(platform.id),
                hint: prefs.cookieHint(platform.id),
                clearCookiesFirst: platform.login == .verify,
                onCookieFound: { header in
                    prefs.setCookie(platform.id, header)
                    // 歌曲宝是「人机验证」不是「登录」：验证通过（拿到 cf_clearance）
                    // 就清掉待验证状态，播放页的提示按钮自动消失。
                    if platform.id == "gequbao" { Gequbao.onVerified() }
                    // 验证型平台不自动收起：旧 Cookie 可能还在、Cloudflare 也会自动续期，
                    // 一命中就退出会让用户没法重新过验证。只提示成功，由用户自己点 Done。
                    if platform.login == .verify {
                        verified = true
                    } else {
                        saved = true
                    }
                },
                onLoaded: { pageLoading = false }
            )

            if pageLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .padding(.top, 6)
            }

            if saved {
                // 登录型：全屏提示，马上自动退出
                VStack(spacing: 6) {
                    Text(L("Sign-in saved"))
                        .font(.system(size: 17, weight: .semibold))
                    Text(L("Requests will carry it automatically from now on."))
                        .font(.system(size: 13))
                        .foregroundColor(Theme.secondaryLabel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.groupedBackground.opacity(0.94))
            } else if verified {
                // 验证型：只给顶部小横幅，不遮挡页面 —— 过期后用户能在同一页重新过验证
                VStack(spacing: 2) {
                    Text(L("Verification passed · you can verify again anytime"))
                        .font(.system(size: 13, weight: .medium))
                    Text(L("Tap Done when finished"))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.secondaryLabel)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.accent.opacity(0.14))
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
    }

    private var pasteContent: some View {
        Form {
            Section {
                // iOS 15 没有 TextField(axis:)，多行输入用 TextEditor
                TextEditor(text: $pasted)
                    .frame(minHeight: 120)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.system(size: 13, design: .monospaced))
            } footer: {
                Text(L("Paste a Cookie header from the platform's website if the in-app sign-in does not work. The app never sees your password - only the resulting Cookie is stored, on this device."))
            }
        }
    }

    private func finish() {
        if mode == .paste {
            let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { prefs.setCookie(platform.id, text) }
            if platform.id == "gequbao" { Gequbao.onVerified() }
            dismiss()
            return
        }
        // 手动兜底：有的平台登录后 Cookie 延迟写入，自动检测可能错过
        LoginWebView.collectCookie(domainSuffix: prefs.cookieDomain(platform.id)) { header in
            if !header.isEmpty { prefs.setCookie(platform.id, header) }
        }
        if platform.id == "gequbao" { Gequbao.onVerified() }
        dismiss()
    }
}

private struct LoginWebView: UIViewRepresentable {
    let urlString: String
    let domain: String
    let hint: String?
    var clearCookiesFirst: Bool = false
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
        // 歌曲宝的人机验证看 Cloudflare 的 cf_clearance，它绑定 User-Agent：
        // WebView 和取流请求必须用同一个 UA，否则验证通过也照样被拦。
        if urlString.contains("gequbao.com") {
            web.customUserAgent = Gequbao.mobileUA
        }

        if let url = URL(string: urlString) {
            if clearCookiesFirst {
                // 验证型平台每次进入先清旧 Cookie：歌曲宝 cf_clearance 很容易过期，
                // 旧值还在的话一进页面就命中 hint，用户没机会重新过人机验证。
                // 清完再 load，强制 Cloudflare 重新下发验证。
                let store = WKWebsiteDataStore.default().httpCookieStore
                store.getAllCookies { cookies in
                    let stale = cookies.filter { cookie in
                        url.host.map { cookie.domain.hasSuffix($0) } ?? false
                    }
                    let group = DispatchGroup()
                    for cookie in stale { group.enter(); store.delete(cookie) { group.leave() } }
                    group.notify(queue: .main) {
                        web.load(URLRequest(url: url))
                    }
                }
            } else {
                web.load(URLRequest(url: url))
            }
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
