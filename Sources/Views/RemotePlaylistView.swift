import SwiftUI

/// 国内平台的歌单详情：拉曲目后直接转成 Track（不做 YouTube 匹配），点了就播。
struct RemotePlaylistView: View {
    let platform: PlaylistPlatform
    let playlistID: String
    let name: String
    let cover: String?

    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var store = PlaylistStore.shared

    @State private var tracks: [Track] = []
    @State private var loading = true
    @State private var error: String?

    private var saved: Bool {
        store.playlists.contains { $0.platform == platform && $0.sourceID == playlistID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if tracks.isEmpty {
                    ErrorBanner(message: error ?? L("Nothing here yet")) {
                        Task { await load() }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                            TrackRow(track: track, showIndex: true, index: index + 1) {
                                player.play(tracks: tracks, startAt: index)
                            }
                            .padding(.horizontal, 16)
                            if index < tracks.count - 1 {
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, Layout.contentBottomInset)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            ArtworkView(url: cover, size: 150, corner: 10)
                .shadow(color: .black.opacity(0.16), radius: 10, y: 4)

            Text(name)
                .font(.system(size: 18, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 24)

            Text(tracks.isEmpty ? platform.label : String(format: L("%d songs"), tracks.count))
                .font(.system(size: 13))
                .foregroundColor(Theme.secondaryLabel)

            HStack(spacing: 10) {
                Button {
                    guard !tracks.isEmpty else { return }
                    player.play(tracks: tracks, startAt: 0)
                } label: {
                    capsule(L("Play"), systemImage: "play.fill", filled: true)
                }
                .buttonStyle(PlainButtonStyle())

                Button {
                    toggleSave()
                } label: {
                    capsule(
                        saved ? L("Saved to Library") : L("Save to Library"),
                        systemImage: saved ? "checkmark" : "plus",
                        filled: false
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
    }

    private func capsule(_ title: String, systemImage: String, filled: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundColor(filled ? .white : Theme.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(filled ? Theme.accent : Color(UIColor.tertiarySystemFill))
        )
    }

    private func toggleSave() {
        if saved {
            PlaylistStore.shared.delete(platform: platform, sourceID: playlistID)
        } else {
            PlaylistStore.shared.save(
                name: name,
                platform: platform,
                cover: cover,
                tracks: tracks,
                totalCount: tracks.count,
                sourceID: playlistID
            )
        }
    }

    private func load() async {
        await MainActor.run {
            loading = true
            error = nil
        }
        do {
            let remote = try await PlaylistFetcher.fetch(platform: platform, id: playlistID)
            let converted = PlaylistMatcher.direct(songs: remote.songs)
            await MainActor.run {
                tracks = converted
                loading = false
                if converted.isEmpty { error = L("Nothing here yet") }
            }
        } catch {
            await MainActor.run {
                tracks = []
                loading = false
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
