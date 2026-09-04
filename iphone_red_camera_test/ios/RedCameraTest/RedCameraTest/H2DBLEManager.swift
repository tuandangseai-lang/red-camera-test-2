import CoreBluetooth
import Combine
import Foundation

struct H2DTimelapseEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case snapshot
        case finished
        case error
    }

    let id = UUID()
    let kind: Kind
    let layer: Int
    let totalLayers: Int
    let jobID: String
    let message: String
}

final class H2DBLEManager: NSObject, ObservableObject {
    @Published private(set) var connectionText = "Đang bật Bluetooth..."
    @Published private(set) var isConnected = false
    @Published private(set) var isH2DBridge = false
    @Published private(set) var h2dBridgeStatus = "Chưa nhận dữ liệu H2D"
    @Published private(set) var h2dPrintState = "IDLE"
    @Published private(set) var h2dCurrentLayer = 0
    @Published private(set) var h2dTotalLayers = 0
    @Published private(set) var h2dPrintPercent = 0
    @Published private(set) var h2dTimelapseEvent: H2DTimelapseEvent?

    private let serviceUUID = CBUUID(string: "7E57A000-8E3A-4D6A-9B2B-13B10A000001")
    private let eventUUID = CBUUID(string: "7E57A001-8E3A-4D6A-9B2B-13B10A000001")
    private let commandUUID = CBUUID(string: "7E57A002-8E3A-4D6A-9B2B-13B10A000001")

    private var central: CBCentralManager!
    private var bridgePeripheral: CBPeripheral?
    private var eventCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var reconnectWorkItem: DispatchWorkItem?
    private var lifecycleActive = true

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func configureH2DBridge(
        wifiSSID: String,
        wifiPassword: String,
        printerIP: String,
        printerSerial: String,
        accessCode: String
    ) {
        let values = [wifiSSID, wifiPassword, printerIP, printerSerial, accessCode]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard values.allSatisfy({ !$0.isEmpty }) else {
            h2dBridgeStatus = "Hãy nhập đủ Wi-Fi, IP, serial và mã truy cập"
            return
        }

        h2dBridgeStatus = "Đang gửi cấu hình bảo mật sang ESP32..."
        let commands = [
            "H2D_WIFI_SSID,\(base64(values[0]))",
            "H2D_WIFI_PASS,\(base64(values[1]))",
            "H2D_IP,\(values[2])",
            "H2D_SERIAL,\(values[3])",
            "H2D_CODE,\(base64(values[4]))",
            "H2D_SAVE"
        ]
        for (index, command) in commands.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.18) { [weak self] in
                self?.send(command)
            }
        }
    }

    func setH2DTimelapseArmed(_ armed: Bool) {
        send(armed ? "H2D_ARM,1" : "H2D_ARM,0")
        h2dBridgeStatus = armed
            ? "Đã bật chụp theo lớp • đang chờ H2D"
            : "Đã dừng chụp theo lớp"
    }

    func requestH2DStatus() {
        send("H2D_STATUS")
    }

    func acknowledgeH2DFrame(layer: Int, success: Bool) {
        send("H2D_ACK,\(max(0, layer)),\(success ? 1 : 0)")
    }

    func suspendForBackground() {
        lifecycleActive = false
        reconnectWorkItem?.cancel()
        central.stopScan()
    }

    func resumeFromForeground() {
        lifecycleActive = true
        if bridgePeripheral?.state != .connected { startScanning() }
    }

    private func base64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private func send(_ command: String) {
        guard let peripheral = bridgePeripheral,
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
        connectionText = "Đang tìm ESP32 H2D..."
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

    private func activateTransportIfReady(_ peripheral: CBPeripheral) {
        guard peripheral.state == .connected,
              commandCharacteristic != nil,
              eventCharacteristic?.isNotifying == true else { return }
        let firstActivation = !isConnected
        isConnected = true
        connectionText = "Đã kết nối ESP32 • đang kiểm tra H2D"
        if firstActivation { send("H2D_STATUS") }
    }

    private func parseEvent(_ event: String) {
        let fields = event.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count >= 2, fields[0].uppercased() == "H2D" else { return }
        isH2DBridge = true
        connectionText = "Đã kết nối ESP32 • cầu nối H2D"

        switch fields[1].uppercased() {
        case "STATUS":
            guard fields.count >= 3 else { return }
            let status = fields[2].uppercased()
            let known: [String: String] = [
                "BOOTING": "ESP32 H2D đang khởi động",
                "CONFIG_REQUIRED": "Chưa có cấu hình H2D",
                "CONFIG_SAVED": "Đã lưu cấu hình • đang kết nối lại",
                "WIFI_CONNECTING": "ESP32 đang kết nối Wi-Fi",
                "WIFI_OK": "Wi-Fi đã kết nối • đang tìm H2D",
                "MQTT_CONNECTING": "Đang đăng nhập H2D trong mạng LAN",
                "READY": "H2D đã sẵn sàng gửi dữ liệu lớp",
                "ARMED": "Đã bật chụp theo lớp • đang chờ máy in",
                "DISARMED": "Đã dừng chụp theo lớp"
            ]
            h2dBridgeStatus = known[status] ?? fields.dropFirst(2).joined(separator: " • ")
        case "PRINT":
            guard fields.count >= 6 else { return }
            h2dPrintState = fields[2].uppercased()
            h2dCurrentLayer = max(0, Int(fields[3]) ?? h2dCurrentLayer)
            h2dTotalLayers = max(0, Int(fields[4]) ?? h2dTotalLayers)
            h2dPrintPercent = min(100, max(0, Int(fields[5]) ?? h2dPrintPercent))
            h2dBridgeStatus = h2dPrintState == "RUNNING"
                ? "H2D đang in lớp \(h2dCurrentLayer)/\(max(1, h2dTotalLayers))"
                : "Trạng thái H2D: \(h2dPrintState)"
        case "SNAP":
            guard fields.count >= 5 else { return }
            let layer = max(1, Int(fields[2]) ?? 1)
            let total = max(layer, Int(fields[3]) ?? layer)
            h2dCurrentLayer = layer
            h2dTotalLayers = total
            h2dTimelapseEvent = H2DTimelapseEvent(
                kind: .snapshot,
                layer: layer,
                totalLayers: total,
                jobID: fields[4],
                message: "Chụp lớp \(layer)"
            )
        case "DONE":
            guard fields.count >= 5 else { return }
            let layer = max(0, Int(fields[2]) ?? h2dCurrentLayer)
            let total = max(layer, Int(fields[3]) ?? h2dTotalLayers)
            h2dPrintState = "FINISH"
            h2dCurrentLayer = layer
            h2dTotalLayers = total
            h2dTimelapseEvent = H2DTimelapseEvent(
                kind: .finished,
                layer: layer,
                totalLayers: total,
                jobID: fields[4],
                message: "H2D đã in xong"
            )
        case "ERROR":
            let detail = fields.dropFirst(2).joined(separator: " • ")
            h2dBridgeStatus = detail.isEmpty ? "Cầu nối H2D gặp lỗi" : detail
            h2dTimelapseEvent = H2DTimelapseEvent(
                kind: .error,
                layer: h2dCurrentLayer,
                totalLayers: h2dTotalLayers,
                jobID: "",
                message: h2dBridgeStatus
            )
        default:
            break
        }
    }
}

extension H2DBLEManager: CBCentralManagerDelegate {
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
        bridgePeripheral = peripheral
        peripheral.delegate = self
        connectionText = "Đã thấy ESP32, đang kết nối..."
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = false
        isH2DBridge = false
        connectionText = "Đã nối BLE • đang mở kênh H2D..."
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnected = false
        isH2DBridge = false
        connectionText = "Kết nối lỗi, đang thử lại..."
        bridgePeripheral = nil
        scheduleReconnect()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnected = false
        isH2DBridge = false
        eventCharacteristic = nil
        commandCharacteristic = nil
        bridgePeripheral = nil
        connectionText = "ESP32 đã ngắt, đang kết nối lại..."
        h2dBridgeStatus = "ESP32 đã ngắt • đang kết nối lại"
        scheduleReconnect()
    }
}

extension H2DBLEManager: CBPeripheralDelegate {
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
            connectionText = "Không đọc được kênh điều khiển H2D"
            return
        }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == eventUUID {
                eventCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            } else if characteristic.uuid == commandUUID {
                commandCharacteristic = characteristic
            }
        }
        activateTransportIfReady(peripheral)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, characteristic.uuid == eventUUID else {
            connectionText = "Không mở được kênh dữ liệu ESP32"
            return
        }
        activateTransportIfReady(peripheral)
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
