import Foundation
import SwiftUI
import UIKit

#if targetEnvironment(macCatalyst)
import CoreAudio

// MARK: - 系统音量

enum MacVolume {
    static var current: Float {
        guard let device = defaultOutputDevice() else { return -1 }
        var addr = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyVolumeScalar),
            mScope: AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
        var v = Float32(0); var sz = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &sz, &v) == noErr else { return -1 }
        return v
    }
    static func set(_ volume: Float) {
        guard let device = defaultOutputDevice() else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyVolumeScalar),
            mScope: AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
        var v = Float32(max(0, min(1, volume)))
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }
    static func adjust(by delta: Float) {
        let vol = current
        guard vol >= 0 else { return }
        set(vol + delta)
    }
    private static func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var addr = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDefaultOutputDevice),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }
}

// MARK: - 设置键

enum MacGestureSettings {
    static let horizontalTabs    = "melo.mac.gesture.tabs"
    static let horizontalTracks  = "melo.mac.gesture.tracks"
    static let verticalVolume    = "melo.mac.gesture.volume"
    static let swipeDismiss      = "melo.mac.gesture.dismiss"
    static let keyboardShortcuts = "melo.mac.keys.enabled"
    static let tabSwipeMode      = "melo.mac.gesture.tabMode"

    static func on(_ key: String) -> Bool {
        let d = UserDefaults.standard
        if d.object(forKey: key) == nil { return true }
        return d.bool(forKey: key)
    }
    static func set(_ key: String, _ value: Bool) { UserDefaults.standard.set(value, forKey: key) }
    static func str(_ key: String, _ fallback: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? fallback
    }
}

// MARK: - 手势 + 快捷键

final class MacGestures: NSObject, UIGestureRecognizerDelegate {

    static let shared = MacGestures()

    private let flickThreshold: CGFloat = 1000
    private let axisRatio: CGFloat = 1.5
    private var installed = false
    private var keyCaptureView: KeyCaptureUIView?
    private var keyCommands: [UIKeyCommand] = []

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
            Diagnostics.mark("gestures: installed")
        }
    }

    private func attach(to window: UIWindow) {
        // ── 两指触控板滑动 ──
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFinger(_:)))
        pan.allowedScrollTypesMask = [.continuous, .discrete]
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delegate = self
        window.addGestureRecognizer(pan)

        // ── 三指滑动（需系统开启「三指拖移」）──
        let three = UIPanGestureRecognizer(target: self, action: #selector(handleThreeFinger(_:)))
        three.minimumNumberOfTouches = 3
        three.maximumNumberOfTouches = 3
        three.cancelsTouchesInView = false
        three.delaysTouchesBegan = false
        three.delegate = self
        window.addGestureRecognizer(three)

        // ── 快捷键：UIKeyCommand 挂在 window 上，走响应链，打字时自动让路 ──
        installKeyCommands(on: window)

        // ── 录制用的按键捕获视图 ──
        let captureView = KeyCaptureUIView(frame: .zero)
        captureView.isHidden = true
        window.addSubview(captureView)
        keyCaptureView = captureView

        // 录制时把 firstResponder 交给捕获视图
        NotificationCenter.default.addObserver(
            forName: .meloFocusKeyCapture, object: nil, queue: .main
        ) { [weak self] _ in
            self?.keyCaptureView?.becomeFirstResponder()
        }

        // 快捷键变更后刷新
        NotificationCenter.default.addObserver(
            forName: .meloRefreshKeyCommands, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.refreshKeyCommands(on: window)
        }
    }

    private func installKeyCommands(on window: UIWindow) {
        keyCommands = ShortcutStore.makeKeyCommands(target: self)
        for cmd in keyCommands {
            window.addKeyCommand(cmd)
        }
    }

    private func refreshKeyCommands(on window: UIWindow) {
        for cmd in keyCommands { window.removeKeyCommand(cmd) }
        installKeyCommands(on: window)
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    // MARK: UIKeyCommand action

    @objc func handleShortcutAction(_ command: UIKeyCommand) {
        guard MacGestureSettings.on(MacGestureSettings.keyboardShortcuts) else { return }
        guard let raw = command.propertyList as? String,
              let action = ShortcutStore.Action(rawValue: raw) else { return }
        ShortcutStore.perform(action)
    }

    // MARK: 两指手势

    @objc private func handleTwoFinger(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended || recognizer.state == .cancelled else { return }
        guard let view = recognizer.view else { return }

        let velocity = recognizer.velocity(in: view)
        let speed = max(abs(velocity.x), abs(velocity.y))
        guard speed >= flickThreshold else { return }

        let isHorizontal = abs(velocity.x) >= abs(velocity.y) * axisRatio
        let isVertical   = abs(velocity.y) >= abs(velocity.x) * axisRatio
        let playerOpen   = PlayerEngine.shared.opensFullPlayer

        if isHorizontal {
            let goForward = velocity.x < 0
            if playerOpen {
                guard MacGestureSettings.on(MacGestureSettings.horizontalTracks) else { return }
                Diagnostics.mark("gesture 2f: \(goForward ? "left→next" : "right→prev")")
                if goForward { PlayerEngine.shared.next() } else { PlayerEngine.shared.previous() }
            } else {
                let mode = MacGestureSettings.str(MacGestureSettings.tabSwipeMode, "two-bg")
                guard mode != "off", MacGestureSettings.on(MacGestureSettings.horizontalTabs) else { return }
                if mode == "two-bg" {
                    let point = recognizer.location(in: view)
                    if isOnHorizontalScrollView(at: point, in: view) { return }
                }
                switchTab(goForward ? 1 : -1)
            }
        } else if isVertical {
            if playerOpen && velocity.y > 0,
               MacGestureSettings.on(MacGestureSettings.swipeDismiss) {
                Diagnostics.mark("gesture 2f: down→close")
                PlayerEngine.shared.opensFullPlayer = false
                return
            }
            guard MacGestureSettings.on(MacGestureSettings.verticalVolume) else { return }
            let delta: Float = velocity.y < 0 ? 0.05 : -0.05
            MacVolume.adjust(by: delta)
        }
    }

    // MARK: 三指手势

    @objc private func handleThreeFinger(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended || recognizer.state == .cancelled else { return }
        guard let view = recognizer.view else { return }
        guard MacGestureSettings.str(MacGestureSettings.tabSwipeMode, "two-bg") == "three" else { return }

        let velocity = recognizer.velocity(in: view)
        guard abs(velocity.x) >= flickThreshold,
              abs(velocity.x) >= abs(velocity.y) * axisRatio else { return }
        guard MacGestureSettings.on(MacGestureSettings.horizontalTabs) else { return }

        let goForward = velocity.x < 0
        Diagnostics.mark("gesture 3f: tab \(goForward ? "→" : "←")")
        switchTab(goForward ? 1 : -1)
    }

    private func isOnHorizontalScrollView(at point: CGPoint, in view: UIView) -> Bool {
        guard let hit = view.hitTest(point, with: nil) else { return false }
        var current: UIView? = hit
        while let v = current {
            if let sv = v as? UIScrollView {
                return sv.contentSize.width > sv.bounds.width + 1
            }
            current = v.superview
        }
        return false
    }

    private func switchTab(_ direction: Int) {
        let cur = UserDefaults.standard.integer(forKey: "melo.mac.currentTab")
        let next = ((cur + direction) % 4 + 4) % 4
        UserDefaults.standard.set(next, forKey: "melo.mac.currentTab")
        NotificationCenter.default.post(name: .meloSwitchTab, object: nil, userInfo: ["index": next])
        Diagnostics.mark("gesture: tab → \(next)")
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

extension Notification.Name {
    static let meloSwitchTab = Notification.Name("melo.switchTab")
    static let meloRefreshKeyCommands = Notification.Name("melo.refreshKeyCommands")
}

/// UIKeyCommand 的 action 走响应链，最终由 window 接收。
/// 这里给 UIWindow 打个补丁，转发给 MacGestures。
extension UIWindow {
    @objc func handleShortcutAction(_ command: UIKeyCommand) {
        MacGestures.shared.handleShortcutAction(command)
    }
}

#endif
