import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 备份文件结构。字段全部是可选的解码后备（老备份也能读进来），
/// 但新增字段时要把 formatVersion 往上加，避免以后读错。
struct MeloBackup: Codable {
    var formatVersion: Int
    var exportedAt: Date
    var favorites: [Track]
    var recent: [Track]
    var playlists: [ImportedPlaylist]
    /// 搜索结果里收藏的歌单 / 专辑。老备份没有这个字段，解码时按空数组处理
    var collections: [MediaCollection]

    private enum CodingKeys: String, CodingKey {
        case formatVersion, exportedAt, favorites, recent, playlists, collections
    }

    init(formatVersion: Int, exportedAt: Date, favorites: [Track], recent: [Track],
         playlists: [ImportedPlaylist], collections: [MediaCollection]) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.favorites = favorites
        self.recent = recent
        self.playlists = playlists
        self.collections = collections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = (try? container.decode(Int.self, forKey: .formatVersion)) ?? 1
        exportedAt = (try? container.decode(Date.self, forKey: .exportedAt)) ?? Date()
        favorites = (try? container.decode([Track].self, forKey: .favorites)) ?? []
        recent = (try? container.decode([Track].self, forKey: .recent)) ?? []
        playlists = (try? container.decode([ImportedPlaylist].self, forKey: .playlists)) ?? []
        collections = (try? container.decode([MediaCollection].self, forKey: .collections)) ?? []
    }

    /// 写了自定义 init(from:) 之后显式补上编码，避免依赖编译器合成行为
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(exportedAt, forKey: .exportedAt)
        try container.encode(favorites, forKey: .favorites)
        try container.encode(recent, forKey: .recent)
        try container.encode(playlists, forKey: .playlists)
        try container.encode(collections, forKey: .collections)
    }
}

/// 本地备份 / 恢复。
///
/// 为什么不做 iCloud 自动同步：CloudKit / NSUbiquitousKeyValueStore 都要求
/// App 绑一个真实的 Apple 开发者 Team，并在 Apple 侧注册 iCloud 容器。
/// 这个包是 ldid 假签名的，没有那个身份，硬塞 entitlement 也只会一直同步失败。
///
/// 能做的是「导出成文件 → 存到「文件」App（可放 iCloud Drive）→ 重装后导入」。
/// 这条路不需要任何 entitlement，卸载 App 也不会连「文件」里的备份一起删。
enum BackupService {

    /// v2：新增 collections（搜索结果收藏的歌单 / 专辑）
    static let currentFormatVersion = 2

    struct Summary {
        var favorites: Int
        var recent: Int
        var playlists: Int

        var text: String {
            String(format: L("Restored %d favorites, %d recently played and %d playlists."),
                   favorites, recent, playlists)
        }
    }

    static func snapshot() -> MeloBackup {
        MeloBackup(
            formatVersion: currentFormatVersion,
            exportedAt: Date(),
            favorites: Library.shared.favorites,
            recent: Library.shared.recent,
            playlists: PlaylistStore.shared.playlists,
            collections: Library.shared.savedCollections
        )
    }

    static func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot())
    }

    /// 导出文件名：Melo-Backup-2026-11-12.json
    ///
    /// 必须带 .json 后缀：SwiftUI 不会替我们补扩展名，文件没有扩展名时
    /// 「文件」App 会把它当未知类型，恢复时在文件选择器里是灰的，根本选不中。
    static func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Melo-Backup-" + formatter.string(from: Date()) + ".json"
    }

    static func restore(from url: URL) throws -> Summary {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let backup = try decode(data)

        // 一个都没解出来时不要装作成功：多半是选错了文件或格式被改过
        if backup.favorites.isEmpty && backup.recent.isEmpty
            && backup.playlists.isEmpty && backup.collections.isEmpty {
            throw BackupError.unreadable
        }

        Library.shared.replace(
            favorites: backup.favorites,
            recent: backup.recent,
            collections: backup.collections
        )
        PlaylistStore.shared.replaceAll(backup.playlists)

        return Summary(
            favorites: backup.favorites.count,
            recent: backup.recent.count,
            playlists: backup.playlists.count
        )
    }

    enum BackupError: LocalizedError {
        case unreadable

        var errorDescription: String? {
            L("This file does not look like a Melo backup.")
        }
    }

    /// 解码：优先 ISO8601（现在的导出格式），失败再用默认策略兜一次
    /// （老版本或别处导出的文件里，日期可能是秒数）。
    private static func decode(_ data: Data) throws -> MeloBackup {
        // Android 版备份的字段名和这边不完全一样，先转换一遍
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let patched = normalizeAndroidFields(object)
            if let patchedData = try? JSONSerialization.data(withJSONObject: patched) {
                let iso = JSONDecoder()
                iso.dateDecodingStrategy = .iso8601
                if let backup = try? iso.decode(MeloBackup.self, from: patchedData) {
                    return backup
                }
                let plain = JSONDecoder()
                plain.dateDecodingStrategy = .deferredToDate
                return try plain.decode(MeloBackup.self, from: patchedData)
            }
        }

        let iso = JSONDecoder()
        iso.dateDecodingStrategy = .iso8601
        if let backup = try? iso.decode(MeloBackup.self, from: data) {
            return backup
        }
        let plain = JSONDecoder()
        plain.dateDecodingStrategy = .deferredToDate
        return try plain.decode(MeloBackup.self, from: data)
    }

    /// Android 版备份 → 这边的字段名：
    /// - 平台 id 写作 `sourceId`（这边是 `sourceID`）
    /// - 曲目没有 `videoId`，只有算出来的 `id`（形如 "netease:123"）
    /// - 歌单没有 `id`（UUID）和 `createdAt`
    private static func normalizeAndroidFields(_ root: [String: Any]) -> [String: Any] {
        var root = root
        if let favorites = root["favorites"] as? [[String: Any]] {
            root["favorites"] = favorites.map(normalizeTrack)
        }
        if let recent = root["recent"] as? [[String: Any]] {
            root["recent"] = recent.map(normalizeTrack)
        }
        if let playlists = root["playlists"] as? [[String: Any]] {
            root["playlists"] = playlists.map { item -> [String: Any] in
                var item = item
                if let sid = item["sourceId"] as? String, item["sourceID"] == nil {
                    item["sourceID"] = sid
                }
                if item["id"] == nil {
                    item["id"] = UUID().uuidString
                }
                if item["createdAt"] == nil {
                    item["createdAt"] = ISO8601DateFormatter().string(from: Date())
                }
                if let tracks = item["tracks"] as? [[String: Any]] {
                    item["tracks"] = tracks.map(normalizeTrack)
                }
                return item
            }
        }
        return root
    }

    private static func normalizeTrack(_ item: [String: Any]) -> [String: Any] {
        var item = item
        if let sid = item["sourceId"] as? String, item["sourceID"] == nil {
            item["sourceID"] = sid
        }
        let videoId = (item["videoId"] as? String) ?? ""
        if videoId.isEmpty, let rawID = item["id"] as? String, !rawID.isEmpty {
            let parts = rawID.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                if item["source"] == nil { item["source"] = parts[0] }
                if item["sourceID"] == nil { item["sourceID"] = parts[1] }
            } else {
                item["videoId"] = rawID
            }
        }
        return item
    }
}

/// 给 SwiftUI 的 fileExporter 用
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
