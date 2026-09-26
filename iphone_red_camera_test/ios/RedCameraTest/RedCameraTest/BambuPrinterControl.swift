import Combine
import Foundation
import Network
import Security

/// Direct LAN MQTT control for the selected printer. Control no longer depends
/// on the ESP32's MQTT session, so a BLE reconnect or fleet scan cannot swallow
/// a user command. The ESP32 remains responsible for telemetry and timelapse.
final class BambuPrinterControlManager: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isPending = false
    @Published private(set) var lastSucceeded: Bool?
    @Published private(set) var statusText = "Đang chuẩn bị điều khiển trực tiếp…"

    private struct Configuration: Equatable {
        let profileID: String
        let host: String
        let serial: String
        let accessCode: String
    }

    private struct PendingCommand {
        let sequence: String
        let mqttCommand: String
        let actionName: String
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

    func start(profile: BambuPrinterProfile, accessCode: String) {
        let next = Configuration(
            profileID: profile.id,
            host: profile.ip.trimmingCharacters(in: .whitespacesAndNewlines),
            serial: profile.serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            accessCode: accessCode.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !next.host.isEmpty, !next.serial.isEmpty, !next.accessCode.isEmpty else {
            publishFailure("Thiếu IP, serial hoặc Access Code của máy in")
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            if self.configuration == next, self.connection != nil { return }
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

    /// On H2D, virtual tray 254 and extruder id 1 are the left external-spool
    /// path. Keep this explicit so the right nozzle is never selected.
    func loadExternalFilamentIntoLeftNozzle(temperature: Int) {
        guard (170...320).contains(temperature) else {
            publishFailure("Nhiệt độ nạp nhựa không hợp lệ")
            return
        }
        send(
            section: "print",
            command: "ams_change_filament",
            fields: [
                "ams_id": 254,
                "slot_id": 0,
                "target": 254,
                "extruder_id": 1,
                "curr_temp": 0,
                "tar_temp": temperature
            ],
            actionName: "Nạp nhựa cuộn ngoài vào đầu trái"
        )
    }

    func unloadExternalFilamentFromLeftNozzle(temperature: Int) {
        guard (170...320).contains(temperature) else {
            publishFailure("Nhiệt độ rút nhựa không hợp lệ")
            return
        }
        send(
            section: "print",
            command: "ams_change_filament",
            fields: [
                "ams_id": 254,
                "slot_id": 255,
                "target": 255,
                "extruder_id": 1,
                "curr_temp": 0,
                "tar_temp": temperature
            ],
            actionName: "Rút nhựa cuộn ngoài khỏi đầu trái"
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
        }
        if let system = root["system"] as? [String: Any] {
            confirmPendingIfMatched(section: system)
        }
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
        actionName: String
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
                actionName: actionName
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
        timer.setEventHandler { [weak self] in self?.sendPacket(Data([0xC0, 0x00])) }
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
        pending = nil
        DispatchQueue.main.async { [weak self] in
            self?.isPending = false
            self?.lastSucceeded = success
            self?.statusText = detail
        }
        requestPushAll()
    }

    private func failConnection(_ text: String) {
        connection?.cancel()
        connection = nil
        pending = nil
        publishFailure(text)
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
