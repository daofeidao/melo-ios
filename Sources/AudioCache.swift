import Foundation
import CryptoKit

/// 音频本体缓存：把播过的曲目落盘到 `Caches/Audio`，二次播放直接读本地文件。
///
/// 和 `StreamCache` 的分工：
/// - `StreamCache` 缓存「直链」，省掉再次解析的等待；直链本身会过期。
/// - `AudioCache` 缓存「音频文件」，不会过期，弱网、直链失效、源站限流都能直接用。
///
/// 默认开启，上限 2 GB，按最近使用时间做 LRU 淘汰。放在 Caches 目录，
/// 系统存储紧张时可能被清理——这是预期行为，不算用户手动删除。
final class AudioCache {

    static let shared = AudioCache()

    /// `@AppStorage` 用的键；关闭后不再下载，但已缓存的文件仍然可播。
    static let enabledKey = "melo.cacheAudio"

    private let limitBytes: Int64 = 2 * 1024 * 1024 * 1024
    private let lock = NSLock()
    private var inFlight = Set<String>()
    private let io = DispatchQueue(label: "melo.audio-cache", qos: .utility)

    private var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Audio", isDirectory: true)
    }

    var isEnabled: Bool {
        // 没写过这个键时默认开启
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    // MARK: - 查询

    /// 命中时更新一次修改时间，LRU 淘汰才不会把刚播过的歌删掉
    func cachedURL(for track: Track) -> URL? {
        let key = Self.digest(track.id)
        for ext in ["m4a", "mp3", "audio"] {
            let url = directory.appendingPathComponent(key + "." + ext)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: url.path
            )
            return url
        }
        return nil
    }

    // MARK: - 下载

    /// 起播后调用：后台把音频拉一份到本地。失败不影响正在播放的流。
    func store(from remote: URL, for track: Track, mime: String, userAgent: String?) {
        guard isEnabled, !remote.isFileURL else { return }

        // AVPlayer 放不了的格式（webm/opus）不缓存，免得下次命中一个播不了的文件
        let ext = Self.fileExtension(for: mime)
        guard !ext.isEmpty else { return }

        // 已经有文件就不再下
        if cachedURL(for: track) != nil { return }

        let key = Self.digest(track.id)
        lock.lock()
        guard !inFlight.contains(key) else {
            lock.unlock()
            return
        }
        inFlight.insert(key)
        lock.unlock()

        let target = directory.appendingPathComponent(key + "." + ext)
        var request = URLRequest(url: remote)
        request.timeoutInterval = 60
        if let userAgent = userAgent, !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        URLSession.shared.downloadTask(with: request) { [weak self] temp, response, _ in
            guard let self = self else { return }
            defer {
                self.lock.lock()
                self.inFlight.remove(key)
                self.lock.unlock()
            }

            guard let temp = temp,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return }

            let attributes = try? FileManager.default.attributesOfItem(atPath: temp.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            // 小于 256 KB 的多半是错误页或截断文件，宁可不缓存
            guard size > 256 * 1024 else {
                try? FileManager.default.removeItem(at: temp)
                return
            }

            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: temp, to: target)
                self.trimIfNeeded()
            } catch {
                try? FileManager.default.removeItem(at: temp)
            }
        }.resume()
    }

    // MARK: - 统计 / 清理

    func size() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        return files.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 内部

    private func trimIfNeeded() {
        guard size() > limitBytes else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let oldestFirst = files.sorted { lhs, rhs in
            let a = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let b = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return a < b
        }

        var total = size()
        for file in oldestFirst where total > limitBytes {
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            try? FileManager.default.removeItem(at: file)
            total -= size
        }
    }

    private static func digest(_ text: String) -> String {
        let data = Data(text.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileExtension(for mime: String) -> String {
        let lower = mime.lowercased()
        if lower.contains("mpeg") || lower.contains("mp3") { return "mp3" }
        if lower.contains("mp4") || lower.contains("aac") || lower.contains("m4a") { return "m4a" }
        return ""
    }
}
