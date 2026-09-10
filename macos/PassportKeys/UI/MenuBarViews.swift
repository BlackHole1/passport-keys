import SwiftUI

/// 菜单栏图标。菜单栏标签在启动时就会显示,因此也负责响应"打开设置窗口"的请求:
/// SwiftUI 只允许在视图里通过 openWindow 打开窗口。
struct MenuBarLabel: View {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow
    @State private var handledRequest = 0

    var body: some View {
        Image(systemName: model.device.isConnected ? "keyboard.fill" : "keyboard")
            .onChange(of: model.settingsWindowRequest, initial: true) { _, request in
                guard request > handledRequest else { return }
                handledRequest = request
                openWindow(id: SettingsWindow.id)
                NSApp.activate()
            }
    }
}

struct MenuBarContentView: View {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Passport Keys")
                    .font(.headline)
                Spacer()
                StatusBadge(status: model.device.status)
                    .font(.callout)
            }

            if let percent = model.device.battery?.percent {
                BatteryLabel(percent: percent, millivolts: nil)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !model.accessibility.isTrusted {
                VStack(alignment: .leading, spacing: 6) {
                    Label("未获得辅助功能权限,按键不会生效", systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Button("去授权") {
                        model.accessibility.requestAccess()
                        openSettings()
                    }
                }
                .font(.callout)
            }

            Divider()

            ForEach(PassportButton.allCases) { button in
                HStack {
                    Label(button.title, systemImage: button.systemImage)
                    Spacer()
                    Text(model.settings.combo(for: button)?.displayString ?? "未设置")
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("启用按键映射", isOn: Binding(
                get: { model.settings.isEnabled },
                set: { model.settings.isEnabled = $0 }
            ))

            Divider()

            HStack {
                Button("设置…") {
                    openSettings()
                }
                Spacer()
                Button("退出") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func openSettings() {
        openWindow(id: SettingsWindow.id)
        NSApp.activate()
    }
}
