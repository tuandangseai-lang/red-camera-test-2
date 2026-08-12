import CoreBluetooth
import Foundation

final class BLEManager: NSObject, ObservableObject {
    @Published private(set) var connectionText = "Đang bật Bluetooth..."
    @Published private(set) var isConnected = false

    var onArm: (() -> Void)?

    private let serviceUUID = CBUUID(string: "7E57A000-8E3A-4D6A-9B2B-13B10A000001")
    private let eventUUID = CBUUID(string: "7E57A001-8E3A-4D6A-9B2B-13B10A000001")
    private let statusUUID = CBUUID(string: "7E57A002-8E3A-4D6A-9B2B-13B10A000001")

    private var central: CBCentralManager!
    private var trackerPeripheral: CBPeripheral?
    private var statusCharacteristic: CBCharacteristic?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func sendStatus(_ message: String) {
        guard let peripheral = trackerPeripheral,
              peripheral.state == .connected,
              let characteristic = statusCharacteristic,
              let data = message.data(using: .utf8) else { return }

        // Tọa độ tracking gửi dày nên dùng writeWithoutResponse. Các lệnh đổi
        // trạng thái servo phải có phản hồi để SEARCH không bị rơi gói BLE.
        // V là gói tracking gọn 15 byte: Vxxxyyyccvvvwww. Gói này có thêm
        // vận tốc hai trục nhưng vẫn nằm dưới payload BLE mặc định 20 byte.
        let isVelocityTelemetry = message.hasPrefix("V") && message.utf8.count == 15
        let isTelemetry = message.hasPrefix("T,") || isVelocityTelemetry
        let canWriteFast = characteristic.properties.contains(.writeWithoutResponse)
        let canWriteConfirmed = characteristic.properties.contains(.write)
        let writeType: CBCharacteristicWriteType
        if isTelemetry, canWriteFast {
            writeType = .withoutResponse
        } else if canWriteConfirmed {
            writeType = .withResponse
        } else {
            writeType = .withoutResponse
        }
        peripheral.writeValue(data, for: characteristic, type: writeType)
        if message.hasPrefix("S,") {
            connectionText = "Đang tìm"
        } else if message == "TARGET_LOCKED" {
            connectionText = "ESP32 đang bám mục tiêu"
        } else if message == "SEARCH_STOP" || message == "RECORDING_STOPPED" {
            connectionText = "ESP32 đã dừng tìm và giữ nguyên góc"
        } else if message == "TRACKING_STARTED" {
            connectionText = "ESP32 sẵn sàng nhận dữ liệu bám"
        }
    }

    private func startScanning() {
        guard central.state == .poweredOn else { return }
        connectionText = "Đang tìm RocketTracker-Test..."
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
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
            connectionText = "Chưa cấp quyền Bluetooth"
        case .unsupported:
            connectionText = "Máy không hỗ trợ Bluetooth LE"
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
        connectionText = "Đã kết nối ESP32"
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnected = false
        connectionText = "Kết nối lỗi, đang thử lại..."
        trackerPeripheral = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.startScanning()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnected = false
        statusCharacteristic = nil
        trackerPeripheral = nil
        connectionText = "ESP32 đã ngắt, đang tìm lại..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.startScanning()
        }
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            connectionText = "Không đọc được dịch vụ BLE"
            return
        }

        peripheral.services?
            .filter { $0.uuid == serviceUUID }
            .forEach { peripheral.discoverCharacteristics([eventUUID, statusUUID], for: $0) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else {
            connectionText = "Không đọc được kênh BLE"
            return
        }

        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == eventUUID {
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            } else if characteristic.uuid == statusUUID {
                statusCharacteristic = characteristic
                sendStatus("APP_READY")
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

        if message.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "ARM" {
            connectionText = "ESP32 đã ra lệnh khóa và bám tên lửa"
            onArm?()
        }
    }
}
