import Foundation

final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var recent: [Track] = []
    @Published private(set) var favorites: [Track] = []

    private let recentKey = "melo.recent"
    private let favoritesKey = "melo.favorites"

    private init() {
        recent = Self.load(recentKey)
        favorites = Self.load(favoritesKey)
    }

    func addRecent(_ track: Track) {
        guard !track.title.isEmpty else { return }
        var list = recent.filter { $0.id != track.id }
        list.insert(track, at: 0)
        if list.count > 60 { list = Array(list.prefix(60)) }
        recent = list
        Self.save(list, recentKey)
    }

    func toggleFavorite(_ track: Track) {
        if let index = favorites.firstIndex(where: { $0.id == track.id }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(track, at: 0)
        }
        Self.save(favorites, favoritesKey)
    }

    func isFavorite(_ track: Track) -> Bool {
        favorites.contains { $0.id == track.id }
    }

    func clearRecent() {
        recent = []
        Self.save(recent, recentKey)
    }

    /// 仅供 CI 截图：混合 YouTube 与国内音源各三首（国内源 videoId 是空串，
    /// 正好用来验证列表 id 冲突有没有修好）
    func seedFavoritesForSmokeTest() {
        guard favorites.isEmpty else { return }
        let youtube = [
            Track(videoId: "dQw4w9WgXcQ", title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269,
                  artwork: "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg"),
            Track(videoId: "9bZkp7q19f0", title: "以父之名", artist: "周杰伦", album: "叶惠美", duration: 342,
                  artwork: "https://i.ytimg.com/vi/9bZkp7q19f0/mqdefault.jpg"),
            Track(videoId: "kJQP7kiw5Fk", title: "稻香", artist: "周杰伦", album: "魔杰座", duration: 223,
                  artwork: "https://i.ytimg.com/vi/kJQP7kiw5Fk/mqdefault.jpg")
        ]
        let domestic = [
            Track(videoId: "", title: "忘不掉的你", artist: "h3R3", album: nil, duration: 172,
                  artwork: nil, source: PlaylistPlatform.netease.rawValue, sourceID: "1851652156"),
            Track(videoId: "", title: "孤勇者", artist: "陈奕迅", album: nil, duration: 257,
                  artwork: nil, source: PlaylistPlatform.kugou.rawValue, sourceID: "A925B6F4818F1F73FFD6B7E146010046"),
            Track(videoId: "", title: "起风了", artist: "买辣椒也用券", album: nil, duration: 325,
                  artwork: nil, source: PlaylistPlatform.kugou.rawValue, sourceID: "DB3014A58B305E63F94ECBE4AA8C9AE1")
        ]
        favorites = youtube + domestic
        Self.save(favorites, favoritesKey)
    }

    /// 从备份恢复：整体替换，不做合并 —— 合并只会让"恢复"变得不可预期
    func replace(favorites newFavorites: [Track], recent newRecent: [Track]) {
        favorites = newFavorites
        recent = newRecent
        Self.save(favorites, favoritesKey)
        Self.save(recent, recentKey)
    }

    private static func load(_ key: String) -> [Track] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Track].self, from: data)) ?? []
    }

    private static func save(_ tracks: [Track], _ key: String) {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
