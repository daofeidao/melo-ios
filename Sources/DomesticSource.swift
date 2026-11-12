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
    /// - Parameter kugouFirst: 兜底匹配用。酷狗能播率高，先在酷狗找，
    ///   找不到再问网易云 —— 比两源并发少一半请求（匹配场景不需要那么全）。
    static func search(query: String, limit: Int = 20, kugouFirst: Bool = false) async -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 设置里关掉的源直接不发请求
        let prefs = SourcePrefs.shared
        let kugouOn = prefs.isEnabled("kugou")
        let neteaseOn = prefs.isEnabled("netease")
        let kuwoOn = prefs.isEnabled("kuwo")

        // 同上：不用 async let（会踩 asyncLet_finish_after_task_completion 的坑）
        let kugouJob = Task { () -> [Track] in
            guard kugouOn else { return [] }
            return await kugouSearch(query: trimmed, limit: limit)
        }
        let neteaseJob: Task<[Track], Never>? = (kugouFirst || !neteaseOn)
            ? nil
            : Task { await neteaseSearch(query: trimmed, limit: limit) }
        // 酷我当第三路：直链最容易拿，兜底用
        let kuwoJob: Task<[Track], Never>? = (kugouFirst || !kuwoOn)
            ? nil
            : Task { await kuwoSearch(query: trimmed, limit: min(limit, 10)) }

        let kugou = await kugouJob.value
        if kugouFirst, !kugou.isEmpty {
            return dedup(kugou)
        }
        let netease = await neteaseJob?.value ?? []
        let kuwo = await kuwoJob?.value ?? []

        return dedup(kugou + netease + kuwo)
    }

    private static func dedup(_ tracks: [Track]) -> [Track] {
        var merged: [Track] = []
        var seen = Set<String>()
        for track in tracks {
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
        request.timeoutInterval = 6
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.kugou.com/", forHTTPHeaderField: "Referer")
        request.meloCookie(for: "kugou")

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
        // 实测 playInfo 74~284ms，5 秒足够；失败要快速暴露
        request.timeoutInterval = 5
        request.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        request.meloCookie(for: "kugou")

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
        request.timeoutInterval = 6
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(declaredIP, forHTTPHeaderField: "X-Real-IP")
        request.meloCookie(for: "netease")

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
            // fee：0 免费、8 免费低音质、1 VIP、4 需购买
            let fee = JS.int(song["fee"]) ?? 0

            return Track(
                videoId: "",
                title: title,
                artist: artists.isEmpty ? L("Unknown Artist") : artists,
                album: albumNode.flatMap { JS.string($0["name"]) },
                duration: seconds,
                artwork: artwork.flatMap { $0.isEmpty ? nil : $0 },
                source: PlaylistPlatform.netease.rawValue,
                sourceID: id,
                isVip: fee == 1 || fee == 4
            )
        }
    }

    /// 按音质档位逐级取流。匿名只给 128，320 / 无损要 Cookie 里的 MUSIC_U（会员），
    /// 所以必须从高往低试：选了无损但没会员时自动落到 320 / 128，而不是整首放不出来。
    static func neteaseStreamURL(
        id: String,
        quality: StreamResolver.Quality = .high
    ) async -> URL? {
        // player/url 直接回 CDN 地址（实测 ~150ms），比 outer/url 的 302 + Range 探测快
        for br in quality.neteaseBitrates {
            if let direct = await neteasePlayerURL(id: id, br: br) { return direct }
        }
        return await resolveURL("https://music.163.com/song/media/outer/url?id=\(id).mp3")
    }

    /// 网易云第二条取流路径：API 直接给带签名的 mp3 地址，不用跟 302。
    /// 实测 http / https 都返回 206 audio/mpeg，这里统一升成 https。
    private static func neteasePlayerURL(id: String, br: Int) async -> URL? {
        guard let url = URL(string: "https://music.163.com/api/song/enhance/player/url?id=\(id)&ids=%5B\(id)%5D&br=\(br)")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(declaredIP, forHTTPHeaderField: "X-Real-IP")
        request.meloCookie(for: "netease")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let first = (JS.array(root["data"]) ?? []).compactMap({ JS.dict($0) }).first,
              let raw = JS.string(first["url"]), !raw.isEmpty else { return nil }

        var text = raw
        if text.hasPrefix("http://") {
            text = "https://" + text.dropFirst("http://".count)
        }
        return URL(string: text)
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
            return await neteaseStreamURL(id: id, quality: .high) != nil
        case .kuwo:
            return await kuwoStreamURL(id: id, quality: .high) != nil
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

    // MARK: - 按歌名匹配（播放失败时的保底）

    /// 严格匹配开关（设置 → 播放 → 严格匹配）。
    /// 开着时「歌名 + 艺人 + 时长」三项必须都对上，时长允许 ±5 秒；
    /// 关掉是原来的打分制，找不到严格命中的也会退而求其次。
    static let strictMatchKey = "melo.matchStrict"

    /// 用户手动「切换音源」时置 true：那一首不套严格匹配，否则点了也播不出来
    static var forceLooseOnce = false

    static var isStrictMatch: Bool {
        if forceLooseOnce { return false }
        return UserDefaults.standard.bool(forKey: strictMatchKey)
    }

    /// 快路径：只问酷狗（一次请求），取最可信的一条。
    static func match(title: String, artist: String, duration: Int) async -> Track? {
        let query = titleArtistQuery(title: title, artist: artist)
        guard !query.isEmpty else { return nil }
        let found = await search(query: query, limit: 30, kugouFirst: true)
        let picked = ranked(title: title, artist: artist, duration: duration, tracks: found)
        guard let best = picked.first else { return nil }
        return best.track
    }

    /// 全源兜底：酷狗 + 网易云 + 酷我并发拉齐，按可播率排序后逐个试。
    /// 歌单里的 QQ / 网易云 VIP 曲目走这条路 —— 以前只问酷狗，酷狗没版权就直接判失败。
    static func fallbackCandidates(title: String, artist: String, duration: Int,
                                   limit: Int = 6) async -> [Track] {
        let query = titleArtistQuery(title: title, artist: artist)
        guard !query.isEmpty else { return [] }
        let found = await search(query: query, limit: 30)
        let picked = ranked(title: title, artist: artist, duration: duration, tracks: found)
        return Array(picked.prefix(limit).map { $0.track })
    }

    /// 严格模式下用来「切换音源」的候选：同名、艺人能对上，但时长不在 ±5 秒内。
    /// 只给用户手动选择，不参与自动播放。
    static func nearMatches(title: String, artist: String, duration: Int,
                            limit: Int = 6) async -> [Track] {
        let query = titleArtistQuery(title: title, artist: artist)
        guard !query.isEmpty else { return [] }
        let found = await search(query: query, limit: 30)
        let wanted = normalize(title)
        guard !wanted.isEmpty else { return [] }
        let sameTitle = found.filter {
            let candidate = normalize($0.title)
            return candidate == wanted || candidate.contains(wanted) || wanted.contains(candidate)
        }
        let rankedLoose = ranked(title: title, artist: artist, duration: duration,
                                 tracks: sameTitle, forceLoose: true)
        return Array(rankedLoose.prefix(limit).map { $0.track })
    }

    private static func titleArtistQuery(title: String, artist: String) -> String {
        [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 宁可找不到，也不播翻唱：标题必须同名或包含，艺人必须对得上。
    /// 另外按实测可播率给音源加权：酷狗 > 酷我 > 网易云，VIP 曲目降权。
    private static func ranked(title: String, artist: String, duration: Int,
                               tracks: [Track],
                               forceLoose: Bool = false) -> [(track: Track, score: Int)] {
        let wantedTitle = normalize(title)
        let wantedArtist = normalize(artist)
        guard !wantedTitle.isEmpty else { return [] }

        var scored: [(track: Track, score: Int)] = []

        // 严格模式：歌名、艺人、时长三项都必须对上，时长允许 ±5 秒。
        // 宁可这首播不出来，也不播成翻唱 / 现场版 / 他人改编。
        if isStrictMatch && !forceLoose {
            for candidate in tracks {
                guard normalize(candidate.title) == wantedTitle else { continue }

                if !wantedArtist.isEmpty {
                    let candidateArtist = normalize(candidate.artist)
                    guard !candidateArtist.isEmpty,
                          candidateArtist == wantedArtist
                            || candidateArtist.contains(wantedArtist)
                            || wantedArtist.contains(candidateArtist) else { continue }
                }

                // 时长是严格模式的硬条件：两边都得有值，且差值不超过 5 秒
                guard duration > 0, candidate.duration > 0,
                      abs(candidate.duration - duration) <= 5 else { continue }

                var score = 190
                switch candidate.source ?? "" {
                case PlaylistPlatform.kugou.rawValue: score += 12
                case PlaylistPlatform.kuwo.rawValue: score += 10
                case PlaylistPlatform.netease.rawValue: score += 4
                default: break
                }
                if candidate.isVip { score -= 8 }
                scored.append((candidate, score))
            }
            return scored.sorted { $0.score > $1.score }
        }

        for candidate in tracks {
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

            let source = candidate.source ?? ""
            if source == PlaylistPlatform.kugou.rawValue {
                score += 12
            } else if source == PlaylistPlatform.kuwo.rawValue {
                score += 10
            } else if source == PlaylistPlatform.netease.rawValue {
                score += 4
            }
            if candidate.isVip { score -= 8 }

            guard score >= 100 else { continue }
            scored.append((candidate, score))
        }

        return scored.sorted { $0.score > $1.score }
    }

    // MARK: - 酷我

    /// 酷我的响应是 Python 字面量（单引号），不是严格 JSON。
    /// 先当 JSON 解析，失败再把「作为分隔符的单引号」换成双引号重试 ——
    /// 值里的撇号（Don't）前面是字母，不会被误伤。
    private static func kuwoJSON(_ text: String) -> [String: Any]? {
        if let data = text.data(using: .utf8),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return root
        }
        var fixed = text
        let patterns = [
            "(?<=[\\{,:])\\s*'",
            "'(?=\\s*[\\},:])"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(fixed.startIndex..., in: fixed)
            fixed = regex.stringByReplacingMatches(in: fixed, range: range, withTemplate: "\"")
        }
        guard let data = fixed.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return root
    }

    /// 酷我的文本里混着 HTML 实体（&nbsp; / &apos; / &amp; / &quot; …）。
    /// 不解码，「Don't」会变成「Don&apos;t」，按歌名匹配直接对不上。
    private static func decodeEntities(_ raw: String?) -> String {
        guard var text = raw else { return "" }
        let entities = [
            "&nbsp;": " ",
            "&apos;": "'",
            "&#39;": "'",
            "&quot;": "\"",
            "&lt;": "<",
            "&gt;": ">",
            "&hellip;": "…",
            "&amp;": "&"
        ]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 依次尝试一组镜像地址，谁先回内容用谁。酷我 / 网易云的 CDN 在不同网络下
    /// http 与 https 表现不一致，单押一个地址会偶发「整片源失效」。
    private static func fetchText(_ urls: [String], timeout: TimeInterval,
                                  headers: [String: String] = [:]) async -> String? {
        for raw in urls {
            guard let url = URL(string: raw) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let text = String(data: data, encoding: .utf8), !text.isEmpty else { continue }
            return text
        }
        return nil
    }

    /// 酷我的请求头：浏览器 UA + 设置里录入的 Cookie（有才加）
    private static var kuwoHeaders: [String: String] {
        var headers = ["User-Agent": browserUA]
        if let cookie = SourcePrefs.shared.cookie("kuwo") { headers["Cookie"] = cookie }
        return headers
    }

    static func kuwoSearch(query: String, limit: Int = 20) async -> [Track] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return [] }
        let path = "r.s?all=\(encoded)&ft=music&itemset=web_2013&client=kt&pn=0&rn=\(limit)&rformat=json&encoding=utf8"
        // 本机实测 https 169ms / http 273ms，两个都通；优先 https
        guard let text = await fetchText(
            ["https://search.kuwo.cn/" + path, "http://search.kuwo.cn/" + path],
            timeout: 6,
            headers: kuwoHeaders
        ),
              let root = kuwoJSON(text),
              let list = JS.array(root["abslist"]) else { return [] }

        return list.compactMap { raw -> Track? in
            guard let item = JS.dict(raw) else { return nil }
            let name = decodeEntities(JS.string(item["NAME"]))
            guard !name.isEmpty else { return nil }

            // MUSICRID 形如 MUSIC_51685512，取数字部分给 antiserver
            let rid = (JS.string(item["MUSICRID"]) ?? "")
                .replacingOccurrences(of: "MUSIC_", with: "")
            guard !rid.isEmpty else { return nil }

            let artist = decodeEntities(JS.string(item["ARTIST"]))
            let album = decodeEntities(JS.string(item["ALBUM"]))

            return Track(
                videoId: "",
                title: name,
                artist: artist.isEmpty ? L("Unknown Artist") : artist,
                album: album.isEmpty ? nil : album,
                duration: JS.int(item["DURATION"]) ?? 0,
                artwork: normalizeArtwork(JS.string(item["web_albumpic_short"])),
                source: PlaylistPlatform.kuwo.rawValue,
                sourceID: rid
            )
        }
    }

    /// antiserver 直接回一个 mp3 地址，不需要签名、不需要 cookie。
    /// 实测 http / https 都可用，直链本身 206 audio/mpeg。
    /// 酷我：`br=320kmp3` 匿名可用，`format=flac` 会被拒（"refuse request!"），
    /// 需要账号 Cookie。所以无损档位从高往低试。
    static func kuwoStreamURL(
        id: String,
        quality: StreamResolver.Quality = .high
    ) async -> URL? {
        for variant in quality.kuwoVariants {
            let path = "anti.s?type=convert_url&response=url&rid=MUSIC_\(id)&\(variant)"
            guard let text = await fetchText(
                ["https://antiserver.kuwo.cn/" + path, "http://antiserver.kuwo.cn/" + path],
                timeout: 5,
                headers: kuwoHeaders
            ) else { continue }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("http"), let resolved = URL(string: trimmed) { return resolved }
        }
        return nil
    }

    // MARK: - QQ 音乐直链（vkey）

    /// QQ 的 vkey 接口用 songmid 换签名直链。文件名前缀决定码率，
    /// 匿名能拿 C400(128) 与 M500(320)，F000(flac) 会回 result=104003。
    static func qqStreamURL(
        mid: String,
        quality: StreamResolver.Quality = .high
    ) async -> URL? {
        for (prefix, ext) in quality.qqTiers {
            if let url = await requestVkey(mid: mid, filename: "\(prefix)\(mid).\(ext)") {
                return url
            }
        }
        return nil
    }

    private static func requestVkey(mid: String, filename: String) async -> URL? {
        guard let endpoint = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return nil }
        let payload: [String: Any] = [
            "req_0": [
                "module": "vkey.GetVkeyServer",
                "method": "CgiGetVkey",
                "param": [
                    "guid": "10000",
                    "songmid": [mid],
                    "songtype": [0],
                    "filename": [filename],
                    "uin": "0",
                    "loginflag": 1,
                    "platform": "20",
                ],
            ],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.meloCookie(for: "qq")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let block = JS.dict(root["req_0"]),
              let info = JS.dict(block["data"]),
              let list = info["midurlinfo"] as? [[String: Any]],
              let first = list.first else { return nil }

        if (JS.int(first["result"]) ?? 0) != 0 { return nil }
        let sip = (info["sip"] as? [String])?.first ?? ""
        guard !sip.isEmpty, let purl = JS.string(first["purl"]), !purl.isEmpty else { return nil }

        var joined = sip + purl
        if joined.hasPrefix("http://") { joined = "https://" + joined.dropFirst("http://".count) }
        return URL(string: joined)
    }

    // MARK: - 网易云专辑 / 歌单搜索

    struct DomesticAlbum: Identifiable, Hashable {
        let id: String
        let name: String
        let artist: String
        let cover: String?
        let trackCount: Int
    }

    struct DomesticPlaylist: Identifiable, Hashable {
        let id: String
        let name: String
        let cover: String?
        let trackCount: Int
        let creator: String
    }

    static func neteaseAlbumSearch(query: String, limit: Int = 20) async -> [DomesticAlbum] {
        guard let result = await neteaseSearchRoot(query: query, type: 10, limit: limit),
              let albums = JS.array(result["albums"]) else { return [] }

        return albums.compactMap { raw -> DomesticAlbum? in
            guard let item = JS.dict(raw),
                  let id = JS.int(item["id"]).map(String.init),
                  let name = JS.string(item["name"]), !name.isEmpty else { return nil }

            let artist = (JS.array(item["artists"]) ?? [])
                .compactMap { JS.dict($0) }
                .compactMap { JS.string($0["name"]) }
                .joined(separator: ", ")

            return DomesticAlbum(
                id: id,
                name: name,
                artist: artist,
                cover: normalizeArtwork(JS.string(item["picUrl"])),
                trackCount: JS.int(item["size"]) ?? 0
            )
        }
    }

    static func neteasePlaylistSearch(query: String, limit: Int = 20) async -> [DomesticPlaylist] {
        guard let result = await neteaseSearchRoot(query: query, type: 1000, limit: limit),
              let playlists = JS.array(result["playlists"]) else { return [] }

        return playlists.compactMap { raw -> DomesticPlaylist? in
            guard let item = JS.dict(raw),
                  let id = JS.int(item["id"]).map(String.init),
                  let name = JS.string(item["name"]), !name.isEmpty else { return nil }

            let creator = JS.dict(item["creator"]).flatMap { JS.string($0["nickname"]) } ?? ""
            return DomesticPlaylist(
                id: id,
                name: name,
                cover: normalizeArtwork(JS.string(item["coverImgUrl"])),
                trackCount: JS.int(item["trackCount"]) ?? 0,
                creator: creator
            )
        }
    }

    /// 专辑详情：曲目挂在 album.songs[] 里（不在顶层）
    static func neteaseAlbumDetail(id: String) async -> CollectionDetail? {
        guard let url = URL(string: "https://music.163.com/api/album/\(id)") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(declaredIP, forHTTPHeaderField: "X-Real-IP")
        request.meloCookie(for: "netease")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let album = JS.dict(root["album"]) else { return nil }

        let name = JS.string(album["name"]) ?? L("Unknown Album")
        let artist = (JS.array(album["artists"]) ?? [])
            .compactMap { JS.dict($0) }
            .compactMap { JS.string($0["name"]) }
            .joined(separator: ", ")

        // 专辑曲目表要完整：没有平台 id、或需要付费的曲目照样占一行，
        // 只是标成灰显不可播。绝不拿同名翻唱 / Live / 别的版本来补位。
        let songs = (JS.array(album["songs"]) ?? []).enumerated().compactMap { index, raw -> Track? in
            guard let song = JS.dict(raw),
                  let title = JS.string(song["name"]), !title.isEmpty else { return nil }
            let sid = JS.int(song["id"]).map(String.init)
            let fee = JS.int(song["fee"]) ?? 0
            let seconds = (JS.int(song["duration"]) ?? JS.int(song["dt"]) ?? 0) / 1000
            let paid = fee == 1 || fee == 4
            return Track(
                videoId: "",
                title: title,
                artist: artist.isEmpty ? L("Unknown Artist") : artist,
                album: name,
                duration: seconds,
                artwork: normalizeArtwork(JS.string(album["picUrl"])),
                source: PlaylistPlatform.netease.rawValue,
                sourceID: sid ?? "unavailable:\(id):\(index)",
                isVip: paid,
                isUnavailable: sid == nil || paid,
                strictSource: true
            )
        }

        guard !songs.isEmpty else { return nil }
        let countText = String(format: L("%d songs"), songs.count)
        return CollectionDetail(
            title: name,
            subtitle: artist.isEmpty ? countText : "\(artist) · \(countText)",
            artwork: normalizeArtwork(JS.string(album["picUrl"])),
            tracks: songs
        )
    }

    private static func neteaseSearchRoot(query: String, type: Int, limit: Int) async -> [String: Any]? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://music.163.com/api/search/get?s=\(encoded)&type=\(type)&limit=\(limit)")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(declaredIP, forHTTPHeaderField: "X-Real-IP")
        request.meloCookie(for: "netease")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = JS.dict(root["result"]) else { return nil }
        return result
    }

    // MARK: - 工具

    /// 酷狗返回的封面是模板：`http://imge.kugou.com/stdmusic/{size}/2025....jpg`。
    /// 必须把 {size} 换成像素数，并升到 https，否则只会一直显示占位图。
    static func normalizeArtwork(_ raw: String?, size: Int = 240) -> String? {
        guard var text = raw, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "{size}", with: String(size))
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
