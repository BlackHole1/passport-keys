import CoreGraphics

/// 在 HID 层合成一次组合键:依次按下修饰键,按下并抬起主键,再逆序抬起修饰键。
/// 需要"辅助功能"授权,未授权时系统会静默丢弃事件。
enum KeyInjector {
    static func post(_ combo: KeyCombo) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let modifierKeys = combo.modifiers.orderedKeys
        var flags: CGEventFlags = []

        for key in modifierKeys {
            flags.insert(key.flag)
            post(keyCode: key.keyCode, down: true, flags: flags, isModifier: true, source: source)
        }

        let keyFlags = flags.union(KeyCombo.intrinsicFlags(for: combo.keyCode))
        post(keyCode: combo.keyCode, down: true, flags: keyFlags, isModifier: false, source: source)
        post(keyCode: combo.keyCode, down: false, flags: keyFlags, isModifier: false, source: source)

        for key in modifierKeys.reversed() {
            flags.remove(key.flag)
            post(keyCode: key.keyCode, down: false, flags: flags, isModifier: true, source: source)
        }
    }

    private static func post(keyCode: UInt16, down: Bool, flags: CGEventFlags, isModifier: Bool, source: CGEventSource) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down) else {
            return
        }
        // 真实键盘上按修饰键产生的是 flagsChanged,而不是 keyDown/keyUp。
        if isModifier {
            event.type = .flagsChanged
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
