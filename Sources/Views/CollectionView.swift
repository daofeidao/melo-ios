import SwiftUI

struct CollectionView: View {
    let browseId: String
    let fallbackTitle: String

    @EnvironmentObject private var player: PlayerEngine

    @State private var detail: CollectionDetail?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                if let detail = detail, !detail.tracks.isEmpty {
                    actionButtons(detail.tracks)
                        .padding(.top, 22)
                        .padding(.bottom, 10)

                    LazyVStack(spacing: 0) {
                        ForEach(Array(detail.tracks.enumerated()), id: \.offset) { index, track in
                            TrackRow(
                                track: track,
                                showArtwork: false,
                                showIndex: true,
                                index: index + 1
                            ) {
                                player.play(tracks: detail.tracks, startAt: index)
                            }
                            .padding(.horizontal, 16)

                            Divider().padding(.leading, 54)
                        }
                    }
                } else if loading {
                    ProgressView()
                        .padding(.top, 60)
                } else {
                    ErrorBanner(message: error ?? L("No tracks found")) {
                        Task { await load() }
                    }
                }
            }
            .padding(.bottom, Layout.contentBottomInset)
        }
        .navigationTitle(fallbackTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(url: detail?.artwork, size: 210, corner: 8)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .padding(.top, 12)

            VStack(spacing: 4) {
                Text(detail?.title ?? fallbackTitle)
                    .font(.system(size: 22, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let subtitle = detail?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.secondaryLabel)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func actionButtons(_ tracks: [Track]) -> some View {
        HStack(spacing: 12) {
            Button {
                player.play(tracks: tracks, startAt: 0)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(L("Play"))
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accent)
                )
            }
            .buttonStyle(PlainButtonStyle())

            Button {
                var shuffled = tracks
                shuffled.shuffle()
                player.play(tracks: shuffled, startAt: 0)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 13, weight: .semibold))
                    Text(L("Shuffle"))
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accent.opacity(0.12))
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 16)
    }

    private func load() async {
        await MainActor.run {
            loading = true
            error = nil
        }

        // 国内专辑：browseId 带前缀，直接从网易云拿曲目，不经 YouTube
        if browseId.hasPrefix("netease:album:") {
            let id = String(browseId.dropFirst("netease:album:".count))
            let result = await DomesticSource.neteaseAlbumDetail(id: id)
            await MainActor.run {
                detail = result
                loading = false
                if let result = result { player.prewarm(tracks: result.tracks) }
                if result == nil { error = L("This album could not be loaded.") }
            }
            return
        }

        // 国内歌单：复用已有的歌单抓取，曲目直接转 Track（不做 YouTube 匹配）
        if browseId.hasPrefix("netease:playlist:") {
            let id = String(browseId.dropFirst("netease:playlist:".count))
            let remote = try? await PlaylistFetcher.fetch(platform: .netease, id: id)
            let tracks = PlaylistMatcher.direct(songs: remote?.songs ?? [])
            await MainActor.run {
                detail = CollectionDetail(
                    title: remote?.name ?? fallbackTitle,
                    subtitle: String(format: L("%d songs"), tracks.count),
                    artwork: remote?.cover,
                    tracks: tracks
                )
                loading = false
                if tracks.isEmpty { error = L("Nothing here yet") } else { player.prewarm(tracks: tracks) }
            }
            return
        }

        do {
            let result = try await InnerTube.shared.collection(browseId: browseId)
            await MainActor.run {
                detail = result
                loading = false
            }
        } catch {
            await MainActor.run {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                loading = false
            }
        }
    }
}
