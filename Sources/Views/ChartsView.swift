import SwiftUI

/// 排行榜：YouTube 榜单 + 各平台热门歌单（点卡片直接看歌曲列表）
struct ChartsView: View {
    @State private var ytShelves: [Shelf] = []
    @State private var external: [String: [ExternalPlaylist]] = [:]
    @State private var loading = true
    @State private var error: String?
    @State private var hasLoaded = false
    @State private var failures: [String: String] = [:]
    private let feed = ChartFeed.shared

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
                        } else if failures[platform.rawValue] != nil {
                            // 抓失败时也要留一块位置，不然用户以为这个源根本没做
                            unavailableSection(platform)
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
            .refreshable { await load(force: true) }
            .task {
                if !hasLoaded { await load() }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func unavailableSection(_ platform: PlaylistPlatform) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SectionHeader(title: platform.label)
                Text(L("Temporarily unavailable"))
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
            Text(failures[platform.rawValue] ?? "")
                .font(.system(size: 12))
                .foregroundColor(Theme.secondaryLabel)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
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

    private func load(force: Bool = false) async {
        // 先用本地缓存铺满：切回 tab 时立刻有内容，不闪白
        var seeded = false
        for platform in platforms {
            if let cached = feed.cached(platform) {
                external[platform.rawValue] = cached
                seeded = true
            }
        }
        if ytShelves.isEmpty { ytShelves = feed.cachedShelves() }

        let listsFresh = seeded && feed.isFresh && !force
        let ytFresh = feed.shelvesReady && !force

        // 两层都热：一次网络请求都不发。这是「每次进排行榜都要重新刷新」的根治点。
        if listsFresh && ytFresh {
            await MainActor.run {
                loading = false
                hasLoaded = true
                error = nil
            }
            return
        }

        await MainActor.run {
            loading = true
            if !seeded { error = nil }
        }

        // 不用 async let：Swift 6 的 async-let 在父作用域提前退出时会 fatalError。
        // 哪一层还新鲜就根本不创建那一层的 Task，省请求也省流量。
        let ytJob: Task<[Shelf], Error>? = ytFresh
            ? nil
            : Task { try await InnerTube.shared.charts() }
        let neteaseJob: Task<[ExternalPlaylist], Error>? = listsFresh
            ? nil
            : Task { try await HotPlaylists.fetch(.netease) }
        let qqJob: Task<[ExternalPlaylist], Error>? = listsFresh
            ? nil
            : Task { try await HotPlaylists.fetch(.qq) }
        let kugouJob: Task<[ExternalPlaylist], Error>? = listsFresh
            ? nil
            : Task { try await HotPlaylists.fetch(.kugou) }

        // 失败不再静默：哪个源挂了就在分区标题旁标出来，用户才不会以为是缺功能
        var failures: [String: String] = [:]

        let yt: [Shelf]
        if let job = ytJob {
            do {
                yt = try await job.value
            } catch {
                yt = []
                failures["youtube"] = describe(error)
            }
            feed.markShelvesAttempted()
        } else {
            yt = []
        }

        let netease: [ExternalPlaylist]
        if let job = neteaseJob {
            do {
                netease = try await job.value
            } catch {
                netease = []
                failures[PlaylistPlatform.netease.rawValue] = describe(error)
            }
        } else {
            netease = []
        }

        let qq: [ExternalPlaylist]
        if let job = qqJob {
            do {
                qq = try await job.value
            } catch {
                qq = []
                failures[PlaylistPlatform.qq.rawValue] = describe(error)
            }
        } else {
            qq = []
        }

        let kugou: [ExternalPlaylist]
        if let job = kugouJob {
            do {
                kugou = try await job.value
            } catch {
                kugou = []
                failures[PlaylistPlatform.kugou.rawValue] = describe(error)
            }
        } else {
            kugou = []
        }

        await MainActor.run {
            // 抓失败时保留上一次的缓存，别让整块内容凭空消失
            if !yt.isEmpty {
                ytShelves = yt
                feed.storeShelves(yt)
            }
            self.failures = failures

            var merged = external
            if !netease.isEmpty {
                merged[PlaylistPlatform.netease.rawValue] = netease
                feed.store(netease, for: .netease)
            }
            if !qq.isEmpty {
                merged[PlaylistPlatform.qq.rawValue] = qq
                feed.store(qq, for: .qq)
            }
            if !kugou.isEmpty {
                merged[PlaylistPlatform.kugou.rawValue] = kugou
                feed.store(kugou, for: .kugou)
            }
            external = merged
            if !listsFresh { feed.touch() }
            loading = false
            hasLoaded = true

            if ytShelves.isEmpty && external.values.allSatisfy({ $0.isEmpty }) {
                error = L("No content was returned. Check that your proxy also covers music.youtube.com, then retry.")
            }
        }
    }
}
