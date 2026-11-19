import Foundation

#if !targetEnvironment(macCatalyst)
import AVFoundation
import MediaPlayer
import UIKit
#endif

/// 音量键双击手势（iOS）。
///
/// **iOS 没有给第三方 App 任何「按键事件」接口**，Apple 只开放了「音量变了」这一条路。
/// 能拿到原始硬件按下事件的只有私有 `IOHIDEventSystemClient`，非越狱设备的沙箱会挡掉，
/// 所以业界（含网易云、Spotify）能用的只有下面两套，而且必须同时上：
///
///   1. **KVO `AVAudioSession.outputVolume`** —— 一定有效，但音量到顶/到底时值不变，
///      压根不回调，双击在那两种情况下失灵。
///   2. **系统音量变化通知**（iOS 15 起叫 `SystemVolumeDidChange`，旧名
///      `AVSystemController_SystemVolumeDidChangeNotification`）—— 音量不变也会发，
///      带 `Reason = ExplicitVolumeChange` 能区分「用户亲手按的」，但这条通知不是
///      公开 API，不同系统版本上能不能收到并不稳定。
///
/// 所以这里两套都挂：谁先报就按谁处理，用 0.18 秒同方向去重把它们合并成一次按键。
/// 通知能收到时，端点（音量满格）也能用；收不到时 KVO 保证基本功能不掉。
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
    private var observation: NSKeyValueObservation?
    private var tokens: [NSObjectProtocol] = []
    private var volumeView: MPVolumeView?

    /// 上一次已知音量。第一次回调只用来对齐基线。
    private var lastVolume: Float = -1
    /// 程序自己拨回音量的瞬间，短暂忽略 KVO 回调
    private var ignoreUntil = Date.distantPast

    /// 同一次按键会被 KVO 和通知各报一次，用它合并
    private var lastKeyAt = Date.distantPast
    private var lastKeyDirection = 0
    /// 上一次按键之后的音量。同一次按键被两路各报一遍时音量完全相同；
    /// 用户真的连按两次时音量必然不同 —— 比单靠时间窗精准，
    /// 不会把「手速很快的双击」误当成重复上报吞掉。
    private var lastKeyVolume: Float = -1

    /// 双击判定：同方向的第一次按键时刻
    private var pendingUp = Date.distantPast
    private var pendingDown = Date.distantPast
    /// 这一轮「第一次按键」之前的音量，双击成立时还原到它
    private var originVolume: Float = -1

    /// 通知序号（iOS 15 一次按键连发两条）
    private var seenSequences = Set<Int>()
    private var seenOrder: [Int] = []
    #endif

    private var onNext: (() -> Void)?
    private var onPrevious: (() -> Void)?
    private var canTrigger: (() -> Bool)?

    /// 人手双击间隔通常 0.25~0.5 秒
    private let window: TimeInterval = 0.6
    /// 同一按键被多路上报的合并窗口
    private let mergeWindow: TimeInterval = 0.18

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
        guard VolumeShortcut.isEnabled else { return }
        if observation == nil { startKVO() }
        if tokens.isEmpty { startNotifications() }
        #endif
    }

    func suspend() {
        #if !targetEnvironment(macCatalyst)
        observation?.invalidate()
        observation = nil
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
        #endif
    }

    #if !targetEnvironment(macCatalyst)

    // MARK: - 通道一：KVO（一定有效）

    private func startKVO() {
        let session = AVAudioSession.sharedInstance()
        lastVolume = session.outputVolume
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self = self, let volume = change.newValue else { return }
            // 回调可能在任意线程，切歌/改 UI 必须回主线程
            DispatchQueue.main.async { self.handleKVO(volume) }
        }
    }

    private func handleKVO(_ volume: Float) {
        let previous = lastVolume
        lastVolume = volume
        if Date() < ignoreUntil { return }
        guard previous >= 0 else { return }
        let delta = volume - previous
        guard abs(delta) > 0.005 else { return }
        noteKey(direction: delta > 0 ? 1 : -1, before: previous, after: volume)
    }

    // MARK: - 通道二：系统通知（能拿到端点与按键原因）

    private func startNotifications() {
        for name in Self.notificationNames {
            let token = NotificationCenter.default.addObserver(
                forName: Notification.Name(rawValue: name),
                object: nil,
                queue: .main
            ) { [weak self] note in
                self?.handleNotification(note.userInfo as? [String: Any] ?? [:])
            }
            tokens.append(token)
        }
    }

    private func handleNotification(_ info: [String: Any]) {
        // 只认「用户亲手按的」；程序调音量、切路由、Siri 都会发通知，但 reason 不同
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

        let previous = lastVolume
        lastVolume = volume
        if Date() < ignoreUntil { return }

        let delta = volume - previous
        if abs(delta) > 0.005 {
            noteKey(direction: delta > 0 ? 1 : -1, before: previous, after: volume)
        } else if volume >= 0.999 {
            // 已经满格还收到按键，那只可能是 +
            noteKey(direction: 1, before: volume, after: volume)
        } else if volume <= 0.001 {
            noteKey(direction: -1, before: volume, after: volume)
        }
    }

    // MARK: - 双击判定

    private func noteKey(direction: Int, before: Float, after: Float) {
        let now = Date()
        // KVO 与通知会为同一次按键各报一次，合并掉。
        // 判据是「同方向 + 同音量值」，不是单看时间：手速快的人 0.15 秒内连按两次
        // 也想切歌，只看时间窗会把它当成重复上报吞掉。
        if now.timeIntervalSince(lastKeyAt) < mergeWindow,
           direction == lastKeyDirection,
           abs(after - lastKeyVolume) < 0.002 {
            return
        }
        lastKeyAt = now
        lastKeyDirection = direction
        lastKeyVolume = after

        if direction > 0 {
            if now.timeIntervalSince(pendingUp) <= window {
                pendingUp = .distantPast
                fire(next: true)
            } else {
                pendingUp = now
                originVolume = before
            }
        } else {
            if now.timeIntervalSince(pendingDown) <= window {
                pendingDown = .distantPast
                fire(next: false)
            } else {
                pendingDown = now
                originVolume = before
            }
        }
    }

    private func fire(next: Bool) {
        guard canTrigger?() ?? true else { return }
        Diagnostics.mark(next ? "volume-key: 双击 下一首" : "volume-key: 双击 上一首")
        // 先把音量拨回第一次按键之前的水平，再切歌：听感上只是「闪一下」
        if originVolume >= 0 { restoreVolume(to: originVolume) }
        if next { onNext?() } else { onPrevious?() }
    }

    // MARK: - 工具

    /// userInfo 里的数值既可能是 NSNumber，也可能是字符串（老格式是 `"0.5625"`）
    private static func floatValue(_ any: Any?) -> Float? {
        if let number = any as? NSNumber { return number.floatValue }
        if let text = any as? String { return Float(text) }
        return nil
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
