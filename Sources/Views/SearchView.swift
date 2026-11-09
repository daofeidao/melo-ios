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
                } else if hasSearched, results.tracks.isEmpty, results.collections.isEmpty {
                    EmptyHint(
                        symbol: "magnifyingglass",
                        title: "没有找到结果",
                        message: "换个关键词试试，比如歌手名或歌曲名。"
                    )
                    Spacer()
                } else if !hasSearched {
                    EmptyHint(
                        symbol: "music.note",
                        title: "搜索音乐",
                        message: "可搜索歌曲、艺人，结果来自 YouTube Music。"
                    )
                    Spacer()
                } else {
                    resultList
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.large)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundColor(Theme.secondaryLabel)

            TextField("搜索歌曲、艺人", text: $query)
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
                if !results.collections.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "专辑与歌单")
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
                        SectionHeader(title: "歌曲")
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
        do {
            let response = try await InnerTube.shared.search(query: trimmed)
            await MainActor.run {
                results = response
                loading = false
                hasSearched = true
            }
        } catch {
            await MainActor.run {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                loading = false
                hasSearched = true
            }
        }
    }
}
