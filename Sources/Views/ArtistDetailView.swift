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
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
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

        // 专辑曲目补上接口漏掉的曲目（有些歌只挂在专辑里，没进 artist/songs）。
        // 依赖 cleanAlbums，必须等上面算完。
        if !cleanAlbums.isEmpty {
            collected += await DomesticSource.artistAlbumTracks(
                albumIDs: Array(cleanAlbums.prefix(6).map(\.id))
            )
        }

        let all = dedup(collected).filter {
            artistMatches(term: name, artist: $0.artist)
                && isCleanTitle($0.title)
                && isCleanTitle($0.album ?? "")
        }
        // 本人主唱排前面，和别人的合唱 / 助阵放后面；同名只留第一次出现的那版。
        // 不再截断 50 首 —— 以前这里 break 掉，高产歌手永远只能看到 50 首。
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
            loading = false
            if cleanAlbums.isEmpty, final.isEmpty, p == nil {
                errorText = L("No artist info found. Try another name.")
            }
        }
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
