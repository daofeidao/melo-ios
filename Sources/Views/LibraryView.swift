import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var store: PlaylistStore
    @ObservedObject private var localMusic = LocalMusicStore.shared

    @State private var showImport = false
    @State private var showSettingsSheet = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        showImport = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(Theme.accent)
                            Text(L("Import Playlist"))
                                .foregroundColor(Theme.accent)
                            Spacer()
                        }
                    }

                    ForEach(store.playlists) { playlist in
                        NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                            PlaylistRow(playlist: playlist)
                        }
                    }
                } header: {
                    Text(L("My Playlists"))
                }

                Section {
                    NavigationLink(destination: LocalMusicView()) {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .foregroundColor(Theme.accent)
                            Text(L("Local Music"))
                            Spacer()
                            Text("\(localMusic.songs.count)")
                                .foregroundColor(Theme.secondaryLabel)
                        }
                    }
                } header: {
                    Text(L("My Music"))
                } footer: {
                    Text(L("Favorites and history live on the Listen Now page; this page keeps your imported files."))
                }

                if store.playlists.isEmpty {
                    EmptyHint(
                        symbol: "heart",
                        title: L("Your library is empty"),
                        message: L("Import a playlist link, or add audio files to Local Music.")
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle(L("Library"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showImport) {
                ImportPlaylistView()
            }
            .sheet(isPresented: $showSettingsSheet) {
                NavigationView {
                    SettingsView()
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }
            // Mac 两指下滑打开设置：由全局手势层发通知（能真正区分双指）
            .onReceive(NotificationCenter.default.publisher(for: .meloOpenSettings)) { _ in
                showSettingsSheet = true
            }
            .onAppear {
                if SmokeTest.opensImport {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        showImport = true
                    }
                }
                if SmokeTest.opensSettingsPage {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        showSettingsSheet = true
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

private enum AboutPage: String, Identifiable {
    case changelog
    case dataSources

    var id: String { rawValue }
}

struct SettingsView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @AppStorage("melo.appearance") private var appearance: String = AppearanceMode.system.rawValue
    @AppStorage(AudioCache.enabledKey) private var cacheAudio = true
    @AppStorage(AudioCache.limitKey) private var cacheLimitMB = AudioCache.defaultLimitMB
    @AppStorage(VolumeShortcut.enabledKey) private var volumeSkipEnabled = true
    #if targetEnvironment(macCatalyst)
    @AppStorage(MacGestureSettings.horizontalTabs) private var macGestureTabs = true
    @AppStorage(MacGestureSettings.horizontalTracks) private var macGestureTracks = true
    @AppStorage(MacGestureSettings.verticalVolume) private var macGestureVolume = true
    @AppStorage(MacGestureSettings.swipeDismiss) private var macGestureDismiss = true
    @AppStorage(MacGestureSettings.keyboardShortcuts) private var macKeyboardEnabled = true
    @AppStorage(MacGestureSettings.tabSwipeMode) private var macTabSwipeMode = "two-bg"
    @State private var shortcutRefresh = 0   // 重置快捷键后刷新列表
    #endif
    @State private var cacheBytes: Int64 = 0
    @State private var showClearCacheConfirm = false

    // 检查更新
    @State private var checkingUpdate = false
    @State private var updateOffer: AppUpdate.Info?
    @State private var showUpToDate = false
    /// 更新包内建下载：下载完交给系统分享面板（TrollStore 安装 / 存到文件）
    @StateObject private var updater = UpdateDownloader()

    // 备份 / 恢复
    @State private var exporting = false
    @State private var importing = false
    @State private var exportDocument: BackupDocument?
    @State private var alertTitle = ""
    @State private var alertText = ""
    @State private var showAlert = false

    // 版本号彩蛋：7 次连点（间隔超过 2.5 秒重新计数）
    @State private var versionTaps = 0
    @State private var lastVersionTap = Date.distantPast
    /// 两个「关于」页共用一个 sheet：iOS 15 上同一视图叠两个 .sheet 会互相顶掉
    @State private var aboutPage: AboutPage?

    var body: some View {
        List {
            // 外观排到最顶：换主题是最常用的设置项（说明文字已按要求去掉）
            Section {
                Picker(L("Appearance"), selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .labelsHidden()
            } header: {
                Text(L("Appearance"))
            }

            Section {
                Toggle(L("Cache played audio"), isOn: $cacheAudio)
                Picker(L("Cache limit"), selection: $cacheLimitMB) {
                    Text("200 MB").tag(200)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                    Text("3 GB").tag(3072)
                    Text("5 GB").tag(5120)
                }
                HStack {
                    Text(L("Audio cache"))
                    Spacer()
                    Text(cacheBytes > 0
                         ? ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
                         : "—")
                        .foregroundColor(Theme.secondaryLabel)
                }
                Button {
                    showClearCacheConfirm = true
                } label: {
                    Text(L("Clear audio cache"))
                        .foregroundColor(.red)
                }
            } header: {
                Text(L("Storage"))
            }

            #if !targetEnvironment(macCatalyst)
            Section {
                Toggle(L("Volume buttons: double-press to skip"), isOn: $volumeSkipEnabled)
                    .onChange(of: volumeSkipEnabled) { value in
                        VolumeShortcut.isEnabled = value
                    }
            } header: {
                Text(L("Playback"))
            } footer: {
                Text(L("Double-press volume up for the next track, volume down for the previous one. Works while a track is playing; the volume itself is put back where it was."))
            }
            #endif

            // 清空最近播放已挪到「现在就听 → 最近播放」标题右侧

            #if targetEnvironment(macCatalyst)
            Section {
                Toggle("播放页左右滑动切歌", isOn: $macGestureTracks)
                Toggle("上下滑动调节音量", isOn: $macGestureVolume)
                Toggle("播放页下滑关闭", isOn: $macGestureDismiss)
            } header: {
                Text("触控板手势")
            } footer: {
                Text("两指快滑（速度够快）才触发，慢滚翻列表不受影响。播放页左右滑切歌；上下滑调系统音量；播放页下滑关闭。")
            }

            Section {
                Picker("切栏目手势", selection: $macTabSwipeMode) {
                    Text("两指滑动（避开横向滚动）").tag("two-bg")
                    Text("三指滑动").tag("three")
                    Text("关闭").tag("off")
                }
            } header: {
                Text("栏目切换")
            } footer: {
                Text("排行榜、喜欢艺人等横向滚动区域会自动避开。「三指滑动」需在 系统设置 → 辅助功能 → 触控板 开启「三指拖移」；若系统手势拦截了三指滑动，请用「两指滑动」模式。")
            }

            Section {
                Toggle("启用键盘快捷键", isOn: $macKeyboardEnabled)
                if macKeyboardEnabled {
                    ForEach(ShortcutStore.Action.allCases, id: \.self) { action in
                        ShortcutSettingRow(action: action)
                            .id("\(action.rawValue)-\(shortcutRefresh)")
                    }
                    Button("恢复默认快捷键") {
                        ShortcutStore.resetAll()
                        shortcutRefresh += 1
                    }
                    .foregroundColor(.red)
                }
            } header: {
                Text("自定义快捷键")
            } footer: {
                Text("点「修改」后按下想要的组合键即可绑定，Esc 取消。媒体键（F7/F8/F9）始终有效不受影响。")
            }
            #endif

            Section {
                Button {
                    prepareExport()
                } label: {
                    HStack {
                        Text(L("Export Backup"))
                        Spacer()
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(Theme.secondaryLabel)
                    }
                }
                Button {
                    importing = true
                } label: {
                    HStack {
                        Text(L("Restore from Backup"))
                        Spacer()
                        Image(systemName: "square.and.arrow.down")
                            .foregroundColor(Theme.secondaryLabel)
                    }
                }
            } header: {
                Text(L("Backup & Restore"))
            } footer: {
                Text(L("Your favorites and playlists live inside the app. Installing a new build over it keeps them; deleting the app erases them. Export to Files — iCloud Drive works — so you can restore after reinstalling."))
            }

            Section {
                // 版本与检查更新合并成一行：左「版本」、中版本号、右红字「检查更新」。
                // 点左侧文字或版本号仍触发彩蛋（连点 7 次出更新记录），只有点红字才检查更新。
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Text(L("Version"))
                        Spacer(minLength: 8)
                        Text("v\(AppUpdate.currentVersion)")
                            .foregroundColor(Theme.secondaryLabel)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { registerVersionTap() }

                    Button {
                        checkForUpdates()
                    } label: {
                        Text(checkingUpdate ? L("Checking…") : L("Check for Updates"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color(hex: 0xE0455E))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(checkingUpdate)
                }

                HStack {
                    Text(L("Author"))
                    Spacer()
                    Text("张宏亮")
                        .foregroundColor(Theme.secondaryLabel)
                }

            } header: {
                Text(L("About"))
            }

            Section {
                Text(L("This app is for personal study only. Please delete the downloaded files within 24 hours. If there is any copyright concern, contact the developer for removal."))
                    .font(.system(size: 13))
                    .foregroundColor(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(L("Disclaimer"))
            }
        }
        .listStyle(InsetGroupedListStyle())
        #if targetEnvironment(macCatalyst)
        // Mac：滚到列表底部后继续下拉就退出设置
        .background(SettingsOverScrollDetector { dismiss() })
        #endif
        .navigationTitle(L("Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: .meloDismissSettings)) { _ in
            dismiss()
        }
        .onAppear {
            refreshCacheSize()
            if SmokeTest.showsChangelog { aboutPage = .changelog }
            if SmokeTest.showsDataSources { aboutPage = .dataSources }
            if SmokeTest.showsChangelog || SmokeTest.showsDataSources {
                NSLog("SMOKE_ABOUT changelog=\(SmokeTest.showsChangelog) sources=\(SmokeTest.showsDataSources)")
            }
            guard SmokeTest.runsPlaybackTest, DiagnosticsModel.shared.playbackLines.isEmpty else { return }
            Task { await DiagnosticsModel.shared.runPlaybackTest() }
        }
        .onChange(of: cacheLimitMB) { _ in
            // 上限调小后立刻淘汰，不能等下次下载才生效
            AudioCache.shared.enforceLimit()
            refreshCacheSize()
        }
        .confirmationDialog(
            L("Clear audio cache?"),
            isPresented: $showClearCacheConfirm,
            titleVisibility: .visible
        ) {
            Button(L("Clear"), role: .destructive) {
                AudioCache.shared.clear()
                cacheBytes = 0
            }
            Button(L("Cancel"), role: .cancel) {}
        }
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: BackupService.defaultFileName()
        ) { result in
            switch result {
            case .success:
                show(title: L("Backup & Restore"), message: L("Backup saved. Keep it in Files or iCloud Drive."))
            case .failure(let error):
                show(
                    title: L("Backup & Restore"),
                    message: String(format: L("Export failed: %@"), error.localizedDescription)
                )
            }
        }
        // 允许类型放宽一点：有些机器上导出的文件没有 .json 扩展名，
        // 只给 .json 的话它在文件选择器里是灰的，看起来就像「没法恢复」
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data, .plainText]) { result in
            switch result {
            case .success(let url):
                restore(from: url)
            case .failure(let error):
                show(
                    title: L("Backup & Restore"),
                    message: String(format: L("Restore failed: %@"), error.localizedDescription)
                )
            }
        }
        .alert(
            updateOffer.map { String(format: L("New version %@"), $0.version) } ?? "",
            isPresented: Binding(
                get: { updateOffer != nil },
                set: { if !$0 { updateOffer = nil } }
            ),
            presenting: updateOffer
        ) { info in
            Button(L("Download")) {
                // 在 App 内直接下载，不跳浏览器；下载完弹系统分享面板
                updater.downloadAndShare(info)
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: { info in
            Text(String(info.notes.prefix(600)))
        }
        .overlay {
            if case .downloading = updater.phase {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView(value: updater.progress)
                            .frame(width: 180)
                        Text(String(format: L("Downloading %d%%"), Int(updater.progress * 100)))
                            .font(.system(size: 13))
                            .foregroundColor(Theme.secondaryLabel)
                        Button(L("Cancel")) { updater.cancel() }
                            .font(.system(size: 13))
                    }
                    .padding(20)
                    .background(Theme.groupedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .onChange(of: updater.phase) { phase in
            if case .failed(let message) = phase {
                show(title: L("Download failed."), message: message)
            }
        }
        .alert(L("Up to date"), isPresented: $showUpToDate) {
            Button(L("Done"), role: .cancel) {}
        } message: {
            Text(L("You are on the latest version."))
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button(L("Done"), role: .cancel) {}
        } message: {
            Text(alertText)
        }
        .sheet(item: $aboutPage) { page in
            switch page {
            case .changelog:
                ChangelogView()
            case .dataSources:
                NavigationView {
                    DataSourcesView()
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }
        }
    }

    private func refreshCacheSize() {
        DispatchQueue.global(qos: .utility).async {
            let bytes = AudioCache.shared.size()
            DispatchQueue.main.async { cacheBytes = bytes }
        }
    }

    /// 连点 7 次才打开更新记录。中间停顿超过 2.5 秒就重新计数，
    /// 免得平时误触把页面弹出来。

    private func checkForUpdates() {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        Task {
            updateOffer = await AppUpdate.check(current: AppUpdate.currentVersion)
            checkingUpdate = false
            if updateOffer == nil { showUpToDate = true }
        }
    }

    private func registerVersionTap() {        let now = Date()
        if now.timeIntervalSince(lastVersionTap) > 2.5 { versionTaps = 0 }
        lastVersionTap = now
        versionTaps += 1
        if versionTaps >= 7 {
            versionTaps = 0
            aboutPage = .changelog
        }
    }

    private func prepareExport() {
        do {
            exportDocument = BackupDocument(data: try BackupService.encoded())
            exporting = true
        } catch {
            show(
                title: L("Backup & Restore"),
                message: String(format: L("Export failed: %@"), error.localizedDescription)
            )
        }
    }

    private func restore(from url: URL) {
        do {
            let summary = try BackupService.restore(from: url)
            show(title: L("Backup & Restore"), message: summary.text)
        } catch {
            show(
                title: L("Backup & Restore"),
                message: String(format: L("Restore failed: %@"), error.localizedDescription)
            )
        }
    }

    private func show(title: String, message: String) {
        alertTitle = title
        alertText = message
        showAlert = true
    }
}

#if targetEnvironment(macCatalyst)
/// Mac：设置页滚到列表底部后，继续下拉就退出设置。
/// SwiftUI List 没有 scroll offset API，这里沿响应链找到底层 UIScrollView，
/// KVO 监听 contentOffset：当已经滚到底（contentOffset ≥ 最大）且还被继续下拉
/// （overscroll 超过阈值）时回调 dismiss。单指滚动/触控板滚动都能触发。
struct SettingsOverScrollDetector: UIViewRepresentable {
    let onOverScroll: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOverScroll: onOverScroll) }

    func makeUIView(context: Context) -> UIView {
        let probe = UIView(frame: .zero)
        probe.backgroundColor = .clear
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ probe: UIView, context: Context) {
        context.coordinator.onOverScroll = onOverScroll
        DispatchQueue.main.async { context.coordinator.attach(to: probe) }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject {
        var onOverScroll: () -> Void
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var didTrigger = false

        init(onOverScroll: @escaping () -> Void) { self.onOverScroll = onOverScroll }

        private func findScrollView(from view: UIView) -> UIScrollView? {
            // 先沿 superview 链
            var current: UIView? = view
            while let v = current {
                if let sv = v as? UIScrollView, sv.contentSize.height > sv.bounds.height + 1 {
                    return sv
                }
                current = v.superview
            }
            // SwiftUI 的 List 底层的滚动视图不一定在 probe 的祖先链上，
            // 再从 window 深搜一个真正可纵向滚动的（List 底层是 UICollectionView/UITableView，
            // 都是 UIScrollView 子类）。
            guard let root = view.window else { return nil }
            return Self.deepestScrollView(in: root)
        }

        private static func deepestScrollView(in view: UIView) -> UIScrollView? {
            if let sv = view as? UIScrollView, sv.contentSize.height > sv.bounds.height + 1 {
                return sv
            }
            for sub in view.subviews {
                if let found = deepestScrollView(in: sub) { return found }
            }
            return nil
        }

        func attach(to probe: UIView) {
            guard let sv = findScrollView(from: probe) else {
                // 视图层级可能还没建好，稍后再试（避免永远 attach 不上）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak probe] in
                    guard let self = self, let probe = probe else { return }
                    self.attach(to: probe)
                }
                return
            }
            guard scrollView !== sv else { return }
            detach()
            scrollView = sv
            observation = sv.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                guard let self = self else { return }
                let maxY = scroll.contentSize.height - scroll.bounds.height
                // 已经越过了底部最大偏移，且被继续往下拉超过 44pt
                if maxY > 0 && scroll.contentOffset.y > maxY + 44 && !self.didTrigger {
                    self.didTrigger = true
                    Diagnostics.mark("settings overscroll -> dismiss")
                    DispatchQueue.main.async { self.onOverScroll() }
                }
                // 回到正常范围内可再次触发
                if scroll.contentOffset.y <= maxY + 10 {
                    self.didTrigger = false
                }
            }
            Diagnostics.mark("settings overscroll detector attached")
        }

        func detach() {
            observation?.invalidate()
            observation = nil
        }
    }
}
#endif
