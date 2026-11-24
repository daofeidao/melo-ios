import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlayerEngine

    @State private var selection = 0
    @State private var showSettings = false
    @State private var showWebProbe = false

    /// 自定义 selection 绑定：拦截「重选已选中 tab」的事件。
    /// 系统默认不会为同值变化触发 onChange，但绑定 setter 仍会被调用，
    /// 借此在重选 Search tab（tag 3）时通知 SearchCoordinator 回到根界面。
    private var tabSelection: Binding<Int> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue == selection {
                    // 重选了同一个 tab：Search / Library 都要 pop 回自己的根界面
                    Diagnostics.mark("tab reselect -> \(newValue)")
                    if newValue == 3 {
                        SearchCoordinator.shared.popToRoot()
                    } else if newValue == 2 {
                        LibraryCoordinator.shared.popToRoot()
                    }
                } else {
                    selection = newValue
                }
            }
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: tabSelection) {
                ListenNowView()
                    // 固定条，不悬浮：safeAreaInset 会让内容自己让位，不再盖住列表。
                    // 只挂在「现在就听」上，其他栏目不再出现。
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if player.hasTrack {
                            MiniPlayerBar(showPlayer: $player.opensFullPlayer)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 6)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .tabItem { Label(L("Listen Now"), systemImage: "play.circle.fill") }
                    .tag(0)

                ChartsView()
                    .tabItem { Label(L("Charts"), systemImage: "dot.radiowaves.left.and.right") }
                    .tag(1)

                LibraryView()
                    .tabItem { Label(L("Library"), systemImage: "music.note.list") }
                    .tag(2)

                SearchView()
                    .tabItem { Label(L("Search"), systemImage: "magnifyingglass") }
                    .tag(3)
            }
            // 冒烟测试专用入口：挂在 TabView 上，避免和播放页的 fullScreenCover 抢同一个宿主
            .fullScreenCover(isPresented: $showWebProbe) {
                NavigationView {
                    YouTubeWebProbeView(autoRun: true)
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }

            // 后台导入的进度条：导入改成后台任务后，这里是唯一的进度出口
            ImportBanner()
        }
        // 兜底识别「再点一次当前 tab」：SwiftUI 的 selection 绑定在部分系统版本上
        // 重选同值不一定回调，这里直接在 UITabBar 上收一层点击，两条路都能回根页。
        .background(
            TabBarReselectCatcher { index in
                Diagnostics.mark("tab bar reselect -> \(index)")
                if index == 2 { LibraryCoordinator.shared.popToRoot() }
                if index == 3 { SearchCoordinator.shared.popToRoot() }
            }
        )
        #if targetEnvironment(macCatalyst)
        // Mac：改用 overlay 打开播放页。fullScreenCover 在 Catalyst 上的呈现
        // 链路（转场 + presented VC）是「一点播放条就退」的另一嫌疑，直接绕开。
        // 顶出来的效果一致：整屏盖住，播放页里下滑/点箭头收起。
        .overlay(
            Group {
                if player.opensFullPlayer {
                    // environmentObject 会自动透传，这里不用再手动塞。
                    // 必须显式撑满 overlay，否则 ZStack 缺尺寸约束会被压成 0×0 ——
                    // 这就是「播放器界面看不见」的根因。
                    PlayerView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                        .zIndex(999)
                        .transition(.opacity)
                }
            }
        )
        #else
        .fullScreenCover(isPresented: $player.opensFullPlayer) {
            PlayerView()
        }
        #endif
        .sheet(isPresented: $showSettings) {
            NavigationView {
                SettingsView()
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
        // 切栏目：Mac 手势、播放页跳艺人页都走这个通知。两端都要接，
        // 以前放在 #if macCatalyst 里，iOS 真机上发通知没人收。
        .onReceive(NotificationCenter.default.publisher(for: .meloSwitchTab)) { note in
            if let index = note.userInfo?["index"] as? Int {
                selection = index
            }
        }
        // 播放页点艺人：先切回「现在就听」再把名字交给隐藏 NavigationLink 推栈。
        // 这样无论从哪个 tab 打开播放页，关掉后都能进艺人页。
        .onReceive(NotificationCenter.default.publisher(for: .meloOpenArtist)) { note in
            guard let name = note.userInfo?["name"] as? String, !name.isEmpty else { return }
            selection = 0
            // 先清再设：万一上一次的 pending 没被消费干净，清一下保证这次一定能推栈
            ArtistRouter.shared.pending = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                ArtistRouter.shared.pending = name
            }
        }
        #if targetEnvironment(macCatalyst)
        // 点击 tab 也要同步记录，否则手势切栏目会算错目标
        .onChange(of: selection) { newValue in
            UserDefaults.standard.set(newValue, forKey: "melo.mac.currentTab")
        }
        #endif
        .onAppear {
            runSmokeTestIfNeeded()
            AudioSource.warmUp()
            // 进 App 就在后台把热门歌单的内容抓下来，点开排行榜卡片直接有列表。
            // 用 detached：解析几千首 JSON 不该占主线程。
            Task.detached(priority: .utility) {
                await ChartLibrary.shared.prefetchHot()
            }
        }
        .animation(.easeOut(duration: 0.22), value: player.hasTrack)
    }

    private func runSmokeTestIfNeeded() {
        // YouTube 链路自检：带 -yt-selftest <videoId> 启动时跑一遍，结果只写日志
        if let vid = YouTubeSelfTest.videoId {
            Task { await YouTubeSelfTest.run(vid) }
        }
        // 各项冒烟动作互相独立，不能用 guard 提前返回
        if SmokeTest.opensYouTubeWebProbe {
            // 页面加载 + 等 player response，至少要 10 秒，这里只负责把页面弹出来
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                showWebProbe = true
            }
            return
        }
        if let tab = SmokeTest.initialTab {
            selection = tab
        }
        if SmokeTest.searchQuery != nil, SmokeTest.initialTab == nil {
            selection = 3
        }
        if SmokeTest.seedsPlaylist {
            PlaylistStore.shared.seedForSmokeTest()
        }
        if SmokeTest.seedsFavorites {
            Library.shared.seedFavoritesForSmokeTest()
        }
        if SmokeTest.seedsCollections {
            Library.shared.seedCollectionsForSmokeTest()
            NSLog("SMOKE_COLLECTIONS saved=\(Library.shared.savedCollections.count)")
        }
        if SmokeTest.runsBackupTest {
            runBackupRoundTrip()
        }
        if SmokeTest.checksChartCache {
            Task {
                let netease = ChartFeed.shared.cached(.netease)?.count ?? 0
                let qq = ChartFeed.shared.cached(.qq)?.count ?? 0
                let kugou = ChartFeed.shared.cached(.kugou)?.count ?? 0
                NSLog("SMOKE_CHART_CACHE netease=\(netease) qq=\(qq) kugou=\(kugou) fresh=\(ChartFeed.shared.isFresh)")
                let list = (try? await HotPlaylists.fetch(.kugou)) ?? []
                let usable = list.compactMap { $0.cover }.filter { !$0.contains("{size}") }.count
                NSLog("SMOKE_CHART_COVERS total=\(list.count) usable=\(usable)")
            }
        }
        if SmokeTest.runsKugouCheck {
            selection = 1
            Task {
                let list = (try? await HotPlaylists.fetch(.kugou)) ?? []
                var tracks = 0
                var firstName = "-"
                if let first = list.first {
                    firstName = first.name
                    let remote = try? await PlaylistFetcher.fetch(
                        platform: .kugou,
                        id: first.playlistID,
                        isRank: first.isRank
                    )
                    tracks = remote?.songs.count ?? 0
                }
                NSLog("SMOKE_KUGOU_CHART playlists=\(list.count) first=\(firstName) tracks=\(tracks)")
            }
            return
        }

        if let cat = SmokeTest.playGenre {
            selection = 3
            Task {
                guard let list = try? await HotPlaylists.fetch(.netease, cat: cat), let first = list.first else {
                    NSLog("SMOKE_GENRE cat=\(cat) playlists=0")
                    return
                }
                let remote = try? await PlaylistFetcher.fetch(platform: first.platform, id: first.playlistID)
                let tracks = PlaylistMatcher.direct(songs: remote?.songs ?? [])
                NSLog("SMOKE_GENRE cat=\(cat) playlists=\(list.count) tracks=\(tracks.count)")
                guard let track = tracks.first else { return }
                NSLog("SMOKE_GENRE first=\(track.title) source=\(track.source ?? "-") id=\(track.sourceID ?? "-")")
                await MainActor.run {
                    player.play(tracks: tracks, startAt: 0)
                }
            }
            return
        }

        if let songID = SmokeTest.neteaseSongID {
            Task {
                guard let track = await AudioSource.netEaseTrack(id: songID) else { return }
                await MainActor.run {
                    player.play(tracks: [track], startAt: 0)
                    if SmokeTest.presentsPlayer {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                            player.opensFullPlayer = true
                        }
                    }
                }
            }
            return
        }

        if let query = SmokeTest.playSearchQuery {
            Task {
                guard let tracks = try? await InnerTube.shared.searchSongs(query: query),
                      let first = tracks.first else { return }
                await MainActor.run {
                    player.play(tracks: [first], startAt: 0)
                    if SmokeTest.presentsPlayer {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                            player.opensFullPlayer = true
                        }
                    }
                }
            }
            return
        }

        if let videoId = SmokeTest.autoPlayVideoId {
            player.play(tracks: [SmokeTest.makeTrack(videoId: videoId)], startAt: 0)

            if SmokeTest.presentsPlayer {
                DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
                    player.opensFullPlayer = true
                }
            }
        }

        if SmokeTest.showsSettings {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                showSettings = true
            }
        }
        // 关于页的两个子页面：直接由根视图弹设置页，不依赖「先切到资料库 tab」。
        // 冒烟启动默认停在首页，走 LibraryView 的延迟 sheet 永远等不到。
        if SmokeTest.showsChangelog || SmokeTest.showsDataSources {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                showSettings = true
            }
        }
    }

    /// 备份往返：编码 → 写文件 → 解码 → 覆盖回内存，确认收藏/歌单没在 Codable 上丢东西
    private func runBackupRoundTrip() {
        Library.shared.toggleFavorite(SmokeTest.makeTrack(videoId: "backupProbe"))
        do {
            let data = try BackupService.encoded()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("melo-backup-probe.json")
            try data.write(to: url, options: .atomic)
            let summary = try BackupService.restore(from: url)
            NSLog("SMOKE_BACKUP ok bytes=\(data.count) favorites=\(summary.favorites) recent=\(summary.recent) playlists=\(summary.playlists)")
        } catch {
            NSLog("SMOKE_BACKUP failed \(error)")
        }
    }
}

/// 在 UITabBar 上补一层「再点一次当前 tab」识别。
///
/// SwiftUI 的 `TabView` 在部分系统版本上重选同值不会回调 selection 绑定的 setter，
/// 「点资料库回首页」就完全没反应。这里用一条独立通道兜底：找到窗口里的 `UITabBar`，
/// 加一个不吞事件的点击手势，命中当前选中项就回调。
/// 只用公开 API（items / selectedItem / subviews 布局），不依赖私有类名；
/// Mac Catalyst 的 TabView 不是 UITabBar，找不到就自然不生效。
struct TabBarReselectCatcher: UIViewRepresentable {
    let onReselect: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onReselect: onReselect) }

    func makeUIView(context: Context) -> UIView {
        let probe = UIView(frame: .zero)
        probe.backgroundColor = .clear
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ probe: UIView, context: Context) {
        context.coordinator.onReselect = onReselect
        DispatchQueue.main.async { context.coordinator.install(from: probe) }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onReselect: (Int) -> Void
        private weak var tabBar: UITabBar?
        private var tap: UILongPressGestureRecognizer?
        private var attempts = 0
        /// 按下瞬间的命中项与「当时是否已选中」——抬手前系统还没改选中项，判定才准
        private var pendingIndex: Int?
        private var pendingWasSelected = false

        init(onReselect: @escaping (Int) -> Void) { self.onReselect = onReselect }

        func install(from probe: UIView) {
            if tabBar != nil { return }
            guard attempts < 20 else { return }
            guard let window = probe.window, let bar = Self.findTabBar(in: window) else {
                attempts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak probe] in
                    guard let self = self, let probe = probe else { return }
                    self.install(from: probe)
                }
                return
            }
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            // 用 0 秒长按当「按下/抬起」探针：能在触摸开始时就读到旧的选中项，
            // 而 UITapGestureRecognizer 只在抬手后回调，那时选中项可能已经变了。
            gesture.minimumPressDuration = 0
            gesture.cancelsTouchesInView = false   // 点击照常传给 tab bar，不影响正常切换
            gesture.delegate = self
            bar.addGestureRecognizer(gesture)
            tabBar = bar
            tap = gesture
        }

        func remove() {
            if let tap = tap, let bar = tabBar { bar.removeGestureRecognizer(tap) }
            tap = nil
            tabBar = nil
        }

        private static func findTabBar(in view: UIView) -> UITabBar? {
            if let bar = view as? UITabBar, !bar.isHidden, (bar.items?.count ?? 0) > 0 { return bar }
            for sub in view.subviews {
                if let found = findTabBar(in: sub) { return found }
            }
            return nil
        }

        @objc private func handle(_ gesture: UILongPressGestureRecognizer) {
            guard let bar = tabBar, let items = bar.items, !items.isEmpty else { return }
            switch gesture.state {
            case .began:
                // 触摸刚落下：这时选中项还是旧的，记下来当判定基准
                let point = gesture.location(in: bar)
                guard let index = itemIndex(at: point, in: bar, count: items.count) else {
                    pendingIndex = nil
                    return
                }
                pendingIndex = index
                pendingWasSelected = (bar.selectedItem === items[index])
            case .ended:
                defer { pendingIndex = nil }
                guard let index = pendingIndex, pendingWasSelected, index < items.count else { return }
                // 抬手位置必须还在同一个 item 上，避免「从 tab bar 上划走」被算成点击
                let point = gesture.location(in: bar)
                guard itemIndex(at: point, in: bar, count: items.count) == index else { return }
                onReselect(index)
            default:
                pendingIndex = nil
            }
        }

        /// 命中第几个 tab。item 按钮宽度远小于整条 bar，背景视图是全宽的，用宽度把背景筛掉。
        private func itemIndex(at point: CGPoint, in bar: UITabBar, count: Int) -> Int? {
            let buttons = bar.subviews
                .filter { !$0.isHidden && $0.bounds.width > 0 && $0.bounds.width < bar.bounds.width * 0.5 }
                .sorted { $0.frame.minX < $1.frame.minX }
            if let hit = buttons.firstIndex(where: { $0.frame.contains(point) }) {
                return hit < count ? hit : nil
            }
            // 布局解析不出来（系统改版）就按等分宽度估算，4 个 tab 足够准
            let step = bar.bounds.width / CGFloat(count)
            guard step > 0, point.x >= 0, point.x <= bar.bounds.width else { return nil }
            return min(count - 1, max(0, Int(point.x / step)))
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
