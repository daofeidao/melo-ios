import SwiftUI

/// 搜索页 → 按风格浏览：某个分类下的热门歌单（全部来自国内源）。
struct GenrePlaylistsView: View {
    let genre: PlaylistGenre

    @State private var items: [ExternalPlaylist] = []
    @State private var loading = true
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 148), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                } else if items.isEmpty {
                    ErrorBanner(message: error ?? L("Nothing here yet")) {
                        Task { await load() }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(items) { item in
                            NavigationLink(destination: RemotePlaylistView(
                                platform: item.platform,
                                playlistID: item.playlistID,
                                name: item.name,
                                cover: item.cover
                            )) {
                                card(item)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, Layout.contentBottomInset)
        }
        .navigationTitle(genre.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func card(_ item: ExternalPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: item.cover, size: 148, corner: 7)
                .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
            Text(item.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(height: 36, alignment: .top)
            Text(item.subtitle.isEmpty ? item.platform.label : item.subtitle)
                .font(.system(size: 12))
                .foregroundColor(Theme.secondaryLabel)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        await MainActor.run {
            loading = true
            error = nil
        }
        do {
            let list = try await (genre.keyword
                ? HotPlaylists.searchPlaylists(query: genre.cat)
                : HotPlaylists.fetch(.netease, cat: genre.cat))
            await MainActor.run {
                items = list
                loading = false
                error = nil
                if list.isEmpty { error = L("Nothing here yet") }
            }
        } catch {
            await MainActor.run {
                items = []
                loading = false
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
