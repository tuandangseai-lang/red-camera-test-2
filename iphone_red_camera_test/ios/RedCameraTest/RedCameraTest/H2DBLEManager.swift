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
    @Published private(set) var isH2DReady = false
    @Published private(set) var h2dBridgeStatus = "Chưa nhận dữ liệu H2D"
    @Published private(set) var h2dPrintState = "IDLE"
    @Published private(set) var h2dCurrentLayer = 0
    @Published private(set) var h2dTotalLayers = 0
    @Published private(set) var h2dPrintPercent = 0
    @Published private(set) var h2dStageCode = -1
    @Published private(set) var h2dTimelapseEvent: H2DTimelapseEvent?
    @Published private(set) var isConfiguring = false
    @Published private(set) var configurationProgress = 0
    @Published private(set) var hasBridgeError = false
    @Published private(set) var hasPrinterAlert = false
    @Published private(set) var hasCriticalPrinterAlert = false
    @Published private(set) var printerAlertText = ""
    @Published private(set) var h2dStatusCode = "BOOTING"
    @Published private(set) var printerModelCode = "Bambu"
    @Published private(set) var printerSerial = ""
    @Published private(set) var filamentType = ""
    @Published private(set) var filamentColorHex = ""
    @Published private(set) var filamentSlot = -1

    var printerKind: BambuPrinterKind {
        let reported = BambuPrinterKind(rawValue: printerModelCode)
        return reported ?? BambuPrinterKind.detect(serial: printerSerial)
    }

    var printerDisplayName: String {
        let kind = printerKind
        return kind == .unknown ? "Bambu" : kind.rawValue
    }

    var materialDescription: String {
        guard !filamentType.isEmpty else { return "Chưa nhận dữ liệu nhựa" }
        let slot = filamentSlot == 254
            ? "cuộn ngoài"
            : filamentSlot >= 0 ? "khay \(filamentSlot + 1)" : ""
        return slot.isEmpty ? filamentType : "\(filamentType) • \(slot)"
    }

    var isActuallyPrinting: Bool {
        guard h2dPrintState.uppercased() == "RUNNING" else { return false }
        // Older firmware did not send stg_cur. Keep its old behavior when the
        // stage is unknown, while v1.6+ can distinguish preparation precisely.
        return h2dStageCode == -1 || h2dStageCode == 0
    }

    var isPrintSessionActive: Bool {
        switch h2dPrintState.uppercased() {
        case "RUNNING", "PREPARE", "PREPARING", "SLICING", "INIT", "HEATING",
             "PAUSE", "PAUSED":
            return true
        default:
            return false
        }
    }

    var hasActivePrinterAlert: Bool {
        hasPrinterAlert && isPrintSessionActive
    }

    var hasActiveCriticalPrinterAlert: Bool {
        guard hasCriticalPrinterAlert else { return false }
        let failedState = ["FAILED", "ERROR"].contains(h2dPrintState.uppercased())
        return isPrintSessionActive || failedState
    }

    var h2dStageText: String {
        switch h2dStageCode {
        case 0: return "Đang in lớp"
        case 1, 40, 47, 48: return "Đang cân bàn"
        case 2: return "Đang làm nóng bàn in"
        case 3: return "Đang kiểm tra chuyển động"
        case 4, 22, 24, 52, 77: return "Đang chuẩn bị vật liệu"
        case 7, 41, 62, 64: return "Đang chuẩn bị đầu phun"
        case 8, 19, 51: return "Đang hiệu chỉnh dòng nhựa"
        case 9, 10, 11, 73, 74, 75: return "Đang kiểm tra bàn in"
        case 12, 18, 43, 57: return "Đang hiệu chỉnh cảm biến"
        case 13: return "Đang đưa đầu in về gốc"
        case 14, 65, 69: return "Đang làm sạch đầu phun"
        case 15, 49, 50, 54, 63: return "Đang ổn định nhiệt độ"
        case 25, 31: return "Đang hiệu chỉnh động cơ"
        case 29, 66: return "Đang điều hòa buồng in"
        case 36, 37, 38, 39, 42, 44, 45, 46, 53, 56, 60, 61, 67, 71, 72:
            return "Đang hiệu chỉnh máy in"
        case 55, 58, 59, 68, 70, 76: return "Đang chuẩn bị in"
        default:
            switch h2dPrintState.uppercased() {
            case "RUNNING": return "Đang chuẩn bị in"
            case "PAUSE", "PAUSED": return "Đang tạm dừng"
            default: return "Đang chuẩn bị"
            }
        }
    }

    private let serviceUUID = CBUUID(string: "7E57A000-8E3A-4D6A-9B2B-13B10A000001")
    private let eventUUID = CBUUID(string: "7E57A001-8E3A-4D6A-9B2B-13B10A000001")
    private let commandUUID = CBUUID(string: "7E57A002-8E3A-4D6A-9B2B-13B10A000001")

    private var central: CBCentralManager!
    private var bridgePeripheral: CBPeripheral?
    private var eventCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var reconnectWorkItem: DispatchWorkItem?
    private var recognitionWorkItem: DispatchWorkItem?
    private var statusRefreshWorkItems: [DispatchWorkItem] = []
    private var configurationTimeoutWorkItem: DispatchWorkItem?
    private var mqttLossWorkItem: DispatchWorkItem?
    private var lifecycleActive = true

    private struct ConfigurationCommand {
        let payload: String
        let acknowledgement: String
        let label: String
    }

    private var configurationCommands: [ConfigurationCommand] = []
    private var configurationIndex = 0
    private var configurationRetryCount = 0

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
        guard isConnected, isH2DBridge else {
            h2dBridgeStatus = "ESP32 chưa chạy firmware Bambu v1.7.4 trở lên"
            requestH2DStatus()
            return
        }

        let normalizedAccessCode = normalizeAccessCode(accessCode)
        let values = [
            wifiSSID.trimmingCharacters(in: .whitespacesAndNewlines),
            wifiPassword,
            printerIP.trimmingCharacters(in: .whitespacesAndNewlines),
            printerSerial.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedAccessCode
        ]
        guard values.allSatisfy({ !$0.isEmpty }) else {
            h2dBridgeStatus = "Hãy nhập đủ Wi-Fi, IP, serial và Access Code LAN"
            return
        }
        guard values[4].count >= 6 else {
            h2dBridgeStatus = "Access Code LAN phải có ít nhất 6 ký tự"
            return
        }

        configurationTimeoutWorkItem?.cancel()
        configurationCommands = [
            ConfigurationCommand(payload: "H2D_WIFI_SSID,\(base64(values[0]))", acknowledgement: "SSID", label: "tên Wi-Fi"),
            ConfigurationCommand(payload: "H2D_WIFI_PASS,\(base64(values[1]))", acknowledgement: "PASS", label: "mật khẩu Wi-Fi"),
            ConfigurationCommand(payload: "H2D_IP,\(values[2])", acknowledgement: "IP", label: "địa chỉ máy in"),
            ConfigurationCommand(payload: "H2D_SERIAL,\(values[3])", acknowledgement: "SERIAL", label: "serial máy in"),
            ConfigurationCommand(payload: "H2D_CODE,\(base64(values[4]))", acknowledgement: "CODE", label: "Access Code"),
            ConfigurationCommand(payload: "H2D_SAVE", acknowledgement: "SAVE", label: "lưu cấu hình")
        ]
        configurationIndex = 0
        configurationRetryCount = 0
        configurationProgress = 0
        isConfiguring = true
        sendNextConfigurationCommand()
    }

    func setH2DTimelapseArmed(_ armed: Bool) {
        send(armed ? "H2D_ARM,1" : "H2D_ARM,0")
        h2dBridgeStatus = armed
            ? "Đã bật chụp theo lớp • đang chờ \(printerDisplayName)"
            : "Đã dừng chụp theo lớp"
    }

    func requestH2DStatus() {
        guard send("H2D_STATUS") else { return }
        // When the app opens during an active print, the first BLE status can
        // arrive before ESP32 has completed its MQTT reconnect. Ask again at
        // short intervals so the current RUNNING/layer/% state is recovered
        // without requiring the user to reopen the screen.
        cancelStatusRefreshes()
        for delay in [1.2, 3.0, 6.0] {
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.lifecycleActive, self.isConnected else { return }
                _ = self.send("H2D_STATUS")
            }
            statusRefreshWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func cancelStatusRefreshes() {
        statusRefreshWorkItems.forEach { $0.cancel() }
        statusRefreshWorkItems.removeAll()
    }

    func acknowledgeH2DFrame(layer: Int, success: Bool) {
        send("H2D_ACK,\(max(0, layer)),\(success ? 1 : 0)")
    }

    func suspendForBackground() {
        lifecycleActive = false
        reconnectWorkItem?.cancel()
        cancelStatusRefreshes()
        central.stopScan()
    }

    func resumeFromForeground() {
        lifecycleActive = true
        if bridgePeripheral?.state != .connected { startScanning() }
    }

    private func base64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private func normalizeAccessCode(_ value: String) -> String {
        value
            .filter { $0.isNumber || ($0.isASCII && $0.isLetter) }
            .lowercased()
    }

    @discardableResult
    private func send(_ command: String) -> Bool {
        guard let peripheral = bridgePeripheral,
              peripheral.state == .connected,
              let characteristic = commandCharacteristic,
              let data = command.data(using: .utf8) else { return false }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write)
            ? .withResponse
            : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: type)
        return true
    }

    private func sendNextConfigurationCommand() {
        guard isConfiguring, configurationIndex < configurationCommands.count else { return }
        let item = configurationCommands[configurationIndex]
        h2dBridgeStatus = "Đang gửi \(configurationIndex + 1)/\(configurationCommands.count): \(item.label)"
        guard send(item.payload) else {
            failConfiguration("Mất kết nối Bluetooth • hãy thử lưu lại")
            return
        }

        configurationTimeoutWorkItem?.cancel()
        let expectedIndex = configurationIndex
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.isConfiguring,
                  self.configurationIndex == expectedIndex else { return }
            if self.configurationRetryCount < 2 {
                self.configurationRetryCount += 1
                self.h2dBridgeStatus = "ESP32 chưa xác nhận • đang gửi lại lần \(self.configurationRetryCount)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.sendNextConfigurationCommand()
                }
            } else {
                self.failConfiguration("ESP32 không xác nhận dữ liệu • cần firmware H2D v1.7.3 trở lên")
            }
        }
        configurationTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: timeout)
    }

    private func acceptConfigurationAcknowledgement(_ value: String) {
        guard isConfiguring, configurationIndex < configurationCommands.count,
              configurationCommands[configurationIndex].acknowledgement == value.uppercased() else { return }
        configurationTimeoutWorkItem?.cancel()
        configurationIndex += 1
        configurationRetryCount = 0
        configurationProgress = configurationIndex
        if configurationIndex == configurationCommands.count {
            isConfiguring = false
            h2dBridgeStatus = "Đã lưu cấu hình • ESP32 đang kết nối Wi-Fi"
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.sendNextConfigurationCommand()
            }
        }
    }

    private func failConfiguration(_ message: String) {
        configurationTimeoutWorkItem?.cancel()
        configurationCommands.removeAll()
        configurationIndex = 0
        configurationRetryCount = 0
        configurationProgress = 0
        isConfiguring = false
        hasBridgeError = true
        h2dBridgeStatus = message
    }

    private func startScanning() {
        guard lifecycleActive, central.state == .poweredOn else { return }
        central.stopScan()
        connectionText = "Đang tìm ESP32-C3 Bambu..."
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

    private func confirmH2DReady() {
        mqttLossWorkItem?.cancel()
        mqttLossWorkItem = nil
        isH2DReady = true
    }

    private func markH2DUnavailable() {
        mqttLossWorkItem?.cancel()
        mqttLossWorkItem = nil
        isH2DReady = false
        hasPrinterAlert = false
        hasCriticalPrinterAlert = false
        printerAlertText = ""
    }

    private func beginMqttLossGrace() {
        guard isH2DReady else {
            markH2DUnavailable()
            return
        }
        mqttLossWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isH2DReady = false
            if !self.hasActiveCriticalPrinterAlert {
                self.h2dBridgeStatus = "Mất dữ liệu H2D • ESP32 đang tự kết nối lại"
            }
        }
        mqttLossWorkItem = item
        // A short MQTT renegotiation must not make the Island flash green/yellow.
        // A real outage still becomes visible after this grace period.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: item)
    }

    private func activateTransportIfReady(_ peripheral: CBPeripheral) {
        guard peripheral.state == .connected,
              commandCharacteristic != nil,
              eventCharacteristic?.isNotifying == true else { return }
        let firstActivation = !isConnected
        isConnected = true
        connectionText = "Đã kết nối ESP32-C3 • đang kiểm tra máy in"
        if firstActivation {
            recognitionWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.isConnected, !self.isH2DBridge else { return }
                self.hasBridgeError = true
                self.h2dBridgeStatus = "ESP32 đang chạy firmware cũ • hãy nạp bản Bambu C3 khi máy rảnh"
            }
            recognitionWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: item)
        }
        requestH2DStatus()
    }

    private func parseEvent(_ event: String) {
        let fields = event.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count >= 2, fields[0].uppercased() == "H2D" else { return }
        recognitionWorkItem?.cancel()
        isH2DBridge = true
        connectionText = "Đã kết nối ESP32-C3 • cầu nối Bambu"

        switch fields[1].uppercased() {
        case "ESP32":
            hasBridgeError = false
        case "PRINTER":
            guard fields.count >= 4 else { return }
            printerModelCode = fields[2]
            printerSerial = fields[3]
            connectionText = "Đã kết nối ESP32-C3 • \(printerDisplayName)"
        case "MATERIAL":
            guard fields.count >= 5 else { return }
            filamentType = fields[2]
            filamentColorHex = fields[3]
            filamentSlot = Int(fields[4]) ?? -1
        case "CFG_ACK":
            guard fields.count >= 3 else { return }
            hasBridgeError = false
            acceptConfigurationAcknowledgement(fields[2])
        case "STATUS":
            guard fields.count >= 3 else { return }
            let status = fields[2].uppercased()
            h2dStatusCode = status
            let known: [String: String] = [
                "BOOTING": "ESP32-C3 đang khởi động",
                "CONFIG_REQUIRED": "Chưa có cấu hình máy in",
                "CONFIG_SAVED": "Đã lưu cấu hình • đang kết nối lại",
                "WIFI_CONNECTING": "ESP32 đang kết nối Wi-Fi",
                "WIFI_OK": "Wi-Fi đã kết nối • đang tìm máy in",
                "MQTT_CONNECTING": "Đang xác thực \(printerDisplayName) LAN bằng Access Code",
                "MQTT_AUTH_FAILED": "Không xác thực được \(printerDisplayName) • kiểm tra Access Code LAN",
                "MQTT_RETRY": "Mạng đã thấy máy in • đang thử kết nối lại",
                "SYNCING": "Đang đồng bộ trạng thái hiện tại từ \(printerDisplayName)",
                "READY": "\(printerDisplayName) đã sẵn sàng gửi dữ liệu lớp",
                "ARMED": "Đã bật chụp theo lớp • đang chờ máy in",
                "DISARMED": "Đã dừng chụp theo lớp"
            ]
            if status == "CONFIG_SAVED", isConfiguring {
                configurationTimeoutWorkItem?.cancel()
                configurationProgress = configurationCommands.count
                isConfiguring = false
            }
            switch status {
            case "READY", "ARMED", "DISARMED":
                confirmH2DReady()
            case "MQTT_CONNECTING", "MQTT_AUTH_FAILED", "SYNCING":
                beginMqttLossGrace()
            case "BOOTING", "CONFIG_REQUIRED", "CONFIG_SAVED", "WIFI_CONNECTING", "WIFI_OK", "BUFFER_ERROR":
                markH2DUnavailable()
            default:
                break
            }
            hasBridgeError = status == "BUFFER_ERROR" || status == "MQTT_AUTH_FAILED"
            if !hasActiveCriticalPrinterAlert {
                h2dBridgeStatus = status == "BUFFER_ERROR"
                    ? "ESP32 thiếu bộ nhớ nhận gói H2D • hãy khởi động lại"
                    : known[status] ?? fields.dropFirst(2).joined(separator: " • ")
            }
        case "PRINT":
            guard fields.count >= 6 else { return }
            confirmH2DReady()
            h2dPrintState = fields[2].uppercased()
            h2dCurrentLayer = max(0, Int(fields[3]) ?? h2dCurrentLayer)
            h2dTotalLayers = max(0, Int(fields[4]) ?? h2dTotalLayers)
            h2dPrintPercent = min(100, max(0, Int(fields[5]) ?? h2dPrintPercent))
            if fields.count >= 7 {
                h2dStageCode = Int(fields[6]) ?? h2dStageCode
            }
            hasBridgeError = false
            if !isPrintSessionActive {
                hasPrinterAlert = false
                hasCriticalPrinterAlert = false
                printerAlertText = ""
            }
            if !hasActiveCriticalPrinterAlert {
                if isActuallyPrinting {
                    h2dBridgeStatus = "\(printerDisplayName) đang in lớp \(h2dCurrentLayer)/\(max(1, h2dTotalLayers))"
                } else if h2dPrintState == "RUNNING" ||
                            (h2dStageCode > 0 && h2dStageCode != 255) {
                    h2dBridgeStatus = h2dStageText
                } else {
                    h2dBridgeStatus = "Trạng thái \(printerDisplayName): \(h2dPrintState)"
                }
            }
        case "SNAP":
            guard fields.count >= 5 else { return }
            confirmH2DReady()
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
            confirmH2DReady()
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
                message: "\(printerDisplayName) đã in xong"
            )
        case "ALERT":
            guard fields.count >= 3 else { return }
            let active = fields[2] == "1"
            let failedState = ["FAILED", "ERROR"].contains(h2dPrintState.uppercased())
            let shouldSurface = active && (isPrintSessionActive || failedState)
            let suppliedSeverity = fields.count >= 4 ? fields[3].uppercased() : ""
            let hasSeverityField = suppliedSeverity == "ERROR" || suppliedSeverity == "WARN"
            let critical = shouldSurface && suppliedSeverity == "ERROR"
            let detailStart = hasSeverityField ? 4 : 3
            hasPrinterAlert = shouldSurface
            hasCriticalPrinterAlert = critical
            printerAlertText = shouldSurface
                ? (fields.count > detailStart
                    ? fields.dropFirst(detailStart).joined(separator: " • ")
                    : "Máy in đang có cảnh báo")
                : ""
            if critical {
                h2dBridgeStatus = printerAlertText
                h2dTimelapseEvent = H2DTimelapseEvent(
                    kind: .error,
                    layer: h2dCurrentLayer,
                    totalLayers: h2dTotalLayers,
                    jobID: "",
                    message: printerAlertText
                )
            } else {
                // A non-critical HMS advisory remains visible below the main
                // status, but must not replace "cleaning nozzle"/preparation
                // or turn the Island red.
                if shouldSurface {
                    // A valid printer event proves the transport is alive. Clear
                    // any stale bridge/auth error left over from a reconnect.
                    hasBridgeError = false
                }
                if !shouldSurface {
                    hasBridgeError = false
                    h2dBridgeStatus = isH2DReady
                        ? (isPrintSessionActive
                            ? h2dStageText
                            : "\(printerDisplayName) chưa bắt đầu • đang theo dõi")
                        : "Đang kết nối \(printerDisplayName)"
                }
            }
        case "ERROR":
            let detail = fields.dropFirst(2).joined(separator: " • ")
            h2dBridgeStatus = detail.isEmpty ? "Cầu nối H2D gặp lỗi" : detail
            hasBridgeError = true
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
            markH2DUnavailable()
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
        markH2DUnavailable()
        hasBridgeError = true
        connectionText = "Đã nối BLE • đang mở kênh H2D..."
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        recognitionWorkItem?.cancel()
        cancelStatusRefreshes()
        if isConfiguring { failConfiguration("Kết nối ESP32 bị gián đoạn • hãy thử lại") }
        isConnected = false
        isH2DBridge = false
        markH2DUnavailable()
        hasBridgeError = true
        connectionText = "Kết nối lỗi, đang thử lại..."
        bridgePeripheral = nil
        scheduleReconnect()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        recognitionWorkItem?.cancel()
        cancelStatusRefreshes()
        if isConfiguring { failConfiguration("ESP32 đã ngắt • đang kết nối lại") }
        isConnected = false
        isH2DBridge = false
        markH2DUnavailable()
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

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == commandUUID, let error else { return }
        if isConfiguring {
            failConfiguration("Bluetooth không gửi được dữ liệu: \(error.localizedDescription)")
        }
    }
}
