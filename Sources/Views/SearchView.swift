import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var results = SearchResults()
    @State private var loading = false
    @State private var hasSearched = false
    @State private var error: String?
    @State private var pending: Task<Void, Never>?

    @EnvironmentObject private var player: PlayerEngine

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
                } else if hasSearched, results.tracks.isEmpty, results.collections.isEmpty, results.domestic.isEmpty {
                    EmptyHint(
                        symbol: "magnifyingglass",
                        title: L("No results"),
                        message: L("Try another keyword, like an artist or song name.")
                    )
                    Spacer()
                } else if !hasSearched {
                    EmptyHint(
                        symbol: "music.note",
                        title: L("Search music"),
                        message: L("Search songs and artists. Results come from YouTube Music, plus domestic sources that play without a VPN.")
                    )
                    Spacer()
                } else {
                    resultList
                }
            }
            .navigationTitle(L("Search"))
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
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
                if !results.domestic.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: L("Domestic Sources · playable now"))
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.domestic.enumerated()), id: \.offset) { index, track in
                                TrackRow(track: track) {
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

                if !results.collections.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: L("Albums & Playlists"))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(results.collections) { collection in
                                    CarouselCard(item: .collection(collection), width: 132)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }

                if !results.tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: L("Songs"))
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.tracks.enumerated()), id: \.offset) { index, track in
                                TrackRow(track: track) {
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
            }
            .padding(.top, 4)
            .padding(.bottom, Layout.contentBottomInset)
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

    private func performSearch(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await MainActor.run {
            loading = true
            error = nil
        }
        // 两路并发：YouTube 拿元数据与专辑，国内音源拿"点了就能播"的曲目。
        // 任何一路失败都不该让另一路白跑 —— 用户至少能看到并播放一边的结果。
        async let youtubeTask: SearchResults? = {
            try? await InnerTube.shared.search(query: trimmed)
        }()
        async let domesticTask = DomesticSource.search(query: trimmed)

        let youtubeResults = await youtubeTask
        let domesticRaw = await domesticTask
        let playable = await DomesticSource.playableOnes(from: domesticRaw, limit: 10)

        NSLog(
            "SMOKE_SEARCH youtube=%d domesticRaw=%d playable=%d",
            youtubeResults?.tracks.count ?? -1,
            domesticRaw.count,
            playable.count
        )

        await MainActor.run {
            var merged = youtubeResults ?? SearchResults()
            merged.domestic = playable
            results = merged
            loading = false
            hasSearched = true

            if youtubeResults == nil, playable.isEmpty {
                error = L("YouTube blocked this network, and no playable song was found on domestic sources either.")
            } else {
                error = nil
            }
        }
    }
}
