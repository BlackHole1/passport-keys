import Carbon.HIToolbox
import Foundation
import Observation

/// 发给设备屏幕显示的三键标签。
nonisolated struct DeviceLabels: Equatable, Sendable {
    var up: String
    var down: String
    var ok: String

    static let empty = DeviceLabels(up: "", down: "", ok: "")
}

/// 用户设置,持久化在 UserDefaults。
@Observable
final class SettingsStore {
    private enum Keys {
        static let mappings = "mappings.v1"
        static let enabled = "mappingEnabled"
        static let allowBluetooth = "allowBluetooth"
        static let hasLaunchedBefore = "hasLaunchedBefore"
    }

    /// 默认映射保持无副作用:方向键 + 回车。用户可改成 ⌘A 等任意组合。
    static let defaultCombos: [PassportButton: KeyCombo] = [
        .up: KeyCombo(kVK_UpArrow),
        .down: KeyCombo(kVK_DownArrow),
        .ok: KeyCombo(kVK_Return),
    ]

    /// 未出现在字典里的按钮表示"未设置",按下时不做任何事。
    private(set) var combos: [PassportButton: KeyCombo]

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }

    var allowBluetooth: Bool {
        didSet { defaults.set(allowBluetooth, forKey: Keys.allowBluetooth) }
    }

    var hasLaunchedBefore: Bool {
        didSet { defaults.set(hasLaunchedBefore, forKey: Keys.hasLaunchedBefore) }
    }

    @ObservationIgnored var onMappingsChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.mappings),
           let stored = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            combos = stored.reduce(into: [:]) { result, entry in
                if let button = PassportButton(rawValue: entry.key) {
                    result[button] = entry.value
                }
            }
        } else {
            combos = Self.defaultCombos
        }
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        allowBluetooth = defaults.object(forKey: Keys.allowBluetooth) as? Bool ?? true
        hasLaunchedBefore = defaults.bool(forKey: Keys.hasLaunchedBefore)
    }

    func combo(for button: PassportButton) -> KeyCombo? {
        combos[button]
    }

    func setCombo(_ combo: KeyCombo?, for button: PassportButton) {
        guard combos[button] != combo else { return }
        combos[button] = combo
        saveMappings()
    }

    func resetMappings() {
        guard combos != Self.defaultCombos else { return }
        combos = Self.defaultCombos
        saveMappings()
    }

    var deviceLabels: DeviceLabels {
        DeviceLabels(
            up: combos[.up]?.deviceLabel ?? "",
            down: combos[.down]?.deviceLabel ?? "",
            ok: combos[.ok]?.deviceLabel ?? ""
        )
    }

    private func saveMappings() {
        let stored = Dictionary(uniqueKeysWithValues: combos.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Keys.mappings)
        }
        onMappingsChange?()
    }
}
