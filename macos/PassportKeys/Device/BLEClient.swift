import CoreBluetooth
import Foundation

/// Passport Keys 固件的 GATT 定义,与 firmware/main/pk_ble.c 保持一致。
enum PassportBLE {
    static let service = CBUUID(string: "12D4FA08-7418-48FA-A95A-B43A2E669E55")
    /// 设备 → Mac,Notify。
    static let events = CBUUID(string: "12D4FA09-7418-48FA-A95A-B43A2E669E55")
    /// Mac → 设备,Write Without Response。
    static let commands = CBUUID(string: "12D4FA0A-7418-48FA-A95A-B43A2E669E55")
}

/// CoreBluetooth central:扫描并连接第一个广播 Passport Keys 服务的设备,订阅事件特征。
/// 委托回调在主队列执行,状态只在主线程修改。
final class BLEClient: NSObject {
    enum State: Equatable {
        case disabled
        case starting
        case poweredOff
        case unauthorized
        case unsupported
        case scanning
        case connecting(String)
        case ready(String)
    }

    private(set) var state: State = .disabled {
        didSet {
            if state != oldValue {
                onStateChange?(state)
            }
        }
    }

    var onStateChange: ((State) -> Void)?
    var onReady: ((String) -> Void)?
    var onData: ((Data) -> Void)?
    var onDisconnected: (() -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var peripheralName = ""
    private var commandCharacteristic: CBCharacteristic?
    private var enabled = false
    private var rescanTask: Task<Void, Never>?

    func setEnabled(_ newValue: Bool) {
        guard newValue != enabled else { return }
        enabled = newValue
        if newValue {
            if let central {
                centralManagerDidUpdateState(central)
            } else {
                state = .starting
                // 首次创建 CBCentralManager 时系统会请求蓝牙授权,因此只在真正需要蓝牙时创建。
                central = CBCentralManager(delegate: self, queue: .main)
            }
        } else {
            rescanTask?.cancel()
            central?.stopScan()
            if let peripheral {
                central?.cancelPeripheralConnection(peripheral)
            }
            endConnection()
            state = .disabled
        }
    }

    func disconnect() {
        guard let peripheral else { return }
        central?.cancelPeripheralConnection(peripheral)
    }

    func send(_ data: Data) {
        guard case .ready = state, let peripheral, let characteristic = commandCharacteristic else { return }
        let chunkSize = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            peripheral.writeValue(data.subdata(in: offset..<end), for: characteristic, type: .withoutResponse)
            offset = end
        }
    }

    private func startScanning() {
        guard enabled, peripheral == nil, let central, central.state == .poweredOn else { return }
        state = .scanning
        central.scanForPeripherals(withServices: [PassportBLE.service])
    }

    /// 清理连接;若之前有连接则通知上层。
    private func endConnection() {
        let hadPeripheral = peripheral != nil
        peripheral?.delegate = nil
        peripheral = nil
        commandCharacteristic = nil
        if hadPeripheral {
            onDisconnected?()
        }
    }

    private func connectionLost() {
        endConnection()
        guard enabled else { return }
        state = .scanning
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.startScanning()
        }
    }
}

extension BLEClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if enabled {
                startScanning()
            }
        case .poweredOff:
            endConnection()
            state = enabled ? .poweredOff : .disabled
        case .unauthorized:
            endConnection()
            state = enabled ? .unauthorized : .disabled
        case .unsupported:
            state = enabled ? .unsupported : .disabled
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard enabled, self.peripheral == nil else { return }
        central.stopScan()
        peripheralName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Passport"
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting(peripheralName)
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([PassportBLE.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionLost()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionLost()
    }
}

extension BLEClient: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == PassportBLE.service }) else {
            disconnect()
            return
        }
        peripheral.discoverCharacteristics([PassportBLE.events, PassportBLE.commands], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        guard let events = characteristics.first(where: { $0.uuid == PassportBLE.events }),
              let commands = characteristics.first(where: { $0.uuid == PassportBLE.commands })
        else {
            disconnect()
            return
        }
        commandCharacteristic = commands
        peripheral.setNotifyValue(true, for: events)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == PassportBLE.events else { return }
        guard error == nil, characteristic.isNotifying else {
            disconnect()
            return
        }
        state = .ready(peripheralName)
        onReady?(peripheralName)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == PassportBLE.events, let value = characteristic.value else { return }
        onData?(value)
    }
}
