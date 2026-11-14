import SwiftUI

struct ListenNowView: View {
    @EnvironmentObject private var library: Library
    @ObservedObject private var artistRouter = ArtistRouter.shared

    @State private var shelves: [Shelf] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showClearRecentConfirm = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    // 固定框架：四个分区的标题直出，空时只显示一行灰字提示。
                    // 首页数据全部来自本地资料库，不必等网络刷新才出现内容；
                    // 只有 YouTube 推荐在后台拉，出来后追加在最下面。
                    frameworkSection(title: L("Saved Playlists & Albums"),
                                     isEmpty: library.savedCollections.isEmpty,
                                     emptyHint: L("Save playlists or albums from search results and they will show up here.")) {                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(library.savedCollections) { collection in
                                    CarouselCard(item: .collection(collection), width: 132)
                                        .contextMenu {
                                            Button {
                                                library.toggleSavedCollection(collection)
                                            } label: {
                                                Label(L("Remove"), systemImage: "heart.slash")
                                            }
                                        }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }

                    CarouselSection(
                        title: L("Recently Played"),
                        items: library.recent.map { ShelfItem.track($0) },
                        onRemove: { item in
                            if case .track(let t) = item { library.removeRecent(t) }
                        },
                        headerTrailing: library.recent.isEmpty ? nil : AnyView(clearRecentButton)
                    )
                    if library.recent.isEmpty { sectionHint(L("Songs you play will show up here.")) }

                    CarouselSection(
                        title: L("My Favorites"),
                        items: library.favorites.map { ShelfItem.track($0) },
                        width: 132,
                        onRemove: { item in
                            if case .track(let t) = item { library.toggleFavorite(t) }
                        }
                    )
                    if library.favorites.isEmpty {
                        sectionHint(L("Tap ♥ or long-press a song to add it to favorites."))
                    }

                    likedArtistsSection

                    ForEach(shelves) { shelf in
                        CarouselSection(title: shelf.title, items: shelf.items)
                    }

                    if loading && shelves.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }

                    if let error = error, shelves.isEmpty {
                        ErrorBanner(message: error) {
                            Task { await load() }
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, Layout.contentBottomInset)
            }
            .navigationTitle(L("Listen Now"))
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await load() }
            // 播放页点艺名后回到这里，由这个隐藏的链接把艺人页推进主栈
            .background(
                NavigationLink(
                    isActive: Binding(
                        get: { artistRouter.pending != nil },
                        set: { if !$0 { artistRouter.pending = nil } }
                    )
                ) {
                    if let name = artistRouter.pending {
                        ArtistDetailView(name: name)
                    }
                } label: {
                    EmptyView()
                }
            )
            .task {
                // 冷启动先用上次成功的结果铺满，再后台刷新
                if shelves.isEmpty, let cached = InnerTube.shared.cachedHomeShelves() {
                    shelves = cached
                }
                await load()
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .confirmationDialog(
            L("Clear recently played?"),
            isPresented: $showClearRecentConfirm,
            titleVisibility: .visible
        ) {
            Button(L("Clear"), role: .destructive) {
                library.clearRecent()
            }
            Button(L("Cancel"), role: .cancel) {}
        }
    }

    /// 固定分区：标题 + 内容；内容为空时显示一行灰字，不再整块消失
    @ViewBuilder
    private func frameworkSection<Content: View>(
        title: String,
        isEmpty: Bool,
        emptyHint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title)
            if isEmpty {
                Text(emptyHint)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.tertiaryLabel)
                    .padding(.horizontal, 16)
            } else {
                content()
            }
        }
    }

    /// 固定分区空态的一行灰字提示
    private func sectionHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Theme.tertiaryLabel)
            .padding(.horizontal, 16)
    }

    /// 最近播放标题右侧的红字「清空」（原设置页「资料库 → 清除最近播放」挪到这里）
    private var clearRecentButton: some View {
        Button {
            showClearRecentConfirm = true
        } label: {
            Text(L("Clear"))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(hex: 0xE0455E))
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.trailing, 16)
    }

    /// 喜欢艺人（新增）：圆形真实头像 + 名字，点开进艺人页，长按移除
    private var likedArtistsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L("Liked Artists"))
            if library.likedArtists.isEmpty {
                Text(L("Long-press an artist to remove."))
                    .font(.system(size: 12))
                    .foregroundColor(Theme.tertiaryLabel)
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(library.likedArtists, id: \.self) { name in
                            NavigationLink(destination: ArtistDetailView(name: name)) {
                                ArtistCircleTile(name: name)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .contextMenu {
                                Button {
                                    library.removeLikedArtist(name)
                                } label: {
                                    Label(L("Remove"), systemImage: "person.slash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func load() async {
        await MainActor.run {
            loading = true
            if shelves.isEmpty { error = nil }
        }
        do {
            let result = try await InnerTube.shared.home()
            await MainActor.run {
                shelves = result
                loading = false
                error = nil
            }
        } catch {
            await MainActor.run {
                // 已经有缓存内容时不打扰用户，只在真正空白时展示错误
                if shelves.isEmpty {
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                loading = false
            }
        }
    }
}
