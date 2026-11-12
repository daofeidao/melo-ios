import SwiftUI

/// 播放历史清单。独立使用时自带导航外壳；被播放页的分段浮层嵌入时只给列表内容，
/// 外壳（标题、关闭、清空）交给外面那一层，避免两层导航栏叠在一起。
struct PlayHistoryView: View {
    var embedded: Bool = false

    @ObservedObject private var history = PlayHistory.shared
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    @State private var showClearConfirm = false

    var body: some View {
        if embedded {
            content
        } else {
            NavigationView {
                content
                    .navigationTitle(L("Play History"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button(L("Done")) { dismiss() }
                        }
                    }
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
    }

    private var content: some View {
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

                    // 清空做成列表最后一行：嵌入到分段浮层里时没有导航栏放按钮
                    Section {
                        Button {
                            showClearConfirm = true
                        } label: {
                            Text(L("Clear"))
                                .font(.system(size: 15))
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }
                .listStyle(PlainListStyle())
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
