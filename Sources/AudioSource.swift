import Foundation

/// 播放源解析：能拿到国内直链就优先用国内（延迟低、不受 YouTube 反爬影响），
/// 拿不到再回落到 YouTube Music。
enum AudioSource {

    static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    /// 上一次判定"YouTube 走不通"的时间。
    /// 持久化到 UserDefaults：不然每次冷启动第一首歌都要再等一次 12 秒超时。
    private static let blockedAtKey = "melo.youtubeBlockedAt"
    private static let blockedWindow: TimeInterval = 30 * 60

    private static var blockedAt: Date? {
        get { UserDefaults.standard.object(forKey: blockedAtKey) as? Date }
        set {
            if let value = newValue {
                UserDefaults.standard.set(value, forKey: blockedAtKey)
            } else {
                UserDefaults.standard.removeObject(forKey: blockedAtKey)
            }
        }
    }

    private static var youtubeLikelyBlocked: Bool {
        guard let blockedAt = blockedAt else { return false }
        return Date().timeIntervalSince(blockedAt) < blockedWindow
    }

    static func noteYouTubeBlocked() {
        blockedAt = Date()
    }

    /// 直链已经拿过、但 AVPlayer 播不出来的曲目。
    /// 标记之后下次解析跳过直链，直接按歌名去国内源找同一首 —— 这就是
    /// "把 probe 移出关键路径"的代价补偿：让播放器当裁判，失败一次就换路。
    private static var failedTracks = Set<String>()

    static func notePlaybackFailure(_ track: Track) {
        failedTracks.insert(track.id)
    }

    /// 冷启动预热：国内源都是新的域名，TLS 握手比 RTT 还贵
    static func warmUp() {
        let hosts = ["https://m.kugou.com/", "https://songsearch.kugou.com/", "https://music.163.com/"]
        for string in hosts {
            guard let url = URL(string: string) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 8
            request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
        }
    }

    static func resolve(track: Track, quality: StreamResolver.Quality) async throws -> AudioStream {
        // 本地导入的音频：直接给 file URL，不联网、不解析
        if track.source == LocalMusicStore.sourceTag {
            guard let url = LocalMusicStore.fileURL(for: track) else {
                throw ApiError.unavailable(L("This local file is no longer on the device."))
            }
            return AudioStream(url: url, itag: -1, bitrate: 0, mime: "audio/mpeg")
        }

        // 直链能拿到就直接播（probe 已经移出关键路径）
        if !failedTracks.contains(track.id), let domestic = await domesticStream(for: track) {
            return domestic
        }

        // 有国内来源但拿不到直链（网易云 VIP / QQ 要登录）：
        // 按歌名在国内源里找同一首。一次解析只做一次，别搜两遍。
        var attemptedFallback = false
        if track.source != nil {
            attemptedFallback = true
            if let fallback = await domesticFallback(for: track) {
                return fallback
            }
            // 已经确认 YouTube 被拦，就别再空等一轮了
            if youtubeLikelyBlocked {
                throw ApiError.unavailable(L("This song is not available on domestic sources right now."))
            }
        } else if youtubeLikelyBlocked, let fallback = await domesticFallback(for: track) {
            return fallback
        }

        do {
            return try await StreamResolver.resolve(videoId: track.videoId, quality: quality)
        } catch {
            if let typed = error as? ApiError, case .botCheck = typed {
                noteYouTubeBlocked()
            } else if error is URLError {
                // 超时 / 连不上 / DNS 失败同样是"这条路走不通"，
                // 以前只认 botCheck，所以熔断几乎从来没生效过
                noteYouTubeBlocked()
            }
            // 上面已经搜过一次就别重复搜（QQ 歌在这条路径上最容易白等两轮）
            if !attemptedFallback, let fallback = await domesticFallback(for: track) {
                return fallback
            }
            throw error
        }
    }

    // MARK: - 按歌名兜底国内音源

    /// 宁可找不到，也不播翻唱：标题必须同名、艺人必须对得上
    private static func domesticFallback(for track: Track) async -> AudioStream? {
        guard let matched = await DomesticSource.match(
            title: track.title,
            artist: track.artist,
            duration: track.duration
        ) else { return nil }
        return await domesticStream(for: matched)
    }

    /// 该曲目是否有可能走国内音源
    static func hasDomesticSource(_ track: Track) -> Bool {
        guard let source = track.source, let id = track.sourceID, !id.isEmpty else { return false }
        return PlaylistPlatform(rawValue: source) != nil
    }

    static func domesticStream(for track: Track) async -> AudioStream? {
        guard let source = track.source,
              let id = track.sourceID,
              !id.isEmpty,
              let platform = PlaylistPlatform(rawValue: source) else { return nil }

        let resolved: URL?
        switch platform {
        case .netease:
            // 网易云「外链」：不需要签名，302 到 CDN 的 mp3；VIP/无版权会跳到 404 网页
            resolved = await DomesticSource.neteaseStreamURL(id: id)
        case .kugou:
            resolved = await DomesticSource.kugouStreamURL(hash: id)
        case .qq:
            // QQ 需要 vkey，公开请求拿不到 purl，只能回落 YouTube
            resolved = nil
        }

        guard let url = resolved else { return nil }
        // 起播前不再 probe：那会多一个 RTT，超时还要拖 4~6 秒，而它拦的只是
        // "VIP 跳到 HTML 404"这一种情况。现在直接交给 AVPlayer，播不出来会走
        // retryCurrentTrack → notePlaybackFailure → 下次按歌名兜底。
        return AudioStream(url: url, itag: -1, bitrate: 128_000, mime: "audio/mpeg")
    }

    // MARK: - 各平台


    /// 先拉 1KB 确认「真的很像音频」，再交给播放器 —— 否则 VIP 曲目会跳到一个 HTML 404 页。
    /// 超时压到 4 秒：源不可用时用户等不起十几秒，宁可快速判失败再回落。
    private static func probe(_ urlString: String) async -> AudioStream? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              data.count > 512,
              let finalURL = response.url else { return nil }

        let mime = http.mimeType ?? ""
        let looksAudio = mime.contains("audio") || mime.contains("mpeg") || mime.contains("octet-stream")
        guard looksAudio else { return nil }

        return AudioStream(url: finalURL, itag: -1, bitrate: 128_000, mime: mime)
    }

    // MARK: - 网易云单曲信息（给冒烟测试用）

    static func netEaseTrack(id: String) async -> Track? {
        guard let url = URL(string: "https://music.163.com/api/song/detail?ids=[\(id)]") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let song = (JS.array(root["songs"]) ?? []).compactMap({ JS.dict($0) }).first,
              let title = JS.string(song["name"]) else { return nil }

        let artist = (JS.array(song["artists"]) ?? [])
            .compactMap { JS.dict($0) }
            .compactMap { JS.string($0["name"]) }
            .joined(separator: ", ")
        let album = JS.dict(song["album"])
        let cover = JS.string(album?["picUrl"])
        let duration = (JS.int(song["duration"]) ?? 0) / 1000

        return Track(
            videoId: "",
            title: title,
            artist: artist.isEmpty ? L("Unknown Artist") : artist,
            album: JS.string(album?["name"]),
            duration: duration,
            artwork: cover,
            source: PlaylistPlatform.netease.rawValue,
            sourceID: id
        )
    }
}
