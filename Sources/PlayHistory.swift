import Foundation

/// 一条播放历史：曲目 + 播放时间。
/// 同一首歌只保留最近一次，避免循环播放把清单刷满同一行。
struct PlayHistoryEntry: Codable, Identifiable {
    let track: Track
    let playedAt: Date
    var id: String { track.id }
}

/// 播放历史（播放器左下角那个入口）。
/// 和「最近播放」的区别：这里保留 200 条、带时间、按天分组，够回溯几天前听过什么；
/// `Library.recent` 只留 60 条，服务「现在就听」的横排卡片。
final class PlayHistory: ObservableObject {

    static let shared = PlayHistory()
    static let limit = 200

    @Published private(set) var entries: [PlayHistoryEntry] = []

    private let storageKey = "melo.playHistory"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([PlayHistoryEntry].self, from: data) else { return }
        entries = saved
    }

    func record(_ track: Track) {
        guard !track.title.isEmpty else { return }
        var list = entries.filter { $0.track.id != track.id }
        list.insert(PlayHistoryEntry(track: track, playedAt: Date()), at: 0)
        if list.count > Self.limit { list = Array(list.prefix(Self.limit)) }
        entries = list
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// 按天分组，最新的在前；同一天内保持播放顺序
    var groupedByDay: [(title: String, items: [PlayHistoryEntry])] {
        guard !entries.isEmpty else { return [] }
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [PlayHistoryEntry]] = [:]

        for entry in entries {
            let key: String
            if calendar.isDateInToday(entry.playedAt) {
                key = L("Today")
            } else if calendar.isDateInYesterday(entry.playedAt) {
                key = L("Yesterday")
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale.current
                formatter.setLocalizedDateFormatFromTemplate("MMMd")
                key = formatter.string(from: entry.playedAt)
            }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(entry)
        }

        return order.map { ($0, buckets[$0] ?? []) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
