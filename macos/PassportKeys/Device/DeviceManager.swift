import Foundation
import Observation
import os

/// 用 `log stream --predicate 'subsystem == "cc.bugs.PassportKeys"'` 查看。
nonisolated let deviceLog = Logger(subsystem: "cc.bugs.PassportKeys", category: "device")

nonisolated enum LinkKind: String, Equatable, Sendable {
    case usb
    case ble

    var title: String {
        switch self {
        case .usb: "USB"
        case .ble: "蓝牙"
        }
    }
}

nonisolated struct ConnectedDevice: Equatable, Sendable {
    var link: LinkKind
    var name: String
    var firmwareVersion: String
    var bootID: String
}

/// 发现并连接 Passport,把协议消息转成按键回调。
///
/// 连接策略是 USB 优先:存在 Espressif USB 串口时先握手,确认是 Passport Keys 固件后关闭蓝牙;
/// 没有可用的 USB 设备时才扫描蓝牙。所有状态只在主线程修改。
@Observable
final class DeviceManager {
    enum Status: Equatable {
        case idle
        case searching
        case handshaking(LinkKind, String)
        case connected(ConnectedDevice)
    }

    private static let handshakeAttempts = 6
    private static let handshakeInterval: Duration = .milliseconds(800)
    private static let heartbeatInterval: Duration = .seconds(5)
    /// 固件每 5 秒回一次 pong,连续约 3 次收不到任何消息即认为链路失效。
    private static let staleTimeout: TimeInterval = 16

    private(set) var status: Status = .idle {
        didSet {
            if status != oldValue {
                deviceLog.info("status: \(String(describing: self.status), privacy: .public)")
            }
        }
    }
    private(set) var battery: BatteryReport?
    private(set) var bluetoothState: BLEClient.State = .disabled
    /// 握手失败的 Espressif 串口,多半是刷了其它固件的 ESP32 设备。
    private(set) var ignoredPorts: [String] = []
    private(set) var lastError: String? {
        didSet {
            if let lastError, lastError != oldValue {
                deviceLog.error("\(lastError, privacy: .public)")
            }
        }
    }

    var bluetoothAllowed = true {
        didSet { updateBluetooth() }
    }

    @ObservationIgnored var onButton: ((PassportButton) -> Void)?
    @ObservationIgnored var labelsProvider: (() -> DeviceLabels)?
    @ObservationIgnored var configProvider: (() -> DeviceConfig?)?

    @ObservationIgnored private let monitor = SerialDeviceMonitor()
    @ObservationIgnored private let ble = BLEClient()
    @ObservationIgnored private var usb: USBSession?
    @ObservationIgnored private var bleBuffer = LineBuffer()
    @ObservationIgnored private var filter = RecentEventFilter()
    @ObservationIgnored private var ports: [SerialPortInfo] = []
    @ObservationIgnored private var rejectedPorts: Set<String> = []
    /// 打开失败(通常被 idf.py monitor 等占用)的串口,期间允许使用蓝牙。
    @ObservationIgnored private var busyPorts: Set<String> = []
    @ObservationIgnored private var handshakeTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var lastMessageAt = Date.distantPast
    @ObservationIgnored private var running = false

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    var bluetoothNote: String? {
        guard bluetoothAllowed else { return nil }
        switch bluetoothState {
        case .poweredOff: return "蓝牙已关闭,只能通过 USB 连接"
        case .unauthorized: return "未获得蓝牙权限,可在 系统设置 > 隐私与安全性 > 蓝牙 中允许 Passport Keys"
        case .unsupported: return "此 Mac 不支持低功耗蓝牙"
        default: return nil
        }
    }

    func start() {
        guard !running else { return }
        running = true
        status = .searching

        monitor.onChange = { [weak self] ports in
            self?.portsChanged(ports)
        }
        ble.onStateChange = { [weak self] state in
            self?.bluetoothState = state
        }
        ble.onReady = { [weak self] name in
            self?.bluetoothReady(name)
        }
        ble.onData = { [weak self] data in
            self?.receiveBluetooth(data)
        }
        ble.onDisconnected = { [weak self] in
            self?.bluetoothDisconnected()
        }

        monitor.start()
        updateBluetooth()

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                self?.heartbeat()
            }
        }
    }

    func stop() {
        guard running else { return }
        if case .connected(let device) = status {
            send(.bye, via: device.link)
        }
        running = false
        heartbeatTask?.cancel()
        openTask?.cancel()
        handshakeTask?.cancel()
        monitor.stop()
        closeUSB(reopen: false)
        ble.setEnabled(false)
        status = .idle
        battery = nil
    }

    /// 把当前映射发给设备屏幕显示。
    func pushLabels() {
        guard case .connected(let device) = status, let labels = labelsProvider?() else { return }
        send(.labels(labels), via: device.link)
    }

    /// 把息屏时间等运行参数发给设备。设备不保存这些参数,每次连接后都要重新下发。
    func pushConfig() {
        guard case .connected(let device) = status, let config = configProvider?() else { return }
        send(.config(config), via: device.link)
    }

    // MARK: - USB

    private func portsChanged(_ newPorts: [SerialPortInfo]) {
        ports = newPorts
        let paths = Set(newPorts.map(\.path))
        // 端口消失后忘掉握手失败记录,重新插入(例如刚刷完固件)时会再次握手。
        rejectedPorts.formIntersection(paths)
        busyPorts.formIntersection(paths)
        ignoredPorts = rejectedPorts.sorted()
        if let usb, !paths.contains(usb.path) {
            closeUSB(reopen: false)
        }
        updateBluetooth()
        // 串口节点刚出现时设备可能仍在启动,稍等再打开。
        scheduleUSBOpen(after: .milliseconds(300))
    }

    private func scheduleUSBOpen(after delay: Duration) {
        openTask?.cancel()
        openTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.openNextUSBPort()
        }
    }

    private func openNextUSBPort() {
        guard running, usb == nil else { return }
        guard let candidate = ports.first(where: { !rejectedPorts.contains($0.path) }) else {
            updateBluetooth()
            return
        }
        let path = candidate.path
        do {
            let port = try SerialPort(
                path: path,
                onData: { [weak self] data in
                    DispatchQueue.main.async {
                        self?.receiveUSB(data, path: path)
                    }
                },
                onClose: { [weak self] code in
                    DispatchQueue.main.async {
                        self?.usbPortClosed(path: path, code: code)
                    }
                }
            )
            usb = USBSession(path: path, port: port)
            busyPorts.remove(path)
            lastError = nil
            updateBluetooth()
            beginHandshake(.usb, name: candidate.displayName)
        } catch {
            // 端口被占用时先允许蓝牙连接,每 3 秒重试一次 USB。
            busyPorts.insert(path)
            lastError = error.localizedDescription
            updateBluetooth()
            scheduleUSBOpen(after: .seconds(3))
        }
    }

    private func receiveUSB(_ data: Data, path: String) {
        guard let usb, usb.path == path else { return }
        for line in usb.buffer.append(data) {
            handle(line: line, via: .usb)
        }
    }

    private func usbPortClosed(path: String, code: Int32?) {
        guard let usb, usb.path == path else { return }
        if let code {
            lastError = "USB 连接中断:\(String(cString: strerror(code)))"
        }
        closeUSB(reopen: true)
    }

    private func closeUSB(reopen: Bool) {
        guard let session = usb else { return }
        usb = nil
        session.port.close()
        if currentLink == .usb {
            resetLinkState()
        }
        updateBluetooth()
        if reopen {
            scheduleUSBOpen(after: .seconds(1))
        }
    }

    // MARK: - Bluetooth

    /// 已有 USB 会话,或存在尚未握手、未被占用的 Espressif 串口时不开蓝牙,
    /// 避免启动瞬间先连上蓝牙又被 USB 抢走。
    private func updateBluetooth() {
        let usbCandidate = ports.contains { !rejectedPorts.contains($0.path) && !busyPorts.contains($0.path) }
        ble.setEnabled(running && bluetoothAllowed && usb == nil && !usbCandidate)
    }

    private func bluetoothReady(_ name: String) {
        guard running, usb == nil else {
            ble.disconnect()
            return
        }
        bleBuffer.reset()
        beginHandshake(.ble, name: name)
    }

    private func receiveBluetooth(_ data: Data) {
        for line in bleBuffer.append(data) {
            handle(line: line, via: .ble)
        }
    }

    private func bluetoothDisconnected() {
        bleBuffer.reset()
        if currentLink == .ble {
            resetLinkState()
        }
    }

    // MARK: - Protocol

    private var currentLink: LinkKind? {
        switch status {
        case .handshaking(let link, _): link
        case .connected(let device): device.link
        case .idle, .searching: nil
        }
    }

    private var currentName: String {
        switch status {
        case .handshaking(_, let name): name
        case .connected(let device): device.name
        case .idle, .searching: ""
        }
    }

    private func handle(line: String, via link: LinkKind) {
        guard link == currentLink, let message = PassportProtocol.decode(line: line) else { return }
        lastMessageAt = Date()

        switch message {
        case .hello(let hello):
            guard hello.firmware == PassportProtocol.firmwareName else {
                handshakeFailed(link)
                return
            }
            handshakeTask?.cancel()
            handshakeTask = nil
            status = .connected(ConnectedDevice(
                link: link,
                name: currentName,
                firmwareVersion: hello.firmwareVersion,
                bootID: hello.bootID
            ))
            lastError = nil
            pushLabels()
            pushConfig()
        case .button(let press):
            guard press.event == "press", filter.accept(press) else { return }
            deviceLog.info("button \(press.button.rawValue, privacy: .public) seq=\(press.seq) via \(link.rawValue, privacy: .public)")
            onButton?(press.button)
        case .battery(let report):
            battery = report
        case .pong, .ack:
            break
        }
    }

    private func beginHandshake(_ link: LinkKind, name: String) {
        status = .handshaking(link, name)
        lastMessageAt = Date()
        handshakeTask?.cancel()
        handshakeTask = Task { [weak self] in
            for _ in 0..<Self.handshakeAttempts {
                guard !Task.isCancelled else { return }
                self?.send(.hello, via: link)
                try? await Task.sleep(for: Self.handshakeInterval)
            }
            guard !Task.isCancelled else { return }
            self?.handshakeFailed(link)
        }
    }

    private func handshakeFailed(_ link: LinkKind) {
        guard currentLink == link else { return }
        deviceLog.notice("handshake failed via \(link.rawValue, privacy: .public)")
        switch link {
        case .usb:
            if let path = usb?.path {
                rejectedPorts.insert(path)
                ignoredPorts = rejectedPorts.sorted()
            }
            closeUSB(reopen: true)
        case .ble:
            lastError = "蓝牙设备未应答握手"
            ble.disconnect()
        }
    }

    private func resetLinkState() {
        handshakeTask?.cancel()
        handshakeTask = nil
        battery = nil
        status = running ? .searching : .idle
    }

    private func heartbeat() {
        guard running, case .connected(let device) = status else { return }
        guard Date().timeIntervalSince(lastMessageAt) <= Self.staleTimeout else {
            // 链路还在但设备不再应答(固件卡住或蓝牙假连接),断开后重新发现。
            lastError = "设备无响应,正在重新连接"
            switch device.link {
            case .usb: closeUSB(reopen: true)
            case .ble: ble.disconnect()
            }
            return
        }
        send(.ping, via: device.link)
    }

    private func send(_ command: HostCommand, via link: LinkKind) {
        let data = PassportProtocol.encode(command)
        switch link {
        case .usb: usb?.port.write(data)
        case .ble: ble.send(data)
        }
    }
}

private final class USBSession {
    let path: String
    let port: SerialPort
    var buffer = LineBuffer()

    init(path: String, port: SerialPort) {
        self.path = path
        self.port = port
    }
}
