import SwiftUI

struct ChangelogEntry: Identifiable {
    let version: String
    let date: String
    let notes: [String]

    var id: String { version }
}

/// 版本更新细节。藏在「版本号连点 7 次」后面，平时不占地方。
enum Changelog {
    static var entries: [ChangelogEntry] {
        [
            ChangelogEntry(version: "1.16.3", date: "2026-11-10", notes: [
                L("Fixed YouTube playback: the blocked ANDROID_VR client identity was replaced with IOS and ANDROID."),
                L("Playback now sends the User-Agent matching the identity that resolved the stream, so audio CDN links no longer return 403."),
                L("The app remembers which YouTube identity works and switches automatically if it stops working.")
            ]),
            ChangelogEntry(version: "1.16.2", date: "2026-11-10", notes: [
                L("Kuwo Music added as a third playback source; a failed link now falls back across Kugou, NetEase and Kuwo."),
                L("NetEase gained a second direct-link API, so fewer songs fall through to a name search."),
                L("Chart lists are cached on disk for 6 hours. Reopening Charts no longer refetches them."),
                L("Kugou chart covers now load (the {size} cover template is resolved)."),
                L("Settings → About lists every data source and what it provides."),
                L("Tap the version number seven times to open this page.")
            ]),
            ChangelogEntry(version: "1.16.1", date: "2026-11-10", notes: [
                L("Kugou charts load in about a second (switched to mobilecdn)."),
                L("Search returns playlists and albums without waiting for YouTube."),
                L("Playback keeps the previous song only when it should.")
            ]),
            ChangelogEntry(version: "1.16.0", date: "2026-11-09", notes: [
                L("Domestic-first search: results in under a second, YouTube folded behind a button."),
                L("Startup no longer waits for an extra probe; three tracks are prefetched ahead."),
                L("Genres in the search empty state play domestic links directly.")
            ]),
            ChangelogEntry(version: "1.14.0", date: "2026-11-09", notes: [
                L("Favorites no longer collapse into a single card."),
                L("Library has a Local Music section; duplicate favorites and history were removed."),
                L("Backup and restore to Files, including iCloud Drive.")
            ])
        ]
    }
}

struct ChangelogView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(Changelog.entries) { entry in
                    Section {
                        ForEach(entry.notes, id: \.self) { note in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 5))
                                    .foregroundColor(Theme.accent)
                                    .padding(.top, 6)
                                Text(note)
                                    .font(.system(size: 13))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } header: {
                        HStack {
                            Text("v" + entry.version)
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Text(entry.date)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.secondaryLabel)
                        }
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle(L("What's New"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

/// 设置 → 关于 → 数据来源：把每个音源负责什么说清楚
struct DataSourcesView: View {
    private struct Row: Identifiable {
        let id = UUID()
        let name: String
        let role: String
        let detail: String
    }

    private var rows: [Row] {
        [
            Row(name: L("Kugou Music"), role: L("Charts · search · direct links"),
                detail: L("Highest hit rate. Chart lists come from mobilecdn.")),
            Row(name: L("NetEase Cloud Music"), role: L("Search · playlists · albums · lyrics"),
                detail: L("Two direct-link APIs. VIP tracks usually fail and fall back.")),
            Row(name: L("Kuwo Music"), role: L("Search · direct links"),
                detail: L("Third source, used when Kugou or NetEase has no playable link. No playlist API.")),
            Row(name: L("QQ Music"), role: L("Playlist import only"),
                detail: L("Streaming needs a logged-in key, so these tracks are matched by name.")),
            Row(name: L("YouTube Music"), role: L("Metadata · catalog"),
                detail: L("Only used when reachable; the app never blocks on it.")),
            Row(name: L("Local Files"), role: L("On-device playback"),
                detail: L("Imported audio in Local Music."))
        ]
    }

    var body: some View {
        List {
            Section {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name)
                            .font(.system(size: 15, weight: .semibold))
                        Text(row.role)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.accent)
                        Text(row.detail)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text(L("Data Sources"))
            } footer: {
                Text(L("Playback always prefers a direct domestic link. YouTube is never on the critical path."))
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("Data Sources"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
