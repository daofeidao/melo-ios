import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var results = SearchResults()
    @State private var loading = false
    @State private var hasSearched = false
    @State private var error: String?
    @State private var pending: Task<Void, Never>?
    @State private var recentSearches: [String] = []
    /// 空态显示内置 + 搜过的艺人；搜索结果页显示本次命中的那几位
    @State private var artists: [String] = ArtistStore.all()
    @State private var matchedArtists: [String] = []
    @State private var youtubeLoaded = false
    @State private var youtubeLoading = false
    @State private var youtubeNote: String?
    @State private var searchGeneration = 0
    @State private var lastQuery = ""

    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var library: Library

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                searchField

                if loading {
                    ProgressView()
                        .padding(.top, 40)
                    Spacer()
                } else if let error = error {
                    ErrorBanner(message: error) {
                        Task { await performSearch(query) }
                    }
                    Spacer()
                } else if hasSearched, results.tracks.isEmpty, results.collections.isEmpty, results.domestic.isEmpty, results.domesticCollections.isEmpty, matchedArtists.isEmpty {
                    EmptyHint(
                        symbol: "magnifyingglass",
                        title: L("No results"),
                        message: L("Try another keyword, like an artist or song name.")
                    )
                    Spacer()
                } else if !hasSearched {
                    browseState
                } else {
                    resultList
                }
            }
            .navigationTitle(L("Search"))
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                loadRecentSearches()
                artists = ArtistStore.all()
                guard let preset = SmokeTest.searchQuery, query.isEmpty else { return }
                query = preset
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundColor(Theme.secondaryLabel)

            TextField(L("Songs, artists"), text: $query)
                .font(.system(size: 16))
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .onSubmit {
                    pending?.cancel()
                    Task { await performSearch(query) }
                }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.tertiaryLabel)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(UIColor.tertiarySystemFill))
        )
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .onChange(of: query) { value in
            schedule(value)
        }
    }

    private var resultList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // 搜索时也把「艺人」放在最上面，和 Apple Music 的结果页一致
                if !matchedArtists.isEmpty {
                    artistSection(matchedArtists)
                }

                if !playlistCollections.isEmpty {
                    collectionSection(title: L("Playlists"), items: playlistCollections)
                }

                if !albumCollections.isEmpty {
                    collectionSection(title: L("Albums"), items: albumCollections)
                }

                if !results.domestic.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: L("Songs"))
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.domestic.enumerated()), id: \.offset) { index, track in
                                TrackRow(track: track, badge: sourceBadge(track)) {
                                    player.play(tracks: results.domestic, startAt: index)
                                }
                                .padding(.horizontal, 16)
                                if index < results.domestic.count - 1 {
                                    Divider().padding(.leading, 76)
                                }
                            }
                        }
                    }
                }

                youtubeSection
            }
            .padding(.top, 4)
            .padding(.bottom, Layout.contentBottomInset)
        }
    }

    private var playlistCollections: [MediaCollection] {
        results.domesticCollections.filter { $0.browseId.hasPrefix("netease:playlist:") }
    }

    private var albumCollections: [MediaCollection] {
        results.domesticCollections.filter { $0.browseId.hasPrefix("netease:album:") }
    }

    private func collectionSection(title: String, items: [MediaCollection]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(items) { collection in
                        VStack(alignment: .leading, spacing: 6) {
                            CarouselCard(item: .collection(collection), width: 132)
                            // 收藏按钮放在卡片外面单独一行：放进 NavigationLink 的 label
                            // 里会被整张卡片的点击区域吞掉
                            CollectionSaveButton(collection: collection)
                        }
                        .frame(width: 132, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    /// YouTube 结果默认折叠：不点就不发请求
    @ViewBuilder
    private var youtubeSection: some View {
        if youtubeLoaded {
            if !results.collections.isEmpty {
                collectionSection(title: L("YouTube"), items: results.collections)
            }
            if !results.tracks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: L("Songs"))
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.tracks.enumerated()), id: \.offset) { index, track in
                            TrackRow(track: track, badge: "YT") {
                                player.play(tracks: results.tracks, startAt: index)
                            }
                            .padding(.horizontal, 16)
                            if index < results.tracks.count - 1 {
                                Divider().padding(.leading, 76)
                            }
                        }
                    }
                }
            }
            if let note = youtubeNote {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryLabel)
                    .padding(.horizontal, 16)
            }
        } else if hasSearched {
            Button {
                Task { await loadYouTube() }
            } label: {
                HStack(spacing: 8) {
                    Text(youtubeLoading ? L("Loading…") : L("More results from YouTube"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.accent)
                    Spacer(minLength: 0)
                    if youtubeLoading {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.accent)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private func schedule(_ value: String) {
        pending?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = SearchResults()
            hasSearched = false
            loading = false
            error = nil
            return
        }

        pending = Task {
            try? await Task.sleep(nanoseconds: 420_000_000)
            if Task.isCancelled { return }
            await performSearch(trimmed)
        }
    }

    // MARK: - 空态：按风格浏览

    private var browseState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !recentSearches.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionHeader(title: L("Recent Searches"))
                        ForEach(recentSearches, id: \.self) { term in
                            Button {
                                query = term
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 13))
                                        .foregroundColor(Theme.secondaryLabel)
                                    Text(term)
                                        .font(.system(size: 15))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.up.left")
                                        .font(.system(size: 12))
                                        .foregroundColor(Theme.tertiaryLabel)
                                }
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }

                artistSection(artists)

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: L("Browse by Genre"))
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 104), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(Array(HotPlaylists.genres.enumerated()), id: \.element.id) { index, genre in
                            NavigationLink(destination: GenrePlaylistsView(genre: genre)) {
                                genreCard(genre, index: index)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 6)
            .padding(.bottom, Layout.contentBottomInset)
        }
    }

    /// Apple Music 式「艺人」区：圆形头像卡片横排、名字居中。空态和结果页共用。
    private func artistSection(_ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L("Artists"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(names, id: \.self) { name in
                        NavigationLink(destination: ArtistDetailView(name: name)) {
                            artistChip(name)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func artistChip(_ name: String) -> some View {
        let colors: [Color] = [
            Color(hex: 0xE0455E), Color(hex: 0x2E7BE0), Color(hex: 0xE08A2E),
            Color(hex: 0x2EA98A), Color(hex: 0x7B5BD6), Color(hex: 0xC24E8F),
            Color(hex: 0x3C6FA8)
        ]
        let index = abs(name.hashValue % colors.count)
        return VStack(spacing: 7) {
            ZStack {
                Circle().fill(colors[index])
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 88, height: 88)
            Text(name)
                .font(.system(size: 13))
                .foregroundColor(Theme.secondaryLabel)
                .lineLimit(1)
        }
        .frame(width: 96)
    }

    private func genreCard(_ genre: PlaylistGenre, index: Int) -> some View {
        let colors: [Color] = [
            Color(hex: 0xE0455E), Color(hex: 0x2E7BE0), Color(hex: 0xE08A2E),
            Color(hex: 0x2EA98A), Color(hex: 0x7B5BD6), Color(hex: 0xC24E8F)
        ]
        return Text(genre.title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(colors[index % colors.count].opacity(0.9))
            )
    }

    // MARK: - 最近搜索

    private var recentSearchesKey: String { "melo.recentSearches" }

    private func loadRecentSearches() {
        recentSearches = UserDefaults.standard.stringArray(forKey: recentSearchesKey) ?? []
    }

    private func rememberSearch(_ term: String) {
        guard !term.isEmpty else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        list.insert(term, at: 0)
        if list.count > 8 { list = Array(list.prefix(8)) }
        recentSearches = list
        UserDefaults.standard.set(list, forKey: recentSearchesKey)
    }

    private func dedup(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { track in
            let key = normalize(track.title) + "|" + normalize(track.artist)
            return seen.insert(key).inserted
        }
    }

    private func normalize(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: " ", with: "")
    }

    private func performSearch(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 防抖只决定"发不发请求"，不负责"停掉旧请求" —— URLSession 不会因为
        // Task 取消而中断，所以用代际号丢弃过期结果，否则连打几个字会越搜越慢。
        searchGeneration += 1
        let generation = searchGeneration
        lastQuery = trimmed

        await MainActor.run {
            loading = true
            error = nil
            youtubeLoaded = false
            youtubeNote = nil
        }

        let started = Date()

        // Hi·FLAC 单独一路，不动 DomesticSource.search（那条链路还被播放取流用着）。
        // 它的结果自带 platform:id，点播时按 id 精确取流，不会走歌名模糊匹配。
        // 四路并发；YouTube 仍不在这里，没有代理时它固定白等 12 秒。
        let flacJob = Task { () -> [Track] in
            guard SourcePrefs.shared.isEnabled("flachi") else { return [] }
            return await FlacHiSource.searchTracks(query: trimmed, limit: 20)
        }
        let songsJob = Task { await DomesticSource.search(query: trimmed) }
        let albumsJob = Task { await DomesticSource.neteaseAlbumSearch(query: trimmed) }
        let playlistsJob = Task { await DomesticSource.neteasePlaylistSearch(query: trimmed) }

        let flac = await flacJob.value
        let songs = await songsJob.value
        let albums = await albumsJob.value
        let playlists = await playlistsJob.value

        guard generation == searchGeneration else { return }

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        NSLog("SMOKE_SEARCH flac=\(flac.count) domestic=\(songs.count) albums=\(albums.count) playlists=\(playlists.count) ms=\(ms)")

        // Hi·FLAC 排最前，其余国内源补充；去重保留先出现的那条（带精确 id，播放最稳）。
        let merged = dedup(flac + songs)
        // 可播排前面、VIP 排后面；同组内保持接口原顺序
        let ordered = merged.filter { !$0.isVip } + merged.filter { $0.isVip }

        var merged = SearchResults()
        merged.domestic = ordered
        merged.domesticCollections = albums.map { album in
            MediaCollection(
                browseId: "netease:album:\(album.id)",
                title: album.name,
                subtitle: album.artist.isEmpty ? String(format: L("%d songs"), album.trackCount) : album.artist,
                artwork: album.cover
            )
        } + playlists.map { playlist in
            MediaCollection(
                browseId: "netease:playlist:\(playlist.id)",
                title: playlist.name,
                subtitle: playlist.creator.isEmpty ? String(format: L("%d songs"), playlist.trackCount) : playlist.creator,
                artwork: playlist.cover
            )
        }

        await MainActor.run {
            guard generation == searchGeneration else { return }
            results = merged
            loading = false
            hasSearched = true
            rememberSearch(trimmed)
            matchedArtists = extractArtists(term: trimmed, tracks: ordered)
            if let hit = matchedArtists.first, artistMatches(term: trimmed, artist: hit) {
                ArtistStore.remember(hit)
                artists = ArtistStore.all()
            }
            // 只预热免费曲目：VIP 会白等一次匹配
            player.prewarm(tracks: ordered.filter { !$0.isVip }, limit: 5)
            if ordered.isEmpty, merged.domesticCollections.isEmpty, matchedArtists.isEmpty {
                error = L("Nothing found on domestic sources. Open “More results” to try YouTube.")
            } else {
                error = nil
            }
        }
    }

    /// 折叠区：用户主动点开才请求 YouTube
    private func loadYouTube() async {
        guard !youtubeLoading else { return }
        let query = lastQuery
        guard !query.isEmpty else { return }
        let generation = searchGeneration

        await MainActor.run { youtubeLoading = true }

        let result = try? await InnerTube.shared.search(query: query)

        await MainActor.run {
            youtubeLoading = false
            guard generation == searchGeneration else { return }
            youtubeLoaded = true
            if let result = result {
                results.tracks = result.tracks
                results.collections = result.collections
                youtubeNote = nil
            } else {
                youtubeNote = L("YouTube is not reachable on this network.")
            }
        }
    }
}
