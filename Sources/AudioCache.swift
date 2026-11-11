import Foundation
import CryptoKit

/// 音频本体缓存：播过的曲目落一份到本地，二次播放不再联网。
///
/// 2026-11-11 按用户要求改成「缓存即本地音乐」：
/// - 文件直接写进 `Documents/LocalMusic/`，文件名是「艺人 - 歌名」，
///   于是落盘后自动出现在「本地音乐」里，可以查看、可以单首删除。
/// - 隐藏索引 `.cache-index.json` 记哪些文件是缓存、各自的最近播放时间，
///   设置页的「清除缓存」只删索引里的文件，不会误伤用户自己导入的音乐。
///
/// 两条硬约束：
/// 1. **只有手动清理才删**（目录在 Documents，不是会被系统回收的 Caches）。
/// 2. **满了先删最久没播的**，不是最早缓存的：淘汰严格按 `lastPlayed` 升序。
final class AudioCache {

    static let shared = AudioCache()

    static let enabledKey = "melo.cacheAudio"
    static let limitKey = "melo.audioCacheLimitMB"
    static let defaultLimitMB = 1024

    private struct Entry: Codable {
        let file: String
        let trackID: String
        let size: Int64
        /// 最近一次播放（命中或落盘）时间 —— LRU 的唯一依据
        var lastPlayed: Date
    }

    private let lock = NSLock()
    private var index: [String: Entry]?
    private var inFlight = Set<String>()
    private let io = DispatchQueue(label: "melo.audio-cache", qos: .utility)

    /// 允许范围 200 MB ~ 5 GB
    var limitBytes: Int64 {
        let stored = UserDefaults.standard.object(forKey: Self.limitKey) as? Int
        let mb = min(5120, max(200, stored ?? Self.defaultLimitMB))
        return Int64(mb) * 1024 * 1024
    }

    private var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LocalMusic", isDirectory: true)
    }

    private var indexURL: URL { directory.appendingPathComponent(Self.indexName) }

    /// 隐藏文件：LocalMusicStore 扫描时跳过了隐藏项，不会把索引当成一首歌
    private static let indexName = ".cache-index.json"

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    // MARK: - 查询

    func cachedURL(for track: Track) -> URL? {
        let key = Self.digest(track.id)
        lock.lock()
        defer { lock.unlock() }
        ensureReadyLocked()

        guard var entry = index?[key] else { return nil }
        let url = directory.appendingPathComponent(entry.file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // 用户在「本地音乐」里删掉了这首歌，索引也要跟着清
            index?.removeValue(forKey: key)
            saveIndexLocked()
            return nil
        }
        entry.lastPlayed = Date()
        index?[key] = entry
        saveIndexLocked()
        return url
    }

    /// 该文件是否由缓存产生（本地音乐页可以据此标一下）
    func isCached(fileName: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        ensureReadyLocked()
        return index?.values.contains { $0.file == fileName } ?? false
    }

    /// 用户在「本地音乐」里删掉了这首歌：把索引里的记录一并剔除，否则占用统计会虚高
    func forget(fileName: String) {
        lock.lock()
        defer { lock.unlock() }
        ensureReadyLocked()
        // 先快照 key：直接遍历 index.keys 再删会踩到「遍历中修改」
        let keys = (index ?? [:]).filter { $0.value.file == fileName }.map { $0.key }
        guard !keys.isEmpty else { return }
        keys.forEach { index?.removeValue(forKey: $0) }
        saveIndexLocked()
    }

    // MARK: - 下载

    func store(from remote: URL, for track: Track, mime: String, userAgent: String?) {
        guard isEnabled, !remote.isFileURL else { return }

        let ext = Self.fileExtension(for: mime)
        guard !ext.isEmpty else { return }
        if cachedURL(for: track) != nil { return }

        let key = Self.digest(track.id)
        lock.lock()
        guard !inFlight.contains(key) else {
            lock.unlock()
            return
        }
        inFlight.insert(key)
        let fileName = availableName(for: track, ext: ext)
        lock.unlock()

        let target = directory.appendingPathComponent(fileName)
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
                try FileManager.default.createDirectory(
                    at: self.directory,
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: temp, to: target)

                self.lock.lock()
                self.ensureReadyLocked()
                self.index?[key] = Entry(
                    file: fileName,
                    trackID: track.id,
                    size: size,
                    lastPlayed: Date()
                )
                self.saveIndexLocked()
                self.lock.unlock()

                self.trimIfNeeded()
                DispatchQueue.main.async { LocalMusicStore.shared.reload() }
            } catch {
                try? FileManager.default.removeItem(at: temp)
            }
        }.resume()
    }

    // MARK: - 统计 / 清理

    func size() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        ensureReadyLocked()
        return (index ?? [:]).values.reduce(Int64(0)) { $0 + $1.size }
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        ensureReadyLocked()
        return (index ?? [:]).count
    }

    /// 手动清理：只删缓存文件，用户自己导入的音乐不动
    func clear() {
        lock.lock()
        let files = (index ?? [:]).values.map { directory.appendingPathComponent($0.file) }
        index = [:]
        saveIndexLocked()
        lock.unlock()

        files.forEach { try? FileManager.default.removeItem(at: $0) }
        DispatchQueue.main.async { LocalMusicStore.shared.reload() }
    }

    func enforceLimit() {
        io.async { [weak self] in
            self?.trimIfNeeded()
        }
    }

    // MARK: - 内部

    /// 超过上限时按「最久没播放」删，直到回到上限以内。
    /// 排序依据是 `lastPlayed`，与文件写入时间无关：天天在听的会留下，
    /// 三个月前缓存却一直没听的会先走。
    private func trimIfNeeded() {
        lock.lock()
        ensureReadyLocked()
        guard var entries = index else {
            lock.unlock()
            return
        }
        var total = entries.values.reduce(Int64(0)) { $0 + $1.size }
        guard total > limitBytes else {
            lock.unlock()
            return
        }

        let oldestFirst = entries.sorted { $0.value.lastPlayed < $1.value.lastPlayed }
        let dir = directory
        var removed = 0
        for (key, entry) in oldestFirst where total > limitBytes {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(entry.file))
            entries.removeValue(forKey: key)
            total -= entry.size
            removed += 1
        }
        index = entries
        saveIndexLocked()
        lock.unlock()

        if removed > 0 {
            print("[MeloCache] evicted \(removed) least-recently-played files")
            DispatchQueue.main.async { LocalMusicStore.shared.reload() }
        }
    }

    /// 缓存文件名按用户要求的格式：`歌名 - 音乐家_5min3s_.m4a`。
    /// 时长用 `_XminYs_` 标记，本地音乐解析文件名时能直接还原时长。
    private func availableName(for track: Track, ext: String) -> String {
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titlePart = title.isEmpty ? Self.digest(track.id) : title
        let artistPart = (artist.isEmpty || artist == L("Unknown Artist")) ? L("Unknown Artist") : artist
        let seconds = max(0, track.duration)
        let stamp = "_\(seconds / 60)min\(seconds % 60)s_"
        let base = "\(titlePart) - \(artistPart)\(stamp)"
        let safe = Self.sanitize(base)
        var candidate = "\(safe).\(ext)"
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(safe) (\(counter)).\(ext)"
            counter += 1
        }
        return candidate
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "audio" : String(cleaned.prefix(100))
    }

    private func ensureReadyLocked() {
        guard index == nil else { return }

        var loaded: [String: Entry] = [:]
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            loaded = decoded
        }
        index = loaded

        // 旧版本把缓存放在 Caches/Audio，文件是 hash 名、不在本地音乐里，
        // 留着只会白占空间，这里一次性清掉
        let legacy = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audio", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    private func saveIndexLocked() {
        guard let snapshot = index else { return }
        let target = indexURL
        let dir = directory
        io.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: target, options: .atomic)
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
