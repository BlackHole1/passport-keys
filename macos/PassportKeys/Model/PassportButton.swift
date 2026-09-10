/// Passport 正面的三个功能键。rawValue 与固件协议里的 `k` 字段一致。
nonisolated enum PassportButton: String, CaseIterable, Codable, Identifiable, Sendable {
    case up
    case down
    case ok

    var id: String { rawValue }

    var title: String {
        switch self {
        case .up: "上键"
        case .down: "下键"
        case .ok: "确认键"
        }
    }

    var systemImage: String {
        switch self {
        case .up: "chevron.up.circle"
        case .down: "chevron.down.circle"
        case .ok: "checkmark.circle"
        }
    }
}
