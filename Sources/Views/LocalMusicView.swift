import SwiftUI
import UniformTypeIdentifiers

/// 资料库 → 本地音乐：从「文件」导入的音频，直接读文件播放，不联网。
struct LocalMusicView: View {
    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var store = LocalMusicStore.shared

    @State private var importing = false

    var body: some View {
        List {
            if store.songs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 42, weight: .light))
                        .foregroundColor(Theme.secondaryLabel)
                    Text(L("No local music"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(L("Tap + to import audio files from Files. They stay on this device."))
                        .font(.system(size: 13))
                        .foregroundColor(Theme.secondaryLabel)
                        .multilineTextAlignment(.center)
                    Button {
                        importing = true
                    } label: {
                        Text(L("Import Audio Files"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.accent)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .listRowSeparator(.hidden)
            } else {
                ForEach(Array(store.songs.enumerated()), id: \.offset) { index, track in
                    TrackRow(track: track) {
                        player.play(tracks: store.songs, startAt: index)
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        store.delete(store.songs[index])
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
        .navigationTitle(L("Local Music"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    importing = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            store.importFiles(urls)
        }
        .onAppear { store.reload() }
    }
}
