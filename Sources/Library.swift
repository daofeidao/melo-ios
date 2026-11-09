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
        var list = recent.filter { $0.videoId != track.videoId }
        list.insert(track, at: 0)
        if list.count > 60 { list = Array(list.prefix(60)) }
        recent = list
        Self.save(list, recentKey)
    }

    func toggleFavorite(_ track: Track) {
        if let index = favorites.firstIndex(where: { $0.videoId == track.videoId }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(track, at: 0)
        }
        Self.save(favorites, favoritesKey)
    }

    func isFavorite(_ track: Track) -> Bool {
        favorites.contains { $0.videoId == track.videoId }
    }

    func clearRecent() {
        recent = []
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
