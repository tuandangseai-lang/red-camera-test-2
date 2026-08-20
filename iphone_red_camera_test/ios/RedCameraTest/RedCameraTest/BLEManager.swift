import CoreBluetooth
import Foundation

enum TrackingMode: String, CaseIterable, Identifiable {
    case waterRocket = "ROCKET"
    case person = "PERSON"
    case animal = "ANIMAL"
    case object = "OBJECT"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .waterRocket: return "Tên lửa nước"
        case .person: return "Người"
        case .animal: return "Thú"
        case .object: return "Vật"
        }
    }

    var icon: String {
        switch self {
        case .waterRocket: return "rocket.fill"
        case .person: return "person.fill"
        case .animal: return "pawprint.fill"
        case .object: return "cube.fill"
        }
    }
}

enum GimbalTrackingState: String {
    case disconnected
    case idle
    case acquire
    case lock
    case search
    case home

    var title: String {
        switch self {
        case .disconnected: return "Chưa kết nối"
        case .idle: return "Sẵn sàng"
        case .acquire: return "Đang tìm"
        case .lock: return "Đã khóa mục tiêu"
        case .search: return "Đang bắt lại"
        case .home: return "Đang về Home"
        }
    }
}

final class BLEManager: NSObject, ObservableObject {
    @Published private(set) var connectionText = "Đang bật Bluetooth..."
    @Published private(set) var isConnected = false
    @Published private(set) var trackingState: GimbalTrackingState = .disconnected
    @Published private(set) var confidence = 0
    @Published private(set) var targetX = 0.5
    @Published private(set) var targetY = 0.5
    @Published private(set) var panAngle = 90.0
    @Published private(set) var tiltAngle = 90.0
    @Published private(set) var maixVersion = "Đang chờ MaixCAM"
    @Published private(set) var selectedMode: TrackingMode = .waterRocket

    private let serviceUUID = CBUUID(string: "7E57A000-8E3A-4D6A-9B2B-13B10A000001")
    private let eventUUID = CBUUID(string: "7E57A001-8E3A-4D6A-9B2B-13B10A000001")
    private let commandUUID = CBUUID(string: "7E57A002-8E3A-4D6A-9B2B-13B10A000001")

    private var central: CBCentralManager!
    private var trackerPeripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var lifecycleActive = true
    private var reconnectWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func arm() {
        send("ARM")
        trackingState = .acquire
    }

    func stop() {
        send("STOP")
        trackingState = .idle
    }

    func home() {
        send("HOME")
        trackingState = .home
    }

    func selectMode(_ mode: TrackingMode) {
        guard selectedMode != mode else { return }
        selectedMode = mode
        confidence = 0
        targetX = 0.5
        targetY = 0.5
        trackingState = .idle
        send("MODE,\(mode.rawValue)")
    }

    func suspendForBackground() {
        lifecycleActive = false
        reconnectWorkItem?.cancel()
        central.stopScan()
    }

    func resumeFromForeground() {
        lifecycleActive = true
        if trackerPeripheral?.state != .connected {
            startScanning()
        }
    }

    private func send(_ command: String) {
        guard let peripheral = trackerPeripheral,
              peripheral.state == .connected,
              let characteristic = commandCharacteristic,
              let data = command.data(using: .utf8) else { return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write)
            ? .withResponse
            : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    private func startScanning() {
        guard lifecycleActive, central.state == .poweredOn else { return }
        central.stopScan()
        connectionText = "Đang tìm bộ điều khiển SE..."
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard self?.lifecycleActive == true else { return }
            self?.startScanning()
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    private func parseEvent(_ event: String) {
        let message = event.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = message.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let head = fields.first?.uppercased() else { return }

        if head == "STATE", fields.count >= 3 {
            switch fields[1].uppercased() {
            case "IDLE", "HOME_DONE": trackingState = .idle
            case "ACQUIRE": trackingState = .acquire
            case "LOCK": trackingState = .lock
            case "SEARCH": trackingState = .search
            case "HOME": trackingState = .home
            default: break
            }
            confidence = Int(fields[2]) ?? 0
            if fields.count >= 5 {
                targetX = min(1, max(0, (Double(fields[3]) ?? 500) / 1000))
                targetY = min(1, max(0, (Double(fields[4]) ?? 500) / 1000))
            }
            if fields.count >= 7 {
                panAngle = Double(fields[5]) ?? panAngle
                tiltAngle = Double(fields[6]) ?? tiltAngle
            }
        } else if head == "MAIX" {
            maixVersion = fields.dropFirst().joined(separator: " • ")
        } else if head == "MODE", fields.count >= 2,
                  let mode = TrackingMode(rawValue: fields[1].uppercased()) {
            selectedMode = mode
        } else if head == "ESP32" {
            connectionText = "ESP32 SE đã sẵn sàng"
        }
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanning()
        case .poweredOff:
            connectionText = "Bluetooth đang tắt"
        case .unauthorized:
            connectionText = "Hãy cấp quyền Bluetooth cho SE"
        case .unsupported:
            connectionText = "iPhone không hỗ trợ Bluetooth LE"
        default:
            connectionText = "Bluetooth chưa sẵn sàng"
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        central.stopScan()
        trackerPeripheral = peripheral
        peripheral.delegate = self
        connectionText = "Đã thấy ESP32, đang kết nối..."
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        trackingState = .idle
        connectionText = "Đã kết nối ESP32 SE"
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnected = false
        trackingState = .disconnected
        connectionText = "Kết nối lỗi, đang thử lại..."
        trackerPeripheral = nil
        scheduleReconnect()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnected = false
        trackingState = .disconnected
        commandCharacteristic = nil
        trackerPeripheral = nil
        confidence = 0
        connectionText = "ESP32 đã ngắt, đang kết nối lại..."
        scheduleReconnect()
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            connectionText = "Không đọc được dịch vụ ESP32"
            return
        }
        peripheral.services?
            .filter { $0.uuid == serviceUUID }
            .forEach { peripheral.discoverCharacteristics([eventUUID, commandUUID], for: $0) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else {
            connectionText = "Không đọc được kênh điều khiển"
            return
        }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == eventUUID {
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            } else if characteristic.uuid == commandUUID {
                commandCharacteristic = characteristic
                send("PING")
                send("MODE,\(selectedMode.rawValue)")
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil,
              characteristic.uuid == eventUUID,
              let data = characteristic.value,
              let message = String(data: data, encoding: .utf8) else { return }
        parseEvent(message)
    }
}
