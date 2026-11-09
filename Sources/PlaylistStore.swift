import Foundation

struct ImportedPlaylist: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var platform: PlaylistPlatform
    var cover: String?
    var tracks: [Track]
    var totalCount: Int
    var sourceID: String
    var createdAt: Date

    var matchedText: String {
        String(format: L("Imported %d of %d songs"), tracks.count, totalCount)
    }
}

final class PlaylistStore: ObservableObject {
    static let shared = PlaylistStore()

    @Published private(set) var playlists: [ImportedPlaylist] = []

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?

    private init() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = directory.appendingPathComponent("playlists.json")
        load()
    }

    // MARK: - 读写

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        playlists = (try? decoder.decode([ImportedPlaylist].self, from: data)) ?? []
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = playlists
        let item = DispatchWorkItem { [fileURL] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
        saveWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    // MARK: - 变更

    /// 同一平台的同一歌单重复导入时覆盖，避免堆积
    func save(
        name: String,
        platform: PlaylistPlatform,
        cover: String?,
        tracks: [Track],
        totalCount: Int,
        sourceID: String
    ) {
        let record = ImportedPlaylist(
            id: UUID(),
            name: name.isEmpty ? platform.label : name,
            platform: platform,
            cover: cover,
            tracks: tracks,
            totalCount: totalCount,
            sourceID: sourceID,
            createdAt: Date()
        )

        if let index = playlists.firstIndex(where: { $0.platform == platform && $0.sourceID == sourceID }) {
            var updated = record
            updated.id = playlists[index].id
            playlists[index] = updated
        } else {
            playlists.insert(record, at: 0)
        }
        scheduleSave()
    }

    func delete(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        scheduleSave()
    }

    func delete(platform: PlaylistPlatform, sourceID: String) {
        playlists.removeAll { $0.platform == platform && $0.sourceID == sourceID }
        scheduleSave()
    }

    /// 仅供 CI 截图用：只写内存，不落盘
    func seedForSmokeTest() {
        guard playlists.isEmpty else { return }
        let tracks = [
            Track(videoId: "dQw4w9WgXcQ", title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269,
                  artwork: "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg"),
            Track(videoId: "dQw4w9WgXcQ", title: "以父之名", artist: "周杰伦", album: "叶惠美", duration: 342,
                  artwork: "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg")
        ]
        playlists = [
            ImportedPlaylist(
                id: UUID(),
                name: "通勤循环",
                platform: .netease,
                cover: "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg",
                tracks: tracks,
                totalCount: 32,
                sourceID: "smoke",
                createdAt: Date()
            )
        ]
    }
}
