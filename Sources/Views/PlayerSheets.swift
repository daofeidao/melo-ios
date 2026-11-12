import SwiftUI

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

    private var quality: StreamResolver.Quality {
        StreamResolver.Quality(rawValue: qualityRaw) ?? .high
    }

    private var isLocalFile: Bool {
        player.currentTrack?.source == LocalMusicStore.sourceTag
    }

    var body: some View {
        NavigationView {
            List {
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
                            row(id: info.id, name: info.name, detail: detail(for: info))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(isLocalFile)
                    }

                    ForEach(prefs.customSources) { source in
                        Button {
                            player.selectSource(source.id)
                            dismiss()
                        } label: {
                            row(
                                id: source.id,
                                name: source.name,
                                detail: isLocalFile ? L("Local files need no network source") : L("Custom resolve endpoint")
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(isLocalFile)
                    }
                } header: {
                    Text(L("Source"))
                } footer: {
                    Text(isLocalFile
                         ? L("This is a local file, played straight from the device, so there is no source to switch.")
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
                .background(active ? Theme.accent.opacity(0.16) : Theme.tertiaryFill)
                .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func detail(for info: SourcePrefs.SourceInfo) -> String {
        if isLocalFile { return L("Local files need no network source") }
        if player.activeSource == info.id { return L("Currently in use") }
        if !prefs.isEnabled(info.id) { return L("Turned off in Data Sources") }
        return L("Resolve again from this source")
    }

    private func row(id: String?, name: String, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 15))
                    .foregroundColor(.primary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondaryLabel)
                    .lineLimit(1)
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
        case "netease": return "网易云音乐"
        case "qq": return "QQ 音乐"
        case "youtube": return "YouTube Music"
        default:
            return prefs.customSources.first { $0.id == id }?.name ?? id
        }
    }
}
