import AVFoundation
import Foundation

/// 本地音乐：用户通过「文件」导入到 App 里的音频文件。
///
/// 走的是 `Documents/LocalMusic/`，和流媒体完全分开：
/// 这些歌没有 videoId，也没有平台 ID，播放时直接用 file URL 交给 AVPlayer。
final class LocalMusicStore: ObservableObject {

    static let shared = LocalMusicStore()

    /// 本地曲目统一用这个 source 标记，AudioSource 见到它就直接读文件
    static let sourceTag = "local"

    @Published private(set) var songs: [Track] = []

    private var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LocalMusic", isDirectory: true)
    }

    private init() {
        reload()
    }

    // MARK: - 读取

    func reload() {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let files = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "caf", "ogg", "opus"]
        songs = files
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .map { Self.makeTrack(url: $0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        fillDurations()
    }

    static func fileURL(for track: Track) -> URL? {
        guard track.source == sourceTag, let name = track.sourceID, !name.isEmpty else { return nil }
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("LocalMusic", isDirectory: true).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func makeTrack(url: URL) -> Track {
        // 文件名多为「艺人 - 歌名」，和导入歌单时的约定保持一致
        let base = url.deletingPathExtension().lastPathComponent
        var title = base
        var artist = L("Unknown Artist")

        let parts = base.components(separatedBy: " - ")
        if parts.count >= 2 {
            let head = parts[0].trimmingCharacters(in: .whitespaces)
            let tail = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            if !head.isEmpty, !tail.isEmpty {
                artist = head
                title = tail
            }
        }

        return Track(
            videoId: "",
            title: title,
            artist: artist,
            album: nil,
            duration: 0,
            artwork: nil,
            source: sourceTag,
            sourceID: url.lastPathComponent
        )
    }

    /// 时长要读 AVAsset，放到后台算，别卡住列表
    private func fillDurations() {
        let snapshot = songs
        guard !snapshot.isEmpty else { return }

        Task.detached(priority: .utility) {
            var updated: [Track] = []
            for var track in snapshot {
                if let url = LocalMusicStore.fileURL(for: track) {
                    let asset = AVURLAsset(url: url)
                    if let value = try? await asset.load(.duration), value.isNumeric {
                        track.duration = max(0, Int(value.seconds))
                    }
                }
                updated.append(track)
            }
            let result = updated
            await MainActor.run {
                // 扫描期间用户可能又导入/删除了文件，数量对不上就别覆盖
                if result.count == self.songs.count {
                    self.songs = result
                }
            }
        }
    }

    // MARK: - 导入 / 删除

    /// 返回成功导入的数量
    @discardableResult
    func importFiles(_ urls: [URL]) -> Int {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

        var imported = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            var name = url.lastPathComponent
            var target = directory.appendingPathComponent(name)
            var index = 2
            while manager.fileExists(atPath: target.path) {
                let base = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
                target = directory.appendingPathComponent(name)
                index += 1
            }

            do {
                try manager.copyItem(at: url, to: target)
                imported += 1
            } catch {
                NSLog("SMOKE_LOCAL import failed \(error.localizedDescription)")
            }
        }

        if imported > 0 { reload() }
        return imported
    }

    func delete(_ track: Track) {
        guard let url = Self.fileURL(for: track) else { return }
        try? FileManager.default.removeItem(at: url)
        reload()
    }
}
