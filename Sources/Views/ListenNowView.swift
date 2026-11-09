import SwiftUI

struct ListenNowView: View {
    @EnvironmentObject private var library: Library

    @State private var shelves: [Shelf] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if !library.recent.isEmpty {
                        CarouselSection(title: "最近播放", items: library.recent.map { .track($0) })
                    }
                    if !library.favorites.isEmpty {
                        CarouselSection(title: "我的收藏", items: library.favorites.map { .track($0) })
                    }
                    ForEach(shelves) { shelf in
                        CarouselSection(title: shelf.title, items: shelf.items)
                    }

                    if loading && shelves.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    }

                    if let error = error, shelves.isEmpty {
                        ErrorBanner(message: error) {
                            Task { await load() }
                        }
                    }

                    if !loading, error == nil, shelves.isEmpty, library.recent.isEmpty, library.favorites.isEmpty {
                        EmptyHint(
                            symbol: "play.circle",
                            title: "开始你的聆听",
                            message: "去「搜索」找一首歌，播放后这里会记录你的最近播放。"
                        )
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, Layout.contentBottomInset)
            }
            .navigationTitle("现在就听")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await load() }
            .task {
                if shelves.isEmpty { await load() }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func load() async {
        await MainActor.run {
            loading = true
            error = nil
        }
        do {
            let result = try await InnerTube.shared.home()
            await MainActor.run {
                shelves = result
                loading = false
            }
        } catch {
            await MainActor.run {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                loading = false
            }
        }
    }
}
