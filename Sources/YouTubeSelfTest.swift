import Foundation
import YouTubeKit

/// YouTube 播放链路的无界面自检。
///
/// 起 App 时带 `-yt-selftest <videoId>` 就会在后台把整条链路跑一遍并写进 trace.log：
///   ① 各客户端返回了什么流
///   ② 各种 PO Token 绑定下，直链的「首块 / 中段」Range 是不是都给 206
///   ③ 本地代理转发是否正常（AVPlayer 实际走的就是这条路）
///
/// 有了它，验证「到底哪个 token 绑定有效」不必反复点界面听歌，
/// 一次启动就能拿到 A/B 结果。
enum YouTubeSelfTest {

    static var videoId: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-yt-selftest"), i + 1 < args.count else { return nil }
        let v = args[i + 1]
        return v.isEmpty ? nil : v
    }

    private static var active: Bool { videoId != nil }

    // MARK: - StreamResolver 埋点

    static func noteStreams(_ all: [YouTubeKit.Stream]) {
        guard active else { return }
        let audio = all.filter { $0.videoCodec == nil }
        let prog = all.filter { $0.isProgressive }
        Diagnostics.mark("YT-TEST streams total=\(all.count) audioOnly=\(audio.count) progressive=\(prog.count)")
        for s in audio.prefix(6) {
            Diagnostics.mark("YT-TEST   audio itag=\(s.itag.itag) ext=\(s.fileExtension.rawValue)"
                + " br=\(s.averageBitrate ?? s.bitrate ?? 0)")
        }
        for s in prog.prefix(3) {
            Diagnostics.mark("YT-TEST   muxed itag=\(s.itag.itag) ext=\(s.fileExtension.rawValue)"
                + " br=\(s.averageBitrate ?? s.bitrate ?? 0)")
        }
    }

    static func noteChosen(itag: Int, probe: String) {
        guard active else { return }
        Diagnostics.mark("YT-TEST chosen itag=\(itag) probe=\(probe)")
    }

    // MARK: - 主流程

    static func run(_ vid: String) async {
        Diagnostics.mark("YT-TEST ===== 自检开始 \(vid) =====")

        // 1) 铸各种绑定的 token，看哪一枚能换来中段 206
        let variants = await PoTokenMinter.shared.mintVariants(videoId: vid)
        Diagnostics.mark("YT-TEST tokens: " + (variants.isEmpty ? "none"
            : variants.map { "\($0.label)=\($0.token.count)ch" }.joined(separator: " ")))
        let identity = await PoTokenMinter.shared.identity(for: vid)

        // 2) 关键 A/B：player 请求带不带 visitor，决定 pot 认不认这条直链
        var best: (YouTubeKit.Stream, String?)? = nil
        var bestLabel = "-"
        for withVisitor in [false, true] {
            let youtube = YouTube(videoID: vid)
            if withVisitor, let id = identity {
                youtube.identity = YouTube.YouTubeIdentity(visitorData: id.visitorData, playerToken: nil)
            }
            guard let all = try? await youtube.streams else {
                Diagnostics.mark("YT-TEST 取流失败 visitor=\(withVisitor)")
                continue
            }
            noteStreams(all)
            let audio = all.filter { $0.videoCodec == nil && $0.fileExtension == .m4a }
                .sorted { ($0.averageBitrate ?? 0) > ($1.averageBitrate ?? 0) }
            guard let stream = audio.first else {
                Diagnostics.mark("YT-TEST 没有 m4a 纯音频 visitor=\(withVisitor)")
                continue
            }
            let ua = stream.clientUserAgent ?? StreamResolver.clientUserAgent
            let tag = withVisitor ? "visitor" : "novisitor"

            var cases: [(String, String?)] = [("\(tag)+nopot", nil)]
            for v in variants { cases.append(("\(tag)+\(v.label)", v.token)) }
            for (label, token) in cases {
                let url = StreamResolver.appendingPot(stream.url, token: token)
                let r = await probeBoth(url, ua: ua)
                Diagnostics.mark("YT-TEST [\(label)] first=\(r.0) mid=\(r.1) total=\(r.2)")
                if r.0 == 206 && r.1 == 206 && best == nil {
                    best = (stream, token)
                    bestLabel = label
                }
            }
        }

        // 3) 兜底路径：渐进式 mp4（format 18），免 token
        let plain = YouTube(videoID: vid)
        if let all = try? await plain.streams,
           let muxed = all.filter({ $0.isProgressive }).min(by: {
               ($0.averageBitrate ?? 0) < ($1.averageBitrate ?? 0)
           }) {
            let ua = muxed.clientUserAgent ?? StreamResolver.clientUserAgent
            let r = await probeBoth(muxed.url, ua: ua)
            Diagnostics.mark("YT-TEST [muxed itag\(muxed.itag.itag) nopot] first=\(r.0) mid=\(r.1) total=\(r.2)")
            if r.0 == 206 && r.1 == 206 && best == nil {
                best = (muxed, nil)
                bestLabel = "muxed itag\(muxed.itag.itag)"
            }
        }

        // 4) 本地代理端到端：这才是 AVPlayer 真正会访问的地址
        if let (stream, token) = best {
            let ua = stream.clientUserAgent ?? StreamResolver.clientUserAgent
            let url = StreamResolver.appendingPot(stream.url, token: token)
            if let local = LocalStreamProxy.shared.register(
                upstream: url, userAgent: ua, mime: "audio/mp4", key: "selftest") {
                let r = await probeBoth(local, ua: "AppleCoreMedia/1.0.0")
                Diagnostics.mark("YT-TEST proxy[\(bestLabel)] first=\(r.0) mid=\(r.1) total=\(r.2)"
                    + " -> \(r.0 == 206 && r.1 == 206 ? "OK" : "FAIL")")
            } else {
                Diagnostics.mark("YT-TEST proxy 启动失败")
            }
        } else {
            Diagnostics.mark("YT-TEST 没有任何候选可用")
        }
        Diagnostics.mark("YT-TEST ===== 自检结束 =====")
    }

    /// 返回 (首块状态, 中段状态, 总长度)。只取 4KB，够判断 gating 又不拖时间。
    private static func probeBoth(_ url: URL, ua: String) async -> (Int, Int, Int64) {
        var first = 0
        var mid = 0
        var total: Int64 = 0
        let n = 4096
        if let (data, resp) = await fetch(url, offset: 0, length: n, ua: ua) {
            first = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let cr = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
               let last = cr.split(separator: "/").last, let t = Int64(last) {
                total = t
            }
            if total == 0 { total = Int64(data.count) }
        }
        if total > 1_048_576 {
            if let (_, resp) = await fetch(url, offset: total / 2, length: n, ua: ua) {
                mid = (resp as? HTTPURLResponse)?.statusCode ?? 0
            }
        } else {
            mid = first
        }
        return (first, mid, total)
    }

    private static func fetch(_ url: URL, offset: Int64, length: Int, ua: String) async -> (Data, URLResponse)? {
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        req.timeoutInterval = 20
        return try? await URLSession.shared.data(for: req)
    }
}
