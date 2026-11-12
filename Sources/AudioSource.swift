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
    /// 原曲目 id -> 已经试过的兜底候选 id。播放失败重试时跳过它们，
    /// 否则会反复撞同一条死链，永远轮到下一个音源。
    private static var attemptedFallbacks: [String: Set<String>] = [:]
    private static let stateLock = NSLock()

    /// 严格模式下被拒的同名版本，播放失败后由播放页读取做「切换音源」
    private static var pendingAlternatives: [Track] = []

    /// 上一次解析实际命中的音源（local / cache / kugou / kuwo / netease / qq / youtube）。
    /// 播放页的「播放源」面板用它标出「正在使用」。
    private(set) static var lastResolvedSource: String?

    static func takeAlternatives() -> [Track] {
        stateLock.lock(); defer { stateLock.unlock() }
        let list = pendingAlternatives
        pendingAlternatives = []
        return list
    }

    static func notePlaybackFailure(_ track: Track) {
        stateLock.lock(); defer { stateLock.unlock() }
        failedTracks.insert(track.id)
    }

    private static func hasFailed(_ id: String) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return failedTracks.contains(id)
    }

    private static func triedCandidates(for id: String) -> Set<String> {
        stateLock.lock(); defer { stateLock.unlock() }
        return attemptedFallbacks[id] ?? []
    }

    private static func rememberFallback(_ candidate: Track, for id: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        attemptedFallbacks[id, default: []].insert(candidate.id)
    }

    /// 冷启动预热：国内源都是新的域名，TLS 握手比 RTT 还贵
    static func warmUp() {
        let hosts = [
            "https://m.kugou.com/",
            "https://songsearch.kugou.com/",
            "https://music.163.com/",
            "https://search.kuwo.cn/",
            "https://antiserver.kuwo.cn/"
        ]
        for string in hosts {
            guard let url = URL(string: string) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 8
            request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
        }
    }

    static func resolve(
        track: Track,
        quality: StreamResolver.Quality,
        pinnedSource: String? = nil
    ) async throws -> AudioStream {
        stateLock.lock()
        pendingAlternatives = []
        stateLock.unlock()
        lastResolvedSource = nil
        // 手动切换音源的那一首，只对本次解析生效
        defer { DomesticSource.forceLooseOnce = false }

        // 本地导入的音频：直接给 file URL，不联网、不解析
        if track.source == LocalMusicStore.sourceTag {
            guard let url = LocalMusicStore.fileURL(for: track) else {
                throw ApiError.unavailable(L("This local file is no longer on the device."))
            }
            lastResolvedSource = "local"
            return AudioStream(url: url, itag: -1, bitrate: 0, mime: "audio/mpeg")
        }

        // 音频本体已缓存：直接读本地文件，不联网、也不受直链过期影响
        if let cached = AudioCache.shared.cachedURL(for: track) {
            lastResolvedSource = "cache"
            return AudioStream(url: cached, itag: -1, bitrate: 0, mime: "audio/mpeg")
        }

        // 用户手动锁定了音源：只走这一条，拿不到就明确失败，不偷偷换源
        if let pinned = pinnedSource {
            if let stream = await pinnedStream(for: track, source: pinned, quality: quality) {
                lastResolvedSource = pinned
                return stream
            }
            throw ApiError.unavailable(L("This source has no playable version of this song."))
        }

        // 直链能拿到就直接播（probe 已经移出关键路径）
        // VIP / 付费专辑曲目例外：实测 player/url 固定返回 -110，outer/url 固定 302 到 /404，
        // 再问一次只是白等，直接按歌名去其他音源找。
        if !track.isVip, !hasFailed(track.id), let domestic = await domesticStream(for: track, quality: quality) {
            lastResolvedSource = track.source
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

        // 用户自己在「关于 → 数据来源」里添加的音源：排在所有内置源之后
        let customSources = SourcePrefs.shared.customSources
        if !customSources.isEmpty {
            for source in customSources {
                guard let raw = await SourcePrefs.shared.resolveCustom(source, track: track) else { continue }
                if let stream = await probe(raw, timeout: 4) { return stream }
            }
        }

        do {
            let stream = try await StreamResolver.resolve(videoId: track.videoId, quality: quality)
            // 解析成功说明 YouTube 这条路已经恢复，清掉上一次失败留下的熔断标记
            blockedAt = nil
            return stream
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

    /// 多源兜底：先走酷狗快路径，再把酷狗 / 网易云 / 酷我的候选逐个试到能播为止。
    /// 歌单里最容易失败的是 QQ 曲目和网易云 VIP —— 以前只问一次酷狗就判失败。
    /// 在指定音源里为这首歌找一条直链。先用曲目自带的 id，再按歌名在该源里搜。
    private static func pinnedStream(
        for track: Track,
        source: String,
        quality: StreamResolver.Quality
    ) async -> AudioStream? {
        if source == "youtube" {
            if !track.videoId.isEmpty,
               let stream = try? await StreamResolver.resolve(videoId: track.videoId, quality: quality) {
                return stream
            }
            return nil
        }

        if track.source == source, !track.isVip, let id = track.sourceID, !id.isEmpty,
           let url = await nativeURL(source: source, id: id, quality: quality) {
            return AudioStream(url: url, itag: -1, bitrate: 0, mime: "audio/mpeg")
        }

        let keyword = "\(track.title) \(track.artist)".trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return nil }
        let hits = await DomesticSource.search(query: keyword, limit: 12)
        let prefix = String(track.title.prefix(4))

        for hit in hits where (hit.source ?? "") == source {
            guard let id = hit.sourceID, !id.isEmpty else { continue }
            if !prefix.isEmpty, !hit.title.contains(prefix) { continue }
            if let url = await nativeURL(source: source, id: id, quality: quality) {
                return AudioStream(url: url, itag: -1, bitrate: 0, mime: "audio/mpeg")
            }
        }
        return nil
    }

    /// 单源的「自带 id 换直链」，不涉及搜索
    private static func nativeURL(
        source: String,
        id: String,
        quality: StreamResolver.Quality
    ) async -> URL? {
        switch source {
        case "netease": return await DomesticSource.neteaseStreamURL(id: id, quality: quality)
        case "kugou": return await DomesticSource.kugouStreamURL(hash: id)
        case "kuwo": return await DomesticSource.kuwoStreamURL(id: id, quality: quality)
        case "qq": return await DomesticSource.qqStreamURL(mid: id, quality: quality)
        default: return nil
        }
    }

    private static func domesticFallback(for track: Track) async -> AudioStream? {
        let tried = triedCandidates(for: track.id)
        // 兜底是「尽力而为」，不能无限试：VIP 曲目必然走到这里，
        // 以前两次搜索 + 四个候选串起来最坏能拖到 60 秒。整条链给 12 秒预算。
        let deadline = Date().addingTimeInterval(12)

        if Date() < deadline,
           let quick = await DomesticSource.match(
            title: track.title,
            artist: track.artist,
            duration: track.duration
           ), !hasFailed(quick.id), !tried.contains(quick.id) {
            rememberFallback(quick, for: track.id)
            if let stream = await verifiedDomesticStream(for: quick) { return stream }
        }

        guard Date() < deadline else { return nil }
        let picks = await DomesticSource.fallbackCandidates(
            title: track.title,
            artist: track.artist,
            duration: track.duration,
            limit: 4
        )
        for candidate in picks {
            guard Date() < deadline else { break }
            guard !hasFailed(candidate.id), !tried.contains(candidate.id) else { continue }
            // 先记下来：拿不到直链的候选下次不必再问
            rememberFallback(candidate, for: track.id)
            if let stream = await verifiedDomesticStream(for: candidate) { return stream }
        }

        // 严格模式下这里通常是「同名但时长对不上」：把那些版本交给播放页手动切换
        if DomesticSource.isStrictMatch {
            let near = await DomesticSource.nearMatches(
                title: track.title,
                artist: track.artist,
                duration: track.duration
            )
            stateLock.lock()
            pendingAlternatives = Array(near.prefix(6))
            stateLock.unlock()
        }
        return nil
    }

    /// 兜底链上每个候选先验 1KB：这些地址的典型失败是「200 但其实是 HTML 404 页」。
    /// 主路径不做这一步，避免正常起播多一个 RTT。
    private static func verifiedDomesticStream(for track: Track) async -> AudioStream? {
        guard let stream = await domesticStream(for: track) else { return nil }
        return await probe(stream.url.absoluteString, timeout: 3)
    }

    /// 该曲目是否有可能走国内音源
    static func hasDomesticSource(_ track: Track) -> Bool {
        guard let source = track.source, let id = track.sourceID, !id.isEmpty else { return false }
        return PlaylistPlatform(rawValue: source) != nil
    }

    static func domesticStream(
        for track: Track,
        quality: StreamResolver.Quality = .high
    ) async -> AudioStream? {
        guard let source = track.source,
              let id = track.sourceID,
              !id.isEmpty,
              let platform = PlaylistPlatform(rawValue: source) else { return nil }

        let resolved: URL?
        switch platform {
        case .netease:
            // 网易云「外链」：不需要签名，302 到 CDN 的 mp3；VIP/无版权会跳到 404 网页
            resolved = await DomesticSource.neteaseStreamURL(id: id, quality: quality)
        case .kugou:
            resolved = await DomesticSource.kugouStreamURL(hash: id)
        case .qq:
            // vkey 接口能拿到匿名直链（128/320），付费曲目会自动降级
            resolved = await DomesticSource.qqStreamURL(mid: id, quality: quality)
        case .kuwo:
            resolved = await DomesticSource.kuwoStreamURL(id: id, quality: quality)
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
    private static func probe(_ urlString: String, timeout: TimeInterval = 6) async -> AudioStream? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
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
