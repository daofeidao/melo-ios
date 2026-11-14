import SwiftUI
import MediaPlayer
import UIKit

// MARK: - 封面

struct ArtworkView: View {
    let url: String?
    var size: CGFloat
    var corner: CGFloat = 6
    var round: Bool = false

    @State private var image: UIImage?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: round ? size / 2 : corner, style: .continuous)
    }

    var body: some View {
        ZStack {
            shape.fill(Color(UIColor.tertiarySystemFill))
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: max(12, size * 0.28), weight: .regular))
                    .foregroundColor(Theme.tertiaryLabel)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let urlString = url, let target = URL(string: urlString) else {
            await MainActor.run { self.image = nil }
            return
        }
        // 按显示尺寸解码：滑到哪里解到哪里的小图，不在主线程解原图（修滚动卡顿）
        let maxPixel = min(max(size * UIScreen.main.scale, 60), 600)
        if let cached = ImageLoader.shared.cached(for: target) {
            await MainActor.run { self.image = cached }
            return
        }
        let loaded = await ImageLoader.shared.image(for: target, maxPixel: maxPixel)
        await MainActor.run { self.image = loaded }
    }
}

// MARK: - 曲目行

struct TrackRow: View {
    let track: Track
    var showArtwork: Bool = true
    var showIndex: Bool = false
    var index: Int = 0
    /// 右侧小标签，目前用来标 VIP
    var badge: String? = nil
    /// 点艺人名跳艺人页；不传就不把艺人名做成可点（保持整行点击 = 播放）
    var onArtistTap: (() -> Void)? = nil
    /// 原唱判定的上下文艺人（搜索词命中的艺人 / 艺人页 / 专辑艺人）
    var contextArtist: String? = nil
    var onTap: () -> Void

    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var library: Library

    private var isCurrent: Bool {
        player.currentTrack?.id == track.id
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if showIndex {
                    Text("\(index)")
                        .font(.system(size: 15))
                        .monospacedDigit()
                        .foregroundColor(isCurrent ? Theme.accent : Theme.secondaryLabel)
                        // 22pt 只够放两位数；100 以后会被挤成两行。
                        // 放宽到 32pt + 单行 + 轻微缩放，四位数也不会换行。
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: 32, alignment: .center)
                }
                if showArtwork {
                    ArtworkView(url: track.artwork, size: 48, corner: 5)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 16))
                        .foregroundColor(isCurrent ? Theme.accent : Color.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if isCurrent {
                            Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                .font(.system(size: 9))
                                .foregroundColor(Theme.accent)
                        }
                        if let onArtistTap {
                            Button(action: onArtistTap) {
                                Text(track.artist)
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.accent)
                                    .lineLimit(1)
                            }
                            .buttonStyle(PlainButtonStyle())
                        } else {
                            Text(track.artist)
                                .font(.system(size: 13))
                                .foregroundColor(Theme.secondaryLabel)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                // 【原唱】实心标：标题里没有翻唱 / DJ / Live / 伴奏等标记、且艺人对得上才打
                if isOriginalVersion(track, contextArtist: contextArtist) {
                    Text("原唱")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Theme.accent)
                        )
                }
                // 不传 badge 时默认按音源显示（酷狗 / 酷我 / 网易云 …），覆盖所有用到 TrackRow 的列表
                if let badge = badge ?? sourceBadge(track) {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.accent)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(Theme.accent.opacity(0.7), lineWidth: 0.8)
                        )
                }
                Text(track.durationText)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.secondaryLabel)
                    .monospacedDigit()
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            Button {
                library.toggleFavorite(track)
            } label: {
                Label(
                    library.isFavorite(track) ? L("Remove Favorite") : L("Favorite"),
                    systemImage: library.isFavorite(track) ? "heart.slash" : "heart"
                )
            }
        }
    }
}

// MARK: - 分区标题

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 21, weight: .bold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }
}

// MARK: - 横向卡片

struct CarouselCard: View {
    let item: ShelfItem
    var width: CGFloat = 148
    /// 传入后长按卡片弹出「移除收藏」菜单（首页收藏 / 最近播放用）
    var onRemove: (() -> Void)? = nil

    @EnvironmentObject private var player: PlayerEngine

    var body: some View {
        switch item {
        case .collection(let collection):
            NavigationLink(destination: CollectionView(browseId: collection.browseId, fallbackTitle: collection.title)) {
                card(
                    title: collection.title,
                    subtitle: collection.subtitle,
                    artwork: collection.artwork,
                    round: collection.isRound
                )
            }
            .buttonStyle(PlainButtonStyle())
            .removeContextMenu(onRemove)

        case .track(let track):
            Button {
                player.play(tracks: [track], startAt: 0)
            } label: {
                card(title: track.title, subtitle: track.artist, artwork: track.artwork, round: false)
            }
            .buttonStyle(PlainButtonStyle())
            .removeContextMenu(onRemove)
        }
    }

    private func card(title: String, subtitle: String, artwork: String?, round: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: artwork, size: width, corner: 7, round: round)
                .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(height: 36, alignment: .top)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(Theme.secondaryLabel)
                .lineLimit(1)
                .frame(height: 15, alignment: .top)
        }
        .frame(width: width, alignment: .leading)
    }
}

extension View {
    /// 长按「移除收藏」菜单；没传 onRemove 就保持原样（搜索 / 艺人页的卡片不受影响）
    @ViewBuilder
    func removeContextMenu(_ action: (() -> Void)?) -> some View {
        if let action {
            contextMenu {
                Button(action: action) {
                    Label(L("Remove Favorite"), systemImage: "heart.slash")
                }
            }
        } else {
            self
        }
    }
}

/// 歌单 / 专辑收藏按钮。搜索结果卡片下方用带文字版，详情页工具栏用图标版。
struct CollectionSaveButton: View {
    let collection: MediaCollection
    var showsLabel: Bool = true

    @EnvironmentObject private var library: Library

    private var saved: Bool { library.isSavedCollection(collection) }

    var body: some View {
        Button {
            library.toggleSavedCollection(collection)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: saved ? "heart.fill" : "heart")
                    .font(.system(size: showsLabel ? 12 : 14))
                if showsLabel {
                    Text(saved ? L("Saved") : L("Save"))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundColor(saved ? Theme.accent : Theme.secondaryLabel)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color(UIColor.tertiarySystemFill)))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct CarouselSection: View {
    let title: String
    let items: [ShelfItem]
    var width: CGFloat = 148
    /// 传入后卡片长按弹出「移除收藏」
    var onRemove: ((ShelfItem) -> Void)? = nil
    /// 标题右侧的自定义动作（首页最近播放的红色「清空」）
    var headerTrailing: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let headerTrailing {
                HStack {
                    SectionHeader(title: title)
                    headerTrailing
                }
            } else {
                SectionHeader(title: title)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        CarouselCard(item: item, width: width, onRemove: onRemove.map { remove in
                            { remove(item) }
                        })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            }
        }
    }
}

/// 圆形艺人头像块：搜索页与首页「喜欢艺人」共用。
/// 头像异步取真实图，拿不到就退回首字色块。
struct ArtistCircleTile: View {
    let name: String
    var size: CGFloat = 88

    @State private var avatar: String?

    private var fallbackColor: Color {
        let colors: [Color] = [
            Color(hex: 0xE0455E), Color(hex: 0x2E7BE0), Color(hex: 0xE08A2E),
            Color(hex: 0x2EA98A), Color(hex: 0x7B5BD6), Color(hex: 0xC24E8F),
            Color(hex: 0x3C6FA8)
        ]
        return colors[abs(name.hashValue) % colors.count]
    }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                if let url = avatar, !url.isEmpty {
                    ArtworkView(url: url, size: size, round: true)
                } else {
                    Circle().fill(fallbackColor)
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.36, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .frame(width: size, height: size)
            Text(name)
                .font(.system(size: 13))
                .foregroundColor(Theme.secondaryLabel)
                .lineLimit(1)
        }
        .frame(width: size + 8)
        .task(id: name) {
            let profile = await ArtistInfo.load(name: name)
            if let url = profile?.avatar, url.hasPrefix("http") {
                avatar = url
            }
        }
    }
}

// MARK: - 进度条

struct Scrubber: View {
    var progress: Double
    var onSeek: (Double) -> Void

    @State private var dragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let value = min(1, max(0, dragging ? dragValue : progress))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.white)
                    .frame(width: width * CGFloat(value), height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: dragging ? 13 : 9, height: dragging ? 13 : 9)
                    .offset(x: width * CGFloat(value) - (dragging ? 6.5 : 4.5))
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            }
            // 24 太窄，手指点偏一点就落到进度条外面；加到 30 更好按
            .frame(height: 30)
            .contentShape(Rectangle())
            // highPriorityGesture：播放页外层挂了「下滑关闭」的 DragGesture(minimumDistance: 12)，
            // 普通 .gesture 会被它先吃掉手势 —— 表现就是「点一下进度条没反应，
            // 非得按住拖一段才跳」。这里提到高优先级，点按和拖动都归进度条。
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        dragging = true
                        dragValue = min(1, max(0, gesture.location.x / width))
                    }
                    .onEnded { gesture in
                        // 直接用这次手势的落点算目标，不读 @State 里的 dragValue：
                        // 单击时 onChanged 只跑一帧，读状态有读到旧值的风险
                        let target = min(1, max(0, gesture.location.x / width))
                        dragValue = target
                        dragging = false
                        onSeek(target)
                    }
            )
        }
        .frame(height: 30)
    }
}

// MARK: - 系统音量条

// MARK: - 空状态

struct EmptyHint: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundColor(Theme.tertiaryLabel)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(Theme.secondaryLabel)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 56)
    }
}

// MARK: - 加载失败

struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(Theme.secondaryLabel)
                .multilineTextAlignment(.center)
            if let retry = retry {
                Button(L("Retry"), action: retry)
                    .font(.system(size: 15, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
    }
}
