import Foundation

struct Track: Identifiable, Hashable, Codable {
    var videoId: String
    var title: String
    var artist: String
    var album: String?
    var duration: Int
    var artwork: String?

    var id: String { videoId }

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
        case .track(let t): return "t:" + t.videoId
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
    var tracks: [Track] = []
    var collections: [MediaCollection] = []
}

struct CollectionDetail {
    var title: String
    var subtitle: String
    var artwork: String?
    var tracks: [Track]
}

struct AudioStream {
    let url: URL
    let itag: Int
    let bitrate: Int
    let mime: String
}
