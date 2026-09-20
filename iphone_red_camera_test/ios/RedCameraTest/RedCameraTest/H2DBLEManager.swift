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
    let playsShutterSound: Bool
}

struct BambuFleetStatus: Equatable {
    var isConfigured = false
    var isOnline = false
    var hasActivePrintJob = false
    var hasCriticalError = false
    var printState = "OFFLINE"
    var printPercent = 0
    var printErrorCode: UInt32 = 0
}

final class H2DBLEManager: NSObject, ObservableObject {
    @Published private(set) var connectionText = "Đang bật Bluetooth..."
    @Published private(set) var isConnected = false
    @Published private(set) var isH2DBridge = false
    @Published private(set) var isH2DReady = false
    @Published private(set) var h2dBridgeStatus = "Chưa nhận dữ liệu máy in"
    @Published private(set) var h2dPrintState = "IDLE"
    @Published private(set) var h2dCurrentLayer = 0
    @Published private(set) var h2dTotalLayers = 0
    @Published private(set) var h2dPrintPercent = 0
    @Published private(set) var h2dStageCode = -1
    @Published private(set) var h2dRemainingMinutes = -1
    @Published private(set) var h2dTimelapseEvent: H2DTimelapseEvent?
    @Published private(set) var isConfiguring = false
    @Published private(set) var configurationProgress = 0
    @Published private(set) var configurationTotal = 6
    @Published private(set) var hasBridgeError = false
    @Published private(set) var hasPrinterAlert = false
    @Published private(set) var hasCriticalPrinterAlert = false
    @Published private(set) var printerAlertText = ""
    @Published private(set) var h2dStatusCode = "BOOTING"
    @Published private(set) var printerModelCode = "Bambu"
    @Published private(set) var printerSerial = ""
    @Published private(set) var filamentType = ""
    @Published private(set) var nozzleTemperature = -1
    @Published private(set) var nozzleTargetTemperature = -1
    @Published private(set) var leftNozzleTemperature = -1
    @Published private(set) var leftNozzleTargetTemperature = -1
    @Published private(set) var bedTemperature = -1
    @Published private(set) var bedTargetTemperature = -1
    @Published private(set) var partFanPercent = -1
    @Published private(set) var auxiliaryFanPercent = -1
    @Published private(set) var exhaustFanPercent = -1
    @Published private(set) var isSwitchingPrinter = false
    @Published private(set) var printerSwitchProgress = 0.0
    @Published private(set) var printerSwitchPhaseText = ""
    @Published private(set) var hardwareMode = 0
    @Published private(set) var hardwareHoldActive = false
    @Published private(set) var hardwareBuzzerEnabled = true
    @Published private(set) var hardwareControlRevision = 0
    @Published private(set) var fleetStatuses: [BambuPrinterKind: BambuFleetStatus] = [:]

    private var expectedPrinterSerial = ""
    private var printerSwitchIdentityConfirmed = false

    var printerKind: BambuPrinterKind {
        let reported = BambuPrinterKind(rawValue: printerModelCode)
        return reported ?? BambuPrinterKind.detect(serial: printerSerial)
    }

    var printerDisplayName: String {
        let kind = printerKind
        return kind == .unknown ? "Bambu" : kind.rawValue
    }

    var materialDescription: String {
        filamentType.isEmpty ? "Chưa nhận loại nhựa" : filamentType
    }

    var hasTemperatureTelemetry: Bool {
        nozzleTemperature >= 0 || leftNozzleTemperature >= 0 || bedTemperature >= 0
    }

    var hasFanTelemetry: Bool {
        [partFanPercent, auxiliaryFanPercent, exhaustFanPercent]
            .contains(where: { $0 >= 0 })
    }

    func fleetStatus(for kind: BambuPrinterKind) -> BambuFleetStatus {
        fleetStatuses[kind] ?? BambuFleetStatus(
            isConfigured: BambuPrinterProfileStore.profile(for: kind) != nil
        )
    }

    private func applyCachedFleetStatus(_ status: BambuFleetStatus, for kind: BambuPrinterKind) {
        guard kind.rawValue == printerModelCode else { return }
        guard status.isOnline else { return }
        // Fleet monitoring continues in the background during a profile
        // change, but it is not proof that the primary MQTT session has moved
        // to the selected printer. Applying these provisional packets used to
        // make the iPhone LEDs jump between the old and new machine states.
        guard !isSwitchingPrinter else { return }

        // Once the switch is complete, a fleet packet can refresh the compact
        // selected-printer card while its detailed telemetry is arriving.
        if status.hasActivePrintJob {
            h2dPrintState = status.printState
            h2dPrintPercent = min(100, max(0, status.printPercent))
            h2dBridgeStatus = "\(kind.rawValue) đang in • \(h2dPrintPercent)%"
        }
    }

    func prepareForPrinterProfile(_ kind: BambuPrinterKind, serial: String) {
        printerSwitchGeneration &+= 1
        printerSwitchTimeoutWorkItem?.cancel()
        printerSwitchTimeoutWorkItem = nil
        expectedPrinterSerial = normalizeSerial(serial)
        isSwitchingPrinter = !expectedPrinterSerial.isEmpty
        printerSwitchIdentityConfirmed = false
        printerSwitchProgress = isSwitchingPrinter ? 0.08 : 0
        printerSwitchPhaseText = isSwitchingPrinter
            ? "Đang chuẩn bị hồ sơ \(kind.rawValue)"
            : ""
        printerModelCode = kind.rawValue
        printerSerial = serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        filamentType = ""
        nozzleTemperature = -1
        nozzleTargetTemperature = -1
        leftNozzleTemperature = -1
        leftNozzleTargetTemperature = -1
        bedTemperature = -1
        bedTargetTemperature = -1
        partFanPercent = -1
        auxiliaryFanPercent = -1
        exhaustFanPercent = -1
        h2dPrintState = "IDLE"
        h2dCurrentLayer = 0
        h2dTotalLayers = 0
        h2dPrintPercent = 0
        h2dStageCode = -1
        h2dRemainingMinutes = -1
        isH2DReady = false
        hasPrinterAlert = false
        hasCriticalPrinterAlert = false
        printerAlertText = ""
        h2dStatusCode = isSwitchingPrinter ? "SWITCHING" : "BOOTING"
        h2dBridgeStatus = isSwitchingPrinter
            ? printerSwitchPhaseText
            : "Đã chọn \(kind.rawValue) • chờ gửi cấu hình"
    }

    private func normalizeSerial(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    var isActuallyPrinting: Bool {
        guard h2dPrintState.uppercased() == "RUNNING" else { return false }
        // Older firmware did not send stg_cur. Keep its old behavior when the
        // stage is unknown, while v1.6+ can distinguish preparation precisely.
        return h2dStageCode == -1 || h2dStageCode == 0
    }

    var isStoppingPrint: Bool {
        switch h2dPrintState.uppercased() {
        case "STOP", "STOPPED", "CANCEL", "CANCELED", "CANCELLED", "FAILED":
            return !hasActiveCriticalPrinterAlert
        default:
            return false
        }
    }

    var isPausedPrint: Bool {
        ["PAUSE", "PAUSED"].contains(h2dPrintState.uppercased())
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

    private var selectedCriticalAlertIsActive: Bool {
        guard hasCriticalPrinterAlert else { return false }
        let failedState = ["FAILED", "ERROR"].contains(h2dPrintState.uppercased())
        return isPrintSessionActive || failedState
    }

    var activeCriticalPrinterKind: BambuPrinterKind? {
        let selected = printerKind
        if selected != .unknown &&
            (selectedCriticalAlertIsActive || fleetStatus(for: selected).hasCriticalError) {
            return selected
        }
        return [BambuPrinterKind.a1, .h2d, .p2s].first {
            fleetStatus(for: $0).hasCriticalError
        }
    }

    var hasActiveCriticalPrinterAlert: Bool {
        activeCriticalPrinterKind != nil
    }

    var shouldPlayPhonePrinterAlarm: Bool {
        guard let criticalKind = activeCriticalPrinterKind else { return false }
        // ESP32 owns the buzzer for a non-selected printer. The iPhone keeps
        // showing that printer in red, but only plays its siren for the profile
        // currently selected for timelapse.
        return criticalKind == printerKind
    }

    var activeCriticalPrinterDisplayName: String {
        activeCriticalPrinterKind?.rawValue ?? printerDisplayName
    }

    var activeCriticalPrinterAlertText: String {
        guard let kind = activeCriticalPrinterKind else { return printerAlertText }
        if kind == printerKind && !printerAlertText.isEmpty {
            return printerAlertText
        }
        let code = fleetStatus(for: kind).printErrorCode
        if code > 0 {
            return String(format: "%@ báo lỗi máy in • mã 0x%08X • xem màn hình máy in", kind.rawValue, code)
        }
        return "\(kind.rawValue) đang có lỗi • xem màn hình máy in"
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
    private var fleetSyncWorkItems: [DispatchWorkItem] = []
    private var configurationTimeoutWorkItem: DispatchWorkItem?
    private var mqttLossWorkItem: DispatchWorkItem?
    private var armSyncWorkItems: [DispatchWorkItem] = []
    private var lifecycleActive = true
    // The capture screen can be armed while CoreBluetooth is still restoring
    // the ESP32 connection. Remember the user's intent and replay it as soon as
    // the writable characteristic becomes available; otherwise the iPhone UI
    // looks armed while the bridge silently suppresses every SNAP event.
    private var desiredTimelapseArmed = false

    private struct ConfigurationCommand {
        let payload: String
        let acknowledgement: String
        let label: String
    }

    private var configurationCommands: [ConfigurationCommand] = []
    private var configurationIndex = 0
    private var configurationRetryCount = 0
    // Monotonic tokens invalidate delayed work from an earlier configuration
    // or fleet-sync pass. DispatchWorkItem.cancel() alone is not sufficient:
    // a block that is already queued may still execute on the main queue.
    private var configurationGeneration: UInt64 = 0
    private var fleetSyncGeneration: UInt64 = 0
    private var printerSwitchTimeoutWorkItem: DispatchWorkItem?
    private var printerSwitchGeneration: UInt64 = 0

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
            h2dBridgeStatus = "ESP32 chưa chạy firmware Bambu v1.8.3 trở lên"
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

        let requestedKind = BambuPrinterKind.detect(serial: values[3])
        guard requestedKind != .unknown else {
            h2dBridgeStatus = "Serial chưa khớp hồ sơ A1, H2D hoặc P2S"
            return
        }
        prepareForPrinterProfile(
            requestedKind,
            serial: values[3]
        )

        fleetSyncGeneration &+= 1
        fleetSyncWorkItems.forEach { $0.cancel() }
        fleetSyncWorkItems.removeAll()
        cancelStatusRefreshes()
        configurationTimeoutWorkItem?.cancel()
        configurationGeneration &+= 1
        var commands = [
            ConfigurationCommand(payload: "H2D_WIFI_SSID,\(base64(values[0]))", acknowledgement: "SSID", label: "tên Wi-Fi"),
            ConfigurationCommand(payload: "H2D_WIFI_PASS,\(base64(values[1]))", acknowledgement: "PASS", label: "mật khẩu Wi-Fi"),
            ConfigurationCommand(payload: "H2D_IP,\(values[2])", acknowledgement: "IP", label: "địa chỉ máy in"),
            ConfigurationCommand(payload: "H2D_SERIAL,\(values[3])", acknowledgement: "SERIAL", label: "serial máy in"),
            ConfigurationCommand(payload: "H2D_CODE,\(base64(values[4]))", acknowledgement: "CODE", label: "Access Code"),
            ConfigurationCommand(payload: "H2D_SAVE", acknowledgement: "SAVE", label: "lưu cấu hình")
        ]
        let storedProfiles = BambuPrinterProfileStore.load()
        for kind in [BambuPrinterKind.a1, .h2d, .p2s] {
            guard let profile = storedProfiles.first(where: { $0.kind == kind }) else { continue }
            let storedCode = normalizeAccessCode(H2DAccessCodeStore.load(for: kind))
            guard !profile.ip.isEmpty, !profile.serial.isEmpty, !storedCode.isEmpty else { continue }
            commands.append(
                ConfigurationCommand(
                    payload: "H2D_PROFILE,\(kind.rawValue),\(base64(profile.ip)),\(base64(profile.serial)),\(base64(storedCode))",
                    acknowledgement: "PROFILE_\(kind.rawValue)",
                    label: "hồ sơ \(kind.rawValue)"
                )
            )
        }
        commands.append(
            ConfigurationCommand(
                payload: "H2D_SELECT,\(requestedKind.rawValue)",
                acknowledgement: "SELECT",
                label: "máy chụp timelapse"
            )
        )
        configurationCommands = commands
        configurationIndex = 0
        configurationRetryCount = 0
        configurationProgress = 0
        configurationTotal = configurationCommands.count
        isConfiguring = true
        sendNextConfigurationCommand()
    }

    /// Switch to a profile that has already been entered on the iPhone.  A
    /// profile change does not need to resend Wi-Fi credentials or rewrite the
    /// whole fleet; sending the selected profile followed by SELECT lets the
    /// ESP32 move its primary MQTT connection immediately.
    func selectStoredPrinterProfile(
        _ kind: BambuPrinterKind,
        printerIP: String,
        printerSerial: String,
        accessCode: String
    ) {
        guard isConnected, isH2DBridge else {
            h2dBridgeStatus = "ESP32 chưa sẵn sàng để đổi máy in"
            requestH2DStatus()
            return
        }
        let ip = printerIP.trimmingCharacters(in: .whitespacesAndNewlines)
        let serial = printerSerial.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = normalizeAccessCode(accessCode)
        guard kind != .unknown, !ip.isEmpty, !serial.isEmpty, !code.isEmpty else {
            h2dBridgeStatus = "Hồ sơ máy in chưa đủ thông tin"
            return
        }

        prepareForPrinterProfile(kind, serial: serial)
        // A profile switch supersedes any delayed all-fleet sync and any
        // timeout from the previous transaction. Without this guard, an old
        // H2D_PROFILE/H2D_SELECT can arrive between the two new commands and
        // make the bridge reconnect to the wrong printer.
        fleetSyncGeneration &+= 1
        fleetSyncWorkItems.forEach { $0.cancel() }
        fleetSyncWorkItems.removeAll()
        cancelStatusRefreshes()
        configurationTimeoutWorkItem?.cancel()
        configurationGeneration &+= 1
        configurationCommands = [
            ConfigurationCommand(
                payload: "H2D_PROFILE,\(kind.rawValue),\(base64(ip)),\(base64(serial)),\(base64(code))",
                acknowledgement: "PROFILE_\(kind.rawValue)",
                label: "hồ sơ \(kind.rawValue)"
            ),
            ConfigurationCommand(
                payload: "H2D_SELECT,\(kind.rawValue)",
                acknowledgement: "SELECT",
                label: "chuyển máy chụp timelapse"
            )
        ]
        configurationIndex = 0
        configurationRetryCount = 0
        configurationProgress = 0
        configurationTotal = configurationCommands.count
        isConfiguring = true
        updatePrinterSwitchProgress(
            0.14,
            message: "Đang gửi hồ sơ \(kind.rawValue) tới ESP32"
        )
        printerSwitchGeneration &+= 1
        let switchGeneration = printerSwitchGeneration
        printerSwitchTimeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isSwitchingPrinter,
                  self.printerSwitchGeneration == switchGeneration else { return }
            self.finishPrinterSwitchAsUnavailable()
        }
        printerSwitchTimeoutWorkItem = timeout
        // A healthy LAN switch normally completes in 1–4 seconds.  Leave room
        // for a sleeping/offline target, but never leave the UI stuck in
        // SWITCHING forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 18.0, execute: timeout)
        sendNextConfigurationCommand()
    }

    func setH2DTimelapseArmed(_ armed: Bool) {
        armSyncWorkItems.forEach { $0.cancel() }
        armSyncWorkItems.removeAll()
        desiredTimelapseArmed = armed
        let sent = send(armed ? "H2D_ARM,1" : "H2D_ARM,0")
        if armed {
            h2dBridgeStatus = sent
                ? "Đã bật chụp theo lớp • đang chờ \(printerDisplayName)"
                : "Đã bật chụp • chờ ESP32 nối lại để đồng bộ"
            // BLE write-without-response can be lost while the capture screen
            // and camera session start together. Repeat an idempotent ARM
            // handshake so the UI can never look armed while ESP32 suppresses
            // every SNAP event.
            for delay in [0.45, 1.35] {
                let item = DispatchWorkItem { [weak self] in
                    guard let self, self.desiredTimelapseArmed,
                          self.isConnected else { return }
                    _ = self.send("H2D_ARM,1")
                }
                armSyncWorkItems.append(item)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            }
        } else {
            h2dBridgeStatus = "Đã dừng chụp theo lớp"
        }
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

    /// Keeps the ESP32's three-printer watch list in sync without changing the
    /// full telemetry/timelapse connection that belongs to the selected tab.
    func syncFleetProfiles(selectedKind: BambuPrinterKind) {
        guard isConnected, isH2DBridge, !isConfiguring else { return }
        fleetSyncGeneration &+= 1
        let generation = fleetSyncGeneration
        fleetSyncWorkItems.forEach { $0.cancel() }
        fleetSyncWorkItems.removeAll()

        let storedProfiles = BambuPrinterProfileStore.load()
        var payloads: [String] = []
        for kind in [BambuPrinterKind.a1, .h2d, .p2s] {
            if let profile = storedProfiles.first(where: { $0.kind == kind }) {
                let code = normalizeAccessCode(H2DAccessCodeStore.load(for: kind))
                if !profile.ip.isEmpty, !profile.serial.isEmpty, !code.isEmpty {
                    payloads.append(
                        "H2D_PROFILE,\(kind.rawValue),\(base64(profile.ip)),\(base64(profile.serial)),\(base64(code))"
                    )
                    continue
                }
            }
            payloads.append("H2D_PROFILE_CLEAR,\(kind.rawValue)")
        }
        if selectedKind != .unknown {
            payloads.append("H2D_SELECT,\(selectedKind.rawValue)")
        }

        for (index, payload) in payloads.enumerated() {
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.isConnected, !self.isConfiguring,
                      self.lifecycleActive,
                      self.fleetSyncGeneration == generation else { return }
                _ = self.send(payload)
            }
            fleetSyncWorkItems.append(item)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.12 * Double(index),
                execute: item
            )
        }
    }

    private func cancelStatusRefreshes() {
        statusRefreshWorkItems.forEach { $0.cancel() }
        statusRefreshWorkItems.removeAll()
    }

    func acknowledgeH2DFrame(layer: Int, success: Bool) {
        send("H2D_ACK,\(max(0, layer)),\(success ? 1 : 0)")
    }

    func requestFleetRefresh() {
        _ = send("H2D_FLEET_REFRESH")
    }

    func setHardwareBuzzerEnabled(_ enabled: Bool) {
        hardwareBuzzerEnabled = enabled
        _ = send("H2D_BUZZER,\(enabled ? 1 : 0)")
    }

    func suspendForBackground() {
        lifecycleActive = false
        reconnectWorkItem?.cancel()
        cancelStatusRefreshes()
        fleetSyncWorkItems.forEach { $0.cancel() }
        fleetSyncWorkItems.removeAll()
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
        let generation = configurationGeneration
        if isSwitchingPrinter {
            let progress = configurationIndex == 0 ? 0.18 : 0.42
            updatePrinterSwitchProgress(
                progress,
                message: "Đang gửi \(configurationIndex + 1)/\(configurationCommands.count): \(item.label)"
            )
        } else {
            h2dBridgeStatus = "Đang gửi \(configurationIndex + 1)/\(configurationCommands.count): \(item.label)"
        }
        guard send(item.payload) else {
            failConfiguration("Mất kết nối Bluetooth • hãy thử lưu lại")
            return
        }

        configurationTimeoutWorkItem?.cancel()
        let expectedIndex = configurationIndex
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.isConfiguring,
                  self.configurationIndex == expectedIndex,
                  self.configurationGeneration == generation else { return }
            if self.configurationRetryCount < 2 {
                self.configurationRetryCount += 1
                self.h2dBridgeStatus = "ESP32 chưa xác nhận • đang gửi lại lần \(self.configurationRetryCount)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.sendNextConfigurationCommand()
                }
            } else {
                self.failConfiguration("ESP32 không xác nhận dữ liệu • cần firmware Bambu v1.8.3 trở lên")
            }
        }
        configurationTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: timeout)
    }

    private func acceptConfigurationAcknowledgement(_ value: String) {
        guard isConfiguring, configurationIndex < configurationCommands.count,
              configurationCommands[configurationIndex].acknowledgement == value.uppercased() else { return }
        let acknowledgement = configurationCommands[configurationIndex].acknowledgement
        configurationTimeoutWorkItem?.cancel()
        configurationIndex += 1
        configurationRetryCount = 0
        configurationProgress = configurationIndex
        if isSwitchingPrinter {
            if acknowledgement.hasPrefix("PROFILE_") {
                updatePrinterSwitchProgress(
                    0.36,
                    message: "ESP32 đã nhận hồ sơ • đang chọn máy \(printerModelCode)"
                )
            } else if acknowledgement == "SELECT" {
                updatePrinterSwitchProgress(
                    0.58,
                    message: "ESP32 đã chọn \(printerModelCode) • đang kiểm tra serial"
                )
            }
        }
        if configurationIndex == configurationCommands.count {
            isConfiguring = false
            if !isSwitchingPrinter {
                h2dBridgeStatus = "Đã lưu cấu hình • ESP32 đang kết nối Wi-Fi"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.requestH2DStatus()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.sendNextConfigurationCommand()
            }
        }
    }

    private func failConfiguration(_ message: String) {
        configurationTimeoutWorkItem?.cancel()
        printerSwitchTimeoutWorkItem?.cancel()
        printerSwitchTimeoutWorkItem = nil
        configurationCommands.removeAll()
        configurationIndex = 0
        configurationRetryCount = 0
        configurationProgress = 0
        isConfiguring = false
        isSwitchingPrinter = false
        expectedPrinterSerial = ""
        printerSwitchIdentityConfirmed = false
        printerSwitchProgress = 0
        printerSwitchPhaseText = ""
        hasBridgeError = true
        h2dBridgeStatus = message
    }

    private func startScanning() {
        guard lifecycleActive, central.state == .poweredOn else { return }
        central.stopScan()
        connectionText = "Đang tìm ESP32 Bambu..."
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

    private func cancelPrinterSwitchTimeout() {
        printerSwitchGeneration &+= 1
        printerSwitchTimeoutWorkItem?.cancel()
        printerSwitchTimeoutWorkItem = nil
    }

    private func updatePrinterSwitchProgress(_ value: Double, message: String) {
        guard isSwitchingPrinter else { return }
        printerSwitchProgress = max(printerSwitchProgress, min(1, max(0, value)))
        printerSwitchPhaseText = message
        h2dStatusCode = "SWITCHING"
        h2dBridgeStatus = message
    }

    private func finishPrinterSwitchSuccessfully() {
        guard isSwitchingPrinter else { return }
        printerSwitchProgress = 1
        printerSwitchPhaseText = "Đã kết nối \(printerModelCode)"
        h2dBridgeStatus = printerSwitchPhaseText
        cancelPrinterSwitchTimeout()
        let completedGeneration = printerSwitchGeneration
        isSwitchingPrinter = false
        expectedPrinterSerial = ""
        printerSwitchIdentityConfirmed = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, !self.isSwitchingPrinter,
                  self.printerSwitchGeneration == completedGeneration else { return }
            self.printerSwitchProgress = 0
            self.printerSwitchPhaseText = ""
        }
    }

    private func finishPrinterSwitchAsUnavailable() {
        guard isSwitchingPrinter else { return }
        let target = BambuPrinterKind(rawValue: printerModelCode) ?? .unknown
        isSwitchingPrinter = false
        expectedPrinterSerial = ""
        printerSwitchIdentityConfirmed = false
        printerSwitchProgress = 0
        printerSwitchPhaseText = ""
        h2dStatusCode = "PRINTER_OFFLINE"
        markH2DUnavailable(for: target)
        h2dBridgeStatus = target == .unknown
            ? "Máy in không phản hồi • kiểm tra nguồn và IP LAN"
            : "\(target.rawValue) không phản hồi • kiểm tra nguồn và IP LAN"
        hasBridgeError = false
    }

    private func markH2DUnavailable(for selectedKind: BambuPrinterKind? = nil) {
        mqttLossWorkItem?.cancel()
        mqttLossWorkItem = nil
        isH2DReady = false
        hasPrinterAlert = false
        hasCriticalPrinterAlert = false
        printerAlertText = ""
        // Keep last-known state for the other two printers. A transient
        // selected-printer reconnect must not turn every fleet indicator black.
        let kind = selectedKind ?? BambuPrinterKind(rawValue: printerModelCode)
        guard let kind, kind != .unknown else { return }
        var offline = fleetStatuses[kind] ?? BambuFleetStatus(
            isConfigured: BambuPrinterProfileStore.profile(for: kind) != nil
        )
        offline.isOnline = false
        offline.hasActivePrintJob = false
        offline.hasCriticalError = false
        offline.printState = "OFFLINE"
        fleetStatuses[kind] = offline
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
                self.h2dBridgeStatus = "Mất dữ liệu \(self.printerDisplayName) • ESP32 đang tự kết nối lại"
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
        connectionText = "Đã kết nối ESP32 • đang kiểm tra máy in"
        if firstActivation {
            recognitionWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.isConnected, !self.isH2DBridge else { return }
                self.hasBridgeError = true
                self.h2dBridgeStatus = "ESP32 đang chạy firmware cũ • hãy nạp bản Bambu v1.8.3"
            }
            recognitionWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: item)
        }
        requestH2DStatus()
        if desiredTimelapseArmed {
            // Give notification subscription a moment to settle, then restore
            // the bridge-side arm state that may have been lost on reconnect.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, self.isConnected, self.desiredTimelapseArmed else { return }
                _ = self.send("H2D_ARM,1")
                self.h2dBridgeStatus = "Đã đồng bộ lại chế độ chụp theo lớp"
            }
        }
    }

    private func parseEvent(_ event: String) {
        let fields = event.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count >= 2, fields[0].uppercased() == "H2D" else { return }
        recognitionWorkItem?.cancel()
        isH2DBridge = true
        connectionText = "Đã kết nối ESP32 • cầu nối Bambu"

        switch fields[1].uppercased() {
        case "ESP32":
            hasBridgeError = false
        case "CONTROL":
            guard fields.count >= 4 else { return }
            let control = fields[2].uppercased()
            var changed = false
            switch control {
            case "MODE":
                let value = min(1, max(-1, Int(fields[3]) ?? 0))
                if value != hardwareMode {
                    hardwareMode = value
                    changed = true
                }
            case "HOLD":
                let value = fields[3] == "1"
                if value != hardwareHoldActive {
                    hardwareHoldActive = value
                    changed = true
                }
            case "BUZZER":
                hardwareBuzzerEnabled = fields[3] != "0"
                // This setting never changes camera/torch state.
                return
            default:
                return
            }
            // ESP32 repeats MODE/HOLD during status synchronization.
            // Do not restart the camera or torch for identical values; a forced
            // synchronization already runs when the view becomes active again.
            if changed {
                hardwareControlRevision &+= 1
            }
        case "PRINTER":
            guard fields.count >= 4 else { return }
            let reportedSerial = normalizeSerial(fields[3])
            if isSwitchingPrinter && !expectedPrinterSerial.isEmpty &&
                reportedSerial != expectedPrinterSerial {
                h2dBridgeStatus = "Đang chuyển ESP32 sang \(printerModelCode)…"
                return
            }
            printerModelCode = fields[2]
            printerSerial = reportedSerial
            if isSwitchingPrinter {
                printerSwitchIdentityConfirmed = true
                updatePrinterSwitchProgress(
                    0.72,
                    message: "Đúng serial \(printerDisplayName) • đang nhận dữ liệu máy in"
                )
            }
            connectionText = "Đã kết nối ESP32 • \(printerDisplayName)"
        case "FLEET":
            guard fields.count >= 9,
                  let kind = BambuPrinterKind(rawValue: fields[2]),
                  kind != .unknown else { return }
            let status = BambuFleetStatus(
                isConfigured: fields[3] == "1",
                isOnline: fields[4] == "1",
                hasActivePrintJob: fields[5] == "1",
                hasCriticalError: fields[6] == "1",
                printState: fields[7].uppercased(),
                printPercent: min(100, max(0, Int(fields[8]) ?? 0)),
                printErrorCode: fields.count >= 10 ? (UInt32(fields[9]) ?? 0) : 0
            )
            fleetStatuses[kind] = status
            applyCachedFleetStatus(status, for: kind)
        case "MATERIAL":
            guard !isSwitchingPrinter else { return }
            guard fields.count >= 3 else { return }
            filamentType = fields[2].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        case "TELEMETRY":
            guard !isSwitchingPrinter, fields.count >= 10 else { return }
            nozzleTemperature = Int(fields[2]) ?? nozzleTemperature
            nozzleTargetTemperature = Int(fields[3]) ?? nozzleTargetTemperature
            if fields.count >= 11 {
                // v1.8.4+: right nozzle, right target, left nozzle, left target,
                // bed, bed target, then exactly Part/Aux/Exhaust.
                leftNozzleTemperature = Int(fields[4]) ?? leftNozzleTemperature
                leftNozzleTargetTemperature = Int(fields[5]) ?? leftNozzleTargetTemperature
                bedTemperature = Int(fields[6]) ?? bedTemperature
                bedTargetTemperature = Int(fields[7]) ?? bedTargetTemperature
                partFanPercent = Int(fields[8]) ?? partFanPercent
                auxiliaryFanPercent = Int(fields[9]) ?? auxiliaryFanPercent
                exhaustFanPercent = Int(fields[10]) ?? exhaustFanPercent
            } else {
                // Compatibility with the currently installed v1.8.3 firmware.
                bedTemperature = Int(fields[4]) ?? bedTemperature
                bedTargetTemperature = Int(fields[5]) ?? bedTargetTemperature
                partFanPercent = Int(fields[6]) ?? partFanPercent
                auxiliaryFanPercent = Int(fields[7]) ?? auxiliaryFanPercent
                exhaustFanPercent = Int(fields[8]) ?? exhaustFanPercent
            }
        case "CFG_ACK":
            guard fields.count >= 3 else { return }
            hasBridgeError = false
            acceptConfigurationAcknowledgement(fields[2])
        case "COMPLETE_ACK":
            // The view already dismisses its blue completion presentation
            // locally. This packet confirms that ESP32 cleared the same timer.
            break
        case "STATUS":
            guard fields.count >= 3 else { return }
            let status = fields[2].uppercased()
            // A profile switch is complete only after the bridge reports the
            // selected printer.  If the target cannot be reached, do not keep
            // swallowing status updates behind the SWITCHING placeholder.
            // Surface the real offline state and allow another profile switch.
            if status == "PRINTER_OFFLINE" || status == "MQTT_RETRY" {
                if isSwitchingPrinter {
                    // The old MQTT session reports a retry while the bridge is
                    // moving to the new target. Wait for PRINTER/<target
                    // serial> or the explicit switch timeout instead of
                    // failing the tab change on this transient status.
                    h2dStatusCode = "SWITCHING"
                    h2dBridgeStatus = "Đang kết nối \(printerModelCode)…"
                    return
                }
                isSwitchingPrinter = false
                expectedPrinterSerial = ""
                h2dStatusCode = "PRINTER_OFFLINE"
                markH2DUnavailable()
                h2dBridgeStatus = "\(printerDisplayName) không phản hồi • kiểm tra nguồn và IP LAN"
                hasBridgeError = false
                return
            }
            if isSwitchingPrinter {
                if status == "CONFIG_SAVED", isConfiguring {
                    configurationTimeoutWorkItem?.cancel()
                    configurationProgress = configurationCommands.count
                    isConfiguring = false
                }
                if printerSwitchIdentityConfirmed {
                    switch status {
                    case "MQTT_CONNECTING":
                        updatePrinterSwitchProgress(
                            0.80,
                            message: "Đúng máy \(printerModelCode) • đang xác thực LAN"
                        )
                        return
                    case "SYNCING":
                        updatePrinterSwitchProgress(
                            0.90,
                            message: "Đang đồng bộ dữ liệu thời gian thực từ \(printerModelCode)"
                        )
                        return
                    case "READY", "ARMED", "DISARMED":
                        finishPrinterSwitchSuccessfully()
                    default:
                        updatePrinterSwitchProgress(
                            0.74,
                            message: "Đúng máy \(printerModelCode) • đang chờ MQTT sẵn sàng"
                        )
                        return
                    }
                } else {
                    updatePrinterSwitchProgress(
                        0.62,
                        message: "ESP32 đang chuyển sang \(printerModelCode) • chờ đúng serial"
                    )
                    return
                }
            }
            h2dStatusCode = status
            let known: [String: String] = [
                "BOOTING": "ESP32 đang khởi động",
                "CONFIG_REQUIRED": "Chưa có cấu hình máy in",
                "CONFIG_SAVED": "Đã lưu cấu hình • đang kết nối lại",
                "WIFI_CONNECTING": "ESP32 đang kết nối Wi-Fi",
                "WIFI_OK": "Wi-Fi đã kết nối • đang tìm máy in",
                "MQTT_CONNECTING": "Đang xác thực \(printerDisplayName) LAN bằng Access Code",
                "MQTT_AUTH_FAILED": "Không xác thực được \(printerDisplayName) • kiểm tra Access Code LAN",
                "MQTT_RETRY": "Mạng đã thấy máy in • đang thử kết nối lại",
                "PRINTER_OFFLINE": "\(printerDisplayName) không phản hồi • kiểm tra nguồn và IP LAN",
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
            case "BOOTING", "CONFIG_REQUIRED", "CONFIG_SAVED", "WIFI_CONNECTING", "WIFI_OK", "BUFFER_ERROR", "PRINTER_OFFLINE":
                markH2DUnavailable()
            default:
                break
            }
            hasBridgeError = status == "BUFFER_ERROR" || status == "MQTT_AUTH_FAILED"
            if !hasActiveCriticalPrinterAlert {
                h2dBridgeStatus = status == "BUFFER_ERROR"
                    ? "ESP32 thiếu bộ nhớ nhận gói \(printerDisplayName) • hãy khởi động lại"
                    : known[status] ?? fields.dropFirst(2).joined(separator: " • ")
            }
        case "PRINT":
            if isSwitchingPrinter {
                // A background monitor can provide a provisional PRINT packet
                // for the new target before its primary MQTT connection has
                // completed. Accept it only when the packet carries the
                // serial we requested; late packets from the old printer are
                // still ignored while switching.
                guard fields.count >= 9,
                      normalizeSerial(fields[8]) == expectedPrinterSerial else { return }
                printerSerial = normalizeSerial(fields[8])
                printerSwitchIdentityConfirmed = true
                finishPrinterSwitchSuccessfully()
            }
            guard fields.count >= 6 else { return }
            confirmH2DReady()
            h2dPrintState = fields[2].uppercased()
            h2dCurrentLayer = max(0, Int(fields[3]) ?? h2dCurrentLayer)
            h2dTotalLayers = max(0, Int(fields[4]) ?? h2dTotalLayers)
            h2dPrintPercent = min(100, max(0, Int(fields[5]) ?? h2dPrintPercent))
            if fields.count >= 7 {
                h2dStageCode = Int(fields[6]) ?? h2dStageCode
            }
            if fields.count >= 8 {
                h2dRemainingMinutes = Int(fields[7]) ?? h2dRemainingMinutes
            }
            hasBridgeError = false
            if !isPrintSessionActive {
                hasPrinterAlert = false
                hasCriticalPrinterAlert = false
                printerAlertText = ""
            }
            if !hasActiveCriticalPrinterAlert {
                if isStoppingPrint {
                    h2dBridgeStatus = "\(printerDisplayName) đang dừng bản in"
                } else if isPausedPrint {
                    h2dBridgeStatus = "\(printerDisplayName) đang tạm dừng"
                } else if isActuallyPrinting {
                    h2dBridgeStatus = "\(printerDisplayName) đang in lớp \(h2dCurrentLayer)/\(max(1, h2dTotalLayers))"
                } else if h2dPrintState == "RUNNING" ||
                            (h2dStageCode > 0 && h2dStageCode != 255) {
                    h2dBridgeStatus = h2dStageText
                } else {
                    h2dBridgeStatus = "Trạng thái \(printerDisplayName): \(h2dPrintState)"
                }
            }
        case "SNAP":
            guard !isSwitchingPrinter else { return }
            guard fields.count >= 5 else { return }
            confirmH2DReady()
            let layer = max(1, Int(fields[2]) ?? 1)
            let total = max(layer, Int(fields[3]) ?? layer)
            let snapshotPhase = fields.count >= 6 ? fields[5].uppercased() : "LAYER"
            h2dCurrentLayer = layer
            h2dTotalLayers = total
            h2dTimelapseEvent = H2DTimelapseEvent(
                kind: .snapshot,
                layer: layer,
                totalLayers: total,
                jobID: fields[4],
                message: "Chụp lớp \(layer)",
                playsShutterSound: snapshotPhase == "LAYER"
            )
        case "DONE":
            guard !isSwitchingPrinter else { return }
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
                message: "\(printerDisplayName) đã in xong",
                playsShutterSound: false
            )
        case "ALERT":
            guard !isSwitchingPrinter else { return }
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
                    message: printerAlertText,
                    playsShutterSound: false
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
            h2dBridgeStatus = detail.isEmpty ? "Cầu nối Bambu gặp lỗi" : detail
            hasBridgeError = true
            h2dTimelapseEvent = H2DTimelapseEvent(
                kind: .error,
                layer: h2dCurrentLayer,
                totalLayers: h2dTotalLayers,
                jobID: "",
                message: h2dBridgeStatus,
                playsShutterSound: false
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
        connectionText = "Đã nối BLE • đang mở kênh Bambu..."
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
            connectionText = "Không đọc được kênh điều khiển Bambu"
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
