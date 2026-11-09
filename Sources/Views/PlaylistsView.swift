import SwiftUI

// MARK: - 歌单行

struct PlaylistRow: View {
    let playlist: ImportedPlaylist

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: playlist.cover, size: 48, corner: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.system(size: 16))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(String(format: L("%d songs"), playlist.tracks.count)) · \(playlist.platform.label)")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 歌单详情

struct PlaylistDetailView: View {
    let playlist: ImportedPlaylist

    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirm = false

    private var item: ImportedPlaylist {
        store.playlists.first { $0.id == playlist.id } ?? playlist
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                if item.tracks.isEmpty {
                    ErrorBanner(message: L("Playlist is empty"))
                } else {
                    actionButtons
                        .padding(.top, 20)
                        .padding(.bottom, 8)

                    LazyVStack(spacing: 0) {
                        ForEach(Array(item.tracks.enumerated()), id: \.offset) { index, track in
                            TrackRow(track: track, showArtwork: false, showIndex: true, index: index + 1) {
                                player.play(tracks: item.tracks, startAt: index)
                            }
                            .padding(.horizontal, 16)

                            Divider().padding(.leading, 54)
                        }
                    }
                }
            }
            .padding(.bottom, Layout.contentBottomInset)
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .confirmationDialog(
            L("Delete this playlist?"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L("Delete"), role: .destructive) {
                store.delete(item.id)
                dismiss()
            }
            Button(L("Cancel"), role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(url: item.cover, size: 200, corner: 10)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .padding(.top, 12)

            VStack(spacing: 4) {
                Text(item.name)
                    .font(.system(size: 22, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("\(String(format: L("%d songs"), item.tracks.count)) · \(item.platform.label)")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.secondaryLabel)
            }
            .padding(.horizontal, 24)

            if item.tracks.count < item.totalCount {
                Text(item.matchedText)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.tertiaryLabel)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                player.play(tracks: item.tracks, startAt: 0)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 13, weight: .semibold))
                    Text(L("Play")).font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent))
            }
            .buttonStyle(PlainButtonStyle())

            Button {
                var shuffled = item.tracks
                shuffled.shuffle()
                player.play(tracks: shuffled, startAt: 0)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "shuffle").font(.system(size: 13, weight: .semibold))
                    Text(L("Shuffle")).font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.12)))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - 导入

struct ImportPlaylistView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PlaylistStore

    @State private var text = ""
    @State private var working = false
    @State private var status: String?
    @State private var done = 0
    @State private var total = 0
    @State private var resultText: String?
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?

    private var canImport: Bool {
        !working && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("Paste a playlist link from NetEase Cloud Music, QQ Music or Kugou."))
                        .font(.system(size: 13))
                        .foregroundColor(Theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)

                    TextEditor(text: $text)
                        .font(.system(size: 15))
                        .frame(height: 120)
                        .padding(6)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(UIColor.separator), lineWidth: 0.5)
                        )
                        .disabled(working)

                    Button(action: start) {
                        HStack(spacing: 8) {
                            if working {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            }
                            Text(L("Import"))
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(canImport ? Theme.accent : Theme.accent.opacity(0.35))
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(!canImport)

                    if working || status != nil {
                        HStack(spacing: 8) {
                            if working, total == 0 {
                                ProgressView()
                            }
                            Text(status ?? L("Recognizing…"))
                                .font(.system(size: 13))
                                .foregroundColor(Theme.secondaryLabel)
                        }
                    }

                    if working, total > 0 {
                        ProgressView(value: Double(done), total: Double(max(1, total)))
                            .tint(Theme.accent)
                    }

                    if let resultText = resultText {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(resultText)
                                .font(.system(size: 14))
                        }
                    }

                    if let errorText = errorText {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(errorText)
                                .font(.system(size: 13))
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(L("Try a different link"))
                                .font(.system(size: 12))
                                .foregroundColor(Theme.tertiaryLabel)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .navigationTitle(L("Import Playlist"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L("Cancel")) {
                        task?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if resultText != nil {
                        Button(L("Done")) { dismiss() }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onDisappear {
            task?.cancel()
        }
        .onAppear {
            guard let preset = SmokeTest.importURL, text.isEmpty, !working else { return }
            text = preset
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                start()
            }
        }
    }

    private func start() {
        errorText = nil
        resultText = nil
        done = 0
        total = 0
        working = true
        status = L("Recognizing…")

        task = Task {
            do {
                let target = try await resolveTarget(text)
                let remote = try await PlaylistFetcher.fetch(platform: target.platform, id: target.id)
                guard !remote.songs.isEmpty else { throw PlaylistImportError.empty }

                await MainActor.run {
                    total = remote.songs.count
                    status = String(format: L("Matching %d of %d"), 0, remote.songs.count)
                }

                let tracks = await PlaylistMatcher.match(songs: remote.songs) { finished, count in
                    done = finished
                    total = count
                    status = String(format: L("Matching %d of %d"), finished, count)
                }

                guard !Task.isCancelled else { return }
                guard !tracks.isEmpty else { throw PlaylistImportError.empty }

                await MainActor.run {
                    store.save(
                        name: remote.name,
                        platform: remote.platform,
                        cover: remote.cover,
                        tracks: tracks,
                        totalCount: remote.songs.count,
                        sourceID: target.id
                    )
                    resultText = String(format: L("Imported %d of %d songs"), tracks.count, remote.songs.count)
                    status = nil
                    working = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    status = nil
                    working = false
                }
            }
        }
    }

    private func resolveTarget(_ raw: String) async throws -> (platform: PlaylistPlatform, id: String) {
        if let hit = PlaylistLink.parse(raw) { return hit }

        for url in PlaylistLink.extractURLs(from: raw) where PlaylistLink.isShortLink(url) {
            if let final = await PlaylistLink.resolveShortLink(url),
               let hit = PlaylistLink.parse(final.absoluteString) {
                return hit
            }
        }
        throw PlaylistImportError.unsupportedLink
    }
}
