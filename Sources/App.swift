import SwiftUI
import UIKit

@main
struct MeloApp: App {
    @StateObject private var player = PlayerEngine.shared
    @StateObject private var library = Library.shared
    @StateObject private var playlists = PlaylistStore.shared

    /// 外观偏好：system / light / dark，持久化在 UserDefaults
    @AppStorage("melo.appearance") private var appearance = AppearanceMode.system.rawValue

    @UIApplicationDelegateAdaptor(MeloAppDelegate.self) private var appDelegate

    init() {
        Diagnostics.install()
        // 上次是闪退的话，这次启动就自动降级（关媒体中心集成、不自动弹播放页），
        // 先让它能用，再靠运行日志定位。
        if SafeMode.beginSession() {
            SafeMode.degrade()
        }
        Diagnostics.mark("compat: np=\(NowPlayingBridge.isEnabled) autoOpen=\(SafeMode.autoOpenPlayer)")
        // 上次崩过的话，系统在 ~/Library/Logs/DiagnosticReports 留了 .ips，
        // 直接抄关键帧进日志，不用用户去翻目录
        CrashReport.ingestLatest()
        MeloAppearance.apply()
        #if targetEnvironment(macCatalyst)
        // 触控板两指手势挂在 keyWindow 上，等窗口建好再装
        MacGestures.shared.install()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(playlists)
                .accentColor(Theme.accent)
                .preferredColorScheme((AppearanceMode(rawValue: appearance) ?? .system).colorScheme)
        }
    }
}

/// 只在进程正常结束时清掉「会话进行中」标记 —— 清不掉就说明这次是闪退。
final class MeloAppDelegate: UIResponder, UIApplicationDelegate {
    /// 快捷键挂在 AppDelegate 的 keyCommands 上（响应链末端）。
    /// 文本框在响应链更前面，会先消费按键，快捷键自动让路。
    override var keyCommands: [UIKeyCommand]? {
        #if targetEnvironment(macCatalyst)
        guard MacGestureSettings.on(MacGestureSettings.keyboardShortcuts) else { return super.keyCommands }
        // 文本框聚焦时不注册快捷键
        if let fr = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?
            .firstResponder,
           fr is UITextField || fr is UITextView {
            return super.keyCommands
        }
        return (super.keyCommands ?? []) + ShortcutStore.makeKeyCommands(target: self)
        #else
        return super.keyCommands
        #endif
    }

    @objc func handleShortcutAction(_ command: UIKeyCommand) {
        #if targetEnvironment(macCatalyst)
        MacGestures.shared.handleShortcutAction(command)
        #endif
    }

    func applicationWillTerminate(_ application: UIApplication) {
        Diagnostics.mark("── 正常退出")
        SafeMode.endSession()
    }
}

enum MeloAppearance {
    static func apply() {
        let tabAppearance = UITabBarAppearance()
        // Mac Catalyst 上只设 tintColor 不管用：标签文字会用系统默认色，
        // 深色栏配浅色字、浅色栏配深色字，遇到「白底白字」就整排看不见了。
        // 所以这里把三种布局的**正常态/选中态文字与图标颜色**都写死。
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor.systemGroupedBackground

        let normalTitle: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.secondaryLabel,
            .font: UIFont.systemFont(ofSize: 10, weight: .medium)
        ]
        let selectedTitle: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.accentUI,
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold)
        ]
        let layouts = [
            tabAppearance.stackedLayoutAppearance,
            tabAppearance.inlineLayoutAppearance,
            tabAppearance.compactInlineLayoutAppearance
        ]
        for layout in layouts {
            layout.normal.titleTextAttributes = normalTitle
            layout.selected.titleTextAttributes = selectedTitle
            layout.normal.iconColor = UIColor.secondaryLabel
            layout.selected.iconColor = Theme.accentUI
        }

        UITabBar.appearance().standardAppearance = tabAppearance
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = tabAppearance
        }
        UITabBar.appearance().tintColor = Theme.accentUI
        UITabBar.appearance().unselectedItemTintColor = UIColor.secondaryLabel

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithDefaultBackground()
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
        if #available(iOS 15.0, *) {
            UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        }
        UINavigationBar.appearance().tintColor = Theme.accentUI
        UINavigationBar.appearance().largeTitleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 34, weight: .bold)
        ]
    }
}
