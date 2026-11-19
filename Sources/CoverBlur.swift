import Foundation
import UIKit

/// 用纯 CPU 把专辑封面预模糊成一张小图，供播放页做「磨砂半透」背景。
///
/// 为什么不用系统方案：
/// - SwiftUI `.blur(radius: 60)`：2011 MBP 的 HD3000 没有 Metal，大半径实时模糊
///   走 CoreAnimation 兼容层，整屏合成时渲染进程会崩（「一点播放页就闪退」）。
/// - Accelerate vImageBoxConvolve：在这台机器的系统库上实测返回
///   kvImageInvalidKernelSize(-21767)，任何 radius 都失败，等于从没成功过。
/// 所以用纯 Swift 滑动窗口 box blur：64×64 小图、三遍、RGBA 四通道，
/// 每遍 O(像素数)、总共几万次运算，x86_64 上几毫秒完成，零 GPU、零外部依赖。
enum CoverBlur {

    private static let side = 64
    /// 三遍 box blur ≈ 高斯；半径 12 是经验值，在小图上足够糊。
    private static let radius = 10
    private static let passes = 3
    /// 提饱和系数：让封面主色透出来，接近 iOS 高斯模糊背景的通透感。
    private static let saturation: Float = 1.35
    /// 暗部抬升下限：避免模糊后被纯黑压死。
    private static let brightnessFloor: Float = 0.06

    static func blurred(_ image: UIImage) -> UIImage? {
        let w = side, h = side
        guard let cg = resizedCG(image, to: w) else {
            Diagnostics.mark("coverblur: resize nil")
            return nil
        }

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let drawCtx = CGContext(
                data: &pixels, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            Diagnostics.mark("coverblur: ctx nil")
            return nil
        }
        drawCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 三遍可分离的 box blur（水平 + 垂直各一遍算一次）。
        var scratch = [UInt8](repeating: 0, count: pixels.count)
        for _ in 0..<passes {
            boxBlurHorizontal(&pixels, &scratch, w: w, h: h, radius: radius)
            boxBlurVertical(&scratch, &pixels, w: w, h: h, radius: radius)
        }

        // 提亮 + 提饱和：iOS 的封面模糊背景是「通透的专辑色」，不是灰扑扑一团。
        vibrance(&pixels, saturation: saturation, floor: brightnessFloor)

        guard let outCtx = CGContext(
                data: &pixels, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let outCG = outCtx.makeImage() else {
            Diagnostics.mark("coverblur: makeImage nil")
            return nil
        }
        Diagnostics.mark("coverblur: ok")
        return UIImage(cgImage: outCG)
    }

    // MARK: - 可分离 box blur（滑动窗口，O(n)）

    /// 水平方向：每行用滑动窗口求 RGBA 均值，写进 dst。
    /// 窗口 [x-r, x+r]，边界外用 clamp 的像素值补齐（edge extend）。
    private static func boxBlurHorizontal(_ src: inout [UInt8], _ dst: inout [UInt8],
                                          w: Int, h: Int, radius r: Int) {
        for y in 0..<h {
            let row = y * w * 4
            var sum = [Int](repeating: 0, count: 4)
            // 初始窗口中心 x=0：覆盖 [-r, r]，负索引按 0 处理
            for k in -r...r {
                let idx = min(max(k, 0), w - 1)
                let i = row + idx * 4
                for c in 0..<4 { sum[c] += Int(src[i + c]) }
            }
            for x in 0..<w {
                let o = row + x * 4
                for c in 0..<4 { dst[o + c] = UInt8(clamping: sum[c] / (2 * r + 1)) }
                if x + 1 < w {
                    // 窗口右移一格：移出最左 (x-r)，移入最右 (x+r+1)，都做边界 clamp
                    let out = min(max(x - r, 0), w - 1)
                    let inn = min(max(x + r + 1, 0), w - 1)
                    let oi = row + out * 4, ii = row + inn * 4
                    for c in 0..<4 { sum[c] += Int(src[ii + c]) - Int(src[oi + c]) }
                }
            }
        }
    }

    /// 垂直方向：每列滑动窗口，src → dst。
    private static func boxBlurVertical(_ src: inout [UInt8], _ dst: inout [UInt8],
                                        w: Int, h: Int, radius r: Int) {
        for x in 0..<w {
            var sum = [Int](repeating: 0, count: 4)
            for k in -r...r {
                let idx = min(max(k, 0), h - 1)
                let i = (idx * w + x) * 4
                for c in 0..<4 { sum[c] += Int(src[i + c]) }
            }
            for y in 0..<h {
                let o = (y * w + x) * 4
                for c in 0..<4 { dst[o + c] = UInt8(clamping: sum[c] / (2 * r + 1)) }
                if y + 1 < h {
                    let out = min(max(y - r, 0), h - 1)
                    let inn = min(max(y + r + 1, 0), h - 1)
                    let oi = (out * w + x) * 4, ii = (inn * w + x) * 4
                    for c in 0..<4 { sum[c] += Int(src[ii + c]) - Int(src[oi + c]) }
                }
            }
        }
    }

    /// 对每个像素：先抬暗部，再围绕灰度做饱和度增强。alpha 保持不动。
    private static func vibrance(_ p: inout [UInt8], saturation sat: Float, floor: Float) {
        var i = 0
        while i < p.count {
            let r = Float(p[i]) / 255, g = Float(p[i + 1]) / 255, b = Float(p[i + 2]) / 255
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            let lifted = floor + lum * (1 - floor)
            p[i]     = UInt8(min(255, max(0, (lifted + (r - lum) * sat) * 255)))
            p[i + 1] = UInt8(min(255, max(0, (lifted + (g - lum) * sat) * 255)))
            p[i + 2] = UInt8(min(255, max(0, (lifted + (b - lum) * sat) * 255)))
            i += 4
        }
    }

    private static func resizedCG(_ image: UIImage, to side: Int) -> CGImage? {
        let target = CGSize(width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }.cgImage
    }
}
