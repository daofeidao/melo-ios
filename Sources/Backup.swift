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

    /// 导出文件名：Melo-Backup-2026-11-10
    static func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Melo-Backup-" + formatter.string(from: Date())
    }

    static func restore(from url: URL) throws -> Summary {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(MeloBackup.self, from: data)

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
