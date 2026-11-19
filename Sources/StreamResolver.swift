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
        var list: [Candidate] = []
        if let top = sortedAudio.first {
            list.append(Candidate(stream: top, bitrate: bitrate(top), needsPot: true))
            if identity?.gvsToken != nil {
                list.append(Candidate(stream: top, bitrate: bitrate(top), needsPot: false))
            }
        }
        // 兜底：format 18 是完整 mp4（含 AAC 96k），实测不受 GVS token 限制，永远能读。
        if let muxed = progressive.min(by: { bitrate($0) < bitrate($1) }) {
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

    /// 起播前探一次：先读文件头 4KB（顺带从 Content-Range 拿总长度），再读文件中段 4KB。
    /// 中段 206 才算这条直链真能播；只验「首块」会漏掉 token 失效的情况
    /// ——受保护视频会放第一块、之后全 403，表现就是「播到 20 秒突然没声音」。
    /// 只取 4KB 是因为卡的是请求本身，不是字节数：小请求一样能判死，还快。
    private static func probe(_ url: URL, userAgent: String) async -> Probe {
        let started = Date()
        var p = Probe(status: 0, total: 0, midStatus: 0, bytes: 0, ms: 0)
        do {
            let (data, resp) = try await rangeFetch(url, offset: 0, length: 4096, ua: userAgent)
            p.status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            p.bytes = data.count
            p.total = parseTotal(resp as? HTTPURLResponse) ?? Int64(data.count)
        } catch {
            // 探测失败最常见的是 403（被 GVS 门禁挡）和网络错；把码记下来才知道是哪种
            Diagnostics.mark("youtubekit: probe head failed \((error as NSError).code)")
            return p
        }
        if p.total > 1_048_576 {
            let mid = p.total / 2
            do {
                let (d, r) = try await rangeFetch(url, offset: mid, length: 4096, ua: userAgent)
                p.midStatus = (r as? HTTPURLResponse)?.statusCode ?? 0
                p.bytes += d.count
            } catch {
                Diagnostics.mark("youtubekit: probe mid failed \((error as NSError).code)")
                p.midStatus = (error as NSError).code
            }
        } else {
            p.midStatus = p.status
        }
        p.ms = Int(Date().timeIntervalSince(started) * 1000)
        return p
    }

    private static func rangeFetch(
        _ url: URL, offset: Int64, length: Int, ua: String
    ) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        req.timeoutInterval = 20
        // 单次不重试：失败就换下一个候选，重试只会拖慢起播
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 206 || (code == 200 && offset == 0) else {
            throw NSError(domain: "melo.youtube", code: code)
        }
        return (data, resp)
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

        // 铸 token 与库解析并行：库要先拉 watch 页 + 下载 player JS，正好盖住铸造耗时。
        async let identityTask = PoTokenMinter.shared.identity(for: videoId)
        let identity = await identityTask
        let attachPot = !UserDefaults.standard.bool(forKey: "melo.debug.noPot")

        do {
            let list = try await candidates(videoId: videoId, quality: quality, identity: identity)

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
            let probes: [Int: Probe]
            if let first = prepared.first {
                probes = [first.index: await probe(first.url, userAgent: first.ua)]
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
            switch error {
            case .videoAgeRestricted, .videoUnavailable, .videoPrivate, .membersOnly, .videoRegionBlocked:
                throw ApiError.botCheck(error.localizedDescription ?? error.rawValue)
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
