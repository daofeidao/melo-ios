import SwiftUI
import UIKit

@main
struct MeloApp: App {
    @StateObject private var player = PlayerEngine.shared
    @StateObject private var library = Library.shared
    @StateObject private var playlists = PlaylistStore.shared

    /// 外观偏好：system / light / dark，持久化在 UserDefaults
    @AppStorage("melo.appearance") private var appearance = AppearanceMode.system.rawValue

    init() {
        Diagnostics.install()
        MeloAppearance.apply()
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
