import Foundation

/// 崩溃自愈 + 降级开关。
///
/// Mac 版的问题是「用户一播就退」，而我这边复现不了、也拿不到机器。
/// 与其让用户每次装完新版再崩一次、再回来描述，不如让 App 自己记：
///   - 启动时写一个「会话进行中」标记，正常退出时清掉；
///   - 下次启动如果标记还在，说明上次是异常退出（闪退/被强杀）；
///   - 这时自动降级：关掉「正在播放」媒体中心集成、起播后不再自动弹播放页。
/// 降级后能用了，就说明崩在这两处之一；还不能用，日志里也会有痕迹。
/// 用户随时可以在 设置 → 高级诊断 → Mac 兼容 里把开关打回去。
enum SafeMode {

    private static let sessionStartKey = "melo.session.startAt"
    private static let autoOpenKey = "melo.player.autoOpen"
    private static let lastCrashKey = "melo.lastCrashAt"

    /// 上次会话「启动时间」——如果残留非空，说明上次没正常收尾。
    /// 用时间戳而非布尔，是为了区分「闪退」和「正常关机但没来得及清标记」：
    /// 运行不足 5 秒就中断，不算崩溃（快速重启、覆盖安装等场景）。
    static var lastSessionCrashed: Bool {
        guard let start = UserDefaults.standard.object(forKey: sessionStartKey) as? Date else { return false }
        return Date().timeIntervalSince(start) > 5
    }

    static var lastCrashAt: Date? {
        UserDefaults.standard.object(forKey: lastCrashKey) as? Date
    }

    /// 启动时调用；返回上次是否是异常退出
    @discardableResult
    static func beginSession() -> Bool {
        let defaults = UserDefaults.standard
        // 读上次残留的时间戳
        let prevStart = defaults.object(forKey: sessionStartKey) as? Date
        let crashed = prevStart.map { Date().timeIntervalSince($0) > 5 } ?? false
        // 写本次启动时间
        defaults.set(Date(), forKey: sessionStartKey)
        defaults.synchronize()
        if crashed {
            defaults.set(Date(), forKey: lastCrashKey)
            Diagnostics.mark("⚠️ 上次会话异常结束（疑似闪退）")
        }
        return crashed
    }

    /// 正常退出时清掉标记
    static func endSession() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: sessionStartKey)
        defaults.synchronize()
    }

    /// 起播后是否自动打开播放页。关掉后只出迷你播放条。
    static var autoOpenPlayer: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: autoOpenKey) == nil { return true }
            return defaults.bool(forKey: autoOpenKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoOpenKey)
            Diagnostics.mark("autoOpenPlayer = \(newValue)")
        }
    }

    /// 上一次异常退出后自动降级（只对 Mac 有意义）。
    /// 只降级媒体中心集成（NowPlayingBridge），不再动 autoOpenPlayer —— 
    /// 用户主动点歌弹播放页是显式操作，不该被崩溃自愈吞掉。
    static func degrade() {
        #if targetEnvironment(macCatalyst)
        guard NowPlayingBridge.isEnabled else { return }
        NowPlayingBridge.isEnabled = false
        Diagnostics.mark("🛟 兼容模式：已关闭媒体中心集成")
        #endif
    }
}
