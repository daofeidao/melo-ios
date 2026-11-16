import Foundation
import SwiftUI
import UIKit

#if targetEnvironment(macCatalyst)
import AppKit

// MARK: - 快捷键模型

/// 一个快捷键 = 修饰键 + 键码。
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifierRaw: UInt   // NSEvent.ModifierFlags rawValue

    static let defaultPlayPause  = Shortcut(keyCode: 49, modifierRaw: 0)
    static let defaultNext       = Shortcut(keyCode: 124, modifierRaw: 1048576)
    static let defaultPrevious   = Shortcut(keyCode: 123, modifierRaw: 1048576)
    static let defaultVolumeUp   = Shortcut(keyCode: 126, modifierRaw: 1048576)
    static let defaultVolumeDown = Shortcut(keyCode: 125, modifierRaw: 1048576)
    static let defaultClose      = Shortcut(keyCode: 53, modifierRaw: 0)

    var displayString: String {
        var s = ""
        let flags = NSEvent.ModifierFlags(rawValue: modifierRaw)
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        s += Self.keyName(keyCode)
        return s
    }

    func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let ef = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mf = NSEvent.ModifierFlags(rawValue: modifierRaw).intersection(.deviceIndependentFlagsMask)
        return ef == mf
    }

    private static func keyName(_ code: UInt16) -> String {
        switch code {
        case 49: return "Space"
        case 36: return "↩"; case 48: return "⇥"; case 51: return "⌫"; case 53: return "Esc"
        case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        case 96: return "F5"; case 97: return "F6"; case 98: return "F7"
        case 100: return "F8"; case 101: return "F9"; case 109: return "F10"
        case 103: return "F11"; case 111: return "F12"
        case 0: return "A"; case 1: return "S"; case 2: return "D"; case 3: return "F"
        case 5: return "G"; case 4: return "H"; case 38: return "J"; case 40: return "K"
        case 37: return "L"; case 6: return "Z"; case 7: return "X"; case 8: return "C"
        case 9: return "V"; case 11: return "B"; case 45: return "N"; case 46: return "M"
        case 12: return "Q"; case 13: return "W"; case 14: return "E"; case 15: return "R"
        case 17: return "T"; case 16: return "Y"; case 32: return "U"; case 34: return "I"
        case 31: return "O"; case 35: return "P"
        case 18: return "1"; case 19: return "2"; case 20: return "3"; case 21: return "4"
        case 23: return "5"; case 22: return "6"; case 26: return "7"; case 28: return "8"
        case 25: return "9"; case 29: return "0"
        default: return "Key\(code)"
        }
    }
}

// MARK: - 快捷键存储与分发

enum ShortcutStore {

    enum Action: String, CaseIterable {
        case playPause, next, previous, volumeUp, volumeDown, closePlayer

        var label: String {
            switch self {
            case .playPause:   return "播放 / 暂停"
            case .next:        return "下一曲"
            case .previous:    return "上一曲"
            case .volumeUp:    return "音量增"
            case .volumeDown:  return "音量减"
            case .closePlayer: return "关闭播放页"
            }
        }

        var defaultShortcut: Shortcut {
            switch self {
            case .playPause:   return .defaultPlayPause
            case .next:        return .defaultNext
            case .previous:    return .defaultPrevious
            case .volumeUp:    return .defaultVolumeUp
            case .volumeDown:  return .defaultVolumeDown
            case .closePlayer: return .defaultClose
            }
        }
    }

    private static func key(_ a: Action) -> String { "melo.mac.shortcut.\(a.rawValue)" }

    static func load(_ a: Action) -> Shortcut {
        guard let d = UserDefaults.standard.data(forKey: key(a)),
              let s = try? JSONDecoder().decode(Shortcut.self, from: d)
        else { return a.defaultShortcut }
        return s
    }

    static func save(_ s: Shortcut, for a: Action) {
        if let d = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(d, forKey: key(a))
        }
    }

    static func reset(_ a: Action) { UserDefaults.standard.removeObject(forKey: key(a)) }

    static func resetAll() { for a in Action.allCases { reset(a) } }

    static func perform(_ a: Action) {
        switch a {
        case .playPause:   PlayerEngine.shared.toggle()
        case .next:        PlayerEngine.shared.next()
        case .previous:    PlayerEngine.shared.previous()
        case .volumeUp:    MacVolume.adjust(by: 0.05)
        case .volumeDown:  MacVolume.adjust(by: -0.05)
        case .closePlayer: PlayerEngine.shared.opensFullPlayer = false
        }
        Diagnostics.mark("shortcut: \(a.label)")
    }

    /// 尝试消费一个 keyDown 事件：匹配到就执行并返回 true
    static func handle(_ event: NSEvent) -> Bool {
        guard MacGestureSettings.on(MacGestureSettings.keyboardShortcuts) else { return false }
        for action in Action.allCases {
            if load(action).matches(event) {
                perform(action)
                return true
            }
        }
        return false
    }
}

// MARK: - 录制管理器

/// 全局快捷键录制状态。`ShortcutRecorderView` 的「修改」按钮把 action 赋给 `recordingAction`，
/// NSEvent 监听器捕获到按键后写入。
enum ShortcutRecording {
    static var recordingAction: ShortcutStore.Action?
    /// 录制完成后回调（刷新 UI）
    static var onRecorded: ((ShortcutStore.Action, Shortcut) -> Void)?

    /// 处理录制中的按键。返回 true = 已消费。
    static func capture(_ event: NSEvent) -> Bool {
        guard let action = recordingAction else { return false }
        // Esc 取消
        if event.keyCode == 53 {
            recordingAction = nil
            onRecorded?(action, ShortcutStore.load(action))
            return true
        }
        // 组装
        var raw: UInt = 0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { raw |= NSEvent.ModifierFlags.command.rawValue }
        if flags.contains(.option)  { raw |= NSEvent.ModifierFlags.option.rawValue }
        if flags.contains(.control) { raw |= NSEvent.ModifierFlags.control.rawValue }
        if flags.contains(.shift)   { raw |= NSEvent.ModifierFlags.shift.rawValue }
        let shortcut = Shortcut(keyCode: event.keyCode, modifierRaw: raw)
        ShortcutStore.save(shortcut, for: action)
        recordingAction = nil
        onRecorded?(action, shortcut)
        return true
    }
}

// MARK: - 快捷键设置行

struct ShortcutSettingRow: View {
    let action: ShortcutStore.Action
    @State private var shortcut: Shortcut
    @State private var isRecording = false

    init(action: ShortcutStore.Action) {
        self.action = action
        _shortcut = State(initialValue: ShortcutStore.load(action))
    }

    var body: some View {
        HStack {
            Text(action.label)
            Spacer()
            if isRecording {
                Text("按下快捷键…（Esc 取消）")
                    .foregroundColor(Theme.accent)
                    .font(.system(size: 13))
            } else {
                Text(shortcut.displayString)
                    .foregroundColor(Theme.secondaryLabel)
                    .font(.system(size: 13, design: .monospaced))
                Button("修改") {
                    ShortcutRecording.recordingAction = action
                    isRecording = true
                    ShortcutRecording.onRecorded = { act, s in
                        guard act == action else { return }
                        shortcut = s
                        isRecording = false
                    }
                }
                .font(.system(size: 13))
                .foregroundColor(Theme.accent)
            }
        }
    }
}

#endif
