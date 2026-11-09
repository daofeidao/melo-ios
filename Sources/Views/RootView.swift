import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlayerEngine

    @State private var selection = 0
    @State private var showPlayer = false
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
                MiniPlayerBar(showPlayer: $showPlayer)
                    .padding(.horizontal, 8)
                    .padding(.bottom, Layout.tabBarHeight + 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerView()
        }
        .sheet(isPresented: $showSettings) {
            NavigationView {
                SettingsView()
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
        .onAppear(perform: runSmokeTestIfNeeded)
        .animation(.easeOut(duration: 0.22), value: player.hasTrack)
    }

    private func runSmokeTestIfNeeded() {
        guard let videoId = SmokeTest.autoPlayVideoId else { return }
        player.play(tracks: [SmokeTest.makeTrack(videoId: videoId)], startAt: 0)

        if SmokeTest.presentsPlayer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
                showPlayer = true
            }
        }

        if SmokeTest.showsSettings {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                showSettings = true
            }
        }
    }
}
