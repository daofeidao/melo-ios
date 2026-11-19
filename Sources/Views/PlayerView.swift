import SwiftUI
import UIKit

struct PlayerView: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var library: Library
    /// 收起播放页。两种宿主（fullScreenCover / Mac 的 overlay）都用同一个绑定，
    /// 所以不要用 @Environment(\.dismiss) —— overlay 模式下它什么都不会做。
    private func close() {
        player.opensFullPlayer = false
    }

    @State private var artwork: UIImage?
    /// CPU 预模糊的封面小图，做播放页背景（Mac 上避免 GPU 大半径模糊崩溃）
    @State private var blurredArtwork: UIImage?
    /// 封面主色：给模糊背景打底，让整体色调跟专辑封面一致（磨砂半透的关键）
    @State private var dominantColor: Color = Color(hex: 0x2A2A2E)
    @State private var offset: CGFloat = 0
    /// iOS 15 上同一视图叠两个 .sheet 会互相顶掉，统一用一个 enum 驱动
    @State private var activeSheet: PlayerSheet?
    /// 浮层里下滑关闭时会和播放页的「下滑收起」同时识别，用短时间窗屏蔽后者
    @State private var swipeGuardUntil = Date.distantPast
    /// Mac Catalyst 上 sheet 里的 NavigationView 会自己重新解析系统外观，
    /// 弹出瞬间先按系统画一帧、再按 preferredColorScheme 画一帧 —— 表现为明暗来回闪。
    /// 从根视图环境读到当前 scheme 后显式传给 sheet，钉死它，不再闪。
    @Environment(\.colorScheme) private var colorScheme
    @State private var showLyrics = false
    /// 歌曲宝被 Cloudflare 风控时显示「完成验证」按钮，可观察
    @StateObject private var verifyState = GequbaoVerificationState.shared
    /// 缓存下载进度（正在下的那首才有值）
    @ObservedObject private var audioCache = AudioCache.shared

    private enum PlayerSheet: String, Identifiable {
        /// 播放历史 + 待播清单，同一个浮层里分段切换
        case library
        /// 音源与音质
        case sources
        /// 歌曲宝人机验证（在 App 内 WebView 完成）
        case verify

        var id: String { rawValue }
    }
    @State private var lyrics: [LyricLine] = []
    @State private var lyricsLoading = false

    /// 键盘快捷键载体（Mac）：零尺寸、不可点，只负责注册 key command
    private var keyboardShortcuts: some View {
        ZStack {
            Button { player.previous() } label: { Image(systemName: "chevron.left").opacity(0) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button { player.next() } label: { Image(systemName: "chevron.right").opacity(0) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button { player.toggle() } label: { Image(systemName: "playpause").opacity(0) }
                .keyboardShortcut(.space, modifiers: [])
            // 有些输入法/焦点状态下无修饰键会被吃掉，再给一套 ⌘←/⌘→ 兜底
            Button { player.previous() } label: { Image(systemName: "chevron.left").opacity(0) }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
            Button { player.next() } label: { Image(systemName: "chevron.right").opacity(0) }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    var body: some View {
        ZStack {
            background
            GeometryReader { proxy in
                let artSide = min(proxy.size.width - 56, proxy.size.height * 0.44, 430)

                VStack(spacing: 0) {
                    Capsule()
                        .fill(Color.white.opacity(0.32))
                        .frame(width: 36, height: 5)
                        .padding(.top, 10)

                    Spacer(minLength: 12)

                    if showLyrics {
                        lyricsView(side: artSide)
                    } else {
                        artworkView(side: artSide)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.22)) { showLyrics = true }
                            }
                    }

                    Spacer(minLength: 16)

                    if let track = player.currentTrack {
                        titleBlock(track)
                        if player.isLoading {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text(L("Loading…"))
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .padding(.top, 6)
                        }
                        Spacer().frame(height: 26)
                        if player.errorText != nil {
                            errorLine
                                .padding(.bottom, 8)
                        }
                        // 歌曲宝被 Cloudflare 风控：直接在播放页给「完成验证」入口，
                        // 点开 App 内 WebView 过验证，回来后重试即可，不用去浏览器折腾。
                        if verifyState.needsVerification {
                            Button {
                                activeSheet = .verify
                            } label: {
                                HStack(spacing: 0) {
                                    Text(L("Gequbao requires a human verification. Tap to finish it inside the app."))
                                        .font(.system(size: 12))
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(L("Verify Now") + " ›")
                                        .font(.system(size: 12))
                                        .foregroundColor(Theme.accent)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(Color.black.opacity(0.3))
                                .cornerRadius(8)
                            }
                            .padding(.horizontal, 4)
                            .padding(.bottom, 8)
                        }
                        progressBlock
                        Spacer().frame(height: 22)
                        controlsBlock
                        Spacer(minLength: 26)
                        bottomBar
                    } else {
                        Text(L("Nothing Playing"))
                            .foregroundColor(.white.opacity(0.7))
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .offset(y: offset)
        // Mac 上要能用键盘控制：空格 播放/暂停、左右方向键 切歌。
        // 用零尺寸不可见按钮承载 keyboardShortcut —— Catalyst 会把它转成
        // 系统的 UIKeyCommand；只在播放页挂，不会抢搜索框里的空格。
        .overlay(keyboardShortcuts, alignment: .topLeading)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    // 浮层打开、或浮层刚通过下滑关闭时，不接管下滑
                    guard activeSheet == nil, Date() >= swipeGuardUntil else { return }
                    if value.translation.height > 0 {
                        offset = value.translation.height
                    }
                }
                .onEnded { value in
                    guard activeSheet == nil, Date() >= swipeGuardUntil else { return }
                    if value.translation.height > 140 {
                        close()
                    } else {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            offset = 0
                        }
                    }
                }
        )
        #if targetEnvironment(macCatalyst)
        // Mac 不用系统 .sheet：Catalyst 的 sheet 是独立 presentation，会把主窗口变成
        // 非活跃态（左上角红绿灯变灰），且卡片外的点击传不进来，点界外关不掉。
        // 改成自己的全屏浮层：暗化背景点一下就关，卡片尺寸随窗口自适应，没有失活问题。
        .overlay {
            if let sheet = activeSheet {
                ZStack {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { activeSheet = nil }
                    sheetContent(sheet)
                        .environment(\.meloSheetClose, { activeSheet = nil })
                        .frame(maxWidth: 560, maxHeight: 600)
                        .background(Color(hex: 0x1C1C1E))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: Color.black.opacity(0.45), radius: 24, y: 10)
                        .padding(40)
                }
                .transition(.opacity)
                .zIndex(1000)
            }
        }
        #else
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
        }
        #endif
        .task(id: player.currentTrack?.id) {
            await loadArtwork()
            await loadLyrics()
        }
        // Mac 全局双指手势：下滑时先关浮层（不是关播放页）
        .onReceive(NotificationCenter.default.publisher(for: .meloCloseSheet)) { _ in
            activeSheet = nil
        }
        .onChange(of: activeSheet) { newValue in
            player.sheetOpen = (newValue != nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .meloOpenPlayerSource)) { _ in
            // Mac 两指上滑打开「播放源」面板
            activeSheet = .sources
        }
        .onDisappear {
            offset = 0
        }
    }

    /// 播放页浮层内容（Mac 用自定义 overlay、iOS 用系统 sheet，共用这一份）。
    @ViewBuilder
    private func sheetContent(_ sheet: PlayerSheet) -> some View {
        Group {
            switch sheet {
            case .library:
                PlayerLibrarySheet()
                    .environmentObject(player)
            case .sources:
                PlayerSourceSheet()
                    .environmentObject(player)
            case .verify:
                if let info = SourcePrefs.shared.builtIn.first(where: { $0.id == "gequbao" }) {
                    WebLoginView(platform: info)
                }
            }
        }
        // 播放页本身是随封面生成的深色背景，面板必须跟它一致。
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    // MARK: - Pieces

    private var background: some View {
        ZStack {
            // 封面主色打底：模糊图边缘/透明处透出的是专辑色，而不是死灰或纯黑，
            // 这正是「磨砂半透、和专辑相关」的底层色调。
            dominantColor.saturation(0.85)

            if let blurred = blurredArtwork {
                // CPU 预模糊的小图拉伸铺满：随专辑封面变化，GPU 零模糊开销。
                // 2011 HD3000 无 Metal，实时大半径 blur 会让渲染进程崩，故不用 .blur()。
                GeometryReader { proxy in
                    Image(uiImage: blurred)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .opacity(0.9)   // 透一点主色出来，避免整块糊死
                }
                // 分段遮罩：顶部略压（状态栏/返回键可读）、中部少压（透出专辑色）、
                // 底部加深（歌词和控件文字可读）。比原来一刀切的 48% 黑更通透。
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.34),
                        Color.black.opacity(0.16),
                        Color.black.opacity(0.30),
                        Color.black.opacity(0.62),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                LinearGradient(
                    colors: [Color(hex: 0x3A3A3C), Color(hex: 0x0A0A0B)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
    }

    private func artworkView(side: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
            if let artwork = artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.25))
                    .foregroundColor(.white.opacity(0.35))
            }
            // 受保护视频走的是「视频+音频」合体流，画面本来就在里面：
            // 直接铺在封面上，用户看到的是原视频而不是一张静止封面。
            // 纯音频流不会走到这里（showsVideo 为假），保持原样。
            if player.showsVideo {
                VideoSurface(player: player.avPlayer)
                    .frame(width: side, height: side)
                    .transition(.opacity)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
        .scaleEffect(player.isPlaying ? 1 : 0.94)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: player.isPlaying)
        .animation(.easeInOut(duration: 0.28), value: player.showsVideo)
    }

    private var currentLine: Int {
        guard !lyrics.isEmpty else { return 0 }
        let time = player.elapsed + 0.2
        var result = 0
        for (index, line) in lyrics.enumerated() where line.time <= time {
            result = index
        }
        return result
    }

    private func lyricsView(side: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if lyricsLoading {
                        ProgressView()
                            .padding(.top, 60)
                    } else if lyrics.isEmpty {
                        Text(L("No lyrics for this song"))
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                            .padding(.top, 60)
                            .padding(.horizontal, 16)
                    } else {
                        ForEach(Array(lyrics.enumerated()), id: \.element.id) { index, line in
                            Text(line.text)
                                .font(.system(size: 15, weight: index == currentLine ? .semibold : .regular))
                                .foregroundColor(.white.opacity(index == currentLine ? 0.98 : 0.45))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .id(index)
                        }
                    }
                }
                .padding(.vertical, 16)
            }
            .onChange(of: currentLine) { value in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(value, anchor: .center)
                }
            }
        }
        .frame(width: side, height: side)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.22)) { showLyrics = false }
        }
    }

    private func loadLyrics() async {
        guard let track = player.currentTrack else {
            await MainActor.run {
                lyrics = []
                lyricsLoading = false
            }
            return
        }
        await MainActor.run {
            lyrics = []
            lyricsLoading = true
        }
        let lines = await LyricsLoader.load(for: track)
        await MainActor.run {
            lyrics = lines
            lyricsLoading = false
        }
    }

    private func titleBlock(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    // 点艺名进艺人页：先记住名字并关掉播放页，再由「现在就听」里那个
                    // 隐藏的 NavigationLink 推进去（fullScreenCover 里推不动主栈）
                    Button {
                        let first = track.artist
                            .components(separatedBy: CharacterSet(charactersIn: ",，、/&"))
                            .first?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? track.artist
                        ArtistRouter.shared.pending = first.isEmpty ? track.artist : first
                        close()
                    } label: {
                        Text(track.artist)
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.58))
                            .lineLimit(1)
                    }
                    .buttonStyle(PlainButtonStyle())
                    // 一次性反馈：正在缓存 / 刚失败（3.5 秒后自动消失）。
                    // 「已缓存」不写文字，图标变实心红就够了
                    if player.cacheBusy {
                        Text(L("Caching…"))
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.55))
                            .padding(.top, 2)
                    } else if let message = player.cacheMessage {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.accent)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    library.toggleFavorite(track)
                } label: {
                    Image(systemName: library.isFavorite(track) ? "heart.fill" : "heart")
                        .font(.system(size: 19))
                        .foregroundColor(library.isFavorite(track) ? Theme.accent : .white.opacity(0.85))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(PlainButtonStyle())
                // 缓存：和收藏同一档的小图标，就摆在收藏右边。
                // 只保留这一个入口 —— 别再额外加「下载」按钮，同一件事两个按钮只会让人犹豫。
                Button {
                    player.cacheCurrent()
                } label: {
                    cacheButton(track)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 28)
    }

    /// 缓存按钮：不额外占一行进度条，就用按钮本身表示进度 ——
    /// 下载中红色沿圆周走一圈，下完红色填满整个图标。
    @ViewBuilder
    private func cacheButton(_ track: Track) -> some View {
        let cached = player.isCached(track)
        let progress = audioCache.progress[track.id]

        ZStack {
            if let progress, !cached {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 2)
                    .frame(width: 28, height: 28)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.accent,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 28, height: 28)
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
            } else {
                Image(systemName: cached ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 19))
                    .foregroundColor(cached ? Theme.accent : .white.opacity(0.85))
            }
        }
        .animation(.easeOut(duration: 0.25), value: progress)
        .animation(.easeOut(duration: 0.25), value: cached)
    }

    private var progressBlock: some View {
        VStack(spacing: 2) {
            Scrubber(progress: player.progress, buffered: player.bufferedRatio) { value in
                player.seek(to: value * max(player.duration, 1))
            }
            HStack {
                Text(Self.clock(player.elapsed))
                Spacer()
                Text("-" + Self.clock(max(0, player.duration - player.elapsed)))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.55))
            .monospacedDigit()
        }
        .padding(.horizontal, 26)
    }

    private var controlsBlock: some View {
        HStack(spacing: 30) {
            Button {
                player.isShuffle.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(player.isShuffle ? Theme.accent : .white.opacity(0.85))
                    .frame(width: 30, height: 34)
            }
            .buttonStyle(PlainButtonStyle())

            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 44)
            }
            .buttonStyle(PlainButtonStyle())

            Button {
                player.toggle()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 74, height: 74)
                    if player.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white)
                            .offset(x: player.isPlaying ? 0 : 2)
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 44)
            }
            .buttonStyle(PlainButtonStyle())

            Button {
                player.repeatMode = player.repeatMode.next
            } label: {
                Image(systemName: player.repeatMode.symbolName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(player.repeatMode == .off ? .white.opacity(0.85) : Theme.accent)
                    .frame(width: 30, height: 34)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    /// 播放失败提示：固定一行，不放按钮、横线、候选列表。
    /// 能播的版本统一进「播放源」面板，避免把进度条和播放键往下顶。
    private var errorLine: some View {
        Button {
            activeSheet = .sources
        } label: {
            HStack(spacing: 5) {
                Text("△")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Text(L("Playback failed"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                Text(L("No exact match. Open Playback Source to see playable versions of this song."))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.68))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.30))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal, 20)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                // 左下角：播放历史入口。感应区从 44×32 扩到 72×56，
                // 图标居中不动——大屏（iPad/Mac）鼠标不用精准点中小图标。
                Button {
                    activeSheet = .library
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 17))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 72, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                // 中间：音源切换。手动锁定音源时变红。
                Button {
                    activeSheet = .sources
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 18))
                        .foregroundColor(player.preferredSource == nil ? .white.opacity(0.85) : Theme.accent)
                        .frame(width: 72, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                // 右下角：收起播放页。
                Button {
                    close()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 72, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.bottom, Layout.safeBottom > 0 ? 6 : 16)
        }
    }

    // MARK: - Helpers

    private func loadArtwork() async {
        guard let urlString = player.currentTrack?.artwork, let url = URL(string: urlString) else {
            await MainActor.run { artwork = nil; blurredArtwork = nil }
            return
        }
        let image: UIImage?
        if let cached = ImageLoader.shared.cached(for: url) {
            image = cached
        } else {
            image = await ImageLoader.shared.image(for: url)
        }
        // 封面、模糊背景、主色一起更新；都在后台线程算，CPU 上几毫秒完成，不卡 UI
        let bg = image.flatMap { CoverBlur.blurred($0) }
        let tint = image.map { ColorExtractor.averageColor(of: $0) }
        Diagnostics.mark("artwork bg=\(bg == nil ? "nil" : "ok") size=\(image?.size.width ?? 0)x\(image?.size.height ?? 0) tint=\(tint == nil ? "nil" : "ok")")
        await MainActor.run {
            artwork = image
            blurredArtwork = bg
            if let tint { dominantColor = tint }
        }
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

/// 面板的关闭动作注入：Mac 上播放源等面板改用自定义浮层（不用系统 sheet），
/// 面板内部的「关闭」按钮通过这个环境值关闭，而不是 @Environment(\.dismiss)。
struct MeloSheetCloseKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var meloSheetClose: (() -> Void)? {
        get { self[MeloSheetCloseKey.self] }
        set { self[MeloSheetCloseKey.self] = newValue }
    }
}
