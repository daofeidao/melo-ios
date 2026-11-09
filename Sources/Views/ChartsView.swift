import SwiftUI

/// 排行榜：YouTube 榜单 + 各平台热门歌单（点卡片直接看歌曲列表）
struct ChartsView: View {
    @State private var ytShelves: [Shelf] = []
    @State private var external: [String: [ExternalPlaylist]] = [:]
    @State private var loading = true
    @State private var error: String?
    @State private var hasLoaded = false
    @State private var failures: [String: String] = [:]

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
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func platformSection(platform: PlaylistPlatform, items: [ExternalPlaylist]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionHeader(title: platform.label)
                if failures[platform.rawValue] != nil {
                    Text(L("Temporarily unavailable"))
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        NavigationLink(destination: ExternalPlaylistView(item: item)) {
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

        // 不用 async let：Swift 6 的 async-let 在父作用域提前退出时会 fatalError
        let ytJob = Task { try await InnerTube.shared.charts() }
        let neteaseJob = Task { try await HotPlaylists.fetch(.netease) }
        let qqJob = Task { try await HotPlaylists.fetch(.qq) }
        let kugouJob = Task { try await HotPlaylists.fetch(.kugou) }

        // 失败不再静默：哪个源挂了就在分区标题旁标出来，用户才不会以为是缺功能
        var failures: [String: String] = [:]

        let yt: [Shelf]
        do {
            yt = try await ytJob.value
        } catch {
            yt = []
            failures["youtube"] = describe(error)
        }

        let netease: [ExternalPlaylist]
        do {
            netease = try await neteaseJob.value
        } catch {
            netease = []
            failures[PlaylistPlatform.netease.rawValue] = describe(error)
        }

        let qq: [ExternalPlaylist]
        do {
            qq = try await qqJob.value
        } catch {
            qq = []
            failures[PlaylistPlatform.qq.rawValue] = describe(error)
        }

        let kugou: [ExternalPlaylist]
        do {
            kugou = try await kugouJob.value
        } catch {
            kugou = []
            failures[PlaylistPlatform.kugou.rawValue] = describe(error)
        }

        await MainActor.run {
            ytShelves = yt
            self.failures = failures
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
