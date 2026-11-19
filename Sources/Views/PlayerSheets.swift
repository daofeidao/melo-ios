import SwiftUI
import UIKit

/// 播放页左下角入口：播放历史与待播清单合成一个浮层，顶部用分段切换。
/// 两者都是「这一轮播放的上下文」，分开放会白占一个按钮位。
struct PlayerLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Mac 自定义浮层下由外层注入关闭动作；iOS 无此值则退回 dismiss()
    @Environment(\.meloSheetClose) private var sheetClose
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
                    Button(L("Close")) { if let sheetClose { sheetClose() } else { dismiss() } }
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
    @Environment(\.meloSheetClose) private var sheetClose
    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var prefs = SourcePrefs.shared

    /// 三模式切换：默认源 / 自动换源 / 指定源。全局偏好，存本地。
    @AppStorage("melo.resolveMode") private var modeRaw = ResolveMode.defaultSource.rawValue
    private var mode: ResolveMode { ResolveMode(rawValue: modeRaw) ?? .defaultSource }

    /// 「可播放版本」一屏最多摆这么多条，其余折起来
    private static let alternativesPreview = 4
    @State private var showAllAlternatives = false

    private var visibleAlternatives: [Track] {
        showAllAlternatives
            ? player.alternatives
            : Array(player.alternatives.prefix(Self.alternativesPreview))
    }

    private var isLocalFile: Bool {
        player.currentTrack?.source == LocalMusicStore.sourceTag
    }

    /// 当前曲目绑定的唯一源。锁定时不显示跨源候选和换源列表。
    private var binding: SourceRouting.Binding? {
        guard let track = player.currentTrack else { return nil }
        return SourceRouting.binding(for: track)
    }

    private var isLocked: Bool { binding?.locked ?? false }

    /// 非锁定曲目：源按「当前使用 → 可用（质量顺序）→ 不可用（灰、沉底）」排列。
    /// 内置源本就按质量/命中率排序，这里只做三分区，不打乱内部顺序。
    private struct SourceEntry: Identifiable {
        let id: String
        let name: String
        let available: Bool
        var isCustom: Bool = false
    }

    private var orderedSources: [SourceEntry] {
        let active = player.activeSource
        var available: [SourceEntry] = []
        var unavailable: [SourceEntry] = []

        for info in prefs.builtIn {
            let ok = prefs.isEnabled(info.id)
            let entry = SourceEntry(id: info.id, name: info.name, available: ok)
            if ok { available.append(entry) } else { unavailable.append(entry) }
        }
        for source in prefs.customSources {
            let entry = SourceEntry(id: source.id, name: source.name, available: true, isCustom: true)
            available.append(entry)
        }

        // 当前正在用的源提到最前
        available.sort { a, b in
            if a.id == active { return true }
            if b.id == active { return false }
            return false
        }
        return available + unavailable
    }

    var body: some View {
        NavigationView {
            List {
                // MARK: 三模式切换（全局偏好）
                Section {
                    Picker("", selection: $modeRaw) {
                        ForEach(ResolveMode.allCases) { m in
                            Text(m.label).tag(m.rawValue)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 14))
                            .foregroundColor(Theme.accent)
                            .frame(width: 20)
                        Text(mode.explain)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.secondaryLabel)
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text(L("Source Switch Mode"))
                }

                // MARK: 当前实际使用的源（第一行高亮）
                if let binding = binding, isLocked, mode != .auto {
                    // 来源绑定：YouTube / 艺人，始终显示它的唯一源
                    Section {
                        row(id: binding.sourceID,
                            name: SourceNames.label(binding.sourceID),
                            detail: L("Currently in use · locked"))
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.secondaryLabel)
                            Text(binding.reason)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.secondaryLabel)
                        }
                    } header: {
                        Text(L("Source"))
                    }
                } else {
                    // 默认源 / 自动换源 / 指定源：列出源，当前使用高亮第一行
                    Section {
                        ForEach(orderedSources) { entry in
                            if entry.available {
                                Button {
                                    selectSource(entry.id)
                                } label: {
                                    sourceRow(entry)
                                }
                                .buttonStyle(PlainButtonStyle())
                            } else {
                                sourceRow(entry)   // 不可用：灰显、不挂点击
                            }
                        }
                    } header: {
                        Text(L("Source"))
                    } footer: {
                        Text(L("The source in use is highlighted first. Available sources follow in quality order; unavailable ones are greyed out at the bottom."))
                    }
                }

                // MARK: 可播放版本（仅自动/默认源模式，指定源与绑定锁定时不显示）
                if !player.alternatives.isEmpty && !isLocked && mode != .pinned {
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
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle(L("Playback Source"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Close")) { if let sheetClose { sheetClose() } else { dismiss() } }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    /// 点选一个源：
    /// - 指定源模式 → 写全局 pinned 源，重新解析当前曲
    /// - 其余模式 → 单曲临时换源
    private func selectSource(_ id: String) {
        if mode == .pinned {
            ResolveModeStore.pinnedSource = id
        }
        player.selectSource(id)
        dismiss()
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

    /// 源列表一行。当前正在使用的源：强调色背景 + 粗体 + 勾选；不可用的灰显。
    private func sourceRow(_ entry: SourceEntry) -> some View {
        let inUse = entry.id == player.activeSource
        let detail: String = !entry.available
            ? L("Unavailable · turned off in settings")
            : inUse ? L("Currently in use") : L("Tap to use this source")

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.system(size: 15, weight: inUse ? .semibold : .regular))
                    .foregroundColor(entry.available ? (inUse ? Theme.accent : .primary) : Theme.secondaryLabel)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(entry.available ? Theme.secondaryLabel : Theme.secondaryLabel.opacity(0.7))
            }
            Spacer(minLength: 4)
            if inUse {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.accent)
            }
        }
        .padding(.vertical, inUse ? 6 : 2)
        .padding(.horizontal, inUse ? 6 : 0)
        .background(inUse ? Theme.accent.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    /// 锁定分支那一行（信息展示，不可点），同样高亮当前源。
    private func row(id: String?, name: String, detail: String, dimmed: Bool = false) -> some View {
        let inUse = id == player.activeSource || isLocked
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 15, weight: inUse ? .semibold : .regular))
                    .foregroundColor(inUse ? Theme.accent : .primary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondaryLabel)
            }
            Spacer(minLength: 4)
            if inUse {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.accent)
            }
        }
        .padding(.vertical, inUse ? 6 : 2)
        .background(inUse ? Theme.accent.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}
