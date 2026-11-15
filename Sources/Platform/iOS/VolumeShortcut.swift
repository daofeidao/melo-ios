import Foundation

#if !targetEnvironment(macCatalyst)
import AVFoundation
import MediaPlayer
import UIKit
#endif

/// 音量键双击手势（iOS）。
///
/// iOS 不给第三方 App 任何「硬件按键」接口，唯一能拿到的是
/// `AVAudioSession.outputVolume` 的 KVO —— 音量变了就说明有人按了音量键。于是：
///   - 0.45 秒内同方向变两次 = 双击；
///   - 音量+ 双击 → 下一曲，音量- 双击 → 上一曲（可在设置里关）。
///
/// 三个必须说清楚的前提：
///   1. 只有音频会话是激活的（正在播放）才收得到音量变化；
///   2. 音量已经在顶或底时再按不产生变化，手势失效；
///   3. 系统音量会跟着跳两格。这里用 `MPVolumeView` 悄悄拨回原值，
///      所以听感上只是「闪一下」，不会真把音量推到最大。
///
/// Mac（Catalyst）没有 AVAudioSession，这些平台上整个类是空壳。
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
    private var volumeView: MPVolumeView?
    private var lastUp = Date.distantPast
    private var lastDown = Date.distantPast
    private var lastVolume: Float = -1
    /// 刚把音量拨回去的那一下，不要当成用户又按了一次
    private var suppressUntil = Date.distantPast
    #endif

    private var onNext: (() -> Void)?
    private var onPrevious: (() -> Void)?
    private var canTrigger: (() -> Bool)?

    private let window: TimeInterval = 0.45

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
        observation?.invalidate()
        let session = AVAudioSession.sharedInstance()
        lastVolume = session.outputVolume
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self = self, let volume = change.newValue else { return }
            self.handle(volume)
        }
        #endif
    }

    func suspend() {
        #if !targetEnvironment(macCatalyst)
        observation?.invalidate()
        observation = nil
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    private func handle(_ volume: Float) {
        let now = Date()
        let previous = lastVolume
        lastVolume = volume

        // 第一次观察只用来对齐基线
        guard previous >= 0 else { return }
        // 拨回音量造成的变化，忽略
        if now < suppressUntil { return }
        let delta = volume - previous
        guard abs(delta) > 0.005 else { return }

        if delta > 0 {
            if now.timeIntervalSince(lastUp) <= window {
                lastUp = .distantPast
                fire(next: true, restoreTo: previous - delta)
            } else {
                lastUp = now
            }
        } else {
            if now.timeIntervalSince(lastDown) <= window {
                lastDown = .distantPast
                fire(next: false, restoreTo: previous - delta)
            } else {
                lastDown = now
            }
        }
    }

    private func fire(next: Bool, restoreTo target: Float) {
        guard canTrigger?() ?? true else { return }
        restoreVolume(to: target)
        if next { onNext?() } else { onPrevious?() }
    }

    /// 用 MPVolumeView 的滑块把音量拨回去（公开 API 里唯一能改系统音量的路子）
    private func restoreVolume(to target: Float) {
        let desired = min(max(target, 0), 1)
        suppressUntil = Date().addingTimeInterval(0.35)
        guard let slider = volumeSlider(in: ensureVolumeView()) else { return }
        slider.value = desired
        lastVolume = desired
    }

    private func ensureVolumeView() -> MPVolumeView {
        if let view = volumeView, view.window != nil { return view }
        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
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
