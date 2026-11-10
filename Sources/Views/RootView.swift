import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlayerEngine

    @State private var selection = 0
    @State private var showSettings = false
    @State private var showWebProbe = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                ListenNowView()
                    .tabItem { Label(L("Listen Now"), systemImage: "play.circle.fill") }
                    .tag(0)

                ChartsView()
                    .tabItem { Label(L("Charts"), systemImage: "dot.radiowaves.left.and.right") }
                    .tag(1)

                LibraryView()
                    .tabItem { Label(L("Library"), systemImage: "music.note.list") }
                    .tag(2)

                SearchView()
                    .tabItem { Label(L("Search"), systemImage: "magnifyingglass") }
                    .tag(3)
            }
            // 冒烟测试专用入口：挂在 TabView 上，避免和播放页的 fullScreenCover 抢同一个宿主
            .fullScreenCover(isPresented: $showWebProbe) {
                NavigationView {
                    YouTubeWebProbeView(autoRun: true)
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }

            if player.hasTrack {
                MiniPlayerBar(showPlayer: $player.opensFullPlayer)
                    .padding(.horizontal, 8)
                    .padding(.bottom, Layout.tabBarHeight + 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .fullScreenCover(isPresented: $player.opensFullPlayer) {
            PlayerView()
        }
        .sheet(isPresented: $showSettings) {
            NavigationView {
                SettingsView()
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
        .onAppear {
            runSmokeTestIfNeeded()
            AudioSource.warmUp()
            // 进 App 就在后台把热门歌单的内容抓下来，点开排行榜卡片直接有列表。
            // 用 detached：解析几千首 JSON 不该占主线程。
            Task.detached(priority: .utility) {
                await ChartLibrary.shared.prefetchHot()
            }
        }
        .animation(.easeOut(duration: 0.22), value: player.hasTrack)
    }

    private func runSmokeTestIfNeeded() {
        // 各项冒烟动作互相独立，不能用 guard 提前返回
        if SmokeTest.opensYouTubeWebProbe {
            // 页面加载 + 等 player response，至少要 10 秒，这里只负责把页面弹出来
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                showWebProbe = true
            }
            return
        }
        if let tab = SmokeTest.initialTab {
            selection = tab
        }
        if SmokeTest.searchQuery != nil, SmokeTest.initialTab == nil {
            selection = 3
        }
        if SmokeTest.seedsPlaylist {
            PlaylistStore.shared.seedForSmokeTest()
        }
        if SmokeTest.seedsFavorites {
            Library.shared.seedFavoritesForSmokeTest()
        }
        if SmokeTest.seedsCollections {
            Library.shared.seedCollectionsForSmokeTest()
            NSLog("SMOKE_COLLECTIONS saved=\(Library.shared.savedCollections.count)")
        }
        if SmokeTest.runsBackupTest {
            runBackupRoundTrip()
        }
        if SmokeTest.checksChartCache {
            Task {
                let netease = ChartFeed.shared.cached(.netease)?.count ?? 0
                let qq = ChartFeed.shared.cached(.qq)?.count ?? 0
                let kugou = ChartFeed.shared.cached(.kugou)?.count ?? 0
                NSLog("SMOKE_CHART_CACHE netease=\(netease) qq=\(qq) kugou=\(kugou) fresh=\(ChartFeed.shared.isFresh)")
                let list = (try? await HotPlaylists.fetch(.kugou)) ?? []
                let usable = list.compactMap { $0.cover }.filter { !$0.contains("{size}") }.count
                NSLog("SMOKE_CHART_COVERS total=\(list.count) usable=\(usable)")
            }
        }
        if SmokeTest.runsKugouCheck {
            selection = 1
            Task {
                let list = (try? await HotPlaylists.fetch(.kugou)) ?? []
                var tracks = 0
                var firstName = "-"
                if let first = list.first {
                    firstName = first.name
                    let remote = try? await PlaylistFetcher.fetch(
                        platform: .kugou,
                        id: first.playlistID,
                        isRank: first.isRank
                    )
                    tracks = remote?.songs.count ?? 0
                }
                NSLog("SMOKE_KUGOU_CHART playlists=\(list.count) first=\(firstName) tracks=\(tracks)")
            }
            return
        }

        if let cat = SmokeTest.playGenre {
            selection = 3
            Task {
                guard let list = try? await HotPlaylists.fetch(.netease, cat: cat), let first = list.first else {
                    NSLog("SMOKE_GENRE cat=\(cat) playlists=0")
                    return
                }
                let remote = try? await PlaylistFetcher.fetch(platform: first.platform, id: first.playlistID)
                let tracks = PlaylistMatcher.direct(songs: remote?.songs ?? [])
                NSLog("SMOKE_GENRE cat=\(cat) playlists=\(list.count) tracks=\(tracks.count)")
                guard let track = tracks.first else { return }
                NSLog("SMOKE_GENRE first=\(track.title) source=\(track.source ?? "-") id=\(track.sourceID ?? "-")")
                await MainActor.run {
                    player.play(tracks: tracks, startAt: 0)
                }
            }
            return
        }

        if let songID = SmokeTest.neteaseSongID {
            Task {
                guard let track = await AudioSource.netEaseTrack(id: songID) else { return }
                await MainActor.run {
                    player.play(tracks: [track], startAt: 0)
                    if SmokeTest.presentsPlayer {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                            player.opensFullPlayer = true
                        }
                    }
                }
            }
            return
        }

        if let query = SmokeTest.playSearchQuery {
            Task {
                guard let tracks = try? await InnerTube.shared.searchSongs(query: query),
                      let first = tracks.first else { return }
                await MainActor.run {
                    player.play(tracks: [first], startAt: 0)
                    if SmokeTest.presentsPlayer {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                            player.opensFullPlayer = true
                        }
                    }
                }
            }
            return
        }

        if let videoId = SmokeTest.autoPlayVideoId {
            player.play(tracks: [SmokeTest.makeTrack(videoId: videoId)], startAt: 0)

            if SmokeTest.presentsPlayer {
                DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
                    player.opensFullPlayer = true
                }
            }
        }

        if SmokeTest.showsSettings {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                showSettings = true
            }
        }
        // 关于页的两个子页面：直接由根视图弹设置页，不依赖「先切到资料库 tab」。
        // 冒烟启动默认停在首页，走 LibraryView 的延迟 sheet 永远等不到。
        if SmokeTest.showsChangelog || SmokeTest.showsDataSources {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                showSettings = true
            }
        }
    }

    /// 备份往返：编码 → 写文件 → 解码 → 覆盖回内存，确认收藏/歌单没在 Codable 上丢东西
    private func runBackupRoundTrip() {
        Library.shared.toggleFavorite(SmokeTest.makeTrack(videoId: "backupProbe"))
        do {
            let data = try BackupService.encoded()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("melo-backup-probe.json")
            try data.write(to: url, options: .atomic)
            let summary = try BackupService.restore(from: url)
            NSLog("SMOKE_BACKUP ok bytes=\(data.count) favorites=\(summary.favorites) recent=\(summary.recent) playlists=\(summary.playlists)")
        } catch {
            NSLog("SMOKE_BACKUP failed \(error)")
        }
    }
}
