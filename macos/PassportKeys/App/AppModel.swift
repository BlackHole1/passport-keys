import AppKit
import Observation

/// 应用级协调者:把设备按键事件翻译成系统快捷键,并向设备同步映射标签。
@Observable
final class AppModel {
    let settings: SettingsStore
    let device: DeviceManager
    let accessibility: AccessibilityPermission
    let loginItem: LoginItemController

    /// 最近一次按下的键与计数器,界面据此做按下反馈。
    private(set) var lastPressed: PassportButton?
    private(set) var pressCount = 0

    /// 正在录制快捷键的按钮。录制期间暂停注入,避免设备按键把快捷键打进录制框。
    var recordingButton: PassportButton?

    /// 递增即请求打开设置窗口;窗口只能由 SwiftUI 视图打开,见 MenuBarLabel。
    private(set) var settingsWindowRequest = 0

    init(defaults: UserDefaults = .standard) {
        settings = SettingsStore(defaults: defaults)
        device = DeviceManager()
        accessibility = AccessibilityPermission()
        loginItem = LoginItemController()

        device.bluetoothAllowed = settings.allowBluetooth
        device.onButton = { [weak self] button in
            self?.handlePress(button)
        }
        device.labelsProvider = { [weak self] in
            self?.settings.deviceLabels ?? .empty
        }
        settings.onMappingsChange = { [weak self] in
            self?.device.pushLabels()
        }
        device.configProvider = { [weak self] in
            self?.settings.deviceConfig
        }
        settings.onDeviceConfigChange = { [weak self] in
            self?.device.pushConfig()
        }
    }

    func start() {
        device.start()
        if !accessibility.isTrusted || !settings.hasLaunchedBefore {
            requestSettingsWindow()
        }
        accessibility.startMonitoring()
        settings.hasLaunchedBefore = true
    }

    func stop() {
        device.stop()
    }

    func requestSettingsWindow() {
        settingsWindowRequest += 1
    }

    func setAllowBluetooth(_ allowed: Bool) {
        settings.allowBluetooth = allowed
        device.bluetoothAllowed = allowed
    }

    func handlePress(_ button: PassportButton) {
        lastPressed = button
        pressCount += 1

        guard settings.isEnabled, recordingButton == nil, let combo = settings.combo(for: button) else {
            return
        }
        // 未授权时系统会静默丢弃合成事件;这里顺带刷新状态,让界面及时提示。
        guard accessibility.refresh() else {
            deviceLog.error("accessibility not granted, \(button.rawValue, privacy: .public) ignored")
            accessibility.startMonitoring()
            return
        }
        deviceLog.info("inject \(combo.displayString, privacy: .public) for \(button.rawValue, privacy: .public)")
        KeyInjector.post(combo)
    }
}
