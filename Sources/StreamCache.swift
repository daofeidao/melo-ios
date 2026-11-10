import Foundation

/// 播放直链缓存：内存 + 落盘。
///
/// 为什么需要它：一次完整解析要经历「YouTube player 请求 → 选流 → CDN 首字节」，
/// 弱网下就是 1~3 秒的空白。缓存命中后这段直接跳过，切歌基本无感。
///
/// TTL 取 30 分钟：YouTube 直链本身约 6 小时过期，但 CDN 节点和签名会漂移，
/// 缓存太久的直链反而容易失败，命中后播不出比不命中更难受。
final class StreamCache {

    static let shared = StreamCache()

    private struct Entry: Codable {
        let url: String
        let itag: Int
        let bitrate: Int
        let mime: String
        let userAgent: String?
        let savedAt: Date
    }

    // 6 小时：YouTube 直链本身大约 6 小时过期，国内直链活得更久。
    // 过期后如果播不出来，PlayerEngine 会清掉这条缓存重新解析。
    private let ttl: TimeInterval = 6 * 3600
    private let lock = NSLock()
    private var memory: [String: Entry] = [:]
    private var primed = false
    private let io = DispatchQueue(label: "melo.stream-cache", qos: .utility)

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("streams.json")
    }

    func stream(forKey key: String) -> AudioStream? {
        lock.lock()
        primeIfNeeded()
        defer { lock.unlock() }

        guard let entry = memory[key] else { return nil }
        guard Date().timeIntervalSince(entry.savedAt) < ttl, let url = URL(string: entry.url) else {
            memory.removeValue(forKey: key)
            return nil
        }
        return AudioStream(url: url, itag: entry.itag, bitrate: entry.bitrate,
                           mime: entry.mime, userAgent: entry.userAgent)
    }

    func store(_ stream: AudioStream, forKey key: String) {
        lock.lock()
        primeIfNeeded()
        memory[key] = Entry(
            url: stream.url.absoluteString,
            itag: stream.itag,
            bitrate: stream.bitrate,
            mime: stream.mime,
            userAgent: stream.userAgent,
            savedAt: Date()
        )
        let snapshot = memory
        lock.unlock()

        let target = fileURL
        io.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: target, options: .atomic)
        }
    }

    func remove(forKey key: String) {
        lock.lock()
        primeIfNeeded()
        memory.removeValue(forKey: key)
        let snapshot = memory
        lock.unlock()

        let target = fileURL
        io.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: target, options: .atomic)
        }
    }

    /// 落盘的直链在冷启动时直接可用，省掉第一首歌的解析等待
    private func primeIfNeeded() {
        guard !primed else { return }
        primed = true

        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }

        let now = Date()
        memory = stored.filter { now.timeIntervalSince($0.value.savedAt) < ttl }
    }
}
