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

    private static let sessionKey = "melo.session.running"
    private static let autoOpenKey = "melo.player.autoOpen"
    private static let lastCrashKey = "melo.lastCrashAt"

    /// 上次启动后有没有正常收尾
    static var lastSessionCrashed: Bool {
        UserDefaults.standard.bool(forKey: sessionKey)
    }

    static var lastCrashAt: Date? {
        UserDefaults.standard.object(forKey: lastCrashKey) as? Date
    }

    /// 启动时调用；返回上次是否是异常退出
    @discardableResult
    static func beginSession() -> Bool {
        let defaults = UserDefaults.standard
        let crashed = defaults.bool(forKey: sessionKey)
        defaults.set(true, forKey: sessionKey)
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
        defaults.set(false, forKey: sessionKey)
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

    /// 上一次异常退出后自动降级（只对 Mac 有意义）
    static func degrade() {
        #if targetEnvironment(macCatalyst)
        guard NowPlayingBridge.isEnabled || autoOpenPlayer else { return }
        NowPlayingBridge.isEnabled = false
        autoOpenPlayer = false
        Diagnostics.mark("🛟 兼容模式：已关闭媒体中心集成与自动打开播放页")
        #endif
    }
}
