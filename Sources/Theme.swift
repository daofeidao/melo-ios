import SwiftUI
import UIKit

enum Theme {
    /// Apple Music 品牌红
    static let accent = Color(red: 0.98, green: 0.18, blue: 0.29)
    static let accentUI = UIColor(red: 0.98, green: 0.18, blue: 0.29, alpha: 1)

    static var groupedBackground: Color { Color(UIColor.systemGroupedBackground) }
    static var secondaryBackground: Color { Color(UIColor.secondarySystemGroupedBackground) }
    static var separator: Color { Color(UIColor.separator) }
    static var secondaryLabel: Color { Color(UIColor.secondaryLabel) }
    static var tertiaryLabel: Color { Color(UIColor.tertiaryLabel) }
}

enum Layout {
    static var safeBottom: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let inset = scene?.windows.first { $0.isKeyWindow }?.safeAreaInsets.bottom
            ?? scene?.windows.first?.safeAreaInsets.bottom
            ?? 0
        return inset
    }

    /// 标准 TabBar 高度（49）+ 底部安全区
    static var tabBarHeight: CGFloat { 49 + safeBottom }

    /// 迷你播放器占位（56）+ 间距
    static var miniPlayerHeight: CGFloat { 64 }

    /// 滚动内容需要预留的底部空间
    static var contentBottomInset: CGFloat { tabBarHeight + miniPlayerHeight + 12 }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}

/// 稳定的颜色提取：给播放页做"随封面变化"的底色
enum ColorExtractor {
    static func averageColor(of image: UIImage) -> Color {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        red = 0.12; green = 0.12; blue = 0.14
        // 降采样后取均值，避免逐像素遍历
        let size = CGSize(width: 12, height: 12)
        let renderer = UIGraphicsImageRenderer(size: size)
        let small = renderer.image { ctx in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cg = small.cgImage else { return Color(red: Double(red), green: Double(green), blue: Double(blue)) }

        let width = cg.width, height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &data, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return Color(red: Double(red), green: Double(green), blue: Double(blue))
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sumR: CGFloat = 0, sumG: CGFloat = 0, sumB: CGFloat = 0
        var count: CGFloat = 0
        var i = 0
        while i < data.count {
            let r = CGFloat(data[i]) / 255.0
            let g = CGFloat(data[i + 1]) / 255.0
            let b = CGFloat(data[i + 2]) / 255.0
            // 忽略极暗与极亮的像素，得到更有辨识度的底色
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            if lum > 0.08 && lum < 0.95 {
                sumR += r; sumG += g; sumB += b; count += 1
            }
            i += 4
        }
        if count < 1 {
            sumR = 0.12; sumG = 0.12; sumB = 0.14; count = 1
            alpha = 1
        }
        _ = alpha
        return Color(
            red: Double(min(1, max(0, sumR / count))),
            green: Double(min(1, max(0, sumG / count))),
            blue: Double(min(1, max(0, sumB / count)))
        )
    }
}
