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
                        CarouselSection(title: L("Recently Played"), items: library.recent.map { .track($0) })
                    }
                    if !library.favorites.isEmpty {
                        CarouselSection(title: L("My Favorites"), items: library.favorites.map { .track($0) })
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
                            title: L("Start listening"),
                            message: L("Search for a song and play it — your listening history will show up here.")
                        )
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, Layout.contentBottomInset)
            }
            .navigationTitle(L("Listen Now"))
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
