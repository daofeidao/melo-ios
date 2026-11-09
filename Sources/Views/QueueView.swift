import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(Array(player.queue.enumerated()), id: \.offset) { index, track in
                    Button {
                        player.jump(to: index)
                    } label: {
                        HStack(spacing: 12) {
                            if player.index == index {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.accent)
                                    .frame(width: 16)
                            } else {
                                Text("\(index + 1)")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.secondaryLabel)
                                    .frame(width: 16)
                                    .monospacedDigit()
                            }
                            ArtworkView(url: track.artwork, size: 42, corner: 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.system(size: 15))
                                    .foregroundColor(player.index == index ? Theme.accent : .primary)
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.secondaryLabel)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text(track.durationText)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.secondaryLabel)
                                .monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .listStyle(PlainListStyle())
            .navigationTitle("待播清单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
