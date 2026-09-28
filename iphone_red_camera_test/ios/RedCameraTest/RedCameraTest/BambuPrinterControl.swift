import Combine
import Foundation
import Network
import Security

struct BambuAMSTraySnapshot: Identifiable, Equatable {
    let amsID: Int
    let slotID: Int
    let material: String
    let colorHex: String
    let isPresent: Bool
    let extruderID: Int?
    let dryingTemperature: Int?
    let dryingHours: Int?

    var id: String { "\(amsID)-\(slotID)" }
    var trayIndex: Int { amsID >= 128 ? amsID : amsID * 4 + slotID }
}

struct BambuDirectSnapshot: Equatable {
    var printState = ""
    var printPercent: Int?
    var currentLayer: Int?
    var totalLayers: Int?
    var remainingMinutes: Int?
    var nozzleTemperature: Int?
    var nozzleTargetTemperature: Int?
    var leftNozzleTemperature: Int?
    var leftNozzleTargetTemperature: Int?
    var bedTemperature: Int?
    var bedTargetTemperature: Int?
    var printSpeedLevel: Int?
    var printStage: Int?
    var printErrorCode: UInt32?
    var printerErrorText = ""
    var printStartedAt: Date?
    var jobID = ""
    var subtaskID = ""
    var chamberLightOn: Bool?
    var extruderCount = 1
    var currentExtruderID: Int?
    var externalSpoolExtruderID: Int?
    var externalFilamentPresent: Bool?
    var filamentPresentByExtruder: [Int: Bool] = [:]
    var currentAMSTrayID: String?
    var hasAMS = false
    var amsDryerUnitID: Int?
    var amsDrying = false
    var amsDryingRemainingMinutes: Int?
    var amsDryingTemperature: Int?
    var amsHumidityPercentByUnit: [Int: Int] = [:]
    var amsTrays: [BambuAMSTraySnapshot] = []
    var receivedAt: Date?

    var isRecent: Bool {
        guard let receivedAt else { return false }
        return Date().timeIntervalSince(receivedAt) < 35
    }

    var hasActivePrintJob: Bool {
        ["RUNNING", "PREPARE", "PREPARING", "PAUSE", "PAUSED", "SLICING", "INIT", "HEATING"]
            .contains(printState)
    }

    var isManualFilamentLoadRequest: Bool {
        guard let code = printErrorCode else { return false }
        return [0x07FEC00A, 0x07FFC00A, 0x07FE8007, 0x07FF8007].contains(code)
    }

    var isManualFilamentUnloadRequest: Bool {
        guard let code = printErrorCode else { return false }
        return [0x07FEC003, 0x07FFC003, 0x07FEC006, 0x07FFC006].contains(code) ||
            (printStage == 22 && (code & 0xFFFF) == 0x8003)
    }

    var hasManualFilamentRequest: Bool {
        isManualFilamentLoadRequest || isManualFilamentUnloadRequest
    }

    var hasCriticalError: Bool {
        !hasManualFilamentRequest && (printState == "ERROR" ||
            ((printErrorCode ?? 0) != 0 && (hasActivePrintJob || printState == "FAILED"))
        )
    }
}

enum BambuRemotePromptKind: Equatable {
    case filamentLoad
    case filamentUnload
    case printerError
}

struct BambuRemotePrompt: Identifiable, Equatable {
    let id: String
    let kind: BambuRemotePromptKind
    let errorCode: UInt32?
    let detail: String?
}

/// Direct LAN MQTT control for the selected printer. Control no longer depends
/// on the ESP32's MQTT session, so a BLE reconnect or fleet scan cannot swallow
/// a user command. The ESP32 remains responsible for telemetry and timelapse.
final class BambuPrinterControlManager: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isPending = false
    @Published private(set) var lastSucceeded: Bool?
    @Published private(set) var statusText = "Đang chuẩn bị điều khiển trực tiếp…"
    @Published private(set) var snapshot = BambuDirectSnapshot()
    @Published private(set) var activePrompt: BambuRemotePrompt?

    private struct Configuration: Equatable {
        let profileID: String
        let host: String
        let serial: String
        let accessCode: String
        let isDualNozzle: Bool
    }

    private struct PendingCommand {
        let sequence: String
        let mqttCommand: String
        let actionName: String
        let onSuccess: (() -> Void)?
    }

    private let queue = DispatchQueue(label: "vn.se.bambu-printer-control", qos: .userInitiated)
    private var configuration: Configuration?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var generation = 0
    private var packetID: UInt16 = 10
    private var sequenceNumber: UInt64 = 200_000
    private var pending: PendingCommand?
    private var pingTimer: DispatchSourceTimer?
    private var snapshotStorage = BambuDirectSnapshot()
    private var activePromptStorage: BambuRemotePrompt?
    private var activeFilamentOperation: BambuRemotePromptKind?
    private var filamentOperationNumber = 0
    private var dismissedPromptID: String?
    private var lastFullStatusRequest = Date.distantPast
    private var lastSnapshotPublishedAt = Date.distantPast
    private var pendingSnapshotPublication: DispatchWorkItem?

    func start(profile: BambuPrinterProfile, accessCode: String) {
        let next = Configuration(
            profileID: profile.id,
            host: profile.ip.trimmingCharacters(in: .whitespacesAndNewlines),
            serial: profile.serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            accessCode: accessCode.trimmingCharacters(in: .whitespacesAndNewlines),
            isDualNozzle: profile.kind == .h2d
        )
        guard !next.host.isEmpty, !next.serial.isEmpty, !next.accessCode.isEmpty else {
            publishFailure("Thiếu IP, serial hoặc Access Code của máy in")
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            if self.configuration == next, self.connection != nil { return }
            self.snapshotStorage = BambuDirectSnapshot()
            self.pendingSnapshotPublication?.cancel()
            self.pendingSnapshotPublication = nil
            self.lastSnapshotPublishedAt = .distantPast
            self.activePromptStorage = nil
            self.activeFilamentOperation = nil
            self.dismissedPromptID = nil
            DispatchQueue.main.async { [weak self] in
                self?.snapshot = BambuDirectSnapshot()
                self?.activePrompt = nil
            }
            self.configuration = next
            self.connect()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.close(clearConfiguration: true)
        }
    }

    func retry() {
        queue.async { [weak self] in
            guard let self, self.configuration != nil else { return }
            self.connect()
        }
    }

    func pausePrint() {
        send(section: "print", command: "pause", fields: [:], actionName: "Tạm dừng bản in")
    }

    func resumePrint() {
        send(section: "print", command: "resume", fields: [:], actionName: "Tiếp tục bản in")
    }

    func stopPrint() {
        send(section: "print", command: "stop", fields: [:], actionName: "Dừng")
    }

    func setNozzleTemperature(_ temperature: Int, extruderID: Int) {
        guard (0...320).contains(temperature), extruderID == 0 || extruderID == 1 else {
            publishFailure("Nhiệt độ đầu in không hợp lệ")
            return
        }
        if snapshotStorage.extruderCount > 1 {
            send(
                section: "print",
                command: "set_nozzle_temp",
                fields: ["extruder_index": extruderID, "target_temp": temperature],
                actionName: "Đặt nhiệt độ đầu in"
            )
        } else {
            send(
                section: "print",
                command: "gcode_line",
                fields: ["param": "M104 S\(temperature)\n"],
                actionName: "Đặt nhiệt độ đầu in"
            )
        }
    }

    func setBedTemperature(_ temperature: Int) {
        guard (0...120).contains(temperature) else {
            publishFailure("Nhiệt độ bàn in không hợp lệ")
            return
        }
        send(
            section: "print",
            command: "gcode_line",
            fields: ["param": "M140 S\(temperature)\n"],
            actionName: "Đặt nhiệt độ bàn in"
        )
    }

    /// Heating-capable AMS units accept this command over the printer's LAN
    /// MQTT channel. Rotation stays off by default so a drying cycle never
    /// starts moving a spool unexpectedly.
    func setAMSDrying(
        enabled: Bool,
        amsID: Int,
        durationHours: Int,
        temperature: Int,
        filament: String
    ) {
        guard amsID >= 0, (1...48).contains(durationHours), (45...90).contains(temperature) else {
            publishFailure("Thông số sấy AMS không hợp lệ")
            return
        }
        send(
            section: "print",
            command: "ams_filament_drying",
            fields: [
                "ams_id": amsID,
                "cooling_temp": enabled ? 45 : 40,
                // The printer protocol expects minutes, not hours.
                "duration": enabled ? durationHours * 60 : 0,
                "humidity": enabled ? 20 : 0,
                "mode": enabled ? 1 : 0,
                "rotate_tray": false,
                "temp": enabled ? temperature : 0,
                "filament": enabled ? filament : "",
                "close_power_conflict": false
            ],
            actionName: enabled ? "Bật sấy AMS" : "Tắt sấy AMS"
        )
    }

    func continueActivePrompt() {
        queue.async { [weak self] in
            guard let self, let prompt = self.activePromptStorage else { return }
            switch prompt.kind {
            case .filamentLoad:
                self.send(
                    section: "print",
                    command: "ams_control",
                    fields: ["param": "resume"],
                    actionName: "Chưa ra nhựa • thử đùn lại"
                )
            case .filamentUnload:
                self.send(
                    section: "print",
                    command: "ams_control",
                    fields: ["param": "resume"],
                    actionName: "Đã rút nhựa • tiếp tục",
                    onSuccess: { [weak self] in
                        self?.activeFilamentOperation = nil
                        self?.dismissCurrentPrompt()
                    }
                )
            case .printerError:
                self.send(
                    section: "print",
                    command: "resume",
                    fields: self.errorActionFields(for: prompt),
                    actionName: "Khắc phục và tiếp tục",
                    onSuccess: { [weak self] in self?.dismissCurrentPrompt() }
                )
            }
        }
    }

    func ignoreActiveError() {
        queue.async { [weak self] in
            guard let self, let prompt = self.activePromptStorage,
                  prompt.kind == .printerError else { return }
            self.send(
                section: "print",
                command: "ignore",
                fields: self.errorActionFields(for: prompt),
                actionName: "Bỏ qua cảnh báo và tiếp tục",
                onSuccess: { [weak self] in self?.dismissCurrentPrompt() }
            )
        }
    }

    func finishFilamentOperation() {
        queue.async { [weak self] in
            guard let self, let prompt = self.activePromptStorage,
                  prompt.kind == .filamentLoad else { return }
            self.send(
                section: "print",
                command: "ams_control",
                fields: ["param": "done"],
                actionName: "Đã đùn nhựa • tiếp tục",
                onSuccess: { [weak self] in
                    self?.activeFilamentOperation = nil
                    self?.dismissCurrentPrompt()
                }
            )
        }
    }

    func stopFromActivePrompt() {
        queue.async { [weak self] in
            guard let self, let prompt = self.activePromptStorage else { return }
            var fields: [String: Any] = [:]
            if prompt.kind == .printerError {
                fields = self.errorActionFields(for: prompt)
            }
            self.send(
                section: "print",
                command: "stop",
                fields: fields,
                actionName: "Dừng",
                onSuccess: { [weak self] in
                    self?.activeFilamentOperation = nil
                    self?.dismissCurrentPrompt()
                }
            )
        }
    }

    /// The selected external-spool path comes from the printer's own extruder
    /// report. Single-nozzle printers use their only extruder, id 0.
    func loadExternalFilament(temperature: Int, extruderID: Int) {
        guard (170...320).contains(temperature) else {
            publishFailure("Nhiệt độ nạp nhựa không hợp lệ")
            return
        }
        guard extruderID == 0 || extruderID == 1 else {
            publishFailure("Đầu đùn nạp nhựa không hợp lệ")
            return
        }
        preheatNozzle(temperature: temperature, extruderID: extruderID) { [weak self] in
            self?.sendExternalFilamentCommand(
                load: true,
                temperature: temperature,
                extruderID: extruderID
            )
        }
    }

    func unloadExternalFilament(temperature: Int, extruderID: Int) {
        guard (170...320).contains(temperature) else {
            publishFailure("Nhiệt độ rút nhựa không hợp lệ")
            return
        }
        guard extruderID == 0 || extruderID == 1 else {
            publishFailure("Đầu đùn rút nhựa không hợp lệ")
            return
        }
        preheatNozzle(temperature: temperature, extruderID: extruderID) { [weak self] in
            self?.sendExternalFilamentCommand(
                load: false,
                temperature: temperature,
                extruderID: extruderID
            )
        }
    }

    func loadAMSFilament(_ tray: BambuAMSTraySnapshot, temperature: Int, extruderID: Int) {
        guard tray.isPresent else {
            publishFailure("Khay AMS này chưa có nhựa")
            return
        }
        guard (170...320).contains(temperature), extruderID == 0 || extruderID == 1 else {
            publishFailure("Thông số nạp nhựa AMS không hợp lệ")
            return
        }
        preheatNozzle(temperature: temperature, extruderID: extruderID) { [weak self] in
            guard let self else { return }
            self.filamentOperationNumber &+= 1
            self.activeFilamentOperation = .filamentLoad
            self.dismissedPromptID = nil
            self.send(
                section: "print",
                command: "ams_change_filament",
                fields: [
                    "ams_id": tray.amsID,
                    "slot_id": tray.slotID,
                    "target": tray.trayIndex,
                    "extruder_id": extruderID,
                    "curr_temp": temperature,
                    "tar_temp": temperature
                ],
                actionName: "Nạp \(tray.material.isEmpty ? "nhựa" : tray.material) từ AMS"
            )
        }
    }

    func unloadAMSFilament(temperature: Int, extruderID: Int) {
        guard (170...320).contains(temperature), extruderID == 0 || extruderID == 1 else {
            publishFailure("Thông số rút nhựa AMS không hợp lệ")
            return
        }
        let current = snapshotStorage.amsTrays.first { $0.id == snapshotStorage.currentAMSTrayID }
        guard let current else {
            publishFailure("Máy in chưa báo khay AMS đang dùng")
            return
        }
        preheatNozzle(temperature: temperature, extruderID: extruderID) { [weak self] in
            guard let self else { return }
            self.filamentOperationNumber &+= 1
            self.activeFilamentOperation = .filamentUnload
            self.dismissedPromptID = nil
            self.send(
                section: "print",
                command: "ams_change_filament",
                fields: [
                    "ams_id": current.amsID,
                    "slot_id": 255,
                    "target": 255,
                    "extruder_id": extruderID,
                    "curr_temp": temperature,
                    "tar_temp": temperature
                ],
                actionName: "Rút nhựa khỏi AMS"
            )
        }
    }

    /// Bambu Studio explicitly sets the nozzle target before a manual filament
    /// operation. Without this step some firmwares begin the positioning/home
    /// phase while leaving the target at 0°C. H2D needs the structured command
    /// so the left nozzle can be addressed; single-nozzle printers use Studio's
    /// broadly supported M104 fallback.
    private func preheatNozzle(
        temperature: Int,
        extruderID: Int,
        completion: @escaping () -> Void
    ) {
        if snapshotStorage.extruderCount > 1 {
            send(
                section: "print",
                command: "set_nozzle_temp",
                fields: [
                    "extruder_index": extruderID,
                    "target_temp": temperature
                ],
                actionName: "Gia nhiệt đầu \(extruderID == 1 ? "trái" : "phải") tới \(temperature)°C",
                onSuccess: completion
            )
        } else {
            send(
                section: "print",
                command: "gcode_line",
                fields: ["param": "M104 S\(temperature)\n"],
                actionName: "Gia nhiệt đầu in tới \(temperature)°C",
                onSuccess: completion
            )
        }
    }

    private func sendExternalFilamentCommand(load: Bool, temperature: Int, extruderID: Int) {
        filamentOperationNumber &+= 1
        activeFilamentOperation = load ? .filamentLoad : .filamentUnload
        dismissedPromptID = nil
        // Bambu's virtual tray 254 belongs to the main/right extruder; 253 is
        // the deputy/left path on dual-tool printers.
        let virtualAMSID = extruderID == 1 ? 253 : 254
        send(
            section: "print",
            command: "ams_change_filament",
            fields: [
                "ams_id": virtualAMSID,
                "slot_id": load ? 0 : 255,
                "target": load ? virtualAMSID : 255,
                "extruder_id": extruderID,
                // Studio supplies both the current-filament and target-filament
                // temperatures. Zero here can leave the nozzle target unchanged.
                "curr_temp": temperature,
                "tar_temp": temperature
            ],
            actionName: load
                ? (extruderID == 1 ? "Nạp nhựa cuộn ngoài vào đầu trái" : "Nạp nhựa cuộn ngoài")
                : (extruderID == 1 ? "Rút nhựa cuộn ngoài khỏi đầu trái" : "Rút nhựa cuộn ngoài")
        )
    }

    func setPrintSpeed(_ level: Int) {
        guard (1...4).contains(level) else { return }
        send(
            section: "print",
            command: "print_speed",
            fields: ["param": String(level)],
            actionName: "Đổi tốc độ in"
        )
    }

    func setChamberLight(enabled: Bool) {
        send(
            section: "system",
            command: "ledctrl",
            fields: [
                "led_node": "chamber_light",
                "led_mode": enabled ? "on" : "off",
                "led_on_time": 500,
                "led_off_time": 500,
                "loop_times": 0,
                "interval_time": 0
            ],
            actionName: enabled ? "Bật đèn buồng in" : "Tắt đèn buồng in"
        )
    }

    private func connect() {
        guard let configuration else { return }
        close(clearConfiguration: false)
        generation &+= 1
        let activeGeneration = generation
        publishReady(false, text: "Đang kết nối MQTT trực tiếp tới máy in…")

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, complete in complete(true) },
            queue
        )
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, true)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.serviceClass = .responsiveData
        guard let port = NWEndpoint.Port(rawValue: 8883) else {
            publishFailure("Cổng MQTT của máy in không hợp lệ")
            return
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(configuration.host),
            port: port,
            using: parameters
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == activeGeneration else { return }
            switch state {
            case .ready:
                self.beginReceive(generation: activeGeneration)
                self.sendPacket(self.connectPacket(configuration: configuration))
            case .failed(let error):
                self.failConnection("Không mở được MQTT LAN (\(error.localizedDescription))")
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.generation == activeGeneration, !self.isReady else { return }
            self.failConnection("MQTT LAN không phản hồi • kiểm tra Developer Mode")
        }
    }

    private func close(clearConfiguration: Bool) {
        generation &+= 1
        pingTimer?.cancel()
        pingTimer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: false)
        pending = nil
        if clearConfiguration { configuration = nil }
        publishReady(false, text: clearConfiguration ? "Điều khiển máy in đã đóng" : "Đang kết nối lại…")
    }

    private func beginReceive(generation activeGeneration: Int) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, self.generation == activeGeneration else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.consumePackets()
            }
            if let error {
                self.failConnection("Mất kết nối MQTT (\(error.localizedDescription))")
                return
            }
            if complete {
                self.failConnection("Máy in đã đóng kết nối MQTT")
                return
            }
            self.beginReceive(generation: activeGeneration)
        }
    }

    private func consumePackets() {
        while receiveBuffer.count >= 2 {
            let bytes = [UInt8](receiveBuffer.prefix(6))
            var multiplier = 1
            var remainingLength = 0
            var index = 1
            var completedLength = false
            while index < bytes.count, index <= 4 {
                let digit = Int(bytes[index])
                remainingLength += (digit & 0x7F) * multiplier
                index += 1
                if digit & 0x80 == 0 {
                    completedLength = true
                    break
                }
                multiplier *= 128
            }
            guard completedLength else { return }
            let packetLength = index + remainingLength
            guard receiveBuffer.count >= packetLength else { return }
            let header = receiveBuffer[receiveBuffer.startIndex]
            let bodyStart = receiveBuffer.index(receiveBuffer.startIndex, offsetBy: index)
            let bodyEnd = receiveBuffer.index(bodyStart, offsetBy: remainingLength)
            let body = Data(receiveBuffer[bodyStart..<bodyEnd])
            receiveBuffer.removeFirst(packetLength)
            handlePacket(header: header, body: body)
        }
    }

    private func handlePacket(header: UInt8, body: Data) {
        switch header >> 4 {
        case 2: // CONNACK
            guard body.count >= 2, body[body.index(body.startIndex, offsetBy: 1)] == 0,
                  let configuration else {
                failConnection("Máy in từ chối Access Code MQTT")
                return
            }
            sendPacket(subscribePacket(topic: "device/\(configuration.serial)/report"))
        case 3: // PUBLISH
            handlePublish(header: header, body: body)
        case 4: // PUBACK
            publishWaitingForPrinter()
        case 9: // SUBACK
            publishReady(true, text: "Đã kết nối trực tiếp • sẵn sàng gửi lệnh")
            startPingTimer()
            requestPushAll()
        default:
            break
        }
    }

    private func handlePublish(header: UInt8, body: Data) {
        guard body.count >= 2 else { return }
        let topicLength = Int(body.uint16BE(at: 0))
        var payloadOffset = 2 + topicLength
        guard payloadOffset <= body.count else { return }
        let qos = (header >> 1) & 0x03
        if qos > 0 {
            guard payloadOffset + 2 <= body.count else { return }
            let incomingPacketID = body.uint16BE(at: payloadOffset)
            payloadOffset += 2
            sendPacket(Data([0x40, 0x02, UInt8(incomingPacketID >> 8), UInt8(incomingPacketID & 0xFF)]))
        }
        let payload = body.suffix(from: body.index(body.startIndex, offsetBy: payloadOffset))
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
        handleReport(root)
    }

    private func handleReport(_ root: [String: Any]) {
        if let print = root["print"] as? [String: Any] {
            confirmPendingIfMatched(section: print)
            updateSnapshot(from: print)
        }
        if let system = root["system"] as? [String: Any] {
            confirmPendingIfMatched(section: system)
        }
    }

    private func updateSnapshot(from report: [String: Any]) {
        var next = snapshotStorage
        var changed = false
        var externalRouteInReport = false
        func number(_ value: Any?) -> Int? {
            if let value = value as? NSNumber { return value.intValue }
            if let value = value as? String { return Int(value) }
            return nil
        }
        func hexadecimal(_ value: Any?) -> UInt64? {
            if let value = value as? NSNumber { return value.uint64Value }
            guard var text = value as? String else { return nil }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("0x") || text.hasPrefix("0X") { text.removeFirst(2) }
            return UInt64(text, radix: 16)
        }
        func update(_ key: String, _ field: WritableKeyPath<BambuDirectSnapshot, Int?>) {
            guard let value = number(report[key]) else { return }
            next[keyPath: field] = value
            changed = true
        }

        if let state = report["gcode_state"] as? String {
            next.printState = state.uppercased()
            if report["print_error"] == nil,
               (!next.hasActivePrintJob && next.printState != "ERROR" && next.printState != "FAILED" ||
                   !snapshotStorage.hasActivePrintJob && next.hasActivePrintJob) {
                next.printErrorCode = 0
            }
            changed = true
        }
        update("mc_percent", \.printPercent)
        update("layer_num", \.currentLayer)
        update("total_layer_num", \.totalLayers)
        update("mc_remaining_time", \.remainingMinutes)
        update("bed_temper", \.bedTemperature)
        update("bed_target_temper", \.bedTargetTemperature)
        update("spd_lvl", \.printSpeedLevel)
        update("stg_cur", \.printStage)

        if let epoch = number(report["gcode_start_time"]) {
            next.printStartedAt = epoch > 1_500_000_000
                ? Date(timeIntervalSince1970: TimeInterval(epoch))
                : nil
            changed = true
        }

        if let jobID = report["job_id"] as? String {
            next.jobID = jobID
            changed = true
        }
        if let subtaskID = report["subtask_id"] as? String {
            next.subtaskID = subtaskID
            changed = true
        } else if let subtaskID = number(report["subtask_id"]) {
            next.subtaskID = String(subtaskID)
            changed = true
        }

        if let extruder = report["extruder"] as? [String: Any],
           let entries = extruder["info"] as? [[String: Any]] {
            if let packedState = number(extruder["state"]) {
                let count = max(1, packedState & 0xF)
                let current = (packedState >> 4) & 0xF
                next.extruderCount = count
                next.currentExtruderID = current < count ? current : nil
                changed = true
            } else if !entries.isEmpty {
                next.extruderCount = max(1, entries.count)
                changed = true
            }

            var filamentByExtruder: [Int: Bool] = [:]
            var detectedExternalExtruder: Int?
            var detectedCurrentTray: String?
            for (index, entry) in entries.enumerated() {
                let id = number(entry["id"]) ?? index
                if let info = number(entry["info"]) {
                    // Bambu Studio's DevExtruderSystem uses bit 1 for the
                    // toolhead filament sensor (bit 2 is the buffer sensor).
                    filamentByExtruder[id] = ((info >> 1) & 1) != 0
                }
                if let packedSlot = number(entry["snow"]), packedSlot >= 0 {
                    let amsID = (packedSlot >> 8) & 0xFF
                    let slotID = packedSlot & 0xFF
                    if amsID == 253 || amsID == 254 {
                        detectedExternalExtruder = id
                        externalRouteInReport = true
                    } else if amsID < 253, slotID < 255 {
                        detectedCurrentTray = "\(amsID)-\(slotID)"
                    }
                }

                guard let packedTemperature = number(entry["temp"]), packedTemperature >= 0 else { continue }
                let actual = packedTemperature & 0xFFFF
                let target = (packedTemperature >> 16) & 0xFFFF
                if id == 0 {
                    next.nozzleTemperature = actual
                    next.nozzleTargetTemperature = target
                } else if id == 1 {
                    next.leftNozzleTemperature = actual
                    next.leftNozzleTargetTemperature = target
                }
                changed = true
            }
            if let detectedExternalExtruder {
                next.externalSpoolExtruderID = detectedExternalExtruder
                next.externalFilamentPresent = filamentByExtruder[detectedExternalExtruder]
                if externalRouteInReport { next.currentAMSTrayID = nil }
                changed = true
            } else if let configured = next.externalSpoolExtruderID,
                      let present = filamentByExtruder[configured] {
                next.externalFilamentPresent = present
                changed = true
            }
            if !filamentByExtruder.isEmpty {
                next.filamentPresentByExtruder = filamentByExtruder
                changed = true
            }
            if let detectedCurrentTray {
                next.currentAMSTrayID = detectedCurrentTray
                changed = true
            }
        } else if let switchState = number(report["hw_switch_state"]) {
            // Single-nozzle printers expose the same sensor as a top-level
            // field. 0 means empty, 1 means filament has reached the extruder.
            next.extruderCount = 1
            next.currentExtruderID = 0
            next.externalSpoolExtruderID = 0
            next.externalFilamentPresent = switchState == 1
            next.filamentPresentByExtruder[0] = switchState == 1
            changed = true
        }

        if externalRouteInReport {
            // extruder.info[].snow is the authoritative H2D route and can be
            // newer than the legacy ams.tray_now value in the same packet.
            next.currentAMSTrayID = nil
        }

        let virtualTrays: [[String: Any]] = {
            if let tray = report["vt_tray"] as? [String: Any] { return [tray] }
            return report["vt_tray"] as? [[String: Any]] ?? []
        }()
        for tray in virtualTrays {
            guard let id = number(tray["id"]) else { continue }
            if id == 254 {
                next.externalSpoolExtruderID = 0
                changed = true
            } else if id == 253 {
                next.externalSpoolExtruderID = 1
                changed = true
            }
        }

        if let ams = report["ams"] as? [String: Any] {
            let units = ams["ams"] as? [[String: Any]] ?? []
            let existenceBits = hexadecimal(ams["ams_exist_bits"])
            let trayExistenceBits = hexadecimal(ams["tray_exist_bits"])
            let hasReportedAMS = (existenceBits ?? 0) != 0 || !units.isEmpty
            next.hasAMS = hasReportedAMS

            if let trayNow = number(ams["tray_now"]) {
                if trayNow >= 0, trayNow < 253, next.extruderCount == 1 {
                    next.currentAMSTrayID = "\(trayNow >> 2)-\(trayNow & 0x3)"
                } else if trayNow >= 253 {
                    // 253/254 are virtual external spools; 255 means no AMS
                    // tray is feeding the nozzle. Never leave a stale AMS
                    // selection visible when the route has moved outside.
                    next.currentAMSTrayID = nil
                }
            }

            var trays: [BambuAMSTraySnapshot] = []
            for unit in units {
                guard let amsID = number(unit["id"]) else { continue }
                let humidityPercent = number(unit["humidity_raw"])
                    ?? number(unit["humidity_percent"])
                    ?? number(unit["humidity_pct"])
                if let humidityPercent, (0...100).contains(humidityPercent) {
                    next.amsHumidityPercentByUnit[amsID] = humidityPercent
                }
                let supportsDrying = unit["dry_time"] != nil ||
                    unit["dry_status"] != nil || humidityPercent != nil
                if supportsDrying {
                    next.amsDryerUnitID = next.amsDryerUnitID ?? amsID
                    let dryMinutes = number(unit["dry_time"])
                    if let dryMinutes {
                        next.amsDryingRemainingMinutes = max(0, dryMinutes)
                        next.amsDrying = dryMinutes > 0
                    }
                    if let dryStatus = number(unit["dry_status"]), dryStatus >= 2 {
                        next.amsDrying = true
                    }
                    if let temperature = number(unit["temp"])
                        ?? number(unit["dry_temp"])
                        ?? number(unit["dryer_temp"]), temperature >= 30 {
                        next.amsDryingTemperature = temperature
                    }
                }
                var boundExtruder: Int?
                if let info = hexadecimal(unit["info"]) {
                    let candidate = Int((info >> 8) & 0xF)
                    if candidate != 0xE { boundExtruder = candidate }
                }
                for tray in unit["tray"] as? [[String: Any]] ?? [] {
                    guard let slotID = number(tray["id"]) else { continue }
                    let bitIndex = amsID >= 128 ? 16 + amsID - 128 + slotID : amsID * 4 + slotID
                    let present = trayExistenceBits.map { ($0 & (UInt64(1) << UInt64(bitIndex))) != 0 }
                        ?? !(tray["tray_type"] as? String ?? "").isEmpty
                    let material = (tray["tray_type"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .uppercased()
                    let color = (tray["tray_color"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let dryingTemperature = number(tray["drying_temp"])
                    let dryingHours = number(tray["drying_time"])
                    trays.append(BambuAMSTraySnapshot(
                        amsID: amsID,
                        slotID: slotID,
                        material: material,
                        colorHex: color,
                        isPresent: present,
                        extruderID: boundExtruder,
                        dryingTemperature: dryingTemperature,
                        dryingHours: dryingHours
                    ))
                }
            }
            next.amsTrays = trays.sorted {
                $0.amsID == $1.amsID ? $0.slotID < $1.slotID : $0.amsID < $1.amsID
            }
            changed = true
        }

        if next.hasActivePrintJob,
           next.currentAMSTrayID == nil,
           (next.externalSpoolExtruderID != nil || next.extruderCount == 1) {
            // The active route is authoritative while material is physically
            // being consumed. Some firmwares briefly publish a zero sensor bit
            // in an incremental packet even though the external spool is the
            // source of the running job. P2S can omit externalSpoolExtruderID
            // from incremental packets, so its single extruder is route 0.
            let externalID = next.externalSpoolExtruderID ?? 0
            next.externalSpoolExtruderID = externalID
            next.externalFilamentPresent = true
            next.filamentPresentByExtruder[externalID] = true
            changed = true
        }

        if let lights = report["lights_report"] as? [[String: Any]],
           let chamber = lights.first(where: { ($0["node"] as? String) == "chamber_light" }),
           let mode = chamber["mode"] as? String {
            next.chamberLightOn = mode.lowercased() == "on"
            changed = true
        }

        if report["extruder"] == nil, configuration?.isDualNozzle == false {
            update("nozzle_temper", \.nozzleTemperature)
            update("nozzle_target_temper", \.nozzleTargetTemperature)
        }

        if let error = number(report["print_error"]), error >= 0 {
            next.printErrorCode = UInt32(truncatingIfNeeded: error)
            if error == 0 { next.printerErrorText = "" }
            changed = true
        }
        if let text = printerErrorDetail(in: report), !text.isEmpty,
           (next.printErrorCode ?? 0) != 0 {
            next.printerErrorText = text
            changed = true
        }
        guard changed else { return }
        let previous = snapshotStorage
        let now = Date()
        let contentChanged = next != previous
        let freshnessDue = now.timeIntervalSince(previous.receivedAt ?? .distantPast) >= 10
        guard contentChanged || freshnessDue else { return }
        next.receivedAt = now
        snapshotStorage = next
        refreshActivePrompt(for: next)

        let urgent = next.printState != previous.printState ||
            next.printErrorCode != previous.printErrorCode ||
            next.printStage != previous.printStage ||
            next.currentAMSTrayID != previous.currentAMSTrayID ||
            next.externalFilamentPresent != previous.externalFilamentPresent ||
            next.chamberLightOn != previous.chamberLightOn ||
            next.amsDrying != previous.amsDrying ||
            next.amsHumidityPercentByUnit != previous.amsHumidityPercentByUnit ||
            next.amsTrays != previous.amsTrays
        let minimumPublishInterval: TimeInterval = 1.25
        let elapsed = now.timeIntervalSince(lastSnapshotPublishedAt)
        if urgent || elapsed >= minimumPublishInterval {
            pendingSnapshotPublication?.cancel()
            pendingSnapshotPublication = nil
            lastSnapshotPublishedAt = now
            let publishedSnapshot = next
            DispatchQueue.main.async { [weak self] in self?.snapshot = publishedSnapshot }
        } else if pendingSnapshotPublication == nil {
            let expectedGeneration = generation
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.generation == expectedGeneration else { return }
                self.pendingSnapshotPublication = nil
                self.lastSnapshotPublishedAt = Date()
                let publishedSnapshot = self.snapshotStorage
                DispatchQueue.main.async { [weak self] in self?.snapshot = publishedSnapshot }
            }
            pendingSnapshotPublication = item
            queue.asyncAfter(
                deadline: .now() + max(0.05, minimumPublishInterval - elapsed),
                execute: item
            )
        }
    }

    private func refreshActivePrompt(for snapshot: BambuDirectSnapshot) {
        if snapshot.printErrorCode == 0,
           snapshot.printStage != 22, snapshot.printStage != 24,
           let active = activePromptStorage,
           active.kind == .filamentLoad || active.kind == .filamentUnload {
            activeFilamentOperation = nil
            dismissedPromptID = nil
            publishPrompt(nil)
        }

        if snapshot.printStage != 22, snapshot.printStage != 24,
           snapshot.printErrorCode == 0,
           dismissedPromptID?.hasPrefix("filament-") == true {
            activeFilamentOperation = nil
            dismissedPromptID = nil
        }

        if snapshot.printStage == 22 {
            activeFilamentOperation = .filamentUnload
        } else if snapshot.printStage == 24 {
            activeFilamentOperation = .filamentLoad
        }

        // Reconstruct the interactive dialog even when SE is opened after the
        // operation began and the incremental stage packet is already gone.
        if snapshot.isManualFilamentLoadRequest {
            activeFilamentOperation = .filamentLoad
        } else if snapshot.isManualFilamentUnloadRequest {
            activeFilamentOperation = .filamentUnload
        }

        // During manual load/unload the printer reports a print_error as the
        // backing code for its interactive dialog (for example 07FEC003).
        // It is not a generic print failure. Preserve the operation type so
        // the iPhone exposes the same `done`/`resume` actions as Bambu Studio.
        if activeFilamentOperation != nil, (snapshot.printErrorCode ?? 0) != 0 {
            publishFilamentPrompt()
            return
        }

        if activeFilamentOperation != nil, snapshot.printErrorCode == 0,
           activePromptStorage?.kind != .printerError {
            publishPrompt(nil)
            return
        }

        if let code = snapshot.printErrorCode, code != 0 {
            let id = "error-\(String(format: "%08X", code))-\(snapshot.jobID)-\(snapshot.subtaskID)"
            publishPrompt(BambuRemotePrompt(
                id: id,
                kind: .printerError,
                errorCode: code,
                detail: snapshot.printerErrorText.isEmpty ? nil : snapshot.printerErrorText
            ))
            return
        }

        if activePromptStorage?.kind == .printerError {
            dismissedPromptID = nil
            publishPrompt(nil)
        }
    }

    private func publishFilamentPrompt() {
        guard let kind = activeFilamentOperation else { return }
        let id = "filament-\(filamentOperationNumber)-\(kind == .filamentLoad ? "load" : "unload")"
        publishPrompt(BambuRemotePrompt(id: id, kind: kind, errorCode: nil, detail: nil))
    }

    private func printerErrorDetail(in report: [String: Any]) -> String? {
        for key in ["error_msg", "error_message", "reason", "message"] {
            if let value = report[key] as? String {
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, !["ok", "good", "success"].contains(text.lowercased()) {
                    return text
                }
            }
        }
        if let entries = report["hms"] as? [[String: Any]] {
            for entry in entries {
                for key in ["message", "msg", "description", "reason"] {
                    if let value = entry[key] as? String,
                       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return value.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
        return nil
    }

    private func publishPrompt(_ prompt: BambuRemotePrompt?) {
        if let prompt, prompt.id == dismissedPromptID { return }
        guard prompt != activePromptStorage else { return }
        activePromptStorage = prompt
        DispatchQueue.main.async { [weak self] in self?.activePrompt = prompt }
    }

    private func dismissCurrentPrompt() {
        guard let prompt = activePromptStorage else { return }
        dismissedPromptID = prompt.id
        publishPrompt(nil)
    }

    private func errorActionFields(for prompt: BambuRemotePrompt) -> [String: Any] {
        var fields: [String: Any] = ["param": "reserve"]
        if let code = prompt.errorCode {
            // Bambu Studio calls std::to_string(error_code) for HMS actions;
            // the protocol expects the decimal value, not the UI's hex label.
            fields["err"] = String(code)
        }
        if !snapshotStorage.jobID.isEmpty {
            fields["job_id"] = snapshotStorage.jobID
        }
        return fields
    }

    private func confirmPendingIfMatched(section: [String: Any]) {
        guard let pending else { return }
        let sequence = String(describing: section["sequence_id"] ?? "")
        let command = (section["command"] as? String) ?? ""
        guard sequence == pending.sequence, command == pending.mqttCommand else { return }
        if let result = section["result"] as? String {
            let normalized = result.lowercased()
            if normalized == "success" || normalized == "ok" {
                completePending(success: true, detail: "Máy in đã xác nhận: \(pending.actionName)")
            } else {
                let reason = (section["reason"] as? String) ?? result
                completePending(success: false, detail: humanReadablePrinterError(reason))
            }
        } else if let result = section["result"] as? NSNumber {
            completePending(
                success: result.intValue == 0,
                detail: result.intValue == 0
                    ? "Máy in đã xác nhận: \(pending.actionName)"
                    : "Máy in từ chối lệnh (mã \(result.intValue))"
            )
        }
    }

    private func send(
        section: String,
        command: String,
        fields: [String: Any],
        actionName: String,
        onSuccess: (() -> Void)? = nil
    ) {
        queue.async { [weak self] in
            guard let self, let configuration = self.configuration, self.connection != nil else {
                self?.publishFailure("Chưa kết nối được kênh điều khiển trực tiếp")
                return
            }
            guard self.pending == nil else {
                self.publishFailure("Hãy chờ lệnh trước được máy in xác nhận")
                return
            }
            self.sequenceNumber &+= 1
            let sequence = String(self.sequenceNumber)
            var commandBody = fields
            commandBody["sequence_id"] = sequence
            commandBody["command"] = command
            let root: [String: Any] = [section: commandBody]
            guard let data = try? JSONSerialization.data(withJSONObject: root),
                  let json = String(data: data, encoding: .utf8) else {
                self.publishFailure("Không tạo được gói lệnh MQTT")
                return
            }
            self.pending = PendingCommand(
                sequence: sequence,
                mqttCommand: command,
                actionName: actionName,
                onSuccess: onSuccess
            )
            self.publishPending("Đang gửi trực tiếp: \(actionName)…")
            self.sendPacket(self.publishPacket(
                topic: "device/\(configuration.serial)/request",
                payload: json,
                qos1: true
            ))
            let activeGeneration = self.generation
            self.queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self, self.generation == activeGeneration,
                      self.pending?.sequence == sequence else { return }
                self.pending = nil
                self.publishFailure(
                    "Máy in không xác nhận lệnh • bật LAN Mode và Developer Mode"
                )
            }
        }
    }

    private func requestPushAll() {
        guard let configuration, connection != nil else { return }
        lastFullStatusRequest = Date()
        sequenceNumber &+= 1
        let root: [String: Any] = [
            "pushing": [
                "sequence_id": String(sequenceNumber),
                "command": "pushall",
                "version": 1,
                "push_target": 1
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let json = String(data: data, encoding: .utf8) else { return }
        sendPacket(publishPacket(
            topic: "device/\(configuration.serial)/request",
            payload: json,
            qos1: false
        ))
    }

    private func startPingTimer() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 12, repeating: 12)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.sendPacket(Data([0xC0, 0x00]))
            let missingData = self.snapshotStorage.printState.isEmpty ||
                self.snapshotStorage.bedTemperature == nil ||
                self.snapshotStorage.hasCriticalError ||
                (self.configuration?.isDualNozzle == true
                    ? self.snapshotStorage.leftNozzleTemperature == nil
                    : self.snapshotStorage.nozzleTemperature == nil)
            let refreshInterval: TimeInterval = missingData ? 24 : 60
            if Date().timeIntervalSince(self.lastFullStatusRequest) >= refreshInterval {
                self.requestPushAll()
            }
        }
        pingTimer = timer
        timer.resume()
    }

    private func sendPacket(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.failConnection("Không gửi được MQTT (\(error.localizedDescription))")
            }
        })
    }

    private func nextPacketID() -> UInt16 {
        packetID &+= 1
        if packetID == 0 { packetID = 1 }
        return packetID
    }

    private func connectPacket(configuration: Configuration) -> Data {
        var body = Data()
        body.appendMQTTString("MQTT")
        body.append(0x04)
        body.append(0xC2) // username, password, clean session
        body.append(contentsOf: [0x00, 0x1E])
        body.appendMQTTString("SE-iPhone-\(UUID().uuidString.prefix(12))")
        body.appendMQTTString("bblp")
        body.appendMQTTString(configuration.accessCode)
        return mqttPacket(header: 0x10, body: body)
    }

    private func subscribePacket(topic: String) -> Data {
        let id = nextPacketID()
        var body = Data([UInt8(id >> 8), UInt8(id & 0xFF)])
        body.appendMQTTString(topic)
        body.append(0x00)
        return mqttPacket(header: 0x82, body: body)
    }

    private func publishPacket(topic: String, payload: String, qos1: Bool) -> Data {
        var body = Data()
        body.appendMQTTString(topic)
        if qos1 {
            let id = nextPacketID()
            body.append(contentsOf: [UInt8(id >> 8), UInt8(id & 0xFF)])
        }
        body.append(Data(payload.utf8))
        return mqttPacket(header: qos1 ? 0x32 : 0x30, body: body)
    }

    private func mqttPacket(header: UInt8, body: Data) -> Data {
        var packet = Data([header])
        var remaining = body.count
        repeat {
            var digit = remaining % 128
            remaining /= 128
            if remaining > 0 { digit |= 0x80 }
            packet.append(UInt8(digit))
        } while remaining > 0
        packet.append(body)
        return packet
    }

    private func completePending(success: Bool, detail: String) {
        let continuation = success ? pending?.onSuccess : nil
        pending = nil
        DispatchQueue.main.async { [weak self] in
            self?.isPending = false
            self?.lastSucceeded = success
            self?.statusText = detail
        }
        requestPushAll()
        continuation?()
    }

    private func failConnection(_ text: String) {
        connection?.cancel()
        connection = nil
        pingTimer?.cancel()
        pingTimer = nil
        pending = nil
        publishFailure(text)
        let failedGeneration = generation
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.generation == failedGeneration,
                  self.configuration != nil, self.connection == nil else { return }
            self.connect()
        }
    }

    private func humanReadablePrinterError(_ reason: String) -> String {
        let lowered = reason.lowercased()
        if lowered.contains("84033543") || lowered.contains("auth") || lowered.contains("sign") {
            return "Máy in chặn lệnh • bật LAN Mode > Developer Mode"
        }
        return "Máy in từ chối lệnh • \(reason)"
    }

    private func publishReady(_ ready: Bool, text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.isReady = ready
            self?.isPending = false
            self?.statusText = text
        }
    }

    private func publishPending(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.isPending = true
            self?.lastSucceeded = nil
            self?.statusText = text
        }
    }

    private func publishWaitingForPrinter() {
        DispatchQueue.main.async { [weak self] in
            guard self?.isPending == true else { return }
            self?.statusText = "MQTT đã nhận gói lệnh • chờ máy in xác nhận…"
        }
    }

    private func publishFailure(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isReady = self.connection != nil
            self.isPending = false
            self.lastSucceeded = false
            self.statusText = text
        }
    }

}

private extension Data {
    mutating func appendMQTTString(_ value: String) {
        let bytes = Data(value.utf8)
        append(UInt8((bytes.count >> 8) & 0xFF))
        append(UInt8(bytes.count & 0xFF))
        append(bytes)
    }

    func uint16BE(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 1 < count else { return 0 }
        let first = self[index(startIndex, offsetBy: offset)]
        let second = self[index(startIndex, offsetBy: offset + 1)]
        return (UInt16(first) << 8) | UInt16(second)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 3 < count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { value, byteOffset in
            let byte = self[index(startIndex, offsetBy: offset + byteOffset)]
            return value | (UInt32(byte) << UInt32(byteOffset * 8))
        }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

// The retired 3MF/FTPS object loader is intentionally excluded from the app.
// Keeping the old implementation below the compile guard makes the rollback
// history readable without shipping or executing the unreliable skip flow.
#if false
private enum BambuObjectError: LocalizedError {
    case invalidArchive
    case missingSliceInfo
    case noObjects

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "file ZIP/3MF không hợp lệ"
        case .missingSliceInfo: return "3MF thiếu Metadata/slice_info.config"
        case .noObjects: return "không tìm thấy danh sách vật thể"
        }
    }
}

private enum Bambu3MFObjectParser {
    static func parse(
        _ data: Data,
        gcodeFile: String,
        skippedObjectIDs: Set<Int>
    ) throws -> [BambuPrintableObject] {
        let archive = try Archive(data: data, accessMode: .read)
        guard let sliceEntry = archive["Metadata/slice_info.config"] else {
            throw BambuObjectError.missingSliceInfo
        }
        var sliceData = Data()
        _ = try archive.extract(sliceEntry) { sliceData.append($0) }
        let parser = BambuSliceInfoParser(targetPlate: plateNumber(in: gcodeFile))
        let xml = XMLParser(data: sliceData)
        xml.delegate = parser
        guard xml.parse() else { throw BambuObjectError.invalidArchive }
        var objects = parser.selectedObjects
        guard !objects.isEmpty else { throw BambuObjectError.noObjects }

        let plateNumber = parser.selectedPlateNumber
        if let jsonEntry = archive["Metadata/plate_\(plateNumber).json"] {
            var jsonData = Data()
            _ = try archive.extract(jsonEntry) { jsonData.append($0) }
            applyPositions(from: jsonData, to: &objects)
        }
        for index in objects.indices {
            objects[index].isSkipped = objects[index].isSkipped || skippedObjectIDs.contains(objects[index].id)
        }
        return objects
    }

    private static func plateNumber(in gcodeFile: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: "plate[_-](\\d+)", options: .caseInsensitive),
              let match = expression.firstMatch(
                in: gcodeFile,
                range: NSRange(gcodeFile.startIndex..., in: gcodeFile)
              ),
              let range = Range(match.range(at: 1), in: gcodeFile) else { return nil }
        return Int(gcodeFile[range])
    }

    private static func applyPositions(from data: Data, to objects: inout [BambuPrintableObject]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let boxes = root["bbox_objects"] as? [[String: Any]] else { return }
        var positions: [String: [(Double, Double)]] = [:]
        for item in boxes {
            guard let name = item["name"] as? String,
                  let values = item["bbox"] as? [NSNumber], values.count >= 4 else { continue }
            let center = (
                (values[0].doubleValue + values[2].doubleValue) / 2,
                (values[1].doubleValue + values[3].doubleValue) / 2
            )
            positions[name, default: []].append(center)
        }
        for index in objects.indices {
            guard var available = positions[objects[index].name], !available.isEmpty else { continue }
            let center = available.removeFirst()
            positions[objects[index].name] = available
            objects[index].centerX = center.0
            objects[index].centerY = center.1
        }
    }
}

private final class BambuSliceInfoParser: NSObject, XMLParserDelegate {
    private let targetPlate: Int?
    private var currentPlateNumber = 1
    private var currentObjects: [BambuPrintableObject] = []
    private var plates: [(number: Int, objects: [BambuPrintableObject])] = []

    init(targetPlate: Int?) {
        self.targetPlate = targetPlate
    }

    var selectedPlateNumber: Int {
        if let targetPlate, plates.contains(where: { $0.number == targetPlate }) { return targetPlate }
        return plates.first?.number ?? 1
    }

    var selectedObjects: [BambuPrintableObject] {
        let target = selectedPlateNumber
        return plates.first(where: { $0.number == target })?.objects ?? plates.first?.objects ?? []
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName.lowercased() {
        case "plate":
            currentPlateNumber = plates.count + 1
            currentObjects = []
        case "metadata":
            if attributeDict["key"] == "index", let value = attributeDict["value"], let number = Int(value) {
                currentPlateNumber = number
            }
        case "object":
            guard let rawID = attributeDict["identify_id"], let id = Int(rawID) else { return }
            let name = attributeDict["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            currentObjects.append(BambuPrintableObject(
                id: id,
                name: (name?.isEmpty == false ? name! : "Vật thể \(currentObjects.count + 1)"),
                centerX: nil,
                centerY: nil,
                isSkipped: attributeDict["skipped"]?.lowercased() == "true"
            ))
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName.lowercased() == "plate" else { return }
        plates.append((currentPlateNumber, currentObjects))
        currentObjects = []
    }
}

private enum BambuArchiveError: LocalizedError {
    case tunnel(String)

    var errorDescription: String? {
        switch self {
        case .tunnel(let detail): return detail
        }
    }
}

private enum BambuArchiveLimits {
    static let maximumBytes = 48 * 1_024 * 1_024
}

/// P2S and newer Bambu firmware expose the current model cache through the
/// TLS file channel on port 6000. Older firmware uses implicit FTPS on 990.
/// Try the native channel first and retain FTPS as a read-only fallback.
private final class BambuArchiveDownload {
    private let host: String
    private let accessCode: String
    private let candidatePaths: [String]
    private let queue: DispatchQueue
    private let completion: (Result<Data, Error>) -> Void
    private var tunnel: BambuPort6000Download?
    private var ftps: BambuFTPSDownload?
    private var tunnelFailure = ""
    private var completed = false

    init(
        host: String,
        accessCode: String,
        candidatePaths: [String],
        queue: DispatchQueue,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        self.host = host
        self.accessCode = accessCode
        self.candidatePaths = candidatePaths
        self.queue = queue
        self.completion = completion
    }

    static func candidatePaths(
        gcodeFile: String,
        subtaskName: String,
        archiveFile: String
    ) -> [String] {
        var rawNames = [archiveFile, gcodeFile, subtaskName]
        let task = subtaskName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !task.isEmpty {
            rawNames += [task + ".gcode.3mf", task + ".3mf"]
            let underscore = task.replacingOccurrences(of: " ", with: "_")
            rawNames += [underscore + ".gcode.3mf", underscore + ".3mf"]
        }

        var names: [String] = []
        for raw in rawNames {
            let decoded = raw.removingPercentEncoding ?? raw
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let filename = (trimmed as NSString).lastPathComponent
            for value in [trimmed, filename] where !value.isEmpty {
                if !names.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                    names.append(value)
                }
            }
            if !filename.lowercased().hasSuffix(".3mf"),
               !filename.lowercased().hasSuffix(".gcode") {
                for suffix in [".gcode.3mf", ".3mf"] {
                    let value = filename + suffix
                    if !names.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                        names.append(value)
                    }
                }
            }
        }

        var paths: [String] = []
        for name in names {
            let clean = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !clean.isEmpty else { continue }
            for prefix in ["/", "/cache/", "/model/", "/data/"] {
                let path = prefix + clean
                if !paths.contains(where: { $0.caseInsensitiveCompare(path) == .orderedSame }) {
                    paths.append(path)
                }
            }
        }
        return paths
    }

    func start() {
        guard !candidatePaths.isEmpty else {
            finish(.failure(BambuFTPError.noCandidate))
            return
        }
        let tunnel = BambuPort6000Download(
            host: host,
            accessCode: accessCode,
            candidatePaths: candidatePaths,
            queue: queue
        ) { [weak self] result in
            guard let self, !self.completed else { return }
            switch result {
            case .success:
                self.finish(result)
            case .failure(let error):
                self.tunnelFailure = error.localizedDescription
                self.startFTPSFallback()
            }
        }
        self.tunnel = tunnel
        tunnel.start()
    }

    func cancel() {
        completed = true
        tunnel?.cancel()
        ftps?.cancel()
    }

    private func startFTPSFallback() {
        tunnel?.cancel()
        tunnel = nil
        let ftps = BambuFTPSDownload(
            host: host,
            accessCode: accessCode,
            candidatePaths: candidatePaths,
            queue: queue
        ) { [weak self] result in
            guard let self, !self.completed else { return }
            switch result {
            case .success:
                self.finish(result)
            case .failure(let error):
                let detail = self.tunnelFailure.isEmpty
                    ? error.localizedDescription
                    : "kênh file P2S: \(self.tunnelFailure); FTPS: \(error.localizedDescription)"
                self.finish(.failure(BambuArchiveError.tunnel(detail)))
            }
        }
        self.ftps = ftps
        ftps.start()
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !completed else { return }
        completed = true
        tunnel?.cancel()
        ftps?.cancel()
        completion(result)
    }
}

private final class BambuPort6000Download {
    private struct RemoteFile {
        let name: String
        let path: String
        let size: Int
    }

    private enum Stage {
        case login, setup, listing, downloading
    }

    private static let clientLoginMagic: UInt32 = 0x0101013F
    private static let serverLoginMagic: UInt32 = 0x0001013F
    private static let clientRPCMagic: UInt32 = 0x0102013F
    private static let serverRPCMagic: UInt32 = 0x0002013F

    private let host: String
    private let accessCode: String
    private let candidatePaths: [String]
    private let queue: DispatchQueue
    private let completion: (Result<Data, Error>) -> Void
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var downloaded = Data()
    private var remoteFiles: [RemoteFile] = []
    private let storages = ["emmc", "internal", "udisk", ""]
    private var storageIndex = 0
    private var frameSequence = UInt32.random(in: 1...0x7FFF_FFFF)
    private var commandSequence: UInt32 = 1
    private var stage: Stage = .login
    private var expectedSize = 0
    private var completed = false

    init(
        host: String,
        accessCode: String,
        candidatePaths: [String],
        queue: DispatchQueue,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        self.host = host
        self.accessCode = accessCode
        self.candidatePaths = candidatePaths
        self.queue = queue
        self.completion = completion
    }

    func start() {
        guard let port = NWEndpoint.Port(rawValue: 6000) else {
            finish(.failure(BambuArchiveError.tunnel("cổng 6000 không hợp lệ")))
            return
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, complete in complete(true) },
            queue
        )
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, true)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: NWParameters(tls: tls, tcp: tcp)
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.completed else { return }
            switch state {
            case .ready:
                self.receive()
                self.sendLogin()
            case .failed(let error):
                self.finish(.failure(BambuArchiveError.tunnel(error.localizedDescription)))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 16) { [weak self] in
            guard let self, !self.completed, self.stage != .downloading else { return }
            self.finish(.failure(BambuArchiveError.tunnel("kênh 6000 hết thời gian chờ")))
        }
    }

    func cancel() {
        completed = true
        connection?.cancel()
    }

    private func sendLogin() {
        var payload = Data(repeating: 0, count: 16)
        let username = Data("bblp".utf8.prefix(8))
        let password = Data(accessCode.utf8.prefix(8))
        payload.replaceSubrange(0..<username.count, with: username)
        payload.replaceSubrange(8..<(8 + password.count), with: password)
        sendFrame(magic: Self.clientLoginMagic, payload: payload)
    }

    private func sendSetup() {
        stage = .setup
        sendJSON([
            "sequence": 0,
            "mtype": 12_291,
            "req": [
                "t_av": 1,
                "mtype": 12_289,
                "peer_t": 3,
                "pid": String(format: "%08x", frameSequence),
                "ver": "02.03.00.00"
            ]
        ])
    }

    private func requestNextStorage() {
        guard storageIndex < storages.count else {
            startBestDownload()
            return
        }
        stage = .listing
        let sequence = commandSequence
        commandSequence &+= 1
        var request: [String: Any] = [
            "type": "model",
            "api_version": 2,
            "notify": "DETAIL"
        ]
        let storage = storages[storageIndex]
        if !storage.isEmpty { request["storage"] = storage }
        sendJSON([
            "mtype": 12_289,
            "cmdtype": 1,
            "sequence": Int(sequence),
            "req": request
        ])
    }

    private func startBestDownload() {
        guard let file = bestRemoteFile() else {
            finish(.failure(BambuArchiveError.tunnel("không thấy file 3MF của bản in hiện tại")))
            return
        }
        guard file.size <= 0 || file.size <= BambuArchiveLimits.maximumBytes else {
            finish(.failure(BambuFTPError.tooLarge))
            return
        }
        stage = .downloading
        downloaded.removeAll(keepingCapacity: true)
        expectedSize = file.size
        let sequence = commandSequence
        commandSequence &+= 1
        var request: [String: Any] = ["offset": 0]
        if file.path.hasPrefix("/") || file.path.hasPrefix("mem:") {
            request["path"] = file.path
        } else {
            request["file"] = file.name
        }
        sendJSON([
            "mtype": 12_289,
            "cmdtype": 4,
            "sequence": Int(sequence),
            "req": request
        ])
        queue.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, !self.completed, self.stage == .downloading else { return }
            self.finish(.failure(BambuArchiveError.tunnel("tải file 3MF hết thời gian chờ")))
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { [weak self] data, _, complete, error in
            guard let self, !self.completed else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.consumeFrames()
            }
            if let error {
                self.finish(.failure(BambuArchiveError.tunnel(error.localizedDescription)))
                return
            }
            if complete {
                self.finish(.failure(BambuArchiveError.tunnel("máy in đã đóng kênh file")))
                return
            }
            self.receive()
        }
    }

    private func consumeFrames() {
        while receiveBuffer.count >= 16 {
            let payloadLength = Int(receiveBuffer.uint32LE(at: 0))
            guard payloadLength >= 0,
                  payloadLength <= BambuArchiveLimits.maximumBytes + 1_024 * 1_024 else {
                finish(.failure(BambuArchiveError.tunnel("khung dữ liệu file không hợp lệ")))
                return
            }
            let frameLength = 16 + payloadLength
            guard receiveBuffer.count >= frameLength else { return }
            let magic = receiveBuffer.uint32LE(at: 4)
            let payloadStart = receiveBuffer.index(receiveBuffer.startIndex, offsetBy: 16)
            let payloadEnd = receiveBuffer.index(payloadStart, offsetBy: payloadLength)
            let payload = Data(receiveBuffer[payloadStart..<payloadEnd])
            receiveBuffer.removeFirst(frameLength)
            handleFrame(magic: magic, payload: payload)
            if completed { return }
        }
    }

    private func handleFrame(magic: UInt32, payload: Data) {
        switch stage {
        case .login:
            guard magic == Self.serverLoginMagic else { return }
            sendSetup()
        case .setup:
            guard magic == Self.serverRPCMagic else { return }
            storageIndex = 0
            requestNextStorage()
        case .listing:
            guard magic == Self.serverRPCMagic else { return }
            if let (json, _) = splitJSONAndBinary(payload),
               let object = try? JSONSerialization.jsonObject(with: json) {
                collectRemoteFiles(from: object)
            }
            storageIndex += 1
            requestNextStorage()
        case .downloading:
            guard magic == Self.serverRPCMagic else { return }
            handleDownloadPayload(payload)
        }
    }

    private func handleDownloadPayload(_ payload: Data) {
        guard let (jsonData, binary) = splitJSONAndBinary(payload),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            downloaded.append(payload)
            validateDownloadLimit()
            return
        }
        let reply = root["reply"] as? [String: Any]
        let memoryParameterSize = (reply?["mem_dl_param_size"] as? NSNumber)?.intValue
            ?? Int((reply?["mem_dl_param_size"] as? String) ?? "")
            ?? 0
        if !binary.isEmpty, memoryParameterSize == 0 {
            downloaded.append(binary)
            validateDownloadLimit()
        }
        let rawResult = root["result"] ?? reply?["result"]
        let result = (rawResult as? NSNumber)?.intValue
            ?? Int((rawResult as? String) ?? "")
        if let result, result < 0 {
            let reason = (root["reason"] as? String)
                ?? (reply?["reason"] as? String)
                ?? "máy in từ chối tải file"
            finish(.failure(BambuArchiveError.tunnel(reason)))
            return
        }
        if let result, result != 0, result != 1 {
            finish(.failure(BambuArchiveError.tunnel("máy in trả mã tải file \(result)")))
            return
        }
        if result == 0 || (expectedSize > 0 && downloaded.count >= expectedSize) {
            if let total = (reply?["total"] as? NSNumber)?.intValue,
               total > 0, downloaded.count != total {
                finish(.failure(BambuArchiveError.tunnel(
                    "file 3MF nhận thiếu dữ liệu (\(downloaded.count)/\(total) byte)"
                )))
                return
            }
            guard downloaded.count >= 4,
                  downloaded[downloaded.startIndex] == 0x50,
                  downloaded[downloaded.index(after: downloaded.startIndex)] == 0x4B else {
                finish(.failure(BambuArchiveError.tunnel("dữ liệu nhận được không phải file 3MF")))
                return
            }
            finish(.success(downloaded))
        }
    }

    private func validateDownloadLimit() {
        if downloaded.count > BambuArchiveLimits.maximumBytes {
            finish(.failure(BambuFTPError.tooLarge))
        }
    }

    private func collectRemoteFiles(from value: Any) {
        if let dictionary = value as? [String: Any] {
            let name = (dictionary["name"] as? String)
                ?? (dictionary["file"] as? String)
                ?? ""
            let path = (dictionary["path"] as? String) ?? name
            if (name.lowercased().hasSuffix(".3mf") || path.lowercased().hasSuffix(".3mf")),
               !path.isEmpty {
                let size = (dictionary["size"] as? NSNumber)?.intValue ?? 0
                if !remoteFiles.contains(where: { $0.path.caseInsensitiveCompare(path) == .orderedSame }) {
                    remoteFiles.append(RemoteFile(
                        name: name.isEmpty ? (path as NSString).lastPathComponent : name,
                        path: path,
                        size: size
                    ))
                }
            }
            for child in dictionary.values { collectRemoteFiles(from: child) }
        } else if let array = value as? [Any] {
            for child in array { collectRemoteFiles(from: child) }
        }
    }

    private func bestRemoteFile() -> RemoteFile? {
        let candidates = candidatePaths.map(normalizedPath)
        let candidateNames = candidates.map { ($0 as NSString).lastPathComponent }
        return remoteFiles
            .map { file -> (RemoteFile, Int) in
                let path = normalizedPath(file.path)
                let name = (normalizedPath(file.name) as NSString).lastPathComponent.lowercased()
                var score = 0
                for (index, candidate) in candidates.enumerated() {
                    if path == candidate { score = max(score, 1_000 - index) }
                    if name == candidateNames[index] { score = max(score, 900 - index) }
                }
                return (file, score)
            }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }

    private func normalizedPath(_ value: String) -> String {
        (value.removingPercentEncoding ?? value)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    private func splitJSONAndBinary(_ payload: Data) -> (Data, Data)? {
        guard payload.first == 0x7B else { return nil }
        let start = payload.startIndex
        var depth = 0
        var inString = false
        var escaped = false
        for offset in 0..<payload.count {
            let index = payload.index(start, offsetBy: offset)
            let byte = payload[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }
            if byte == 0x22 {
                inString = true
            } else if byte == 0x7B {
                depth += 1
            } else if byte == 0x7D {
                depth -= 1
                if depth == 0 {
                    let jsonEnd = payload.index(after: index)
                    let json = Data(payload[start..<jsonEnd])
                    var binaryStart = jsonEnd
                    if payload.distance(from: binaryStart, to: payload.endIndex) >= 2,
                       payload[binaryStart] == 0x0A,
                       payload[payload.index(after: binaryStart)] == 0x0A {
                        binaryStart = payload.index(binaryStart, offsetBy: 2)
                    } else if payload.distance(from: binaryStart, to: payload.endIndex) >= 4 {
                        let separatorEnd = payload.index(binaryStart, offsetBy: 4)
                        if Array(payload[binaryStart..<separatorEnd]) == [0x0D, 0x0A, 0x0D, 0x0A] {
                            binaryStart = separatorEnd
                        }
                    }
                    let binary = binaryStart < payload.endIndex
                        ? Data(payload[binaryStart..<payload.endIndex])
                        : Data()
                    return (json, binary)
                }
            }
        }
        return nil
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else {
            finish(.failure(BambuArchiveError.tunnel("không tạo được yêu cầu file")))
            return
        }
        sendFrame(magic: Self.clientRPCMagic, payload: payload)
    }

    private func sendFrame(magic: UInt32, payload: Data) {
        var frame = Data()
        frame.appendUInt32LE(UInt32(payload.count))
        frame.appendUInt32LE(magic)
        frame.appendUInt32LE(frameSequence)
        frame.appendUInt32LE(0)
        frame.append(payload)
        frameSequence &+= 1
        connection?.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finish(.failure(BambuArchiveError.tunnel(error.localizedDescription)))
            }
        })
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !completed else { return }
        completed = true
        connection?.cancel()
        completion(result)
    }
}

private enum BambuFTPError: LocalizedError {
    case noCandidate
    case rejected(String)
    case connection(String)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .noCandidate: return "không tìm thấy file bản in trên bộ nhớ máy"
        case .rejected(let reply): return reply
        case .connection(let detail): return detail
        case .tooLarge: return "file 3MF lớn hơn giới hạn an toàn 48 MB"
        }
    }
}

/// Minimal implicit-FTPS reader for Bambu's port 990. Only binary RETR is
/// implemented; no printer file is changed, uploaded, renamed or deleted.
private final class BambuFTPSDownload {
    private enum Stage {
        case welcome, user, password, pbsz, protection, binary, passive, dataConnecting, retrieving, transfer
    }

    private let host: String
    private let accessCode: String
    private let candidatePaths: [String]
    private let queue: DispatchQueue
    private let completion: (Result<Data, Error>) -> Void
    private var control: NWConnection?
    private var dataConnection: NWConnection?
    private var controlBuffer = ""
    private var downloaded = Data()
    private var stage: Stage = .welcome
    private var candidateIndex = 0
    private var controlFinished = false
    private var dataFinished = false
    private var completed = false

    init(
        host: String,
        accessCode: String,
        candidatePaths: [String],
        queue: DispatchQueue,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        self.host = host
        self.accessCode = accessCode
        self.candidatePaths = candidatePaths
        self.queue = queue
        self.completion = completion
    }

    static func candidatePaths(gcodeFile: String, subtaskName: String) -> [String] {
        let trimmed = gcodeFile.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let filename = (trimmed as NSString).lastPathComponent
        var names = [trimmed, filename]
        if !filename.lowercased().hasSuffix(".3mf") {
            names.append(filename + ".3mf")
            if filename.lowercased().hasSuffix(".gcode") {
                names.append(String(filename.dropLast(6)) + ".gcode.3mf")
            }
        }
        let task = subtaskName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !task.isEmpty {
            names.append(task)
            if !task.lowercased().hasSuffix(".3mf") { names.append(task + ".gcode.3mf") }
        }
        var paths: [String] = []
        for name in names where !name.isEmpty {
            for prefix in ["/", "/cache/"] {
                let path = prefix + name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !paths.contains(path) { paths.append(path) }
            }
        }
        return paths
    }

    func start() {
        guard !candidatePaths.isEmpty else {
            finish(.failure(BambuFTPError.noCandidate))
            return
        }
        guard let port = NWEndpoint.Port(rawValue: 990) else {
            finish(.failure(BambuFTPError.connection("cổng FTPS không hợp lệ")))
            return
        }
        let connection = makeTLSConnection(port: port)
        control = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveControl()
            case .failed(let error):
                self.finish(.failure(BambuFTPError.connection(error.localizedDescription)))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 35) { [weak self] in
            guard let self, !self.completed else { return }
            self.finish(.failure(BambuFTPError.connection("FTPS hết thời gian chờ")))
        }
    }

    func cancel() {
        completed = true
        control?.cancel()
        dataConnection?.cancel()
    }

    private func makeTLSConnection(port: NWEndpoint.Port) -> NWConnection {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, complete in complete(true) },
            queue
        )
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, true)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: NWParameters(tls: tls, tcp: tcp)
        )
    }

    private func receiveControl() {
        control?.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, !self.completed else { return }
            if let data, let text = String(data: data, encoding: .utf8) {
                self.controlBuffer += text
                self.consumeControlLines()
            }
            if let error {
                self.finish(.failure(BambuFTPError.connection(error.localizedDescription)))
                return
            }
            if complete, !self.completed {
                self.finish(.failure(BambuFTPError.connection("máy in đóng FTPS quá sớm")))
                return
            }
            self.receiveControl()
        }
    }

    private func consumeControlLines() {
        while let range = controlBuffer.range(of: "\r\n") {
            let line = String(controlBuffer[..<range.lowerBound])
            controlBuffer.removeSubrange(controlBuffer.startIndex..<range.upperBound)
            guard line.count >= 3, let code = Int(line.prefix(3)) else { continue }
            // Ignore intermediate lines in a multiline FTP response.
            if line.count > 3, line[line.index(line.startIndex, offsetBy: 3)] == "-" { continue }
            handleReply(code: code, line: line)
        }
    }

    private func handleReply(code: Int, line: String) {
        switch stage {
        case .welcome where code == 220:
            send("USER bblp", next: .user)
        case .user where code == 331:
            send("PASS \(accessCode)", next: .password)
        case .user where code == 230:
            send("PBSZ 0", next: .pbsz)
        case .password where code == 230:
            send("PBSZ 0", next: .pbsz)
        case .pbsz where code == 200:
            send("PROT P", next: .protection)
        case .protection where code == 200:
            send("TYPE I", next: .binary)
        case .binary where code == 200:
            requestPassivePort()
        case .passive where code == 229:
            guard let port = parseEPSVPort(line), let endpointPort = NWEndpoint.Port(rawValue: port) else {
                finish(.failure(BambuFTPError.rejected("Máy in trả cổng dữ liệu FTPS không hợp lệ")))
                return
            }
            openDataConnection(port: endpointPort)
        case .retrieving where code == 125 || code == 150:
            stage = .transfer
        case .retrieving where code == 550:
            tryNextCandidate()
        case .transfer where code == 226:
            controlFinished = true
            finishTransferIfReady()
        default:
            if code >= 400 {
                finish(.failure(BambuFTPError.rejected(line)))
            }
        }
    }

    private func requestPassivePort() {
        downloaded.removeAll(keepingCapacity: true)
        controlFinished = false
        dataFinished = false
        send("EPSV", next: .passive)
    }

    private func openDataConnection(port: NWEndpoint.Port) {
        stage = .dataConnecting
        let connection = makeTLSConnection(port: port)
        dataConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.completed else { return }
            switch state {
            case .ready:
                self.receiveData()
            case .failed(let error):
                self.finish(.failure(BambuFTPError.connection(error.localizedDescription)))
            default:
                break
            }
        }
        connection.start(queue: queue)
        // vsftpd waits for RETR before it starts TLS on the passive socket.
        // Sending RETR only after NWConnection reports .ready deadlocks both
        // sides and used to surface as "FTPS hết thời gian chờ".
        stage = .retrieving
        queue.asyncAfter(deadline: .now() + 0.12) { [weak self, weak connection] in
            guard let self, let connection, !self.completed,
                  self.dataConnection === connection,
                  self.stage == .retrieving else { return }
            self.sendRaw("RETR \(self.candidatePaths[self.candidateIndex])")
        }
    }

    private func receiveData() {
        dataConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.completed else { return }
            if let data, !data.isEmpty {
                self.downloaded.append(data)
                if self.downloaded.count > BambuArchiveLimits.maximumBytes {
                    self.finish(.failure(BambuFTPError.tooLarge))
                    return
                }
            }
            if let error {
                self.finish(.failure(BambuFTPError.connection(error.localizedDescription)))
                return
            }
            if complete {
                self.dataFinished = true
                self.finishTransferIfReady()
                return
            }
            self.receiveData()
        }
    }

    private func tryNextCandidate() {
        dataConnection?.cancel()
        dataConnection = nil
        candidateIndex += 1
        guard candidateIndex < candidatePaths.count else {
            finish(.failure(BambuFTPError.noCandidate))
            return
        }
        requestPassivePort()
    }

    private func finishTransferIfReady() {
        guard controlFinished, dataFinished else { return }
        finish(.success(downloaded))
    }

    private func parseEPSVPort(_ line: String) -> UInt16? {
        guard let start = line.range(of: "(|||"),
              let end = line.range(of: "|)", range: start.upperBound..<line.endIndex) else { return nil }
        return UInt16(line[start.upperBound..<end.lowerBound])
    }

    private func send(_ command: String, next: Stage) {
        stage = next
        sendRaw(command)
    }

    private func sendRaw(_ command: String) {
        control?.send(content: Data("\(command)\r\n".utf8), completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finish(.failure(BambuFTPError.connection(error.localizedDescription)))
            }
        })
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !completed else { return }
        completed = true
        control?.cancel()
        dataConnection?.cancel()
        completion(result)
    }
}
#endif
