import Foundation
import UIKit

final class ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let diskDir: URL
    private let diskQueue = DispatchQueue(label: "melo.artwork-disk", qos: .utility)

    private init() {
        cache.countLimit = 260
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
        cache.object(forKey: url.absoluteString as NSString)
    }

    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return cached }

        // 磁盘缓存：榜单封面在冷启动后不必再下一遍（每次几十 KB，几十张就是几 MB）
        if let data = try? Data(contentsOf: diskURL(url)),
           let image = UIImage(data: data) {
            cache.setObject(image, forKey: key)
            return image
        }

        do {
            let (data, _) = try await session.data(from: url)
            guard let image = UIImage(data: data) else { return nil }
            cache.setObject(image, forKey: key)
            saveToDisk(data, for: url)
            return image
        } catch {
            return nil
        }
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
