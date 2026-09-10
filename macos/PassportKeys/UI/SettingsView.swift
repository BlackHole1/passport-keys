import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            DeviceSection(device: model.device)
            PermissionSection(permission: model.accessibility)
            MappingSection(model: model)
            GeneralSection(model: model)
        }
        .formStyle(.grouped)
        // 高度可调:默认尺寸由 Window 的 defaultSize 决定,窗口变矮时表单改为滚动。
        .frame(width: 540)
        .frame(minHeight: 420, maxHeight: .infinity)
        .onAppear {
            // 菜单栏 app 默认没有 Dock 图标;设置窗口打开期间临时切换为普通 app,便于用 ⌘Tab 切回。
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear {
            model.recordingButton = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private struct DeviceSection: View {
    let device: DeviceManager

    var body: some View {
        Section("设备") {
            LabeledContent("状态") {
                StatusBadge(status: device.status)
            }
            if case .connected(let info) = device.status {
                LabeledContent("连接方式", value: info.link.title)
                LabeledContent(info.link == .usb ? "端口" : "设备名", value: info.name)
                LabeledContent("固件版本", value: info.firmwareVersion)
            }
            if let battery = device.battery, let percent = battery.percent {
                LabeledContent("电量") {
                    BatteryLabel(percent: percent, millivolts: battery.millivolts)
                }
            }
            if device.status == .searching {
                Text("打开 Passport 电源后,用 USB 数据线连接这台 Mac,或保持蓝牙开启。设备需要先刷入 Passport Keys 固件。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let note = device.bluetoothNote {
                Label(note, systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !device.ignoredPorts.isEmpty {
                Label("已忽略未刷入 Passport Keys 固件的串口:\(device.ignoredPorts.joined(separator: "、"))", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error = device.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct PermissionSection: View {
    let permission: AccessibilityPermission

    var body: some View {
        Section("权限") {
            if permission.isTrusted {
                Label("已获得辅助功能权限", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("需要辅助功能权限才能模拟按键", systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Text("在 系统设置 > 隐私与安全性 > 辅助功能 中打开 Passport Keys,授权后这里会自动刷新。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("请求授权") {
                            permission.requestAccess()
                        }
                        Button("打开系统设置") {
                            permission.openSystemSettings()
                        }
                    }
                }
            }
        }
    }
}

private struct MappingSection: View {
    let model: AppModel

    var body: some View {
        Section {
            Toggle("启用按键映射", isOn: Binding(
                get: { model.settings.isEnabled },
                set: { model.settings.isEnabled = $0 }
            ))
            ForEach(PassportButton.allCases) { button in
                MappingRow(button: button, model: model)
            }
        } header: {
            Text("按键映射")
        } footer: {
            Text("点击快捷键后按下想要的组合键,按 Esc 取消。⌘Tab 这类被系统占用、录制不到的组合,可以从右侧菜单选择。在设备上按键时,对应的行会高亮。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MappingRow: View {
    let button: PassportButton
    let model: AppModel

    @State private var highlighted = false

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                ShortcutRecorder(
                    combo: model.settings.combo(for: button),
                    isRecording: Binding(
                        get: { model.recordingButton == button },
                        set: { recording in
                            if recording {
                                model.recordingButton = button
                            } else if model.recordingButton == button {
                                model.recordingButton = nil
                            }
                        }
                    ),
                    onRecord: { model.settings.setCombo($0, for: button) }
                )
                PresetMenu { model.settings.setCombo($0, for: button) }
                Button {
                    model.settings.setCombo(nil, for: button)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(model.settings.combo(for: button) == nil)
                .help("清除")
            }
        } label: {
            Label(button.title, systemImage: button.systemImage)
                .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
        }
        .onChange(of: model.pressCount) {
            guard model.lastPressed == button else { return }
            highlighted = true
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                highlighted = false
            }
        }
    }
}

private struct GeneralSection: View {
    let model: AppModel

    var body: some View {
        Section("通用") {
            Toggle("允许通过蓝牙连接", isOn: Binding(
                get: { model.settings.allowBluetooth },
                set: { model.setAllowBluetooth($0) }
            ))
            Toggle("登录时自动启动", isOn: Binding(
                get: { model.loginItem.isEnabled },
                set: { model.loginItem.setEnabled($0) }
            ))
            if let error = model.loginItem.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("恢复默认映射") {
                    model.settings.resetMappings()
                }
                Spacer()
                Button("退出 Passport Keys") {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
