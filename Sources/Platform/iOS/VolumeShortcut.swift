import Foundation

#if !targetEnvironment(macCatalyst)
import AVFoundation
import MediaPlayer
import UIKit
#endif

/// 音量键双击手势（iOS）。
///
/// iOS 不给第三方 App 任何「硬件按键」接口。业界（含网易云 / Spotify 这类）的通行做法
/// 是监听系统内部那条音量变化通知，而不是 KVO `AVAudioSession.outputVolume`：
///
///   - 通知名：iOS 15 起叫 `SystemVolumeDidChange`，之前叫
///     `AVSystemController_SystemVolumeDidChangeNotification`，两个都注册。
///   - userInfo 里 `Reason`（旧键 `AVSystemController_AudioVolumeChangeReasonNotificationParameter`）
///     为 `ExplicitVolumeChange` 才是「用户亲手按的」；程序改音量、切音频路由、
///     调起 Siri 都会发通知，但 reason 不同 —— 这条判据替掉了原来那套靠时间窗
///     猜「是不是我自己拨回去的」的写法。
///   - iOS 15 按一下会连发两次通知，用 `SequenceNumber` 去重。
///
/// 相比旧实现（KVO outputVolume）的实际改进：
///   1. 音量已在最大 / 最小时，KVO 根本不触发，通知照样发 —— 双击不再「到顶就失灵」；
///   2. 不需要 0.35 秒的抑制窗口，两次快速双击不会被吃掉；
///   3. 不会把程序自己拨回去的动作误判成用户按键。
///
/// 仍然存在的物理限制：音量到顶时通知里只有「当前音量 = 1.0」，没有方向信息，
/// 无法区分用户按的是 + 还是 −，这种情况只能忽略。
enum VolumeShortcut {

    static let enabledKey = "melo.volumeDoublePress"

    static var isEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: enabledKey) == nil { return true }
            return defaults.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue { shared.resume() } else { shared.suspend() }
        }
    }

    static let shared = VolumeShortcutMonitor()
}

final class VolumeShortcutMonitor {

    #if !targetEnvironment(macCatalyst)
    private var tokens: [NSObjectProtocol] = []
    private var volumeView: MPVolumeView?
    private var lastUp = Date.distantPast
    private var lastDown = Date.distantPast
    /// 上一次已知音量。第一次通知只用来对齐基线。
    private var lastVolume: Float = -1
    /// 已经处理过的通知序号（iOS 15 一次按键会发两遍）
    private var seenSequences = Set<Int>()
    private var seenOrder: [Int] = []
    /// 程序拨回音量的瞬间，短暂忽略，避免把 1.0 → 0.5 当成用户按了「−」
    private var ignoreUntil = Date.distantPast
    /// 上一次真正处理通知的时刻。两套通知名可能对同一次按键各发一条，
    /// 靠它压掉重复，避免一次按键被算成「双击」。
    private var lastHandledAt = Date.distantPast
    #endif

    private var onNext: (() -> Void)?
    private var onPrevious: (() -> Void)?
    private var canTrigger: (() -> Bool)?

    /// 人手双击的间隔通常在 0.25~0.5 秒；0.45 偏紧，放宽到 0.6
    private let window: TimeInterval = 0.6

    /// 两套通知名：iOS 15 之后系统给的是短名，老的私有名仍可能生效
    private static let notificationNames = [
        "SystemVolumeDidChange",
        "AVSystemController_SystemVolumeDidChangeNotification"
    ]

    func start(onNext: @escaping () -> Void,
               onPrevious: @escaping () -> Void,
               canTrigger: @escaping () -> Bool) {
        #if !targetEnvironment(macCatalyst)
        self.onNext = onNext
        self.onPrevious = onPrevious
        self.canTrigger = canTrigger
        resume()
        #endif
    }

    func resume() {
        #if !targetEnvironment(macCatalyst)
        guard VolumeShortcut.isEnabled, tokens.isEmpty else { return }
        lastVolume = AVAudioSession.sharedInstance().outputVolume
        for name in Self.notificationNames {
            let token = NotificationCenter.default.addObserver(
                forName: Notification.Name(rawValue: name),
                object: nil,
                queue: .main
            ) { [weak self] note in
                self?.handle(note.userInfo as? [String: Any] ?? [:])
            }
            tokens.append(token)
        }
        #endif
    }

    func suspend() {
        #if !targetEnvironment(macCatalyst)
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
        #endif
    }

    #if !targetEnvironment(macCatalyst)

    private func handle(_ info: [String: Any]) {
        // 只认「用户亲手按的」。程序调音量、路由切换、Siri 都会发通知，但 reason 不同。
        let reason = (info["Reason"] as? String)
            ?? (info["AVSystemController_AudioVolumeChangeReasonNotificationParameter"] as? String)
        guard reason == "ExplicitVolumeChange" else { return }

        // iOS 15 一次按键会连发两条，序号相同
        if let raw = Self.floatValue(info["SequenceNumber"])
            ?? Self.floatValue(info["AVSystemController_AudioVolumeChangeSequenceNumberParameter"]) {
            let seq = Int(raw)
            if seenSequences.contains(seq) { return }
            seenSequences.insert(seq)
            seenOrder.append(seq)
            if seenOrder.count > 64 {
                seenSequences.remove(seenOrder.removeFirst())
            }
        }

        let volume = Self.floatValue(info["Volume"])
            ?? Self.floatValue(info["AVSystemController_AudioVolumeNotificationParameter"])
            ?? AVAudioSession.sharedInstance().outputVolume

        let now = Date()
        let previous = lastVolume
        lastVolume = volume

        if now < ignoreUntil { return }
        // 两套通知名可能对同一次按键各发一条（且音量完全相同）：0.12 秒内
        // 同值的第二次直接丢掉，否则一次按键就被算成双击，歌会莫名其妙跳走。
        if now.timeIntervalSince(lastHandledAt) < 0.12, abs(volume - previous) <= 0.001 {
            return
        }
        lastHandledAt = now
        guard previous >= 0 else { return }

        let delta = volume - previous

        // 音量没变，只有一种情况能确定方向：已经顶到头 / 到底了。
        //   音量 = 1.0 还收到「用户按键」，那必然是按的 +（按 − 会变小）；
        //   音量 = 0.0 同理必然是 −。
        // 这一条正是旧实现最大的毛病：KVO 在音量不变时压根不回调，
        // 「音量开到最大之后双击切歌就没反应了」。
        // 中间音量却不变（比如系统里关了「用按钮调整」）无法判断方向，只能忽略。
        let direction: Int
        if abs(delta) > 0.001 {
            direction = delta > 0 ? 1 : -1
        } else if volume >= 0.999 {
            direction = 1
        } else if volume <= 0.001 {
            direction = -1
        } else {
            return
        }

        if direction > 0 {
            if now.timeIntervalSince(lastUp) <= window {
                lastUp = .distantPast
                fire(next: true, restoreTo: previous)
            } else {
                lastUp = now
            }
        } else {
            if now.timeIntervalSince(lastDown) <= window {
                lastDown = .distantPast
                fire(next: false, restoreTo: previous)
            } else {
                lastDown = now
            }
        }
    }

    /// userInfo 里的数值既可能是 NSNumber，也可能是字符串（老格式是 `"0.5625"`）
    private static func floatValue(_ any: Any?) -> Float? {
        if let number = any as? NSNumber { return number.floatValue }
        if let text = any as? String { return Float(text) }
        return nil
    }

    private func fire(next: Bool, restoreTo target: Float) {
        guard canTrigger?() ?? true else { return }
        // 先把音量拨回第一次按键之前的水平，再把动作发出去。
        // 顺序不能反：切歌会触发 UI 刷新，先把音量稳下来，听感上才只是「闪一下」。
        restoreVolume(to: target)
        if next { onNext?() } else { onPrevious?() }
    }

    /// 用 MPVolumeView 的滑块把音量拨回去（公开 API 里唯一能改系统音量的路子）
    private func restoreVolume(to target: Float) {
        let desired = min(max(target, 0), 1)
        ignoreUntil = Date().addingTimeInterval(0.45)
        guard let slider = volumeSlider(in: ensureVolumeView()) else { return }
        slider.value = desired
        lastVolume = desired
    }

    private func ensureVolumeView() -> MPVolumeView {
        if let view = volumeView, view.window != nil { return view }
        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 2, height: 2))
        view.alpha = 0.01
        let host = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        host?.addSubview(view)
        volumeView = view
        return view
    }

    private func volumeSlider(in view: MPVolumeView) -> UISlider? {
        findSlider(in: view)
    }

    private func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for sub in view.subviews {
            if let found = findSlider(in: sub) { return found }
        }
        return nil
    }

    #endif
}
