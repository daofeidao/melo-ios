import Foundation
import SwiftUI
import UIKit

#if targetEnvironment(macCatalyst)
import CoreAudio
import AudioToolbox

// MARK: - 系统音量（CoreAudio）

/// Mac 系统输出音量。走 CoreAudio 的 `kAudioDevicePropertyVolumeScalar`，
/// 不依赖任何私有 API；设备不支持时优雅降级（静默不动）。
enum MacVolume {

    /// 当前音量 (0…1)，获取失败返回 -1。
    static var current: Float {
        guard let device = defaultOutputDevice() else { return -1 }
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyVolumeScalar),
            mScope: AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { return -1 }
        return value
    }

    static func set(_ volume: Float) {
        guard let device = defaultOutputDevice() else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyVolumeScalar),
            mScope: AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var value = Float32(max(0, min(1, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }

    static func adjust(by delta: Float) {
        let vol = current
        guard vol >= 0 else { return }
        set(vol + delta)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDefaultOutputDevice),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}

// MARK: - 设置键

enum MacGestureSettings {
    static let horizontalTabs    = "melo.mac.gesture.tabs"
    static let horizontalTracks  = "melo.mac.gesture.tracks"
    static let verticalVolume    = "melo.mac.gesture.volume"
    static let swipeDismiss      = "melo.mac.gesture.dismiss"
    static let keyboardShortcuts = "melo.mac.keys.enabled"

    static func on(_ key: String) -> Bool {
        let d = UserDefaults.standard
        if d.object(forKey: key) == nil { return true }
        return d.bool(forKey: key)
    }

    static func set(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

// MARK: - 触控板手势

/// Mac 触控板两指滑动手势。
///
/// 手势挂在**窗口**上（不是某个 SwiftUI 视图），`cancelsTouchesInView = false`
/// 保证列表正常滚动不受影响；只在「快滑」（速度 ≥ 1000 pt/s）时触发动作，
/// 慢滚不触发。
///
/// 按场景区分：
///   - 主界面：左右滑 = 切栏目；上下滑 = 调音量
///   - 播放页：左右滑 = 切歌；下滑 = 关闭播放页；上滑 = 调音量
final class MacGestures: NSObject, UIGestureRecognizerDelegate {

    static let shared = MacGestures()

    /// 快滑判定阈值（pt/s）。低于此速度视为正常滚动。
    private let flickThreshold: CGFloat = 1000
    /// 主轴速度至少是副轴的 1.5 倍才算「明确方向」。
    private let axisRatio: CGFloat = 1.5

    private var installed = false

    /// 在 keyWindow 上装手势识别器。幂等，可多次调用。
    func install() {
        guard !installed else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.installed else { return }
            guard let window = Self.keyWindow() else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.install() }
                return
            }
            self.attach(to: window)
            self.installed = true
            Diagnostics.mark("gestures: installed on keyWindow")
        }
    }

    private func attach(to window: UIWindow) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedScrollTypesMask = [.continuous, .discrete]
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delegate = self
        window.addGestureRecognizer(pan)
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    // MARK: 手势处理

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended || recognizer.state == .cancelled else { return }
        guard let view = recognizer.view else { return }

        let velocity = recognizer.velocity(in: view)
        let speed = max(abs(velocity.x), abs(velocity.y))
        guard speed >= flickThreshold else { return }

        let isHorizontal = abs(velocity.x) >= abs(velocity.y) * axisRatio
        let isVertical   = abs(velocity.y) >= abs(velocity.x) * axisRatio
        let playerOpen   = PlayerEngine.shared.opensFullPlayer

        if isHorizontal {
            let goForward = velocity.x < 0   // 手指向左划 → 下一页
            if playerOpen {
                guard MacGestureSettings.on(MacGestureSettings.horizontalTracks) else { return }
                Diagnostics.mark("gesture: swipe \(goForward ? "left→next" : "right→prev")")
                if goForward { PlayerEngine.shared.next() } else { PlayerEngine.shared.previous() }
            } else {
                guard MacGestureSettings.on(MacGestureSettings.horizontalTabs) else { return }
                switchTab(goForward ? 1 : -1)
            }
        } else if isVertical {
            // 播放页：下滑关闭
            if playerOpen && velocity.y > 0,
               MacGestureSettings.on(MacGestureSettings.swipeDismiss) {
                Diagnostics.mark("gesture: swipe down → close player")
                PlayerEngine.shared.opensFullPlayer = false
                return
            }
            // 上下滑动调音量
            guard MacGestureSettings.on(MacGestureSettings.verticalVolume) else { return }
            let delta: Float = velocity.y < 0 ? 0.05 : -0.05
            Diagnostics.mark("gesture: swipe \(velocity.y < 0 ? "up→vol+" : "down→vol-")")
            MacVolume.adjust(by: delta)
        }
    }

    /// 切栏目：0 就听 → 1 排行榜 → 2 资料库 → 3 搜索 → 循环
    private func switchTab(_ direction: Int) {
        let current = UserDefaults.standard.integer(forKey: "melo.mac.currentTab")
        let count = 4
        let next = ((current + direction) % count + count) % count
        UserDefaults.standard.set(next, forKey: "melo.mac.currentTab")
        NotificationCenter.default.post(
            name: .meloSwitchTab,
            object: nil,
            userInfo: ["index": next]
        )
        Diagnostics.mark("gesture: tab → \(next)")
    }

    // MARK: UIGestureRecognizerDelegate

    /// 与 ScrollView 的 pan 共存：两边都识别，互不取消。
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

// MARK: - Tab 切换通知

extension Notification.Name {
    static let meloSwitchTab = Notification.Name("melo.switchTab")
}

// MARK: - 键盘快捷键载体（SwiftUI）

/// Mac 键盘快捷键：放在 RootView 里，零尺寸不可见，只负责注册 key command。
/// SwiftUI 的 `.keyboardShortcut` 会走 `UIKeyCommand` 响应链，
/// 文本框输入时自动让路（不会抢空格/方向键）。
struct MacKeyboardShortcuts: View {
    var body: some View {
        Group {
            // 空格：播放 / 暂停
            Button { PlayerEngine.shared.toggle() }
                label: { Color.clear.frame(width: 0, height: 0) }
                .keyboardShortcut(.space, modifiers: [])

            // ⌘← / ⌘→：上一曲 / 下一曲
            Button { PlayerEngine.shared.previous() }
                label: { Color.clear.frame(width: 0, height: 0) }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
            Button { PlayerEngine.shared.next() }
                label: { Color.clear.frame(width: 0, height: 0) }
                .keyboardShortcut(.rightArrow, modifiers: [.command])

            // ⌘↑ / ⌘↓：音量增减
            Button { MacVolume.adjust(by: 0.05) }
                label: { Color.clear.frame(width: 0, height: 0) }
                .keyboardShortcut(.upArrow, modifiers: [.command])
            Button { MacVolume.adjust(by: -0.05) }
                label: { Color.clear.frame(width: 0, height: 0) }
                .keyboardShortcut(.downArrow, modifiers: [.command])

            // Esc：关闭播放页
            Button { PlayerEngine.shared.opensFullPlayer = false }
                label: { Color.clear.frame(width: 0, height: 0) }
                .keyboardShortcut(.cancelAction)
        }
        .allowsHitTesting(false)
        .opacity(0)
        .frame(width: 0, height: 0)
    }
}

#endif
