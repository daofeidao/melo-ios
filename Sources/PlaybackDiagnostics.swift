import Foundation
import AVFoundation

struct DiagnosticLine: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let ok: Bool
}

/// 播放链路的自检：解析地址 → 连音频节点 → 播放器起播。
/// 三步分别对应三种不同的故障源，用户能直接看出卡在哪。
enum PlaybackDiagnostics {

    /// 白名单热门视频：用来验证「解析→CDN→解码」链路本身
    static let pipelineVideoId = "dQw4w9WgXcQ"

    /// 普通版权曲目：会被反爬命中，用来判断当前 IP 是否被判定为机器人
    static let reputationVideoId = "9q7JOQfcJQM"

    static func run() async -> [DiagnosticLine] {
        var lines: [DiagnosticLine] = []

        // 步骤 0：拿一首普通版权曲目试解析，被拦说明客户端身份被判机器人
        do {
            _ = try await StreamResolver.resolve(videoId: reputationVideoId, quality: .normal)
            lines.append(DiagnosticLine(
                title: L("Step 0 · YouTube access"),
                detail: L("Not flagged as a bot"),
                ok: true
            ))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lines.append(DiagnosticLine(
                title: L("Step 0 · YouTube access"),
                detail: message,
                ok: false
            ))
        }

        let resolved: AudioStream
        do {
            resolved = try await StreamResolver.resolve(videoId: pipelineVideoId, quality: .normal)
            lines.append(DiagnosticLine(
                title: L("Step 1 · Resolve audio URL"),
                detail: "itag \(resolved.itag) · \(max(1, resolved.bitrate / 1000)) kbps",
                ok: true
            ))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lines.append(DiagnosticLine(
                title: L("Step 1 · Resolve audio URL"),
                detail: message,
                ok: false
            ))
            return lines
        }

        // 只拉 2KB，够判断连通性又不浪费流量
        var request = URLRequest(url: resolved.url)
        request.timeoutInterval = 10
        request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        request.setValue(resolved.userAgent ?? StreamResolver.clientUserAgent, forHTTPHeaderField: "User-Agent")

        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = (200...299).contains(code) && !data.isEmpty
            lines.append(DiagnosticLine(
                title: L("Step 2 · Audio CDN"),
                detail: ok
                    ? "HTTP \(code) · \(data.count) B · \(elapsed) ms · \(resolved.url.host ?? "")"
                    : "HTTP \(code) · \(resolved.url.host ?? "")",
                ok: ok
            ))
        } catch {
            lines.append(DiagnosticLine(
                title: L("Step 2 · Audio CDN"),
                detail: "\(resolved.url.host ?? "")：\(error.localizedDescription)",
                ok: false
            ))
        }

        lines.append(await probePlayer(
            url: resolved.url,
            userAgent: resolved.userAgent ?? StreamResolver.clientUserAgent
        ))
        return lines
    }

    @MainActor
    private static func probePlayer(url: URL, userAgent: String) async -> DiagnosticLine {
        let asset = AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]]
        )
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        player.play()

        defer { player.pause() }

        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 400_000_000)
            switch item.status {
            case .readyToPlay:
                return DiagnosticLine(title: L("Step 3 · AVPlayer"), detail: L("Ready to play"), ok: true)
            case .failed:
                let message = item.error?.localizedDescription ?? L("Unknown error")
                return DiagnosticLine(title: L("Step 3 · AVPlayer"), detail: message, ok: false)
            default:
                continue
            }
        }

        return DiagnosticLine(
            title: L("Step 3 · AVPlayer"),
            detail: L("Timed out waiting for audio"),
            ok: false
        )
    }
}
