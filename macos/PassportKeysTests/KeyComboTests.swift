import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import PassportKeys

struct KeyComboTests {
    @Test func formatsSpecialKeys() {
        let combo = KeyCombo(kVK_LeftArrow, [.command, .shift])
        #expect(combo.displayString == "⇧⌘←")
        #expect(combo.deviceLabel == "Shift+Cmd+Left")
    }

    @Test func formatsModifiersInSystemOrder() {
        let combo = KeyCombo(kVK_Space, [.command, .option, .control, .shift])
        #expect(combo.displayString == "⌃⌥⇧⌘空格")
        #expect(combo.deviceLabel == "Ctrl+Opt+Shift+Cmd+Space")
    }

    @Test func translatesCharacterKeysWithCurrentLayout() {
        // 字符取决于当前 ASCII 键盘布局,这里只断言格式。
        let label = KeyCombo(kVK_ANSI_A, .command).deviceLabel
        #expect(label.hasPrefix("Cmd+"))
        #expect(label.count == 5)
        #expect(label.last?.isUppercase == true)
    }

    @Test func keepsOnlySupportedModifiersFromEventFlags() {
        let flags: NSEvent.ModifierFlags = [.command, .shift, .capsLock, .function, .numericPad]
        #expect(KeyCombo.Modifiers(flags) == [.command, .shift])
    }

    @Test func roundTripsThroughCodable() throws {
        let combo = KeyCombo(kVK_ANSI_A, [.command, .option])
        let data = try JSONEncoder().encode(combo)
        #expect(try JSONDecoder().decode(KeyCombo.self, from: data) == combo)
    }

    @Test func arrowKeysCarryHardwareFlags() {
        #expect(KeyCombo.intrinsicFlags(for: UInt16(kVK_UpArrow)) == [.maskNumericPad, .maskSecondaryFn])
        #expect(KeyCombo.intrinsicFlags(for: UInt16(kVK_F5)) == .maskSecondaryFn)
        #expect(KeyCombo.intrinsicFlags(for: UInt16(kVK_ANSI_A)).isEmpty)
    }
}

struct SettingsStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "PassportKeysTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func usesDefaultsOnFirstLaunch() {
        let store = SettingsStore(defaults: makeDefaults())
        #expect(store.combo(for: .up) == KeyCombo(kVK_UpArrow))
        #expect(store.combo(for: .down) == KeyCombo(kVK_DownArrow))
        #expect(store.combo(for: .ok) == KeyCombo(kVK_Return))
        #expect(store.isEnabled)
        #expect(store.allowBluetooth)
        #expect(!store.hasLaunchedBefore)
    }

    @Test func persistsMappingsIncludingClearedButtons() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        var notifications = 0
        store.onMappingsChange = { notifications += 1 }

        store.setCombo(KeyCombo(kVK_ANSI_A, .command), for: .up)
        store.setCombo(KeyCombo(kVK_ANSI_A, .command), for: .up)
        store.setCombo(nil, for: .ok)
        store.isEnabled = false
        #expect(notifications == 2)

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.combo(for: .up) == KeyCombo(kVK_ANSI_A, .command))
        #expect(reloaded.combo(for: .down) == KeyCombo(kVK_DownArrow))
        #expect(reloaded.combo(for: .ok) == nil)
        #expect(!reloaded.isEnabled)

        reloaded.resetMappings()
        #expect(SettingsStore(defaults: defaults).combo(for: .ok) == KeyCombo(kVK_Return))
    }

    @Test func buildsAsciiDeviceLabels() {
        let store = SettingsStore(defaults: makeDefaults())
        store.setCombo(nil, for: .down)
        #expect(store.deviceLabels == DeviceLabels(up: "Up", down: "", ok: "Return"))
    }
}
