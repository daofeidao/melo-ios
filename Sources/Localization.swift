import SwiftUI

/// 英文原文即 key，中文在 zh-Hans.lproj。
/// 若语言包未加载，界面退化为英文，不会露出裸 key。
func L(_ key: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return L("Follow System")
        case .light: return L("Light")
        case .dark: return L("Dark")
        }
    }

    /// nil 表示跟随系统
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
