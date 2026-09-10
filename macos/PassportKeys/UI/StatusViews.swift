import SwiftUI

struct StatusBadge: View {
    let status: DeviceManager.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
        }
    }

    private var text: String {
        switch status {
        case .idle: "未启动"
        case .searching: "等待设备"
        case .handshaking(let link, _): "正在通过\(link.title)握手"
        case .connected(let device): "已通过\(device.link.title)连接"
        }
    }

    private var color: Color {
        switch status {
        case .idle: .gray
        case .searching: .orange
        case .handshaking: .yellow
        case .connected: .green
        }
    }
}

struct BatteryLabel: View {
    let percent: Int
    let millivolts: Int?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text("\(percent)%")
            if let millivolts {
                Text(String(format: "%.2f V", Double(millivolts) / 1000))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var symbol: String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}
