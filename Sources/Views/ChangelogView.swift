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
            ChangelogEntry(version: "1.16.11", date: "2026-11-12", notes: [
                L("Search now shows Hi·FLAC results first, with a source badge on every song."),
                L("A new Artists section with circular cards appears both on the search page and in search results, like Apple Music."),
                L("Artists you search for are saved automatically."),
                L("Tapping an artist opens a page with representative works, albums, top songs and a biography."),
                L("Album track lists are now complete: songs without a playable version stay in the list, greyed out, and are never replaced by a cover or live take.")
            ]),
            ChangelogEntry(version: "1.16.10", date: "2026-11-12", notes: [
                L("Hi·FLAC now checks title, artist and duration before accepting a match, so covers, live takes and DJ edits are no longer played as the original."),
                L("Hi·FLAC searches by song title only: adding the artist made the site return no results at all."),
                L("A stream found by name search is no longer written to the local audio cache."),
                L("Cached audio now records its source and quality. Turning a source off, switching sources or changing quality invalidates that file instead of replaying it."),
                L("Wrong cached files left by older versions are removed automatically on upgrade."),
                L("Playback errors now name the sources you turned off.")
            ]),
            ChangelogEntry(version: "1.16.9", date: "2026-11-12", notes: [
                L("Picking a source in the player now really switches the source: the previous stream is no longer reused from cache."),
                L("Turning a source off in Data Sources now takes effect immediately; picking a disabled source reports it instead of silently playing the old one."),
                L("Backup restore now works, and a backup exported on Android can be restored on iPhone (and the other way round)."),
                L("Importing a playlist now runs in the background with a progress bar, and long playlists load much faster."),
                L("Hi·FLAC is now tried first when resolving a song; other sources are used only when it has no match.")
            ]),
            ChangelogEntry(version: "1.16.7", date: "2026-11-12", notes: [
                L("Hi·FLAC added as a built-in source: it can serve 320 kbps and real FLAC lossless."),
                L("The source sheet no longer pushes its last rows off the screen."),
                L("Local files can now be played through an online source instead of the file on the device."),
                L("QQ Music sign-in opens the mobile login page instead of the desktop home page.")
            ]),
            ChangelogEntry(version: "1.16.4", date: "2026-11-11", notes: [
                L("Cached audio now lives in Local Music: every cached song can be browsed and deleted there."),
                L("Cached files are named title – artist_4min29s_ so the duration is readable at a glance."),
                L("Cache survives app restarts and is only removed when you clear it; when the limit is hit, the songs you have not played for the longest time go first."),
                L("The decorative quote icon at the bottom-left of the player is now Play History."),
                L("Settings gained strict matching: title, artist and duration (±5 s) must all agree, otherwise the song reports no source and offers to switch sources."),
                L("Data Sources can be toggled, signed in with a Cookie, or extended with your own resolve endpoint."),
                L("Connection diagnostics moved to About → Advanced Diagnostics.")
            ]),
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
                // 置顶：作者与项目地址（用户 2026-11-11 要求）
                Section {
                    HStack {
                        Text(L("Author"))
                        Spacer()
                        Text("张宏亮")
                            .foregroundColor(Theme.secondaryLabel)
                    }
                    Link(destination: URL(string: "https://github.com/daofeidao/melo-ios")!) {
                        HStack {
                            Text(L("Project"))
                            Spacer()
                            Text("github.com/daofeidao/melo-ios")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.accent)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text(L("About this build"))
                } footer: {
                    Text(L("A third-party client for personal study only."))
                }

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
