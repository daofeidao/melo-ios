import Foundation

/// 国内音源（酷狗 + 网易云）搜索与取流。
///
/// 为什么以酷狗为主：实测主流歌曲在网易云几乎全是 VIP，外链（outer/url）会跳到
/// 404 网页，命中率仅 0~20%；酷狗的 `songsearch_v2` + `playInfo` 对同一批歌
/// 全部返回可播直链，是更可靠的免费来源。网易云作为补充保留。
///
/// 两个已知坑：
/// 1. 网易云请求不带中国境内 IP 时会返回 `{"result":"<hex>"}` 加密体，必须加 `X-Real-IP`；
/// 2. 酷狗的 `mobilecdn` / `msearchcdn` 域名证书校验会失败，只有 `songsearch` 可用。
enum DomesticSource {

    static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"

    /// 声明一个境内 IP，绕开「境外 IP 返回加密体」的反爬策略
    static let declaredIP = "116.25.146.177"

    // MARK: - 搜索

    /// 两源并发合并：酷狗在前（可播率高），网易云在后（补充冷门与独立音乐）
    static func search(query: String, limit: Int = 20) async -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 同上：不用 async let（会踩 asyncLet_finish_after_task_completion 的坑）
        let kugouJob = Task { await kugouSearch(query: trimmed, limit: limit) }
        let neteaseJob = Task { await neteaseSearch(query: trimmed, limit: limit) }

        let kugou = await kugouJob.value
        let netease = await neteaseJob.value

        var merged: [Track] = []
        var seen = Set<String>()

        for track in kugou + netease {
            let key = normalize(track.title) + "|" + normalize(track.artist)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(track)
        }
        return merged
    }

    // MARK: - 酷狗

    static func kugouSearch(query: String, limit: Int = 20) async -> [Track] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://songsearch.kugou.com/song_search_v2?keyword=\(encoded)&page=1&pagesize=\(limit)")
        else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.kugou.com/", forHTTPHeaderField: "Referer")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = JS.dict(root["data"]),
              let lists = JS.array(payload["lists"])
        else { return [] }

        return lists.compactMap { raw -> Track? in
            guard let item = JS.dict(raw),
                  let hash = JS.string(item["FileHash"]), !hash.isEmpty,
                  let title = JS.string(item["SongName"]), !title.isEmpty
            else { return nil }

            let artist = JS.string(item["SingerName"]) ?? ""
            let seconds = JS.int(item["Duration"]) ?? 0
            // 酷狗的 Image 是模板串（含 {size} 占位），AlbumImage 才是专辑图。
            // 以前直接拿 Image 当 URL，界面就一直是占位符。
            let artwork = normalizeArtwork(JS.string(item["AlbumImage"]))
                ?? normalizeArtwork(JS.string(item["Image"]))

            return Track(
                videoId: "",
                title: title.replacingOccurrences(of: "<em>", with: "").replacingOccurrences(of: "</em>", with: ""),
                artist: artist.isEmpty ? L("Unknown Artist") : artist,
                album: JS.string(item["AlbumName"]),
                duration: seconds,
                artwork: artwork,
                source: PlaylistPlatform.kugou.rawValue,
                sourceID: hash
            )
        }
    }

    static func kugouStreamURL(hash: String) async -> URL? {
        guard let url = URL(string: "https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=\(hash)") else {
            return nil
        }
        var request = URLRequest(url: url)
        // 12 秒：从境外机房到 m.kugou.com 实测经常要 6~10 秒，
        // 之前压到 6 秒导致搜索结果里"可播"的曲子全部被判失败
        request.timeoutInterval = 12
        request.setValue(mobileUA, forHTTPHeaderField: "User-Agent")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let playURL = JS.string(root["url"]), !playURL.isEmpty,
              let parsed = URL(string: playURL)
        else { return nil }
        return parsed
    }

    // MARK: - 网易云

    static func neteaseSearch(query: String, limit: Int = 20) async -> [Track] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://music.163.com/api/search/get/web?s=\(encoded)&type=1&limit=\(limit)&offset=0")
        else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(declaredIP, forHTTPHeaderField: "X-Real-IP")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = JS.dict(root["result"]),
              let songs = JS.array(result["songs"])
        else { return [] }

        return songs.compactMap { raw -> Track? in
            guard let song = JS.dict(raw),
                  let id = JS.int(song["id"]).map(String.init),
                  let title = JS.string(song["name"]), !title.isEmpty
            else { return nil }

            let artists = (JS.array(song["artists"]) ?? [])
                .compactMap { JS.dict($0) }
                .compactMap { JS.string($0["name"]) }
                .joined(separator: ", ")

            let albumNode = JS.dict(song["album"])
            let artwork = JS.string(albumNode?["picUrl"] ?? "")
            let seconds = (JS.int(song["duration"]) ?? 0) / 1000

            return Track(
                videoId: "",
                title: title,
                artist: artists.isEmpty ? L("Unknown Artist") : artists,
                album: albumNode.flatMap { JS.string($0["name"]) },
                duration: seconds,
                artwork: artwork.flatMap { $0.isEmpty ? nil : $0 },
                source: PlaylistPlatform.netease.rawValue,
                sourceID: id
            )
        }
    }

    static func neteaseStreamURL(id: String) async -> URL? {
        await resolveURL("https://music.163.com/song/media/outer/url?id=\(id).mp3")
    }

    // MARK: - 可播性验证

    /// 只保留真正能拉到音频的曲目，避免"看得见点不动"。
    /// 网易云对 VIP/无版权会重定向到 404 网页，必须逐条验证。
    static func playableOnes(from tracks: [Track], limit: Int = 12) async -> [Track] {
        let candidates = Array(tracks.prefix(limit))
        guard !candidates.isEmpty else { return [] }

        var keep = [Bool](repeating: false, count: candidates.count)

        await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, track) in candidates.enumerated() {
                group.addTask { (index, await isPlayable(track: track)) }
            }
            for await (index, ok) in group {
                keep[index] = ok
            }
        }

        return candidates.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    static func isPlayable(track: Track) async -> Bool {
        guard let platform = track.source.flatMap(PlaylistPlatform.init(rawValue:)),
              let id = track.sourceID, !id.isEmpty else { return false }

        switch platform {
        case .kugou:
            // playInfo 直接给出直链，能取到就说明可播
            return await kugouStreamURL(hash: id) != nil
        case .netease:
            return await neteaseStreamURL(id: id) != nil
        case .qq:
            return false
        }
    }

    private static func resolveURL(_ string: String) async -> URL? {
        guard let url = URL(string: string) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              data.count > 512,
              let finalURL = response.url
        else { return nil }

        let mime = (http.mimeType ?? "").lowercased()
        let looksAudio = mime.contains("audio") || mime.contains("mpeg") || mime.contains("octet-stream")
        return looksAudio ? finalURL : nil
    }

    // MARK: - 按歌名匹配（YouTube 被拦时的保底）

    /// 宁可找不到，也不播翻唱：标题必须同名或包含，艺人必须对得上
    static func match(title: String, artist: String, duration: Int) async -> Track? {
        let query = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
        guard !query.isEmpty else { return nil }

        let candidates = await search(query: query, limit: 30)
        guard !candidates.isEmpty else { return nil }

        let wantedTitle = normalize(title)
        let wantedArtist = normalize(artist)
        guard !wantedTitle.isEmpty else { return nil }

        var best: (track: Track, score: Int)?

        for candidate in candidates {
            let candidateTitle = normalize(candidate.title)
            var score = 0

            if candidateTitle == wantedTitle {
                score += 100
            } else if candidateTitle.contains(wantedTitle) || wantedTitle.contains(candidateTitle) {
                score += 50
            } else {
                continue
            }

            if !wantedArtist.isEmpty {
                let candidateArtist = normalize(candidate.artist)
                let matched = candidateArtist == wantedArtist
                    || candidateArtist.contains(wantedArtist)
                    || wantedArtist.contains(candidateArtist)
                // 艺人没对上基本就是翻唱，直接跳过，避免播成别人的版本
                guard matched else { continue }
                score += 60
            } else {
                // 没有艺人信息时，酷狗优先（可播率更高）
                if candidate.source == PlaylistPlatform.kugou.rawValue { score += 20 }
            }

            if duration > 20, candidate.duration > 20 {
                let diff = abs(candidate.duration - duration)
                if diff <= 5 {
                    score += 30
                } else if diff <= 15 {
                    score += 10
                } else if diff > 60 {
                    continue
                }
            }

            if score > (best?.score ?? 0) {
                best = (candidate, score)
            }
        }

        guard let picked = best, picked.score >= 100 else { return nil }
        return picked.track
    }

    // MARK: - 工具

    /// 酷狗返回的封面是模板：`http://imge.kugou.com/stdmusic/{size}/2025....jpg`。
    /// 必须把 {size} 换成像素数，并升到 https，否则只会一直显示占位图。
    static func normalizeArtwork(_ raw: String?) -> String? {
        guard var text = raw, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "{size}", with: "240")
        if text.hasPrefix("http://") {
            text = "https://" + text.dropFirst("http://".count)
        }
        guard text.hasPrefix("https://") else { return nil }
        return text
    }

    /// 小写、去括注与书名号、只留数字/字母/CJK，让「晴天 (Live)」和「晴天」能对上
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let stripped = lowered.replacingOccurrences(
            of: "\\([^)]*\\)|（[^）]*）|\\[[^\\]]*\\]|【[^】]*】|《[^》]*》|〈[^〉]*〉",
            with: "",
            options: .regularExpression
        )
        let cleaned = String(stripped.unicodeScalars.filter { scalar in
            let value = scalar.value
            return (value >= 48 && value <= 57)
                || (value >= 97 && value <= 122)
                || (value >= 0x4E00 && value <= 0x9FA5)
        })
        return cleaned.isEmpty ? lowered.trimmingCharacters(in: .whitespaces) : cleaned
    }
}
