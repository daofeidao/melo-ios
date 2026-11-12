import SwiftUI
import UIKit

/// 艺人详情，版式照 Apple Music 的艺人页：
/// 顶部圆形大头像 + 艺人名 + 播放，下面依次是 代表作 / 专辑 / 歌曲排行 / 简介。
///
/// 头像、简介、代表作品来自网易云艺人接口（ArtistInfo，匿名可直连）；
/// 专辑和歌曲按艺人名实时拉，不写死离线表。
struct ArtistDetailView: View {
    let name: String

    @EnvironmentObject private var player: PlayerEngine
    @State private var profile: ArtistInfo.Profile?
    @State private var albums: [DomesticSource.DomesticAlbum] = []
    @State private var tracks: [Track] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var bioExpanded = false

    var body: some View {
        ScrollView {
            if loading {
                ProgressView().padding(.top, 60)
            } else if let errorText, albums.isEmpty, tracks.isEmpty, profile == nil {
                ErrorBanner(message: errorText) { Task { await load() } }
            } else {
                LazyVStack(alignment: .leading, spacing: 24) {
                    hero
                    if let works = profile?.works, !works.isEmpty {
                        worksSection(works)
                    }
                    if !albums.isEmpty { albumSection }
                    if !tracks.isEmpty { chartSection }
                    if !bioText.isEmpty { bioSection }
                }
                .padding(.bottom, Layout.contentBottomInset)
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            ArtistStore.remember(name)
            await load()
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
            Text(L("Artist"))
                .font(.system(size: 13))
                .foregroundColor(Theme.secondaryLabel)
            if !tracks.isEmpty {
                Button {
                    player.play(tracks: tracks, startAt: 0)
                } label: {
                    Text(L("Play All"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - 代表作

    private func worksSection(_ works: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L("Representative Works"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(works, id: \.self) { title in
                        Button {
                            Task { await playWork(title) }
                        } label: {
                            Text(title)
                                .font(.system(size: 14))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .padding(.horizontal, 15)
                                .padding(.vertical, 9)
                                .background(Capsule().fill(Color(UIColor.tertiarySystemFill)))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - 专辑

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L("Albums"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { album in
                        let collection = MediaCollection(
                            browseId: "netease:album:\(album.id)",
                            title: album.name,
                            subtitle: album.artist.isEmpty
                                ? String(format: L("%d songs"), album.trackCount)
                                : album.artist,
                            artwork: album.cover
                        )
                        VStack(alignment: .leading, spacing: 6) {
                            CarouselCard(item: .collection(collection), width: 132)
                            CollectionSaveButton(collection: collection)
                        }
                        .frame(width: 132, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - 歌曲排行

    private var ranked: [Track] { Array(tracks.prefix(12)) }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L("Top Songs"))
            LazyVStack(spacing: 0) {
                ForEach(Array(ranked.enumerated()), id: \.offset) { index, track in
                    TrackRow(
                        track: track,
                        showIndex: true,
                        index: index + 1,
                        badge: sourceBadge(track)
                    ) {
                        player.play(tracks: ranked, startAt: index)
                    }
                    .padding(.horizontal, 16)
                    if index < ranked.count - 1 {
                        Divider().padding(.leading, 76)
                    }
                }
            }
        }
    }

    // MARK: - 简介

    private var bioText: String {
        let bio = profile?.biography ?? ""
        return bio.isEmpty ? (profile?.brief ?? "") : bio
    }

    private var bioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: L("Biography"))
            VStack(alignment: .leading, spacing: 6) {
                Text(bioText)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.secondaryLabel)
                    .lineLimit(bioExpanded ? nil : 6)
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

    // MARK: - 数据

    private func load() async {
        loading = true
        errorText = nil

        // 用 Task 而不是 async let：项目里踩过 asyncLet_finish_after_task_completion 的坑
        let profileTask = Task { await ArtistInfo.load(name: name) }
        let albumTask = Task { await DomesticSource.neteaseAlbumSearch(query: name, limit: 12) }
        let flacTask = Task { () -> [Track] in
            guard SourcePrefs.shared.isEnabled("flachi") else { return [] }
            return await FlacHiSource.searchTracks(query: name, limit: 20)
        }
        let songTask = Task { await DomesticSource.search(query: name, limit: 20) }

        let p = await profileTask.value
        let a = await albumTask.value
        let f = await flacTask.value
        let s = await songTask.value
        // 只认这位艺人本人的作品，别把同名合辑 / 翻唱 / 别人专辑里收录的曲子混进来
        let merged = dedup(f + s).filter { artistMatches(term: name, artist: $0.artist) }
        let ownAlbums = a.filter { $0.artist.isEmpty || artistMatches(term: name, artist: $0.artist) }

        await MainActor.run {
            profile = p
            albums = ownAlbums
            tracks = merged
            loading = false
            if ownAlbums.isEmpty, merged.isEmpty, p == nil {
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

    /// 点代表作：先在当前排行里找同名，找不到再按歌名临时搜一首
    private func playWork(_ title: String) async {
        let wanted = normalize(title)
        if let hit = tracks.first(where: { track in
            let candidate = normalize(track.title)
            return candidate.contains(wanted) || wanted.contains(candidate)
        }) {
            await MainActor.run { player.play(tracks: [hit], startAt: 0) }
            return
        }
        let found = await DomesticSource.search(query: title, limit: 5)
        if let hit = found.first {
            await MainActor.run { player.play(tracks: [hit], startAt: 0) }
        }
    }
}
