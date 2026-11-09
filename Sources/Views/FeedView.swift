import SwiftUI

struct FeedView: View {
    let title: String
    var cacheKey: String? = nil
    let loader: () async throws -> [Shelf]

    @State private var shelves: [Shelf] = []
    @State private var loading = false
    @State private var error: String?
    @State private var hasLoaded = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
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

                    if !loading, error == nil, hasLoaded, shelves.isEmpty {
                        EmptyHint(symbol: "square.stack", title: L("Nothing here yet"), message: L("Pull to refresh and try again."))
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, Layout.contentBottomInset)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await load() }
            .task {
                if !hasLoaded, shelves.isEmpty, let key = cacheKey,
                   let cached = InnerTube.shared.cachedShelves(key: key) {
                    shelves = cached
                }
                if !hasLoaded { await load() }
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
            let result = try await loader()
            await MainActor.run {
                shelves = result
                loading = false
                hasLoaded = true
            }
        } catch {
            await MainActor.run {
                if shelves.isEmpty {
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                loading = false
                hasLoaded = true
            }
        }
    }
}

struct BrowseView: View {
    var body: some View {
        FeedView(title: L("Browse"), cacheKey: "browse_FEmusic_home") {
            try await InnerTube.shared.home()
        }
    }
}

struct ChartsView: View {
    var body: some View {
        FeedView(title: L("Charts"), cacheKey: "browse_FEmusic_charts") {
            try await InnerTube.shared.charts()
        }
    }
}
