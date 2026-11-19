import SwiftUI
import UIKit

/// 艺人详情，版式照 Apple Music 的艺人页：
/// 顶部圆形大头像 + 艺人名 + 统计，下面依次是 简介 / 专辑 / 歌曲。
///
/// 头像、简介来自网易云艺人接口（ArtistInfo，匿名可直连）；
/// 专辑按**艺人 id** 直取本人全部专辑（关键词搜索会回来一堆同名野生账号的假专辑）；
/// 歌曲取本人专辑里的曲目（热门榜对创作型歌手不可信），再补多源搜索。
struct ArtistDetailView: View {
    let name: String

    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ArtistInfo.Profile?
    @State private var albums: [DomesticSource.DomesticAlbum] = []
    @State private var tracks: [Track] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var bioExpanded = false
    @State private var showAllAlbums = false
    @State private var showAllTracks = false
    /// 只拉一次：艺人页是用 NavigationLink 推出来的，从子页（专辑）pop 回来时
    /// 视图仍活着、@State 还在，但 .task 每次出现都会重跑 → 又拉一遍全部数据，
    /// 看着就像「返回很慢、重载了一遍」。用这个标记跳过重复加载。
    @State private var didLoad = false
    /// 喜欢按钮：点下后先过白名单校验，校验期间转圈，失败给个明确提示
    @State private var likeBusy = false
    @State private var likeMessage: String?

    private let albumPreview = 5
    private let trackPreview = 8

    var body: some View {
        ScrollView {
            if loading {
                ProgressView().padding(.top, 60)
            } else if let errorText, albums.isEmpty, tracks.isEmpty, profile == nil {
                ErrorBanner(message: errorText) { Task { await load() } }
            } else {
                LazyVStack(alignment: .leading, spacing: 22) {
                    hero
                    // 简介紧跟头像：以前排在最底部，几乎滑不到，看着就像「没有简介」
                    if !bioText.isEmpty { bioSection }
                    if !albums.isEmpty { albumSection }
                    if !tracks.isEmpty { chartSection }
                }
                .padding(.bottom, Layout.contentBottomInset)
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        // 快速下滑退出：在艺人页里快速向下甩（flick down）就返回上一页。
        // 用 simultaneousGesture 和 ScrollView 滚动并存，只认「向下的快速甩动」，
        // 普通慢速滚动不受影响。
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    let vy = value.predictedEndTranslation.height - value.translation.height
                    let fastDown = value.translation.height > 80 && vy > 40
                    if fastDown {
                        dismiss()
                    }
                }
        )
        .task {
            ArtistStore.remember(name)
            // 艺人页是 NavigationLink 推出来的：从子页（专辑）pop 回来时视图仍活着、
            // @State 还在，但 .task 每次出现都会重跑 → 又拉一遍全部数据，
            // 看着就像「返回很慢、重载了一遍」。用 didLoad 跳过重复加载。
            if !didLoad {
                didLoad = true
                await load()
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 12) {
            if let avatar = profile?.avatar, !avatar.isEmpty {
                ArtworkView(url: avatar, size: 132, corner: 66)
            } else {
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.85))
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(width: 132, height: 132)
            }
            Text(profile?.name ?? name)
                .font(.system(size: 27, weight: .bold))
                .lineLimit(1)
            // 「艺人 · 48 张专辑 · 50 首歌」——一眼看出这个页面装了多少内容
            Text(heroSubtitle)
                .font(.system(size: 13))
                .foregroundColor(Theme.secondaryLabel)

            likeButton
            if let likeMessage {
                Text(likeMessage)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: 0xE0455E))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - 喜欢

    private var isLiked: Bool { library.isLikedArtist(name) }

    private var likeButton: some View {
        Button(action: toggleLike) {
            HStack(spacing: 6) {
                if likeBusy {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(isLiked ? L("Liked") : L("Like"))
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(isLiked ? .white : Theme.accent)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(
                Capsule().fill(isLiked ? Theme.accent : Theme.accent.opacity(0.12))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(likeBusy)
        .padding(.top, 2)
    }

    /// 取消喜欢立刻生效；加喜欢要先确认这名字在艺人库里真实存在，
    /// 否则用户从搜索结果误点到派生账号，会把它永久塞进首页。
    private func toggleLike() {
        guard !likeBusy else { return }
        likeMessage = nil
        if isLiked {
            library.removeLikedArtist(name)
            return
        }
        likeBusy = true
        Task {
            let ok = await ArtistResolver.resolve(name) != nil
            await MainActor.run {
                likeBusy = false
                if ok {
                    library.addLikedArtist(name)
                } else {
                    likeMessage = L("Can't add: this name isn't in the artist library.")
                }
            }
        }
    }

    private var heroSubtitle: String {
        var parts: [String] = [L("Artist")]
        if !albums.isEmpty { parts.append("\(albums.count) 张专辑") }
        if !tracks.isEmpty { parts.append("\(tracks.count) 首歌") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 简介

    private var bioText: String {
        let bio = profile?.biography ?? ""
        let brief = profile?.brief ?? ""
        return bio.count >= brief.count ? bio : brief
    }

    private var bioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: L("Biography"))
            VStack(alignment: .leading, spacing: 6) {
                Text(bioText)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.secondaryLabel)
                    .lineLimit(bioExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    bioExpanded.toggle()
                } label: {
                    Text(L(bioExpanded ? "Show Less" : "Show More"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.accent)
                }
                .buttonStyle(PlainButtonStyle())
                Text(L("Info from NetEase Cloud Music"))
                    .font(.system(size: 11))
                    .foregroundColor(Theme.tertiaryLabel)
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - 专辑

    private var shownAlbums: [DomesticSource.DomesticAlbum] {
        showAllAlbums ? albums : Array(albums.prefix(albumPreview))
    }

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("Albums"), canExpand: albums.count > albumPreview, expanded: showAllAlbums) {
                showAllAlbums.toggle()
            }
            if showAllAlbums {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 14)], alignment: .leading, spacing: 18) {
                    ForEach(shownAlbums) { album in
                        albumCard(album)
                    }
                }
                .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(shownAlbums) { album in
                            albumCard(album)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func albumCard(_ album: DomesticSource.DomesticAlbum) -> some View {
        let collection = MediaCollection(
            browseId: "netease:album:\(album.id)",
            title: album.name,
            subtitle: album.artist.isEmpty
                ? String(format: L("%d songs"), album.trackCount)
                : album.artist,
            artwork: album.cover
        )
        return VStack(alignment: .leading, spacing: 6) {
            CarouselCard(item: .collection(collection), width: 132)
            CollectionSaveButton(collection: collection)
        }
        .frame(width: 132, alignment: .leading)
    }

    // MARK: - 歌曲

    private var shownTracks: [Track] {
        showAllTracks ? tracks : Array(tracks.prefix(trackPreview))
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(L("Songs"), canExpand: tracks.count > trackPreview, expanded: showAllTracks) {
                showAllTracks.toggle()
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(shownTracks.enumerated()), id: \.offset) { index, track in
                    TrackRow(
                        track: track,
                        showIndex: true,
                        index: index + 1,
                        badge: sourceBadge(track)
                    ) {
                        player.play(tracks: shownTracks, startAt: index)
                    }
                    .padding(.horizontal, 16)
                    if index < shownTracks.count - 1 {
                        Divider().padding(.leading, 76)
                    }
                }
            }
        }
    }

    /// 分区标题 + 右侧「显示全部 / 收起」
    private func sectionHeader(
        _ title: String,
        canExpand: Bool,
        expanded: Bool,
        toggle: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            SectionHeader(title: title)
            if canExpand {
                Button(action: toggle) {
                    Text(expanded ? "收起" : "显示全部")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.accent)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.trailing, 16)
            }
        }
    }

    // MARK: - 数据

    private func load() async {
        loading = true
        errorText = nil

        // 缓存秒开：退出再进来时，先直接展示上次的结果，后台再静默刷新。
        // 这样二次进入不再是「转圈 + 全量重拉」，而是立即有内容。
        // 收藏的艺人跳过 12 小时期限：用户在意的歌手，任何时候打开都该秒开
        if let cached = ArtistDetailCache.get(name, ignoreExpiry: Library.shared.isLikedArtist(name)) {
            await MainActor.run {
                profile = cached.profile
                albums = cached.albums
                tracks = cached.tracks
                loading = false
            }
            // 已有缓存就不再阻塞等待网络；后台静默拉最新，拉到就更新。
            await refreshInBackground()
            return
        }

        // 先把艺人本体解析出来（id / 头像 / 简介），专辑和歌曲都靠这个 id 直取
        let p = await ArtistInfo.load(name: name)
        let artistID = p?.id ?? 0

        var rawAlbums: [DomesticSource.DomesticAlbum] = []
        var collected: [Track] = []

        // 拿到 artistID 后，专辑列表 / 全量歌曲 / 热门榜 三路互不影响，并发取数。
        // 艺人页进入慢的根因是顺序 await：先把这一批并发跑起来，再处理依赖专辑的环节。
        if artistID > 0 {
            async let albumsTask = DomesticSource.artistAlbums(artistID: artistID)
            async let songsTask = DomesticSource.artistSongs(artistID: artistID)
            async let topTask = DomesticSource.artistTopSongs(artistID: artistID)

            rawAlbums = await albumsTask
            let ownSongs = await songsTask
            let top = await topTask
            collected += ownSongs
            collected += top.filter { primaryArtistMatches(term: name, artist: $0.artist) }
        }

        if rawAlbums.isEmpty {
            rawAlbums = await DomesticSource.neteaseAlbumSearch(query: name, limit: 30)
        }
        // 只认这位艺人本人的正版作品：同名合辑 / 翻唱 / Live / 原声带都剔掉
        let cleanAlbums = rawAlbums
            .filter {
                ($0.artist.isEmpty || artistMatches(term: name, artist: $0.artist))
                    && isCleanTitle($0.name)
            }
            // 大碟（曲目多的）排前面，单曲 / EP 往后
            .sorted {
                $0.trackCount == $1.trackCount ? $0.name < $1.name : $0.trackCount > $1.trackCount
            }

        // 先把「不依赖专辑曲目」的结果画出来。
        // 专辑曲目那一步是第二个网络往返，慢网下要十几秒 —— 挡在首屏前面，
        // 等于每次进来都先干等一轮。歌手本体 / 专辑 / 热门歌已经够撑起首屏了。
        let firstPass = mergeTracks(collected)
        await MainActor.run {
            profile = p
            albums = cleanAlbums
            tracks = firstPass
            loading = false
            if cleanAlbums.isEmpty, firstPass.isEmpty, p == nil {
                errorText = L("No artist info found. Try another name.")
            }
        }

        // 再补专辑里漏掉的歌（有些歌只挂在专辑里，没进 artist/songs）
        if !cleanAlbums.isEmpty {
            let extra = await DomesticSource.artistAlbumTracks(
                albumIDs: Array(cleanAlbums.prefix(6).map(\.id))
            )
            let merged = mergeTracks(collected + extra)
            await MainActor.run {
                // 只在新结果确实更多时才替换，避免列表无谓跳动
                if merged.count != tracks.count { tracks = merged }
            }
            ArtistDetailCache.set(name, profile: p, albums: cleanAlbums, tracks: merged)
        } else {
            ArtistDetailCache.set(name, profile: p, albums: cleanAlbums, tracks: firstPass)
        }
    }

    /// 合并 + 去重 + 排序：本人主唱在前，合唱 / 助阵在后，同名只留第一次出现的版本。
    private func mergeTracks(_ input: [Track]) -> [Track] {
        let all = dedup(input).filter {
            artistMatches(term: name, artist: $0.artist)
                && isCleanTitle($0.title)
                && isCleanTitle($0.album ?? "")
        }
        let own = all.filter { primaryArtistMatches(term: name, artist: $0.artist) }
        let collab = all.filter { !primaryArtistMatches(term: name, artist: $0.artist) }
        var out: [Track] = []
        var seen = Set<String>()
        for track in own + collab {
            let key = normalize(track.title)
            if seen.insert(key).inserted { out.append(track) }
        }
        return out
    }

    /// 后台静默刷新：已有缓存时，拉最新数据并更新缓存与界面。
    private func refreshInBackground() async {
        let p = await ArtistInfo.load(name: name)
        let artistID = p?.id ?? 0

        var rawAlbums: [DomesticSource.DomesticAlbum] = []
        var collected: [Track] = []
        if artistID > 0 {
            async let albumsTask = DomesticSource.artistAlbums(artistID: artistID)
            async let songsTask = DomesticSource.artistSongs(artistID: artistID)
            async let topTask = DomesticSource.artistTopSongs(artistID: artistID)
            rawAlbums = await albumsTask
            collected += await songsTask
            collected += (await topTask).filter { primaryArtistMatches(term: name, artist: $0.artist) }
        }
        if rawAlbums.isEmpty {
            rawAlbums = await DomesticSource.neteaseAlbumSearch(query: name, limit: 30)
        }
        let cleanAlbums = rawAlbums
            .filter { ($0.artist.isEmpty || artistMatches(term: name, artist: $0.artist)) && isCleanTitle($0.name) }
            .sorted { $0.trackCount == $1.trackCount ? $0.name < $1.name : $0.trackCount > $1.trackCount }
        if !cleanAlbums.isEmpty {
            collected += await DomesticSource.artistAlbumTracks(albumIDs: Array(cleanAlbums.prefix(6).map(\.id)))
        }
        let all = dedup(collected).filter {
            artistMatches(term: name, artist: $0.artist) && isCleanTitle($0.title) && isCleanTitle($0.album ?? "")
        }
        let own = all.filter { primaryArtistMatches(term: name, artist: $0.artist) }
        let collab = all.filter { !primaryArtistMatches(term: name, artist: $0.artist) }
        var final: [Track] = []
        var seen = Set<String>()
        for track in own + collab {
            let key = normalize(track.title)
            if seen.insert(key).inserted { final.append(track) }
        }

        await MainActor.run {
            profile = p
            albums = cleanAlbums
            tracks = final
        }
        ArtistDetailCache.set(name, profile: p, albums: cleanAlbums, tracks: final)
    }

    private func dedup(_ list: [Track]) -> [Track] {
        var seen = Set<String>()
        return list.filter { track in
            let key = normalize(track.title) + "|" + normalize(track.artist)
            return seen.insert(key).inserted
        }
    }

    private func normalize(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: " ", with: "")
    }
}

/// 过滤掉 DJ 魔改 / 翻唱 / Live / 演唱会 / 原声带 / 合辑 / 伴奏 / Remix / 串烧 / 对唱 /
/// 合唱 / 铃声 / 车载 DJ / 致敬 / 纪念等非本人正版内容。词表同时作用于专辑和歌曲。
private func isCleanTitle(_ title: String) -> Bool {
    let lower = title.lowercased()
    let blocked = [
        "dj", "remix", "remix版", "dj版", "mashup", "sped", "slowed", "mix版",
        "翻唱", "原声带", "ost", "合辑", "伴奏", "纯音乐", "试听", "片段",
        "live", "演唱会", "现场版",
        "钢琴版", "吉他版", "小提琴版", "串烧", "迪斯科", "的士高", "disco",
        "对唱", "合唱", "合唱版", "卡拉", "卡啦", "铃声", "手机铃声",
        "喊麦", "慢摇", "广场舞", "车载", "翻版", "假唱", "试唱", "清唱",
        "朗读", "相声", "评书", "致敬", "纪念"
    ]
    return !blocked.contains { lower.contains($0) }
}
