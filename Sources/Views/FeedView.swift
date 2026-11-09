import SwiftUI

struct FeedView: View {
    let title: String
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
                        EmptyHint(symbol: "square.stack", title: "暂无内容", message: "下拉刷新试试。")
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, Layout.contentBottomInset)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await load() }
            .task {
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
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                loading = false
                hasLoaded = true
            }
        }
    }
}

struct BrowseView: View {
    var body: some View {
        FeedView(title: "浏览") {
            try await InnerTube.shared.home()
        }
    }
}

struct ChartsView: View {
    var body: some View {
        FeedView(title: "排行榜") {
            try await InnerTube.shared.charts()
        }
    }
}
