import Foundation
import SwiftUI
import UIKit

#if targetEnvironment(macCatalyst)

// MARK: - 快捷键模型

/// 一个快捷键 = UIKeyCommand 的 keyEquivalent + modifierFlags。
/// 用 UIKit 而不是 NSEvent（NSEvent 在 Catalyst 上不可用）。
struct Shortcut: Codable, Equatable {
    /// UIKeyCommand.input 系列常量或普通字符（小写），如 " "、"a"、UIKeyCommand.inputLeftArrow
    var keyEquivalent: String
    /// UIKeyModifierFlags.rawValue（command=1<<20, shift=1<<17, alternate=1<<19, control=1<<18）
    var modifierRaw: Int

    static let defaultPlayPause  = Shortcut(keyEquivalent: " ", modifierRaw: 0)
    static let defaultNext       = Shortcut(keyEquivalent: UIKeyCommand.inputRightArrow, modifierRaw: 1 << 20)
    static let defaultPrevious   = Shortcut(keyEquivalent: UIKeyCommand.inputLeftArrow, modifierRaw: 1 << 20)
    static let defaultVolumeUp   = Shortcut(keyEquivalent: UIKeyCommand.inputUpArrow, modifierRaw: 1 << 20)
    static let defaultVolumeDown = Shortcut(keyEquivalent: UIKeyCommand.inputDownArrow, modifierRaw: 1 << 20)
    static let defaultClose      = Shortcut(keyEquivalent: UIKeyCommand.inputEscape, modifierRaw: 0)

    /// 显示文字
    var displayString: String {
        var s = ""
        let flags = UIKeyModifierFlags(rawValue: modifierRaw)
        if flags.contains(.control)   { s += "⌃" }
        if flags.contains(.alternate) { s += "⌥" }
        if flags.contains(.shift)     { s += "⇧" }
        if flags.contains(.command)   { s += "⌘" }
        s += Self.keyName(keyEquivalent)
        return s
    }

    private static func keyName(_ eq: String) -> String {
        switch eq {
        case " ": return "Space"
        case "\r": return "↩"
        case "\t": return "⇥"
        case UIKeyCommand.inputEscape: return "Esc"
        case UIKeyCommand.inputLeftArrow: return "←"
        case UIKeyCommand.inputRightArrow: return "→"
        case UIKeyCommand.inputUpArrow: return "↑"
        case UIKeyCommand.inputDownArrow: return "↓"
        default: return eq.uppercased()
        }
    }

    /// 从 UIKey 构建（录制时用）
    static func from(key: UIKey) -> Shortcut? {
        let eq: String
        switch key.keyCode {
        case .keyboardEscape: eq = UIKeyCommand.inputEscape
        case .keyboardLeftArrow: eq = UIKeyCommand.inputLeftArrow
        case .keyboardRightArrow: eq = UIKeyCommand.inputRightArrow
        case .keyboardUpArrow: eq = UIKeyCommand.inputUpArrow
        case .keyboardDownArrow: eq = UIKeyCommand.inputDownArrow
        case .keyboardSpacebar: eq = " "
        case .keyboardReturnOrEnter: eq = "\r"
        default:
            let chars = key.charactersIgnoringModifiers
            guard !chars.isEmpty else { return nil }
            eq = chars.lowercased()
        }
        let raw: Int = Int(key.modifierFlags
            .intersection([.command, .alternate, .control, .shift]).rawValue)
        return Shortcut(keyEquivalent: eq, modifierRaw: raw)
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

        /// 生成 UIKeyCommand 的 action selector 名
        var selectorName: String { "handleShortcut_\(rawValue)" }
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
        NotificationCenter.default.post(name: .meloRefreshKeyCommands, object: nil)
    }

    static func reset(_ a: Action) { UserDefaults.standard.removeObject(forKey: key(a)) }
    static func resetAll() {
        for a in Action.allCases { reset(a) }
        NotificationCenter.default.post(name: .meloRefreshKeyCommands, object: nil)
    }

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

    /// 创建所有 UIKeyCommand（挂在窗口上，走响应链，打字时自动让路）
    static func makeKeyCommands(target: AnyObject) -> [UIKeyCommand] {
        Action.allCases.map { action in
            let s = load(action)
            let cmd = UIKeyCommand(
                title: action.label,
                action: NSSelectorFromString("handleShortcutAction:"),
                input: s.keyEquivalent,
                modifierFlags: UIKeyModifierFlags(rawValue: s.modifierRaw)
            )
            cmd.propertyList = action.rawValue
            return cmd
        }
    }
}

// MARK: - 录制管理器

enum ShortcutRecording {
    static var recordingAction: ShortcutStore.Action?
    static var onRecorded: ((ShortcutStore.Action, Shortcut) -> Void)?

    /// 尝试消费一个 UIKey（录制模式下）。返回 true = 已消费。
    static func capture(_ key: UIKey) -> Bool {
        guard let action = recordingAction else { return false }
        if key.keyCode == .keyboardEscape {
            recordingAction = nil
            onRecorded?(action, ShortcutStore.load(action))
            return true
        }
        guard let shortcut = Shortcut.from(key: key) else { return true } // 吞掉不识别的按键
        ShortcutStore.save(shortcut, for: action)
        recordingAction = nil
        onRecorded?(action, shortcut)
        return true
    }
}

// MARK: - 按键捕获视图（录制用）

/// 成为 firstResponder 后接收 pressesBegan，转交给 ShortcutRecording。
final class KeyCaptureUIView: UIView {
    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let key = presses.first?.key else {
            super.pressesBegan(presses, with: event)
            return
        }
        if ShortcutRecording.capture(key) { return }
        super.pressesBegan(presses, with: event)
    }
}

struct KeyCaptureView: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyCaptureUIView { KeyCaptureUIView() }
    func updateUIView(_ uiView: KeyCaptureUIView, context: Context) {}
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
                    ShortcutRecording.onRecorded = { act, s in
                        guard act == action else { return }
                        shortcut = s
                        isRecording = false
                    }
                    isRecording = true
                    // 让捕获视图成为 firstResponder
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        NotificationCenter.default.post(name: .meloFocusKeyCapture, object: nil)
                    }
                }
                .font(.system(size: 13))
                .foregroundColor(Theme.accent)
            }
        }
    }
}

extension Notification.Name {
    static let meloFocusKeyCapture = Notification.Name("melo.focusKeyCapture")
}

#endif
