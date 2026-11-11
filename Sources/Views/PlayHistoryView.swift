import SwiftUI

/// 播放历史清单：从播放页左下角进入，和中间的「待播清单」成对。
struct PlayHistoryView: View {
    @ObservedObject private var history = PlayHistory.shared
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    @State private var showClearConfirm = false

    var body: some View {
        NavigationView {
            Group {
                if history.entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 30))
                            .foregroundColor(Theme.tertiaryLabel)
                        Text(L("No play history yet"))
                            .font(.system(size: 15))
                            .foregroundColor(Theme.secondaryLabel)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(history.groupedByDay, id: \.title) { group in
                            Section {
                                ForEach(group.items) { entry in
                                    Button {
                                        player.playSingle(entry.track)
                                        dismiss()
                                    } label: {
                                        row(entry)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            } header: {
                                Text(group.title)
                            }
                        }
                    }
                    .listStyle(PlainListStyle())
                }
            }
            .navigationTitle(L("Play History"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !history.entries.isEmpty {
                        Button(L("Clear")) { showClearConfirm = true }
                            .foregroundColor(.red)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Done")) { dismiss() }
                }
            }
            .alert(isPresented: $showClearConfirm) {
                Alert(
                    title: Text(L("Clear play history?")),
                    message: Text(L("This only clears the history list. Favorites and playlists are untouched.")),
                    primaryButton: .destructive(Text(L("Clear"))) { history.clear() },
                    secondaryButton: .cancel(Text(L("Cancel")))
                )
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func row(_ entry: PlayHistoryEntry) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: entry.track.artwork, size: 42, corner: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.track.title)
                    .font(.system(size: 15))
                    // 正在播的那首标成强调色，和待播清单的规则一致
                    .foregroundColor(player.currentTrack?.id == entry.track.id ? Theme.accent : .primary)
                    .lineLimit(1)
                Text(entry.track.artist)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Self.time(entry.playedAt))
                .font(.system(size: 12))
                .foregroundColor(Theme.secondaryLabel)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("HHmm")
        return formatter.string(from: date)
    }
}
