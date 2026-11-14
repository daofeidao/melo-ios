import Foundation

final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var recent: [Track] = []
    @Published private(set) var favorites: [Track] = []
    /// 搜索结果里收藏的歌单 / 专辑，出现在「现在就听」
    @Published private(set) var savedCollections: [MediaCollection] = []
    /// 喜欢艺人：只存名字，头像与歌曲点开时实时拉；长按可移除
    @Published private(set) var likedArtists: [String] = []

    private let recentKey = "melo.recent"
    private let favoritesKey = "melo.favorites"
    private let savedCollectionsKey = "melo.savedCollections"
    private let likedArtistsKey = "melo.likedArtists"
    private let didSeedKey = "melo.didSeedDefaults"

    private init() {
        recent = Self.load(recentKey)
        favorites = Self.load(favoritesKey)
        savedCollections = Self.loadCollections(savedCollectionsKey)
        let savedArtists = UserDefaults.standard.stringArray(forKey: likedArtistsKey)
        likedArtists = savedArtists ?? Self.defaultLikedArtists
        seedDefaultsIfNeeded()
    }

    /** 首次启动的喜欢艺人种子 */
    private static let defaultLikedArtists = ["周杰伦", "周传雄", "林俊杰", "张学友"]

    /**
     * 首次启动种入真实内容：收藏三首经典曲 + 喜欢艺人四位。
     * 首页四个分区因此「开箱即有内容」，不用等用户先收藏。
     * 种子就是普通收藏，长按即可移除；打了 didSeed 标记，移除后不会再长回来。
     */
    private func seedDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didSeedKey) else { return }
        if favorites.isEmpty && recent.isEmpty && savedCollections.isEmpty {
            favorites = Self.defaultSeedTracks
            Self.save(favorites, favoritesKey)
        }
        saveLikedArtists()
        defaults.set(true, forKey: didSeedKey)
    }

    /** 种子歌曲：周杰伦《太阳之子》按强制规则走歌曲宝（兼当歌曲宝健康探针），
     *  青花 / 黄昏 用网易云官方曲库精确 id 直链，不靠歌名猜版本 */
    private static let defaultSeedTracks: [Track] = [
        Track(
            videoId: "", title: "太阳之子", artist: "周杰伦", album: "太阳之子", duration: 0
        ),
        Track(
            videoId: "", title: "青花", artist: "周传雄",
            album: "蓝色土耳其", duration: 298,
            artwork: "https://p2.music.126.net/prDyYpF9EsrLA4O13Tf5hw==/109951169874952327.jpg",
            source: "netease", sourceID: "189602"
        ),
        Track(
            videoId: "", title: "黄昏", artist: "周传雄",
            album: "Transfer", duration: 344,
            artwork: "https://p2.music.126.net/mFM2Ii6Kxktb_87b4q3TYQ==/109951167366664357.jpg",
            source: "netease", sourceID: "190072"
        ),
    ]

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

    /// 首页最近播放单条移除（长按）
    func removeRecent(_ track: Track) {
        recent.removeAll { $0.id == track.id }
        Self.save(recent, recentKey)
    }

    // MARK: - 喜欢艺人

    func isLikedArtist(_ name: String) -> Bool {
        likedArtists.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func toggleLikedArtist(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = likedArtists.firstIndex(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            likedArtists.remove(at: index)
        } else {
            likedArtists.insert(clean, at: 0)
        }
        saveLikedArtists()
    }

    func removeLikedArtist(_ name: String) {
        likedArtists.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        saveLikedArtists()
    }

    private func saveLikedArtists() {
        UserDefaults.standard.set(likedArtists, forKey: likedArtistsKey)
    }

    // MARK: - 歌单 / 专辑收藏

    func toggleSavedCollection(_ collection: MediaCollection) {
        if let index = savedCollections.firstIndex(where: { $0.browseId == collection.browseId }) {
            savedCollections.remove(at: index)
        } else {
            savedCollections.insert(collection, at: 0)
        }
        Self.saveCollections(savedCollections, savedCollectionsKey)
    }

    func isSavedCollection(_ collection: MediaCollection) -> Bool {
        savedCollections.contains { $0.browseId == collection.browseId }
    }

    /// 仅供 CI 截图：验证「现在就听」会渲染收藏的歌单 / 专辑
    func seedCollectionsForSmokeTest() {
        guard savedCollections.isEmpty else { return }
        savedCollections = [
            MediaCollection(browseId: "netease:playlist:3778678", title: "云村热歌榜",
                            subtitle: "网易云音乐", artwork: nil),
            MediaCollection(browseId: "netease:album:32311", title: "叶惠美",
                            subtitle: "周杰伦", artwork: nil)
        ]
        Self.saveCollections(savedCollections, savedCollectionsKey)
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
    func replace(favorites newFavorites: [Track], recent newRecent: [Track],
                 collections newCollections: [MediaCollection]) {
        favorites = newFavorites
        recent = newRecent
        savedCollections = newCollections
        Self.save(favorites, favoritesKey)
        Self.save(recent, recentKey)
        Self.saveCollections(savedCollections, savedCollectionsKey)
    }

    private static func load(_ key: String) -> [Track] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Track].self, from: data)) ?? []
    }

    private static func save(_ tracks: [Track], _ key: String) {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func loadCollections(_ key: String) -> [MediaCollection] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([MediaCollection].self, from: data)) ?? []
    }

    private static func saveCollections(_ list: [MediaCollection], _ key: String) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
