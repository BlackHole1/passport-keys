import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// 一个快捷键:物理键位 keyCode + 修饰键。
/// 保存 keyCode 而不是字符,回放时与键盘布局无关,和录制时按下的是同一个键。
nonisolated struct KeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: Modifiers

    init(keyCode: UInt16, modifiers: Modifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(_ keyCode: Int, _ modifiers: Modifiers = []) {
        self.init(keyCode: UInt16(keyCode), modifiers: modifiers)
    }

    nonisolated struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: UInt8

        init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)

        init(_ flags: NSEvent.ModifierFlags) {
            var result: Modifiers = []
            if flags.contains(.control) { result.insert(.control) }
            if flags.contains(.option) { result.insert(.option) }
            if flags.contains(.shift) { result.insert(.shift) }
            if flags.contains(.command) { result.insert(.command) }
            self = result
        }

        /// 系统菜单的书写顺序:⌃⌥⇧⌘。
        var symbols: String {
            orderedKeys.map(\.symbol).joined()
        }

        var asciiNames: [String] {
            orderedKeys.map(\.ascii)
        }

        var eventFlags: CGEventFlags {
            orderedKeys.reduce(into: []) { $0.insert($1.flag) }
        }

        /// 模拟按键时修饰键的按下顺序,抬起时逆序。
        var orderedKeys: [ModifierKey] {
            ModifierKey.all.filter { contains($0.modifier) }
        }
    }

    nonisolated struct ModifierKey: Sendable {
        let modifier: Modifiers
        let flag: CGEventFlags
        let keyCode: UInt16
        let symbol: String
        let ascii: String

        static let all: [ModifierKey] = [
            ModifierKey(modifier: .control, flag: .maskControl, keyCode: UInt16(kVK_Control), symbol: "⌃", ascii: "Ctrl"),
            ModifierKey(modifier: .option, flag: .maskAlternate, keyCode: UInt16(kVK_Option), symbol: "⌥", ascii: "Opt"),
            ModifierKey(modifier: .shift, flag: .maskShift, keyCode: UInt16(kVK_Shift), symbol: "⇧", ascii: "Shift"),
            ModifierKey(modifier: .command, flag: .maskCommand, keyCode: UInt16(kVK_Command), symbol: "⌘", ascii: "Cmd"),
        ]
    }
}

extension KeyCombo {
    /// 界面显示,例如 "⇧⌘A"。
    var displayString: String {
        modifiers.symbols + KeyNames.displayName(for: keyCode)
    }

    /// 设备屏幕显示。Passport 固件字体只有 ASCII,例如 "Shift+Cmd+A"。
    var deviceLabel: String {
        (modifiers.asciiNames + [KeyNames.asciiName(for: keyCode)]).joined(separator: "+")
    }

    /// 真实键盘上方向键、翻页键、F 键等自带的标志位。部分 app 会据此区分按键,回放时保持一致。
    nonisolated static func intrinsicFlags(for keyCode: UInt16) -> CGEventFlags {
        switch Int(keyCode) {
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            return [.maskNumericPad, .maskSecondaryFn]
        case kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete, kVK_Help,
             kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
             kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20:
            return .maskSecondaryFn
        default:
            return []
        }
    }
}

extension KeyCombo {
    nonisolated struct Preset: Identifiable, Sendable {
        let title: String
        let combo: KeyCombo

        var id: String { title }
    }

    nonisolated struct PresetGroup: Identifiable, Sendable {
        let title: String
        let presets: [Preset]

        var id: String { title }
    }

    /// 录制框录不到的系统保留组合(如 ⌘Tab)以及演示翻页等常用键,可以从菜单直接选择。
    nonisolated static let presetGroups: [PresetGroup] = [
        PresetGroup(title: "方向与翻页", presets: [
            Preset(title: "上方向键", combo: KeyCombo(kVK_UpArrow)),
            Preset(title: "下方向键", combo: KeyCombo(kVK_DownArrow)),
            Preset(title: "左方向键", combo: KeyCombo(kVK_LeftArrow)),
            Preset(title: "右方向键", combo: KeyCombo(kVK_RightArrow)),
            Preset(title: "Page Up", combo: KeyCombo(kVK_PageUp)),
            Preset(title: "Page Down", combo: KeyCombo(kVK_PageDown)),
        ]),
        PresetGroup(title: "常用键", presets: [
            Preset(title: "回车", combo: KeyCombo(kVK_Return)),
            Preset(title: "空格", combo: KeyCombo(kVK_Space)),
            Preset(title: "Esc", combo: KeyCombo(kVK_Escape)),
            Preset(title: "Tab", combo: KeyCombo(kVK_Tab)),
            Preset(title: "删除", combo: KeyCombo(kVK_Delete)),
        ]),
        PresetGroup(title: "系统快捷键", presets: [
            Preset(title: "全选", combo: KeyCombo(kVK_ANSI_A, .command)),
            Preset(title: "复制", combo: KeyCombo(kVK_ANSI_C, .command)),
            Preset(title: "粘贴", combo: KeyCombo(kVK_ANSI_V, .command)),
            Preset(title: "撤销", combo: KeyCombo(kVK_ANSI_Z, .command)),
            Preset(title: "切换应用", combo: KeyCombo(kVK_Tab, .command)),
            Preset(title: "Spotlight", combo: KeyCombo(kVK_Space, .command)),
            Preset(title: "调度中心", combo: KeyCombo(kVK_UpArrow, .control)),
        ]),
    ]
}
