import Foundation
import YouTubeKit

/// YouTube 解析层。
///
/// 底层用 alexeichhorn/YouTubeKit 做真正的 player 请求 + cipher 求解 + 多客户端兜底，
/// 本文件负责三件事：
///   1. 把库选出的流翻译成 Melo 的 `AudioStream`；
///   2. **验证**这条直链真的能分段读（受保护视频只放第一块，后面全 403）；
///   3. 交给 `LocalStreamProxy` 包一层本地地址，让 AVPlayer 不必自己去应付
///      googlevideo 的 UA 校验、pot 参数和代理问题。
///
/// 为什么必须验证：
/// YouTube 现在对不少视频强制 GVS PO Token，没有 token 时第一块 256KB 正常返回
/// 206，之后的 Range 全部 403 —— 表现就是「播到 20 秒突然没声音、进度条照走」。
/// 起播前在文件中段探一次字节，能当场判死，不必等用户听完 20 秒才发现。
enum StreamResolver {

    enum Quality: String, CaseIterable, Identifiable {
        case lossless
        case high
        case normal
        case low

        var id: String { rawValue }

        var label: String {
            switch self {
            case .lossless: return L("Lossless")
            case .high: return L("High")
            case .normal: return L("Standard")
            case .low: return L("Data Saver")
            }
        }

        var detail: String {
            switch self {
            case .lossless: return L("FLAC where the source has it. Needs a signed-in membership account.")
            case .high: return L("Up to 320 kbps")
            case .normal: return L("About 128 kbps")
            case .low: return L("About 64 kbps")
            }
        }

        /// 国内源要码率数字：网易云按 br、腾讯按文件名前缀、酷我按 query
        var neteaseBitrates: [Int] {
            switch self {
            case .lossless: return [999_000, 320_000, 128_000]
            case .high: return [320_000, 128_000]
            case .normal, .low: return [128_000]
            }
        }

        var kuwoVariants: [String] {
            switch self {
            case .lossless: return ["format=flac&br=2000kflac", "format=mp3&br=320kmp3", "format=mp3&br=128kmp3"]
            case .high: return ["format=mp3&br=320kmp3", "format=mp3&br=128kmp3"]
            case .normal, .low: return ["format=mp3&br=128kmp3"]
            }
        }

        /// 文件名前缀即码率：C400=m4a 128、M500=mp3 320、F000=flac（付费）
        var qqTiers: [(String, String)] {
            switch self {
            case .lossless: return [("F000", "flac"), ("M500", "mp3"), ("C400", "m4a")]
            case .high: return [("M500", "mp3"), ("C400", "m4a")]
            case .normal, .low: return [("C400", "m4a")]
            }
        }
    }

    /// 对外仍暴露一个数（诊断面板显示「客户端池」用）。库由多客户端并发兜底，
    /// 这里给一个固定值代表池大小，避免改动诊断 UI。
    static var clientCount: Int { 3 }

    /// googlevideo 拉流要带与解析身份一致的 UA。
    /// 必须与解析客户端一致：库用 ANDROID 客户端拿明文直链，
    /// googlevideo 校验 UA 与签名身份绑定，换 UA 会被拒。
    static let clientUserAgent = "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip"

    // MARK: - 候选

    /// 一条待验证的播放候选。`needsPot` 为 false 的是免 token 的兜底（format 18）。
    private struct Candidate {
        let stream: YouTubeKit.Stream
        let bitrate: Int
        let needsPot: Bool
    }

    /// 用 YouTubeKit 解析一次，按优先级排出候选：
    /// ① 目标音质的 m4a 纯音频（要 pot）→ ② 其余 m4a → ③ 渐进式 mp4（format 18，免 pot）
    /// YouTube 的画面与音轨是两条互斥的流，取哪条由用户决定：
    ///   - 纯音频（itag 140 等，约 130k）—— 音质好，但没有画面
    ///   - muxed（format 18，96k AAC + 360p）—— 有画面，音质差
    enum VideoPreference: String, CaseIterable {
        /// 只看画面：直接选带画面的合体流
        case video
        /// 只听声音：优先纯音频；万一只能拿到合体流，播放页也不显示画面
        case audio
        /// 自动：优先纯音频（音质优先），拿到带画面的流就顺手把画面显示出来
        case auto
    }

    static let videoModeKey = "melo.youtube.videoMode"
    /// 3.1.2 只有一个布尔开关，开过的人迁移到「视频」
    private static let legacyPreferVideoKey = "melo.youtube.preferVideo"

    static var videoMode: VideoPreference {
        get {
            if let raw = UserDefaults.standard.string(forKey: videoModeKey),
               let mode = VideoPreference(rawValue: raw) {
                return mode
            }
            if UserDefaults.standard.bool(forKey: legacyPreferVideoKey) { return .video }
            return .auto
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: videoModeKey) }
    }

    private static func candidates(
        videoId: String, quality: Quality,
        identity: PoTokenMinter.POIdentity?
    ) async throws -> [Candidate] {
        let youtube = YouTube(videoID: videoId)
        if let identity = identity {
            // 实测：给 ANDROID 的 player 请求塞 serviceIntegrityDimensions
            // 会被直接打回 400（token 与客户端不匹配），比不发还糟。
            // 默认只传 visitor（与铸 token 用的 visitor 同源，服务端才认得出）。
            let sendPlayerToken = UserDefaults.standard.bool(forKey: "melo.debug.playerToken")
            youtube.identity = YouTube.YouTubeIdentity(
                visitorData: identity.visitorData,
                playerToken: sendPlayerToken ? identity.playerToken : nil)
        }
        let all = try await youtube.streams
        YouTubeSelfTest.noteStreams(all)

        // AVPlayer 原生只吃 AAC/m4a；webm/opus 在 Catalyst 上解不了。
        let audioOnly = all.filter { $0.videoCodec == nil && $0.fileExtension == .m4a }
        let progressive = all.filter { $0.isProgressive && $0.fileExtension == .mp4 }

        func bitrate(_ s: YouTubeKit.Stream) -> Int { s.averageBitrate ?? s.bitrate ?? 0 }

        let sortedAudio: [YouTubeKit.Stream]
        switch quality {
        case .lossless, .high:
            sortedAudio = audioOnly.sorted { bitrate($0) > bitrate($1) }
        case .normal:
            sortedAudio = audioOnly.sorted { abs(bitrate($0) - 128_000) < abs(bitrate($1) - 128_000) }
        case .low:
            sortedAudio = audioOnly.sorted { bitrate($0) < bitrate($1) }
        }

        // 只留三条候选，别把 4 个音质档都排上：受保护视频它们会以同样的方式 403，
        // 每多探一条就多等 5 秒。顺序 = 首选音质(带 pot) → 同一档不带 pot → 免 token 兜底。
        //
        // 唯一的例外是「只看画面」：YouTube 的纯音频流没有视频轨，播放页只能显示封面；
        // 只有 muxed 的 format 18 自带画面（360p），代价是 96k。
        // 选 audio / auto 时仍以纯音频优先，auto 拿到合体流会顺手显示画面。
        let muxed = progressive.min(by: { bitrate($0) < bitrate($1) })

        var list: [Candidate] = []
        if Self.videoMode == .video, let muxed = muxed {
            list.append(Candidate(stream: muxed, bitrate: bitrate(muxed), needsPot: false))
        } else if let top = sortedAudio.first {
            list.append(Candidate(stream: top, bitrate: bitrate(top), needsPot: true))
            if identity?.gvsToken != nil {
                list.append(Candidate(stream: top, bitrate: bitrate(top), needsPot: false))
            }
        }
        // 兜底：format 18 是完整 mp4（含 AAC 96k），实测不受 GVS token 限制，永远能读。
        if let muxed = muxed, list.first?.stream.itag.itag != muxed.itag.itag {
            list.append(Candidate(stream: muxed, bitrate: bitrate(muxed), needsPot: false))
        }
        guard !list.isEmpty else {
            throw ApiError.unavailable(L("No audio stream available for this track"))
        }
        return list
    }

    // MARK: - pot

    /// GVS token 是内容绑定（videoId），必须走媒体直链的 `&pot=`。
    /// 不能重排/重新解析 URL —— URLComponents 往返会动到 `sig` 的转义，
    /// 服务端签名一破就 403（实测会变成 -1 NSURLError）。所以只做字符串拼接。
    static func appendingPot(_ url: URL, token: String?) -> URL {
        guard let token = token, !token.isEmpty else { return url }
        let text = url.absoluteString
        if text.contains("&pot=") || text.contains("?pot=") { return url }
        let glue = text.contains("?") ? "&" : "?"
        return URL(string: text + glue + "pot=" + token) ?? url
    }

    // MARK: - 验证

    private struct Probe {
        var status: Int
        var total: Int64
        var midStatus: Int
        var bytes: Int
        var ms: Int
    }

    /// 起播前探一次：文件头 4KB + 文件尾部 4KB，**并发**发出去。
    ///
    /// 尾部能读，说明这道 GVS 门禁不拦「非首块」请求，中段自然也读得到；
    /// 只验首块会漏掉 token 失效——受保护视频会放第一块、之后全 403，
    /// 表现就是「播到 20 秒突然没声音」。
    ///
    /// 串行做这两次在慢网下实测要 8.6 秒（两次往返），并发只等于慢的那一次。
    /// 尾部用 `bytes=-4096` 而不是「总长的一半」：不必先等首块的 Content-Range 回来。
    private static func probe(_ url: URL, userAgent: String) async -> Probe {
        let started = Date()
        async let headTask = rangeProbe(url, range: "bytes=0-4095", ua: userAgent)
        async let tailTask = rangeProbe(url, range: "bytes=-4096", ua: userAgent)
        let head = await headTask
        let tail = await tailTask

        var p = Probe(status: head.code, total: head.total > 0 ? head.total : tail.total,
                      midStatus: tail.code, bytes: head.bytes + tail.bytes, ms: 0)
        // 几 KB 的小文件没有「中段」可判，直接按首块结论走
        if p.total > 0 && p.total < 65_536 { p.midStatus = p.status }
        if head.code != 206 && head.code != 200 {
            Diagnostics.mark("youtubekit: probe head failed \(head.code)")
        }
        if tail.code != 206 && tail.code != 200 {
            Diagnostics.mark("youtubekit: probe tail failed \(tail.code)")
        }
        p.ms = Int(Date().timeIntervalSince(started) * 1000)
        return p
    }

    /// 只关心状态码的探测请求：失败也把码带回来（403 / -1001 都要能记日志）
    private static func rangeProbe(_ url: URL, range: String, ua: String) async
        -> (code: Int, bytes: Int, total: Int64) {
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue(range, forHTTPHeaderField: "Range")
        req.timeoutInterval = 12
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            return (http?.statusCode ?? 0, data.count, parseTotal(http) ?? Int64(data.count))
        } catch {
            return ((error as NSError).code, 0, 0)
        }
    }

    private static func parseTotal(_ http: HTTPURLResponse?) -> Int64? {
        guard let cr = http?.value(forHTTPHeaderField: "Content-Range"),
              let last = cr.split(separator: "/").last,
              let n = Int64(last) else { return nil }
        return n > 0 ? n : nil
    }

    /// 逐条候选验证，第一条「首块 + 中段都通」的直接用。
    static func resolve(videoId: String, quality: Quality) async throws -> AudioStream {
        guard !videoId.isEmpty else {
            throw ApiError.unavailable(L("Invalid video ID"))
        }

        // 库内部的 os_log 不落到 App 的 trace，接出来才能看到每个客户端的真实结果。
        YouTube.debugLog = { message in Diagnostics.mark(message) }

        // 把「设置里登录的 YouTube 账号」交给库。登录之后 YouTube 对 GVS PO Token
        // 的强制会大幅放宽（官方文档：Premium 订阅者完全不需要），也是唯一能同时
        // 解决「96k 天花板」和「Sign in to confirm you're not a bot」的东西。
        YouTube.cookieProvider = {
            let cookie = SourcePrefs.shared.cookie("youtube") ?? ""
            // 只认真正带登录态的 Cookie。残缺或过期的 Cookie 带上去，YouTube 会按
            // 「已登录但身份无效」处理，比匿名更容易被判 videoUnavailable —— 表现就是
            // 同一首歌在别的设备能播，在这台反而「无匹配版本」。
            let hasAuth = cookie.contains("SAPISID=") || cookie.contains("__Secure-3PSID=")
            if !hasAuth {
                if !cookie.isEmpty {
                    Diagnostics.mark("youtube: cookie 不完整，按匿名处理")
                }
                return nil
            }
            return cookie
        }

        // 铸 token 与 player 请求**真正并行**，而且不再挡在起播前面。
        // Android 客户端的 player 请求本来就不需要 token，而 BotGuard 首次要 6~10 秒。
        // 以前是先 await token 再发请求，等于把两段耗时相加；现在先发请求，
        // 拿到格式列表后再收 token，重叠掉的那几秒直接省下。
        let identityTask = Task { await PoTokenMinter.shared.identity(for: videoId) }
        let attachPot = !UserDefaults.standard.bool(forKey: "melo.debug.noPot")

        do {
            let list = try await candidates(videoId: videoId, quality: quality, identity: nil)
            let identity = await identityTask.value

            // 每条候选先算好 URL，再**并发**探测。串行探三条在慢网下要 15 秒，
            // 并发只需要一次往返的时间，最后仍按优先级取第一条通过的。
            var prepared: [(index: Int, cand: Candidate, url: URL, ua: String, pot: Bool)] = []
            for (i, cand) in list.enumerated() {
                try await cand.stream.waitUntilAvailable()
                let ua = cand.stream.clientUserAgent ?? clientUserAgent
                let token = (attachPot && cand.needsPot) ? identity?.gvsToken : nil
                prepared.append((i, cand, appendingPot(cand.stream.url, token: token), ua, token != nil))
            }

            // 只探首条：走的是「先试最高音质，不行就用免 token 兜底」。
            // 三条并发探测在慢网下等于陪最慢的那条等，实测多花 3 秒还多费两次请求。
            //
            // 但「需要 pot 却没拿到 pot」的那条根本不用探：itag 140 在无 GVS token 时
            // 中段必然 403（四种绑定组合全试过），探它只是白花 4~8 秒。
            // 直接跳过，让免 token 的 muxed 兜底上，起播立刻快一截。
            let probes: [Int: Probe]
            if let first = prepared.first {
                if first.cand.needsPot && !first.pot {
                    probes = [:]
                    Diagnostics.mark("youtubekit: 无 GVS token，跳过 itag\(first.cand.stream.itag.itag) 探测")
                } else {
                    probes = [first.index: await probe(first.url, userAgent: first.ua)]
                }
            } else {
                probes = [:]
            }

            for item in prepared {
                let p = probes[item.index] ?? Probe(status: 0, total: 0, midStatus: 0, bytes: 0, ms: 0)
                Diagnostics.mark("youtubekit: try itag=\(item.cand.stream.itag.itag) br=\(item.cand.bitrate)"
                    + " pot=\(item.pot ? "yes" : "no")"
                    + " first=\(p.status) mid=\(p.midStatus) total=\(p.total) \(p.ms)ms")

                // 首条不通：免 token 的兜底（format 18）是实测必然能读的，直接用它，
                // 不再为它多花一次探测；剩下的候选才需要真探。
                let trusted = item.cand.needsPot == false && item.cand.stream.isProgressive
                guard (p.status == 206 && p.midStatus == 206) || trusted else { continue }
                YouTubeSelfTest.noteChosen(itag: item.cand.stream.itag.itag,
                                          probe: "\(p.status)/\(p.midStatus)")

                // 这里返回的是**上游**直链，AudioStream 里不存 127.0.0.1 地址：
                // 那样缓存到磁盘后重启就是死链。本地地址由播放时按 key 现取。
                let mime = item.cand.stream.videoCodec == nil ? "audio/mp4" : "video/mp4"
                Diagnostics.mark("youtubekit: chosen itag=\(item.cand.stream.itag.itag) size=\(p.total)")
                // 顺手登记路由，并带上「直链挂了怎么办」的补救闭包：
                // 播到一半节点掉线时，代理会调它重新解析换一条新直链，续上同一个 Range。
                let chosenItag = item.cand.stream.itag.itag
                let chosenNeedsPot = item.cand.needsPot
                _ = LocalStreamProxy.shared.register(
                    upstream: item.url, userAgent: item.ua, mime: mime,
                    key: "yt-\(chosenItag)-\(videoId)",
                    refresh: {
                        // 重新走一遍候选流程（新建 YouTube 对象才会真的重发 player 请求），
                        // 锁定同一个 itag，避免换流导致字节错位。
                        guard let fresh = try? await candidates(
                                videoId: videoId, quality: quality, identity: identity),
                              let same = fresh.first(where: { $0.stream.itag.itag == chosenItag })
                        else { return nil }
                        let token = (attachPot && chosenNeedsPot) ? identity?.gvsToken : nil
                        return appendingPot(same.stream.url, token: token)
                    })
                // 调试留痕：把最终交给 AVPlayer 的上游直链落一份，方便在外部用 curl 复现 403
                if UserDefaults.standard.bool(forKey: "melo.debug.dumpURL") {
                    let dump = item.url.absoluteString + "\nUA: " + item.ua + "\n"
                    try? dump.write(toFile: NSTemporaryDirectory() + "melo-stream-url.txt",
                                    atomically: true, encoding: .utf8)
                    Diagnostics.mark("youtubekit: url dumped -> \(NSTemporaryDirectory())melo-stream-url.txt")
                }
                return AudioStream(url: item.url, itag: item.cand.stream.itag.itag,
                                   bitrate: item.cand.bitrate, mime: mime,
                                   userAgent: item.ua, viaProxy: true)
            }

            let detail = prepared.map { "itag\($0.cand.stream.itag.itag):"
                + "\(probes[$0.index]?.status ?? 0)/\(probes[$0.index]?.midStatus ?? 0)" }
                .joined(separator: " ")
            Diagnostics.mark("youtubekit: 全部候选不可播 · \(detail)")
            throw ApiError.unavailable(L("No audio stream available for this track"))
        } catch let error as YouTubeKitError {
            // 库的 YouTubeKitError 多数 case 没有 localizedDescription，
            // 不记原始值的话日志里只剩「没有可播放版本」，根本定位不了。
            Diagnostics.mark("youtubekit: FAIL \(error.rawValue) · \(error.localizedDescription ?? "-")")
            // 每种失败原因给的处置方式完全不同，不能混成一句「无匹配版本」：
            // 地区限制 → 换节点；年龄限制 → 登录；IP 风控 → 换节点或稍后重试；
            // 私享/会员视频 → 这歌本身就看不了，换源也没用。
            switch error {
            case .videoRegionBlocked:
                throw ApiError.botCheck(L("YouTube says this video is not available in your network's region. Switching to another proxy node usually fixes it."))
            case .videoAgeRestricted:
                throw ApiError.botCheck(L("This video is age-restricted. Sign in to YouTube in Settings → Sources, then try again."))
            case .videoPrivate:
                throw ApiError.botCheck(L("This video is private and cannot be played."))
            case .membersOnly:
                throw ApiError.botCheck(L("This video is for channel members only."))
            case .videoUnavailable:
                throw ApiError.botCheck(L("YouTube rejected the request. This usually means the proxy's exit IP is being rate-limited — switch node and retry."))
            default:
                throw ApiError.unavailable(String(format: L("Unable to resolve playback URL: %@"),
                                                  error.localizedDescription ?? error.rawValue))
            }
        } catch {
            Diagnostics.mark("youtubekit: FAIL other \(type(of: error)) · \(error.localizedDescription)")
            if let typed = error as? ApiError { throw typed }
            throw ApiError.unavailable(String(format: L("Unable to resolve playback URL: %@"),
                                              error.localizedDescription))
        }
    }
}
