import SwiftUI

private struct ImportRequest: Identifiable {
    let id = UUID()
    let url: String
}

/// 排行榜：YouTube 榜单 + 各平台热门歌单（点卡片直接进导入流程）
struct ChartsView: View {
    @State private var ytShelves: [Shelf] = []
    @State private var external: [String: [ExternalPlaylist]] = [:]
    @State private var loading = true
    @State private var error: String?
    @State private var hasLoaded = false
    @State private var importTarget: ImportRequest?

    private let platforms: [PlaylistPlatform] = [.netease, .qq, .kugou]

    private var hasExternal: Bool {
        external.values.contains { !$0.isEmpty }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(ytShelves) { shelf in
                        CarouselSection(title: shelf.title, items: shelf.items)
                    }

                    ForEach(platforms) { platform in
                        if let items = external[platform.rawValue], !items.isEmpty {
                            platformSection(platform: platform, items: items)
                        }
                    }

                    if loading && ytShelves.isEmpty && !hasExternal {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    }

                    if let error = error, ytShelves.isEmpty && !hasExternal {
                        ErrorBanner(message: error) {
                            Task { await load() }
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, Layout.contentBottomInset)
            }
            .navigationTitle(L("Charts"))
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await load() }
            .task {
                if !hasLoaded { await load() }
            }
            .sheet(item: $importTarget) { request in
                ImportPlaylistView(presetURL: request.url)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func platformSection(platform: PlaylistPlatform, items: [ExternalPlaylist]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                SectionHeader(title: platform.label)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        Button {
                            importTarget = ImportRequest(url: item.importURL)
                        } label: {
                            card(item)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            }
        }
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
            Text(item.subtitle)
                .font(.system(size: 12))
                .foregroundColor(Theme.secondaryLabel)
                .lineLimit(1)
                .frame(height: 15, alignment: .top)
        }
        .frame(width: 148, alignment: .leading)
    }

    private func load() async {
        await MainActor.run {
            loading = true
            error = nil
        }

        async let ytTask = InnerTube.shared.charts()
        async let neteaseTask = HotPlaylists.fetch(.netease)
        async let qqTask = HotPlaylists.fetch(.qq)
        async let kugouTask = HotPlaylists.fetch(.kugou)

        let yt = (try? await ytTask) ?? []
        let netease = (try? await neteaseTask) ?? []
        let qq = (try? await qqTask) ?? []
        let kugou = (try? await kugouTask) ?? []

        await MainActor.run {
            ytShelves = yt
            external = [
                PlaylistPlatform.netease.rawValue: netease,
                PlaylistPlatform.qq.rawValue: qq,
                PlaylistPlatform.kugou.rawValue: kugou
            ]
            loading = false
            hasLoaded = true
            if yt.isEmpty && netease.isEmpty && qq.isEmpty && kugou.isEmpty {
                error = L("No content was returned. Check that your proxy also covers music.youtube.com, then retry.")
            }
        }
    }
}
