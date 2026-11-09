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
        tabAppearance.configureWithDefaultBackground()
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
