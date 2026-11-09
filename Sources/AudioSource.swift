import Foundation

/// 播放源解析：能拿到国内直链就优先用国内（延迟低、不受 YouTube 反爬影响），
/// 拿不到再回落到 YouTube Music。
enum AudioSource {

    static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    static func resolve(track: Track, quality: StreamResolver.Quality) async throws -> AudioStream {
        if let domestic = await domesticStream(for: track) {
            return domestic
        }
        return try await StreamResolver.resolve(videoId: track.videoId, quality: quality)
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

        switch platform {
        case .netease:
            // 网易云「外链」：不需要签名，302 到 CDN 的 mp3；VIP/无版权会跳到 404 页面
            return await probe("https://music.163.com/song/media/outer/url?id=\(id).mp3")
        case .kugou:
            return await kugouStream(hash: id)
        case .qq:
            // QQ 需要 vkey，公开请求拿不到 purl，只能回落 YouTube
            return nil
        }
    }

    // MARK: - 各平台

    private static func kugouStream(hash: String) async -> AudioStream? {
        guard let url = URL(string: "http://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=\(hash)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let playURL = JS.string(root["url"]), !playURL.isEmpty else {
            return nil
        }
        return await probe(playURL)
    }

    /// 先拉 1KB 确认「真的很像音频」，再交给播放器 —— 否则 VIP 曲目会跳到一个 HTML 404 页
    private static func probe(_ urlString: String) async -> AudioStream? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
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
