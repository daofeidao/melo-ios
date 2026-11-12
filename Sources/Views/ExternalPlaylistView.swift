import SwiftUI

/// 排行榜歌单详情：直接是歌曲列表，点歌就播，想留下才点「收藏到资料库」。
struct ExternalPlaylistView: View {
    let item: ExternalPlaylist

    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var store = PlaylistStore.shared

    @State private var tracks: [Track] = []
    @State private var loading = true
    @State private var hint: String?

    private var saved: Bool {
        store.playlists.contains { $0.platform == item.platform && $0.sourceID == item.playlistID }
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
                    EmptyHint(
                        symbol: "music.note.list",
                        title: L("Nothing here yet"),
                        message: L("This playlist could not be loaded. Pull back and open it again.")
                    )
                    .padding(.top, 24)
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
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            ArtworkView(url: item.cover, size: 150, corner: 10)
                .shadow(color: .black.opacity(0.16), radius: 10, y: 4)

            Text(item.name)
                .font(.system(size: 18, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 24)

            Text(item.subtitle.isEmpty ? item.platform.label : item.subtitle)
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

            if let hint = hint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.accent)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
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
            PlaylistStore.shared.delete(platform: item.platform, sourceID: item.playlistID)
        } else {
            // 后台导入：点完就能走开，不用守在这个页面上等它翻完所有分页
            ImportCoordinator.shared.start(
                platform: item.platform,
                id: item.playlistID,
                isRank: item.isRank,
                fallbackTitle: item.name
            )
            hint = L("Importing in the background. You can keep using the app.")
        }
    }

    private func reload() async {
        if let hit = ChartLibrary.shared.cached(item), !hit.isEmpty {
            tracks = hit
            loading = false
            return
        }
        loading = true
        let list = await ChartLibrary.shared.load(item)
        await MainActor.run {
            tracks = list
            loading = false
            if !list.isEmpty { player.prewarm(tracks: list) }
        }
    }
}
