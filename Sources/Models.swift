import Foundation

struct Track: Identifiable, Hashable, Codable {
    var videoId: String
    var title: String
    var artist: String
    var album: String?
    var duration: Int
    var artwork: String?
    /// 国内音源标记（netease / qq / kugou），与 sourceID 配合可直接取直链
    var source: String? = nil
    var sourceID: String? = nil
    /// 网易云的 VIP / 付费曲目：搜出来能看见，但外链大概率拿不到直链
    var isVip: Bool = false

    var id: String { videoId.isEmpty ? (source ?? "") + ":" + (sourceID ?? "") : videoId }

    /// 手写解码：新增字段要能读老数据（收藏、最近播放都存在 UserDefaults 里），
    /// 合成解码遇到缺字段会直接抛错，用户的收藏就整个没了。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try container.decodeIfPresent(String.self, forKey: .videoId) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try container.decodeIfPresent(String.self, forKey: .album)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration) ?? 0
        artwork = try container.decodeIfPresent(String.self, forKey: .artwork)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID)
        isVip = try container.decodeIfPresent(Bool.self, forKey: .isVip) ?? false
    }

    init(
        videoId: String,
        title: String,
        artist: String,
        album: String? = nil,
        duration: Int,
        artwork: String? = nil,
        source: String? = nil,
        sourceID: String? = nil,
        isVip: Bool = false
    ) {
        self.videoId = videoId
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artwork = artwork
        self.source = source
        self.sourceID = sourceID
        self.isVip = isVip
    }

    var durationText: String {
        guard duration > 0 else { return "--:--" }
        let h = duration / 3600
        let m = (duration % 3600) / 60
        let s = duration % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

struct MediaCollection: Identifiable, Hashable {
    var browseId: String
    var title: String
    var subtitle: String
    var artwork: String?
    var isRound: Bool

    var id: String { browseId }

    init(browseId: String, title: String, subtitle: String = "", artwork: String? = nil, isRound: Bool = false) {
        self.browseId = browseId
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
        self.isRound = isRound
    }
}

enum ShelfItem: Identifiable, Hashable {
    case track(Track)
    case collection(MediaCollection)

    var id: String {
        switch self {
        // 不能用 videoId：国内音源和本地音乐的 videoId 都是空串，
        // 所有卡片会共用同一个 id，SwiftUI 的 ForEach 只渲染第一条 —— 表现就是
        // 「我的收藏只显示一部分，还经常整片消失」。
        case .track(let t): return "t:" + t.id
        case .collection(let c): return "c:" + c.browseId
        }
    }

    var title: String {
        switch self {
        case .track(let t): return t.title
        case .collection(let c): return c.title
        }
    }

    var subtitle: String {
        switch self {
        case .track(let t): return t.artist
        case .collection(let c): return c.subtitle
        }
    }

    var artwork: String? {
        switch self {
        case .track(let t): return t.artwork
        case .collection(let c): return c.artwork
        }
    }

    var isRound: Bool {
        switch self {
        case .track: return false
        case .collection(let c): return c.isRound
        }
    }
}

struct Shelf: Identifiable {
    let id = UUID()
    var title: String
    var items: [ShelfItem]
}

struct SearchResults {
    /// 国内专辑 / 歌单，browseId 前缀分别是 netease:album: / netease:playlist:
    var domesticCollections: [MediaCollection] = []

    var tracks: [Track] = []
    var collections: [MediaCollection] = []
    /// 国内音源结果，已逐条验证可拉流，点开必定能播
    var domestic: [Track] = []
}

struct CollectionDetail {
    var title: String
    var subtitle: String
    var artwork: String?
    var tracks: [Track]
}

struct AudioStream: Codable {
    let url: URL
    let itag: Int
    let bitrate: Int
    let mime: String
}
