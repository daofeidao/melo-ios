import Foundation
import UIKit

/// 轻量痕迹日志 + 崩溃兜底记录。
///
/// 为什么需要它：Mac 版「一按播放就崩」在本地复现不了，系统生成的 `.ips`
/// 用户不一定找得到、也未必愿意翻目录。这里自己落一份最小可用的日志：
///   - 每次关键步骤（解析 → 建 item → play → 写 Now Playing）记一行；
///   - ObjC 异常（AVFoundation / MediaRemote 这类常见于 Catalyst）走
///     `NSSetUncaughtExceptionHandler`，把异常名、原因、调用栈写进去；
///   - Swift 陷阱（强解包、数组越界）会变成信号，处理器只补一行固定标记，
///     真正的定位靠它前面最后一条步骤。
///
/// 文件放在 Application Support/Melo/trace.log，设置 → 高级诊断里能看到路径、
/// 最近几十行，并且可以一键复制。
enum Diagnostics {

    static private(set) var logURL: URL?
    /// 信号处理里只能用 async-signal-safe 的 write，所以预开 fd 并缓存一个 C 字符串
    private static var fd: Int32 = -1
    private static let crashNote = strdup("\n💥 崩溃信号：见上一行最后一步\n")!
    private static let lock = NSLock()
    private static let maxBytes = 256 * 1024

    static var logPath: String {
        logURL?.path ?? "（未创建）"
    }

    static func install() {
        guard logURL == nil else { return }

        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Melo", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("trace.log")

        // 超过上限就重开一份，避免长期使用后无限增长
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber, size.intValue > maxBytes {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }

        logURL = url
        fd = open(url.path, O_WRONLY | O_APPEND)
        installExceptionHandler()
        installSignalHandlers()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        mark("── 启动 v\(version)(\(build)) · \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    /// 记一行痕迹。步骤名尽量短，读日志时一眼能看出走到哪。
    static func mark(_ step: String) {
        guard fd >= 0 else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "\(formatter.string(from: Date())) \(step)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        data.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress {
                _ = write(fd, base, buffer.count)
            }
        }
        lock.unlock()
    }

    /// 读日志尾部，给诊断页展示 / 复制用
    static func tail(_ lines: Int = 60) -> String {
        guard let url = logURL, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "（还没有日志）"
        }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(lines).joined(separator: "\n")
    }

    static func clear() {
        guard let url = logURL else { return }
        try? "".write(to: url, atomically: true, encoding: .utf8)
        mark("── 日志已清空")
    }

    // MARK: - 崩溃兜底

    private static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            // 异常处理器仍允许调用 Foundation（不是信号上下文），可以正常写栈
            Diagnostics.mark("💥 NSException \(exception.name.rawValue)：\(exception.reason ?? "-")")
            for symbol in exception.callStackSymbols.prefix(40) {
                Diagnostics.mark("   \(symbol)")
            }
            // 不拦截默认行为：系统仍会照常生成 .ips
        }
    }

    private static func installSignalHandlers() {
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGILL, SIGFPE, SIGBUS, SIGTRAP]
        for sig in signals {
            signal(sig) { received in
                // 只能用 async-signal-safe 的调用：这里只有 write + 固定的 C 字符串
                if Diagnostics.fd >= 0 {
                    _ = write(Diagnostics.fd, Diagnostics.crashNote, strlen(Diagnostics.crashNote))
                }
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }
}
