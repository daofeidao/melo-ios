import SwiftUI
import UIKit

struct PlayerView: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss

    @State private var artwork: UIImage?
    @State private var offset: CGFloat = 0
    @State private var showQueue = false
    @State private var showLyrics = false
    @State private var lyrics: [LyricLine] = []
    @State private var lyricsLoading = false

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
                        Spacer().frame(height: 26)
                        if player.errorText != nil {
                            errorCard
                                .padding(.bottom, 14)
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
        .preferredColorScheme(.dark)
        .offset(y: offset)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    if value.translation.height > 0 {
                        offset = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height > 140 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            offset = 0
                        }
                    }
                }
        )
        .sheet(isPresented: $showQueue) {
            QueueView()
                .environmentObject(player)
        }
        .task(id: player.currentTrack?.id) {
            await loadArtwork()
            await loadLyrics()
        }
        .onDisappear {
            offset = 0
        }
    }

    // MARK: - Pieces

    private var background: some View {
        ZStack {
            if let artwork = artwork {
                GeometryReader { proxy in
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .blur(radius: 60, opaque: true)
                }
                Color.black.opacity(0.42)
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.55)],
                    startPoint: .center,
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
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 22, y: 12)
        .scaleEffect(player.isPlaying ? 1 : 0.94)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: player.isPlaying)
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.58))
                    .lineLimit(1)
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
        }
        .padding(.horizontal, 28)
    }

    private var progressBlock: some View {
        VStack(spacing: 2) {
            Scrubber(progress: player.progress) { value in
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

    private var errorCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
                Text(L("Playback failed"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }
            if let error = player.errorText {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                player.retryCurrent()
            } label: {
                Text(L("Retry"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.38))
        )
        .padding(.horizontal, 24)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "text.quote")
                    .font(.system(size: 17))
                    .foregroundColor(.white.opacity(0.4))

                Spacer()

                Button {
                    showQueue = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 44, height: 32)
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 44, height: 32)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 30)
            .padding(.bottom, Layout.safeBottom > 0 ? 6 : 16)
        }
    }

    // MARK: - Helpers

    private func loadArtwork() async {
        guard let urlString = player.currentTrack?.artwork, let url = URL(string: urlString) else {
            await MainActor.run { artwork = nil }
            return
        }
        if let cached = ImageLoader.shared.cached(for: url) {
            await MainActor.run { artwork = cached }
            return
        }
        let image = await ImageLoader.shared.image(for: url)
        await MainActor.run { artwork = image }
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
