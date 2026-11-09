import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlayerEngine

    @State private var selection = 0
    @State private var showPlayer = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                ListenNowView()
                    .tabItem { Label("现在就听", systemImage: "play.circle.fill") }
                    .tag(0)

                BrowseView()
                    .tabItem { Label("浏览", systemImage: "square.grid.2x2.fill") }
                    .tag(1)

                ChartsView()
                    .tabItem { Label("排行榜", systemImage: "dot.radiowaves.left.and.right") }
                    .tag(2)

                LibraryView()
                    .tabItem { Label("资料库", systemImage: "music.note.list") }
                    .tag(3)

                SearchView()
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }
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
    }
}
