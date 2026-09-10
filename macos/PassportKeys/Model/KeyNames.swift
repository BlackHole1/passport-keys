import Carbon.HIToolbox
import Foundation

/// keyCode 到可读名称的转换。
/// 字符键按当前 ASCII 键盘布局翻译(中文输入法下取其底层英文布局),特殊键使用固定名称。
/// TIS/UCKeyTranslate 只能在主线程调用,因此本类型保持主线程隔离。
enum KeyNames {
    private struct Name {
        let symbol: String
        let ascii: String
    }

    private static let special: [Int: Name] = [
        kVK_Return: Name(symbol: "↩", ascii: "Return"),
        kVK_ANSI_KeypadEnter: Name(symbol: "⌤", ascii: "Enter"),
        kVK_Tab: Name(symbol: "⇥", ascii: "Tab"),
        kVK_Space: Name(symbol: "空格", ascii: "Space"),
        kVK_Delete: Name(symbol: "⌫", ascii: "Delete"),
        kVK_ForwardDelete: Name(symbol: "⌦", ascii: "FwdDel"),
        kVK_Escape: Name(symbol: "⎋", ascii: "Esc"),
        kVK_LeftArrow: Name(symbol: "←", ascii: "Left"),
        kVK_RightArrow: Name(symbol: "→", ascii: "Right"),
        kVK_UpArrow: Name(symbol: "↑", ascii: "Up"),
        kVK_DownArrow: Name(symbol: "↓", ascii: "Down"),
        kVK_Home: Name(symbol: "↖", ascii: "Home"),
        kVK_End: Name(symbol: "↘", ascii: "End"),
        kVK_PageUp: Name(symbol: "⇞", ascii: "PgUp"),
        kVK_PageDown: Name(symbol: "⇟", ascii: "PgDn"),
        kVK_Help: Name(symbol: "Help", ascii: "Help"),
        kVK_CapsLock: Name(symbol: "⇪", ascii: "Caps"),
        kVK_F1: Name(symbol: "F1", ascii: "F1"),
        kVK_F2: Name(symbol: "F2", ascii: "F2"),
        kVK_F3: Name(symbol: "F3", ascii: "F3"),
        kVK_F4: Name(symbol: "F4", ascii: "F4"),
        kVK_F5: Name(symbol: "F5", ascii: "F5"),
        kVK_F6: Name(symbol: "F6", ascii: "F6"),
        kVK_F7: Name(symbol: "F7", ascii: "F7"),
        kVK_F8: Name(symbol: "F8", ascii: "F8"),
        kVK_F9: Name(symbol: "F9", ascii: "F9"),
        kVK_F10: Name(symbol: "F10", ascii: "F10"),
        kVK_F11: Name(symbol: "F11", ascii: "F11"),
        kVK_F12: Name(symbol: "F12", ascii: "F12"),
        kVK_F13: Name(symbol: "F13", ascii: "F13"),
        kVK_F14: Name(symbol: "F14", ascii: "F14"),
        kVK_F15: Name(symbol: "F15", ascii: "F15"),
        kVK_F16: Name(symbol: "F16", ascii: "F16"),
        kVK_F17: Name(symbol: "F17", ascii: "F17"),
        kVK_F18: Name(symbol: "F18", ascii: "F18"),
        kVK_F19: Name(symbol: "F19", ascii: "F19"),
        kVK_F20: Name(symbol: "F20", ascii: "F20"),
    ]

    static func displayName(for keyCode: UInt16) -> String {
        if let name = special[Int(keyCode)] {
            return name.symbol
        }
        if let character = character(for: keyCode) {
            return character.uppercased()
        }
        return "Key \(keyCode)"
    }

    static func asciiName(for keyCode: UInt16) -> String {
        if let name = special[Int(keyCode)] {
            return name.ascii
        }
        if let character = character(for: keyCode),
           character.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) {
            return character.uppercased()
        }
        return "Key\(keyCode)"
    }

    private static func character(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: characters, count: length)
            return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).isEmpty ? nil : text
        }
    }
}
