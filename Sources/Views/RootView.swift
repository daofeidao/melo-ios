import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlayerEngine

    @State private var selection = 0
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                ListenNowView()
                    .tabItem { Label(L("Listen Now"), systemImage: "play.circle.fill") }
                    .tag(0)

                BrowseView()
                    .tabItem { Label(L("Browse"), systemImage: "square.grid.2x2.fill") }
                    .tag(1)

                ChartsView()
                    .tabItem { Label(L("Charts"), systemImage: "dot.radiowaves.left.and.right") }
                    .tag(2)

                LibraryView()
                    .tabItem { Label(L("Library"), systemImage: "music.note.list") }
                    .tag(3)

                SearchView()
                    .tabItem { Label(L("Search"), systemImage: "magnifyingglass") }
                    .tag(4)
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
            // 进 App 就在后台把热门歌单的内容抓下来，点开排行榜卡片直接有列表
            Task { await ChartLibrary.shared.prefetchHot() }
        }
        .animation(.easeOut(duration: 0.22), value: player.hasTrack)
    }

    private func runSmokeTestIfNeeded() {
        // 各项冒烟动作互相独立，不能用 guard 提前返回
        if let tab = SmokeTest.initialTab {
            selection = tab
        }
        if SmokeTest.searchQuery != nil, SmokeTest.initialTab == nil {
            selection = 4
        }
        if SmokeTest.seedsPlaylist {
            PlaylistStore.shared.seedForSmokeTest()
        }
        if SmokeTest.runsBackupTest {
            runBackupRoundTrip()
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
