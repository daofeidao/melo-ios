import Foundation

/// 自取 macOS 系统崩溃报告（Mac 专用）。
///
/// 用户那边一按就退，最需要的就是崩溃栈，但让 TA 去
/// `~/Library/Logs/DiagnosticReports` 翻 .ips 太折腾。App 没有沙盒，
/// 可以直接读到系统写的崩溃报告，启动时把关键字段抄进运行日志：
///   · 终止原因（Termination Reason / Exception Type）
///   · 崩溃线程的前 20 帧（符号名 + 偏移）
/// 这样一条「运行日志」就同时包含我自己的步骤痕迹和系统的崩溃栈。
enum CrashReport {

    /// 读最近一次 Melo 的崩溃报告，写进运行日志。返回是否有收获。
    @discardableResult
    static func ingestLatest() -> Bool {
        #if targetEnvironment(macCatalyst)
        let fm = FileManager.default
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return false }

        let candidates = names
            .filter { $0.hasPrefix("Melo-") && ($0.hasSuffix(".ips") || $0.hasSuffix(".crash")) }
            .map { name -> (String, Date) in
                let path = (dir as NSString).appendingPathComponent(name)
                let date = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                return (path, date)
            }
            .sorted { $0.1 > $1.1 }

        guard let newest = candidates.first else { return false }
        guard let data = fm.contents(atPath: newest.0),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return false
        }

        let name = (newest.0 as NSString).lastPathComponent
        Diagnostics.mark("── 系统崩溃报告 \(name)")

        // .ips 是「一行 JSON 头 + 一整块 JSON 体」；旧式 .crash 是纯文本，两种都吃
        let summary = newest.0.hasSuffix(".ips")
            ? summarizeIPS(text)
            : summarizeLegacy(text)

        guard !summary.isEmpty else {
            Diagnostics.mark("（无法解析该报告，仅记录文件名）")
            return true
        }
        for line in summary {
            Diagnostics.mark("   \(line)")
        }
        return true
        #else
        return false
        #endif
    }

    #if targetEnvironment(macCatalyst)
    private static func summarizeIPS(_ text: String) -> [String] {
        var out: [String] = []
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let bodyData = parts[1].data(using: .utf8),
              let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
            // 整块 JSON（有些版本就是单块）
            guard let data = text.data(using: .utf8),
                  let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return []
            }
            return extract(from: body)
        }
        return extract(from: body)
    }

    private static func extract(from body: [String: Any]) -> [String] {
        var out: [String] = []

        if let termination = body["termination"] as? [String: Any] {
            let indicator = termination["indicator"] as? String ?? "-"
            let reason = termination["reason"] as? String ?? "-"
            out.append("终止：\(indicator) · \(reason)")
        }
        if let exception = body["exception"] as? [String: Any] {
            let type = exception["type"] as? String ?? "-"
            let codes = (exception["codes"] as? [String])?.joined(separator: ",") ?? "-"
            out.append("异常：\(type) codes=\(codes)")
        }

        guard let threads = body["threads"] as? [[String: Any]] else {
            return out.isEmpty ? [] : out
        }
        let crashed = threads.first { ($0["triggered"] as? Bool) == true } ?? threads.first
        if let thread = crashed, let frames = thread["frames"] as? [[String: Any]] {
            let images = body["usedImages"] as? [[String: Any]] ?? []
            out.append("崩溃线程共 \(frames.count) 帧，前 20：")
            for frame in frames.prefix(20) {
                let idx = frame["imageIndex"] as? Int ?? -1
                let imageName: String
                if idx >= 0 && idx < images.count {
                    let name = (images[idx]["name"] as? String) ?? "?"
                    imageName = name
                } else {
                    imageName = "?"
                }
                let symbol = (frame["symbol"] as? String) ?? "?"
                let off = frame["symbolLocation"] as? Int ?? 0
                out.append("    \(imageName)  \(symbol) +\(off)")
            }
        }
        return out
    }

    private static func summarizeLegacy(_ text: String) -> [String] {
        var out: [String] = []
        var capturing = false
        var count = 0
        for line in text.split(separator: "\n") {
            let s = String(line)
            if s.contains("Exception Type") || s.contains("Termination") || s.contains("Crashed Thread") {
                out.append(s.trimmingCharacters(in: .whitespaces))
            }
            if s.hasPrefix("Thread") && s.contains("Crashed") {
                capturing = true
            }
            if capturing {
                out.append("    " + s.trimmingCharacters(in: .whitespaces))
                count += 1
                if count > 22 { break }
            }
        }
        return out
    }
    #endif
}
