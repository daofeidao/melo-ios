import Foundation

/// Cold Start Token（冷启动 PO Token）—— 本地算出来的占位 PO Token。
///
/// 背景（2026-11-17 实测）：YouTube 对未登录的 Web 客户端返回 SABR 分帧流，
/// 浏览器靠它原生支持来播；其中 SABR 的 googlevideo 请求需要 `pot=` 参数，
/// 而这个参数在「播放还没真正开始」时，用的是一个**本地 XOR 加密**的冷启动 token，
/// 不需要跑 BotGuard 挑战、不需要网络请求。
///
/// 算法来自 BgUtils 的 `createColdStartToken`：
///   packet = [34, payloadLen] + header + contentBindingBytes
///   header = 2 个随机字节 + [0, clientState] + 4 字节大端时间戳
///   payload（header+binding）用 header 的前 2 字节做循环 XOR
///   最后 base64（websafe 字符，保留 = 填充）
///
/// contentBinding：未登录用 visitorData，登录用 Data Sync ID。
enum ColdStartToken {

    /// 生成一个冷启动 PO Token。
    /// - Parameters:
    ///   - contentBinding: visitorData（未登录）或 dataSyncId（已登录）
    ///   - clientState: 客户端状态，默认 1
    static func make(contentBinding: String, clientState: Int = 1) -> String {
        let binding = Array(contentBinding.utf8)
        let timestamp = Int(Date().timeIntervalSince1970)
        // 两个随机字节既是 XOR 的密钥，也在 header 里
        let random: [UInt8] = [UInt8.random(in: 0...255), UInt8.random(in: 0...255)]

        var header: [UInt8] = random
        header.append(0)
        header.append(UInt8(clamping: clientState))
        header.append(UInt8((timestamp >> 24) & 0xFF))
        header.append(UInt8((timestamp >> 16) & 0xFF))
        header.append(UInt8((timestamp >> 8) & 0xFF))
        header.append(UInt8(timestamp & 0xFF))

        var packet = [UInt8](repeating: 0, count: 2 + header.count + binding.count)
        packet[0] = 34
        packet[1] = UInt8((header.count + binding.count) & 0xFF)
        for (i, b) in header.enumerated() { packet[2 + i] = b }
        for (i, b) in binding.enumerated() { packet[2 + header.count + i] = b }

        // payload（header + binding）用随机字节做循环 XOR
        let keyLength = random.count
        for i in keyLength..<(packet.count - 2) {
            packet[2 + i] ^= packet[2 + (i % keyLength)]
        }

        return webSafeBase64(packet)
    }

    /// websafe base64：`+`→`-`、`/`→`_`，**保留 `=` 填充**（对齐 BgUtils 的 u8ToBase64）。
    static func webSafeBase64(_ bytes: [UInt8]) -> String {
        var s = Data(bytes).base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        return s
    }
}
