import Foundation
import ImageIO
import UIKit

final class ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let diskDir: URL
    private let diskQueue = DispatchQueue(label: "melo.artwork-disk", qos: .utility)

    private init() {
        // 降采样后每张封面只占几万到几十 KB，260 的上限可以放宽到 600
        cache.countLimit = 600
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .returnCacheDataElseLoad
        self.session = URLSession(configuration: config)

        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.diskDir = dir
    }

    /// 内存缓存，给 SwiftUI 的 .task 快速命中用
    func cached(for url: URL) -> UIImage? {
        cache.object(forKey: cacheKey(url, maxPixel: 420))
    }

    /// maxPixel：按显示尺寸解码封面。滚动卡顿的根因是封面原图动辄 1500~3000px，
    /// UIImage(data:) 是惰性解码 —— 滑到哪张就在主线程解哪张，一解就是几十毫秒。
    /// 这里用 ImageIO 直接解出目标尺寸的小图（shouldCacheImmediately 预解码），
    /// 解码在后台完成，主线程只做贴图。
    func image(for url: URL, maxPixel: CGFloat = 420) async -> UIImage? {
        let pixel = min(max(maxPixel, 60), 600)
        let key = cacheKey(url, maxPixel: pixel)
        if let cached = cache.object(forKey: key) { return cached }

        // 磁盘缓存：榜单封面在冷启动后不必再下一遍（每次几十 KB，几十张就是几 MB）
        if let data = try? Data(contentsOf: diskURL(url)),
           let image = Self.downsampled(data, maxPixel: pixel) {
            cache.setObject(image, forKey: key)
            return image
        }

        do {
            let (data, _) = try await session.data(from: url)
            guard let image = Self.downsampled(data, maxPixel: pixel) else { return nil }
            cache.setObject(image, forKey: key)
            saveToDisk(data, for: url)
            return image
        } catch {
            return nil
        }
    }

    // MARK: - 降采样

    private static func downsampled(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // 关键：解码时立即解到内存，而不是第一次绘制才解（惰性解码会卡主线程）
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            // 解不出来（比如 WebP 之类系统不认的格式）退回原解码，保证有图
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    private func cacheKey(_ url: URL, maxPixel: CGFloat) -> NSString {
        "\(url.absoluteString)#\(Int(maxPixel))" as NSString
    }

    // MARK: - 磁盘缓存

    /// FNV-1a，跨启动稳定；Swift 的 hashValue 每次进程都带随机种子，不能当文件名
    private func diskKey(_ url: URL) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16) + ".img"
    }

    private func diskURL(_ url: URL) -> URL {
        diskDir.appendingPathComponent(diskKey(url))
    }

    private func saveToDisk(_ data: Data, for url: URL) {
        // 只缓存正常大小的封面，别让一张异常大图占满 Caches
        guard data.count > 0, data.count < 2_000_000 else { return }
        let target = diskURL(url)
        diskQueue.async { try? data.write(to: target, options: .atomic) }
    }
}
