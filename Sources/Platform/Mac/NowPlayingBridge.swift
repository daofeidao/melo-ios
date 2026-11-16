import Foundation
import MediaPlayer

/// 「正在播放」（Mac 菜单栏 / 控制中心）发布桥。
///
/// 为什么要把 MediaPlayer 的所有写操作收进这一个文件：
/// Mac（Catalyst）上 `MPNowPlayingInfoCenter` 落到的是 macOS 那套实现，部分
/// setter 在某些系统版本里并不存在。Swift 的 `try?` 拦不住 ObjC 异常，
/// 一个 `unrecognized selector` 就是 `NSInvalidArgumentException`，进程当场退出
/// —— 表现正是「歌一开始放就没了」。所以这里：
///   1. 每个 setter 前后都留痕迹（日志里能看出是 info 崩还是 state 崩）；
///   2. `playbackState` 先用 `responds(to:)` 问运行时有没有这个 setter，没有就跳过；
///   3. 数值全部过一遍有限性检查（NaN / inf 塞进 plist 也会炸）；
///   4. 整个发布可以一键关掉（Mac 兼容开关），用于自查与兜底。
enum NowPlayingBridge {

    static let enabledKey = "melo.nowPlaying.enabled"

    static var isEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: enabledKey) == nil { return true }
            return defaults.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            Diagnostics.mark("np: enabled = \(newValue)")
        }
    }

    private static let playbackStateSelector = NSSelectorFromString("setPlaybackState:")

    /// macOS 侧才有 playbackState；Catalyst 运行时不一定实现了这个 setter
    static var supportsPlaybackState: Bool {
        MPNowPlayingInfoCenter.default().responds(to: playbackStateSelector)
    }

    /// 发布当前曲目。`playing` 只用于 macOS 的 playbackState。
    static func publish(_ info: [String: Any], playing: Bool) {
        guard isEnabled else {
            Diagnostics.mark("np: disabled, skipped")
            return
        }
        let center = MPNowPlayingInfoCenter.default()
        Diagnostics.mark("np: set info begin")
        ExceptionGuard.run("nowPlayingInfo") {
            center.nowPlayingInfo = self.sanitize(info)
        }
        Diagnostics.mark("np: info ok")

        // iOS 有自己的推断（rate + 音频会话），这条路只在 macOS 上补状态
        #if targetEnvironment(macCatalyst)
        guard supportsPlaybackState else {
            Diagnostics.mark("np: state skipped (runtime has no setPlaybackState:)")
            return
        }
        Diagnostics.mark("np: set state")
        ExceptionGuard.run("playbackState") {
            center.playbackState = playing ? .playing : .paused
        }
        Diagnostics.mark("np: state ok")
        #endif
    }

    static func clear() {
        guard isEnabled else { return }
        Diagnostics.mark("np: clear")
        ExceptionGuard.run("nowPlayingInfo(clear)") {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    /// nowPlayingInfo 只接受 plist 类型；NaN / 无穷大要换成 0，空字符串要去掉
    private static func sanitize(_ info: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in info {
            if let number = value as? Double {
                out[key] = number.isFinite ? number : 0
            } else if let number = value as? Float {
                out[key] = number.isFinite ? Double(number) : 0
            } else if let text = value as? String {
                if !text.isEmpty { out[key] = text }
            } else {
                out[key] = value
            }
        }
        return out
    }
}
