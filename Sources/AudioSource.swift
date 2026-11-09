import Foundation

/// 播放源解析：能拿到国内直链就优先用国内（延迟低、不受 YouTube 反爬影响），
/// 拿不到再回落到 YouTube Music。
enum AudioSource {

    static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    static func resolve(track: Track, quality: StreamResolver.Quality) async throws -> AudioStream {
        if let domestic = await domesticStream(for: track) {
            return domestic
        }

        do {
            return try await StreamResolver.resolve(videoId: track.videoId, quality: quality)
        } catch {
            // YouTube 被判定为机器人（或取不到直链）时，按歌名 + 艺人去国内音源找同一个版本。
            // 搜索/浏览里的歌没有平台 ID，这条兜底是它们唯一的出路。
            if let fallback = await domesticFallback(for: track) {
                return fallback
            }
            throw error
        }
    }

    // MARK: - 按歌名兜底国内音源

    /// 宁可找不到，也不播翻唱：标题必须同名、艺人必须对得上
    private static func domesticFallback(for track: Track) async -> AudioStream? {
        guard let id = await netEaseMatch(for: track) else { return nil }
        return await probe("https://music.163.com/song/media/outer/url?id=\(id).mp3")
    }

    private static func netEaseMatch(for track: Track) async -> String? {
        let query = [track.title, track.artist]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://music.163.com/api/search/get/web?s=\(encoded)&type=1&limit=30&offset=0")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = JS.dict(root["result"]),
              let songs = JS.array(result["songs"]) else { return nil }

        let wantedTitle = normalize(track.title)
        let wantedArtist = normalize(track.artist)

        var best: (id: String, score: Int)?

        for raw in songs {
            guard let song = JS.dict(raw),
                  let id = JS.int(song["id"]).map(String.init),
                  let name = JS.string(song["name"]) else { continue }

            let candidateTitle = normalize(name)
            var score = 0

            if candidateTitle == wantedTitle {
                score += 100
            } else if candidateTitle.contains(wantedTitle) || wantedTitle.contains(candidateTitle) {
                score += 50
            } else {
                continue
            }

            let artistNames = (JS.array(song["artists"]) ?? [])
                .compactMap { JS.dict($0) }
                .compactMap { JS.string($0["name"]) }
                .map(normalize)

            if !wantedArtist.isEmpty {
                let matched = artistNames.contains {
                    $0 == wantedArtist || $0.contains(wantedArtist) || wantedArtist.contains($0)
                }
                // 艺人没对上基本就是翻唱，直接跳过，避免播成别人的版本
                guard matched else { continue }
                score += 60
            }

            let seconds = (JS.int(song["duration"]) ?? 0) / 1000
            if track.duration > 20, seconds > 20 {
                let diff = abs(seconds - track.duration)
                if diff <= 5 {
                    score += 30
                } else if diff <= 15 {
                    score += 10
                } else if diff > 60 {
                    continue
                }
            }

            if score > (best?.score ?? 0) {
                best = (id, score)
            }
        }

        guard let picked = best, picked.score >= 100 else { return nil }
        return picked.id
    }

    /// 小写、去括号内容、去标点与空白，让「晴天 (Live)」和「晴天」能对上
    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let stripped = lowered.replacingOccurrences(
            of: "\\([^)]*\\)|（[^）]*）|\\[[^\\]]*\\]",
            with: "",
            options: .regularExpression
        )
        // 只留数字、小写字母和 CJK 基本区，避免依赖 ICU 的 \u 转义
        let cleaned = String(stripped.unicodeScalars.filter { scalar in
            let v = scalar.value
            return (v >= 48 && v <= 57) || (v >= 97 && v <= 122) || (v >= 0x4E00 && v <= 0x9FA5)
        })
        return cleaned.isEmpty ? lowered.trimmingCharacters(in: .whitespaces) : cleaned
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
