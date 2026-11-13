import SwiftUI
import UIKit

/// 播放页左下角入口：播放历史与待播清单合成一个浮层，顶部用分段切换。
/// 两者都是「这一轮播放的上下文」，分开放会白占一个按钮位。
struct PlayerLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerEngine

    @State private var tab = 0

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text(L("Play History")).tag(0)
                    Text(L("Up Next")).tag(1)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if tab == 0 {
                    PlayHistoryView(embedded: true)
                } else {
                    QueueView(embedded: true)
                }
            }
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

/// 播放页底部中间的入口（图标沿用原来的列表图标）：选音源 + 选音质。
///
/// 音质放在这里而不是只放设置里，是因为这两件事在用户心里是同一个问题
/// ——「这首现在怎么听」。换音质会立即重新解析当前这一首。
struct PlayerSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var prefs = SourcePrefs.shared

    @AppStorage("melo.quality") private var qualityRaw = StreamResolver.Quality.high.rawValue

    /// 「可播放版本」一屏最多摆这么多条，其余折起来
    private static let alternativesPreview = 4
    @State private var showAllAlternatives = false

    private var visibleAlternatives: [Track] {
        showAllAlternatives
            ? player.alternatives
            : Array(player.alternatives.prefix(Self.alternativesPreview))
    }

    private var quality: StreamResolver.Quality {
        StreamResolver.Quality(rawValue: qualityRaw) ?? .high
    }

    private var isLocalFile: Bool {
        player.currentTrack?.source == LocalMusicStore.sourceTag
    }

    var body: some View {
        NavigationView {
            List {
                // 播放失败时能直接播的版本放最上面（在「音质」之上），
                // 播放页本身只留一行提示，不再把候选堆在进度条上方。
                // 这些是「同名不同版本」，属于次要信息：默认只露 4 条，
                // 再多就把下面的音源列表顶出屏幕，用户真正要点的「换音源」反而看不见。
                if !player.alternatives.isEmpty {
                    Section {
                        ForEach(visibleAlternatives) { candidate in
                            Button {
                                player.playAlternative(candidate)
                                dismiss()
                            } label: {
                                alternativeRow(candidate)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        if player.alternatives.count > Self.alternativesPreview {
                            Button {
                                showAllAlternatives.toggle()
                            } label: {
                                Text(showAllAlternatives
                                     ? L("Show less")
                                     : String(format: L("Show all %d versions"),
                                              player.alternatives.count))
                                    .font(.system(size: 14))
                                    .foregroundColor(Theme.accent)
                            }
                        }
                    } header: {
                        HStack {
                            Text(L("Playable versions"))
                            Spacer()
                            Text("\(player.alternatives.count)")
                                .foregroundColor(.secondary)
                        }
                    } footer: {
                        Text(L("These versions came back from the sources and can be played right away."))
                    }
                }

                Section {
                    HStack(spacing: 8) {
                        ForEach(StreamResolver.Quality.allCases) { option in
                            qualityButton(option)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text(L("Quality"))
                } footer: {
                    Text(quality.detail)
                }

                Section {
                    Button {
                        player.selectSource(nil)
                        dismiss()
                    } label: {
                        row(
                            id: nil,
                            name: L("Auto"),
                            detail: player.activeSource.map {
                                String(format: L("Automatic · currently %@"), sourceLabel($0))
                            } ?? L("Tries the built-in sources in order")
                        )
                    }
                    .buttonStyle(PlainButtonStyle())

                    ForEach(prefs.builtIn) { info in
                        Button {
                            player.selectSource(info.id)
                            dismiss()
                        } label: {
                            row(
                                id: info.id,
                                name: info.name,
                                detail: detail(for: info),
                                dimmed: !prefs.supports(info.id, quality: quality)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    ForEach(prefs.customSources) { source in
                        Button {
                            player.selectSource(source.id)
                            dismiss()
                        } label: {
                            row(
                                id: source.id,
                                name: source.name,
                                detail: isLocalFile ? L("Play online from this source") : L("Custom resolve endpoint")
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                } header: {
                    Text(L("Source"))
                } footer: {
                    Text(isLocalFile
                         ? L("This is a local file. Pick an online source to stream it instead; Auto plays the local file again.")
                         : L("A manually picked source stays pinned to this song. If it cannot serve the track the app tells you instead of silently switching back."))
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle(L("Playback Source"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    /// 单独抽出来，避免 List 里内联复杂 HStack 触发 Swift 类型检查超时
    private func alternativeRow(_ candidate: Track) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(candidate.artist)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("\(candidate.source ?? "?") · \(candidate.durationText)")
                .font(.system(size: 11))
                .foregroundColor(Theme.secondaryLabel)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    /// 单独抽成方法：这段内联在 ForEach 里会让类型检查超时（实测 Swift 5.9 编译失败）
    private func qualityButton(_ option: StreamResolver.Quality) -> some View {
        let active = option == quality
        return Button {
            qualityRaw = option.rawValue
            player.reloadForQuality()
        } label: {
            Text(option.label)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundColor(active ? Theme.accent : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(active ? Theme.accent.opacity(0.16) : Color(UIColor.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func detail(for info: SourcePrefs.SourceInfo) -> String {
        // 灰 ≠ 不可点：这一档它给不了，只提示，用户照样可以点
        if !prefs.supports(info.id, quality: quality) {
            return String(format: L("This source has no %@ — it will still try, and may fall back or fail."), quality.label)
        }
        if isLocalFile { return L("Play online from this source") }
        if player.activeSource == info.id { return L("Currently in use") }
        if !prefs.isEnabled(info.id) { return L("Turned off in Data Sources") }
        return L("Resolve again from this source")
    }

    private func row(id: String?, name: String, detail: String, dimmed: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 15))
                    .foregroundColor(dimmed ? Theme.secondaryLabel : .primary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(dimmed ? Theme.secondaryLabel.opacity(0.75) : Theme.secondaryLabel)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if player.preferredSource == id {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private func sourceLabel(_ id: String) -> String {
        switch id {
        case "local": return L("Local Music")
        case "cache": return L("Local cache")
        case "kugou": return "酷狗音乐"
        case "kuwo": return "酷我音乐"
        case "flachi": return "Hi·FLAC"
        case "netease": return "网易云音乐"
        case "qq": return "QQ 音乐"
        case "youtube": return "YouTube Music"
        default:
            return prefs.customSources.first { $0.id == id }?.name ?? id
        }
    }
}
