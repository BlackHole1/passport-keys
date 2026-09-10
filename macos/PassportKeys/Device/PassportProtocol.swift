import Foundation

nonisolated struct DeviceHello: Equatable, Sendable {
    var firmware: String
    var protocolVersion: Int
    var firmwareVersion: String
    var bootID: String
}

nonisolated struct ButtonPress: Equatable, Sendable {
    var button: PassportButton
    var event: String
    var seq: Int
    var bootID: String
}

nonisolated struct BatteryReport: Equatable, Sendable {
    var percent: Int?
    var millivolts: Int?
}

nonisolated enum DeviceMessage: Equatable, Sendable {
    case hello(DeviceHello)
    case button(ButtonPress)
    case battery(BatteryReport)
    case pong
    case ack(String)
}

nonisolated enum HostCommand: Equatable, Sendable {
    case hello
    case ping
    case labels(DeviceLabels)
    case bye

    var name: String {
        switch self {
        case .hello: "hello"
        case .ping: "ping"
        case .labels: "labels"
        case .bye: "bye"
        }
    }
}

/// 设备与 Mac 之间的 JSON Lines 协议 v1,字段定义见 docs/protocol.md,
/// 设备端实现见 firmware/main/pk_protocol.c。
nonisolated enum PassportProtocol {
    static let firmwareName = "passport-keys"
    static let version = 1

    private nonisolated struct RawMessage: Decodable {
        let t: String
        let fw: String?
        let proto: Int?
        let ver: String?
        let boot: String?
        let k: String?
        let e: String?
        let seq: Int?
        let soc: Int?
        let mv: Int?
        let cmd: String?
    }

    static func decode(line: String) -> DeviceMessage? {
        // USB 串口与 ESP-IDF 日志共用通道,日志前缀可能和协议帧落在同一行,因此从 {"t": 处截取。
        guard let start = line.range(of: #"{"t":"#),
              let raw = try? JSONDecoder().decode(RawMessage.self, from: Data(line[start.lowerBound...].utf8))
        else {
            return nil
        }

        switch raw.t {
        case "hello":
            guard let firmware = raw.fw else { return nil }
            return .hello(DeviceHello(
                firmware: firmware,
                protocolVersion: raw.proto ?? 0,
                firmwareVersion: raw.ver ?? "",
                bootID: raw.boot ?? ""
            ))
        case "btn":
            guard let key = raw.k, let button = PassportButton(rawValue: key), let seq = raw.seq else {
                return nil
            }
            return .button(ButtonPress(button: button, event: raw.e ?? "press", seq: seq, bootID: raw.boot ?? ""))
        case "bat":
            // 固件读不到电量计时发 -1。
            let percent = raw.soc.flatMap { (0...100).contains($0) ? $0 : nil }
            let millivolts = raw.mv.flatMap { $0 > 0 ? $0 : nil }
            return .battery(BatteryReport(percent: percent, millivolts: millivolts))
        case "pong":
            return .pong
        case "ack":
            return .ack(raw.cmd ?? "")
        default:
            return nil
        }
    }

    static func encode(_ command: HostCommand) -> Data {
        var object = ["cmd": command.name]
        if case .labels(let labels) = command {
            object["up"] = labels.up
            object["down"] = labels.down
            object["ok"] = labels.ok
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(object)) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// 按 (boot, seq) 去重最近的按键事件,防止链路切换或重传导致一次按键触发两次。
nonisolated struct RecentEventFilter: Sendable {
    private let capacity: Int
    private var recent: [String] = []

    init(capacity: Int = 32) {
        self.capacity = capacity
    }

    mutating func accept(_ press: ButtonPress) -> Bool {
        let key = "\(press.bootID):\(press.seq)"
        guard !recent.contains(key) else { return false }
        recent.append(key)
        if recent.count > capacity {
            recent.removeFirst(recent.count - capacity)
        }
        return true
    }
}
