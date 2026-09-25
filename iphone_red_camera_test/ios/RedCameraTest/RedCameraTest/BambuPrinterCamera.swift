import AVFoundation
import Combine
import CoreImage
import CryptoKit
import Foundation
import Network
import Security
import UIKit
import VideoToolbox

/// Direct LAN live view for Bambu printers. H2D/P2S use RTSPS/H.264 on
/// port 322, while A1 uses the framed MJPEG/TLS stream on port 6000.
/// The ESP32 bridge remains dedicated to telemetry and control so camera
/// traffic never competes with BLE status packets.
final class BambuPrinterCameraManager: ObservableObject {
    @Published private(set) var frame: CGImage?
    @Published private(set) var statusText = "Camera máy in đang tắt"
    @Published private(set) var transportText = "LAN"
    @Published private(set) var isConnecting = false
    @Published private(set) var isStreaming = false

    private struct Configuration: Equatable {
        let profileID: String
        let kind: BambuPrinterKind
        let host: String
        let accessCode: String
    }

    private let queue = DispatchQueue(label: "vn.se.bambu-printer-camera", qos: .userInitiated)
    private var transport: BambuCameraTransport?
    private var requestedConfiguration: Configuration?
    private var activeConfiguration: Configuration?
    private var retryWorkItem: DispatchWorkItem?
    private var retryAttempt = 0
    private var generation = 0
    private var firstFrameDeadline: DispatchWorkItem?

    func start(profile: BambuPrinterProfile, accessCode: String) {
        let host = profile.ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = accessCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !code.isEmpty else {
            publishStatus("Thiếu IP hoặc Access Code của camera máy in", connecting: false, streaming: false)
            return
        }

        let configuration = Configuration(
            profileID: profile.id,
            kind: profile.kind,
            host: host,
            accessCode: code
        )
        queue.async { [weak self] in
            guard let self else { return }
            self.requestedConfiguration = configuration
            if self.activeConfiguration == configuration, self.transport != nil { return }
            self.retryAttempt = 0
            self.connect(configuration)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.requestedConfiguration = nil
            self.generation &+= 1
            self.cancelConnection()
            self.publishFrame(nil)
            self.publishStatus("Camera máy in đang tắt", connecting: false, streaming: false)
        }
    }

    func retryNow() {
        queue.async { [weak self] in
            guard let self, let configuration = self.requestedConfiguration else { return }
            self.retryAttempt = 0
            self.connect(configuration)
        }
    }

    private func connect(_ configuration: Configuration) {
        generation &+= 1
        let connectionGeneration = generation
        cancelConnection()
        activeConfiguration = configuration

        let usesMJPEG = configuration.kind == .a1
        publishTransport(usesMJPEG ? "MJPEG • LAN" : "RTSPS • LAN")
        publishFrame(nil)
        publishStatus(
            "Đang kết nối camera của \(configuration.kind.rawValue)",
            connecting: true,
            streaming: false
        )

        let onStatus: (String) -> Void = { [weak self] text in
            guard let self, self.generation == connectionGeneration else { return }
            self.publishStatus(text, connecting: true, streaming: false)
        }
        let onFrame: (CGImage) -> Void = { [weak self] image in
            guard let self, self.generation == connectionGeneration else { return }
            self.firstFrameDeadline?.cancel()
            self.firstFrameDeadline = nil
            self.retryAttempt = 0
            self.publishFrame(image)
            self.publishStatus("Camera máy in đang phát trực tiếp", connecting: false, streaming: true)
        }
        let onFailure: (String) -> Void = { [weak self] reason in
            guard let self, self.generation == connectionGeneration else { return }
            self.handleFailure(reason, configuration: configuration)
        }

        if usesMJPEG {
            transport = BambuMJPEGCameraTransport(
                host: configuration.host,
                accessCode: configuration.accessCode,
                queue: queue,
                onStatus: onStatus,
                onFrame: onFrame,
                onFailure: onFailure
            )
        } else {
            transport = BambuRTSPCameraTransport(
                host: configuration.host,
                accessCode: configuration.accessCode,
                queue: queue,
                onStatus: onStatus,
                onFrame: onFrame,
                onFailure: onFailure
            )
        }
        transport?.start()

        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.generation == connectionGeneration, !self.isStreaming else { return }
            self.handleFailure(
                usesMJPEG
                    ? "Camera không gửi hình • kiểm tra IP và Access Code LAN"
                    : "Camera không gửi hình • hãy bật LAN Only Liveview trên máy in",
                configuration: configuration
            )
        }
        firstFrameDeadline = deadline
        queue.asyncAfter(deadline: .now() + 14, execute: deadline)
    }

    private func handleFailure(_ reason: String, configuration: Configuration) {
        guard requestedConfiguration == configuration else { return }
        transport?.stop()
        transport = nil
        activeConfiguration = nil
        firstFrameDeadline?.cancel()
        firstFrameDeadline = nil
        retryAttempt += 1
        let delay = min(15.0, pow(2.0, Double(min(retryAttempt, 4))))
        publishStatus("\(reason) • đang thử lại", connecting: false, streaming: false)

        retryWorkItem?.cancel()
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.requestedConfiguration == configuration else { return }
            self.connect(configuration)
        }
        retryWorkItem = retry
        queue.asyncAfter(deadline: .now() + delay, execute: retry)
    }

    private func cancelConnection() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        firstFrameDeadline?.cancel()
        firstFrameDeadline = nil
        transport?.stop()
        transport = nil
        activeConfiguration = nil
    }

    private func publishStatus(_ text: String, connecting: Bool, streaming: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.statusText = text
            self?.isConnecting = connecting
            self?.isStreaming = streaming
        }
    }

    private func publishFrame(_ image: CGImage?) {
        DispatchQueue.main.async { [weak self] in self?.frame = image }
    }

    private func publishTransport(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.transportText = text }
    }
}

private protocol BambuCameraTransport: AnyObject {
    func start()
    func stop()
}

private func makeBambuTLSConnection(
    host: String,
    port: UInt16,
    queue: DispatchQueue
) -> NWConnection {
    let tls = NWProtocolTLS.Options()
    // Bambu printers use their own device certificate on the isolated LAN.
    // Authentication is still enforced separately with the per-printer LAN
    // access code; accept that device certificate for this direct connection.
    sec_protocol_options_set_verify_block(
        tls.securityProtocolOptions,
        { _, _, complete in complete(true) },
        queue
    )
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: tls, tcp: tcp)
    parameters.serviceClass = .interactiveVideo
    return NWConnection(
        host: NWEndpoint.Host(host),
        port: NWEndpoint.Port(rawValue: port)!,
        using: parameters
    )
}

private final class BambuMJPEGCameraTransport: BambuCameraTransport {
    private let host: String
    private let accessCode: String
    private let queue: DispatchQueue
    private let onStatus: (String) -> Void
    private let onFrame: (CGImage) -> Void
    private let onFailure: (String) -> Void
    private var connection: NWConnection?
    private var buffer = Data()
    private var stopped = false
    private var deliveredFrame = false

    init(
        host: String,
        accessCode: String,
        queue: DispatchQueue,
        onStatus: @escaping (String) -> Void,
        onFrame: @escaping (CGImage) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        self.host = host
        self.accessCode = accessCode
        self.queue = queue
        self.onStatus = onStatus
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func start() {
        stopped = false
        buffer.removeAll(keepingCapacity: true)
        deliveredFrame = false
        let connection = makeBambuTLSConnection(host: host, port: 6000, queue: queue)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                self.onStatus("Đang xác thực camera của A1")
                self.sendAuthentication()
                self.receiveNextChunk()
            case .failed(let error):
                self.fail("Mất kết nối camera A1 (\(error.localizedDescription))")
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        stopped = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll(keepingCapacity: false)
    }

    private func sendAuthentication() {
        var packet = Data(count: 80)
        packet.writeLittleEndian(UInt32(0x40), at: 0)
        packet.writeLittleEndian(UInt32(0x3000), at: 4)
        packet.replaceFixedASCII("bblp", at: 16, length: 32)
        packet.replaceFixedASCII(accessCode, at: 48, length: 32)
        connection?.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.fail("Không gửi được Access Code tới camera (\(error.localizedDescription))")
        })
    }

    private func receiveNextChunk() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.consumeFrames()
            }
            if let error {
                self.fail("Lỗi đọc camera A1 (\(error.localizedDescription))")
                return
            }
            if isComplete {
                self.fail("Camera A1 đã đóng kết nối")
                return
            }
            self.receiveNextChunk()
        }
    }

    private func consumeFrames() {
        let maximumJPEGSize = 4 * 1024 * 1024
        while buffer.count >= 16 {
            let payloadSize = Int(buffer.littleEndianUInt32(at: 0))
            guard payloadSize > 0, payloadSize <= maximumJPEGSize else {
                fail("Camera A1 gửi khung hình không hợp lệ")
                return
            }
            let frameSize = 16 + payloadSize
            guard buffer.count >= frameSize else { return }
            let jpeg = buffer.subdata(in: 16..<frameSize)
            buffer.removeSubrange(0..<frameSize)
            guard jpeg.count >= 4,
                  jpeg[jpeg.startIndex] == 0xFF,
                  jpeg[jpeg.index(after: jpeg.startIndex)] == 0xD8,
                  let image = UIImage(data: jpeg)?.cgImage else { continue }
            if !deliveredFrame {
                deliveredFrame = true
                onStatus("Đã xác thực camera A1 • đang nhận hình")
            }
            onFrame(image)
        }
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        stopped = true
        connection?.cancel()
        connection = nil
        onFailure(message)
    }
}

private final class BambuRTSPCameraTransport: BambuCameraTransport {
    private struct Request {
        let method: String
        let uri: String
        let headers: [String: String]
        let authorized: Bool
    }

    private struct Response {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private enum Authentication {
        case basic
        case digest([String: String])
    }

    private let host: String
    private let accessCode: String
    private let queue: DispatchQueue
    private let onStatus: (String) -> Void
    private let onFrame: (CGImage) -> Void
    private let onFailure: (String) -> Void
    private let baseURI: String
    private let decoder: H264FrameDecoder

    private var connection: NWConnection?
    private var buffer = Data()
    private var stopped = false
    private var sequence = 0
    private var pendingRequests: [Int: Request] = [:]
    private var authentication: Authentication?
    private var digestNonceCount = 0
    private var contentBase = ""
    private var trackURI = ""
    private var sessionID = ""
    private var keepaliveWorkItem: DispatchWorkItem?
    private var accessUnitTimestamp: UInt32?
    private var accessUnitNALs: [Data] = []
    private var fragmentedNAL: Data?
    private var sps: Data?
    private var pps: Data?
    private var receivedVideo = false

    init(
        host: String,
        accessCode: String,
        queue: DispatchQueue,
        onStatus: @escaping (String) -> Void,
        onFrame: @escaping (CGImage) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        self.host = host
        self.accessCode = accessCode
        self.queue = queue
        self.onStatus = onStatus
        self.onFrame = onFrame
        self.onFailure = onFailure
        self.baseURI = "rtsps://\(host):322/streaming/live/1"
        self.decoder = H264FrameDecoder(onFrame: onFrame)
    }

    func start() {
        stopped = false
        buffer.removeAll(keepingCapacity: true)
        let connection = makeBambuTLSConnection(host: host, port: 322, queue: queue)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                self.onStatus("Đang xác thực camera RTSPS")
                self.receiveNextChunk()
                self.sendRequest(method: "OPTIONS", uri: self.baseURI)
            case .failed(let error):
                self.fail("Mất kết nối camera RTSPS (\(error.localizedDescription))")
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        stopped = true
        keepaliveWorkItem?.cancel()
        keepaliveWorkItem = nil
        if !sessionID.isEmpty, let connection {
            let cseq = sequence + 1
            let text = "TEARDOWN \(baseURI) RTSP/1.0\r\nCSeq: \(cseq)\r\nSession: \(sessionID)\r\n\r\n"
            connection.send(content: text.data(using: .utf8), completion: .idempotent)
        }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        decoder.invalidate()
        buffer.removeAll(keepingCapacity: false)
        pendingRequests.removeAll()
        accessUnitNALs.removeAll()
        fragmentedNAL = nil
    }

    private func receiveNextChunk() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.consumeInput()
            }
            if let error {
                self.fail("Lỗi đọc camera RTSPS (\(error.localizedDescription))")
                return
            }
            if isComplete {
                self.fail("Camera RTSPS đã đóng kết nối")
                return
            }
            self.receiveNextChunk()
        }
    }

    private func consumeInput() {
        while !buffer.isEmpty {
            if buffer[buffer.startIndex] == 0x24 {
                guard buffer.count >= 4 else { return }
                let channel = buffer.byte(at: 1)
                let length = Int(buffer.bigEndianUInt16(at: 2))
                guard length <= 2 * 1024 * 1024 else {
                    fail("Gói video RTSPS quá lớn")
                    return
                }
                guard buffer.count >= 4 + length else { return }
                let packet = buffer.subdata(in: 4..<(4 + length))
                buffer.removeSubrange(0..<(4 + length))
                if channel == 0 { consumeRTPPacket(packet) }
                continue
            }

            guard let headerRange = buffer.range(of: Data([13, 10, 13, 10])) else { return }
            let headerEnd = headerRange.upperBound
            guard let headerText = String(data: buffer.subdata(in: 0..<headerEnd), encoding: .utf8) else {
                fail("Phản hồi RTSPS không hợp lệ")
                return
            }
            let parsedHeaders = parseHeaders(headerText)
            let contentLength = Int(parsedHeaders["content-length"] ?? "0") ?? 0
            guard contentLength >= 0, contentLength <= 512 * 1024 else {
                fail("Phản hồi RTSPS quá lớn")
                return
            }
            guard buffer.count >= headerEnd + contentLength else { return }
            let body = contentLength > 0
                ? buffer.subdata(in: headerEnd..<(headerEnd + contentLength))
                : Data()
            buffer.removeSubrange(0..<(headerEnd + contentLength))
            let statusCode = Int(headerText.split(separator: " ", maxSplits: 2).dropFirst().first ?? "0") ?? 0
            handleResponse(Response(statusCode: statusCode, headers: parsedHeaders, body: body))
        }
    }

    private func parseHeaders(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n").dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result[name] = value
        }
        return result
    }

    private func handleResponse(_ response: Response) {
        let cseq = Int(response.headers["cseq"] ?? "")
        let request = cseq.flatMap { pendingRequests.removeValue(forKey: $0) }
            ?? pendingRequests.keys.sorted().first.flatMap { pendingRequests.removeValue(forKey: $0) }
        guard let request else { return }

        if response.statusCode == 401 {
            guard !request.authorized,
                  let challengeText = response.headers["www-authenticate"],
                  let challenge = parseAuthentication(challengeText) else {
                fail("Access Code camera không đúng")
                return
            }
            authentication = challenge
            sendRequest(
                method: request.method,
                uri: request.uri,
                headers: request.headers,
                authorized: true
            )
            return
        }

        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 404 || response.statusCode == 454 {
                fail("LAN Only Liveview chưa được bật trên máy in")
            } else {
                fail("Camera RTSPS trả về lỗi \(response.statusCode)")
            }
            return
        }

        switch request.method {
        case "OPTIONS":
            sendRequest(
                method: "DESCRIBE",
                uri: baseURI,
                headers: ["Accept": "application/sdp"]
            )
        case "DESCRIBE":
            guard configureFromSDP(response.body, headers: response.headers) else {
                fail("Camera không cung cấp luồng H.264")
                return
            }
            sendRequest(
                method: "SETUP",
                uri: trackURI,
                headers: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"]
            )
        case "SETUP":
            guard let rawSession = response.headers["session"] else {
                fail("Camera RTSPS không trả về phiên phát")
                return
            }
            sessionID = rawSession.components(separatedBy: ";").first ?? rawSession
            sendRequest(
                method: "PLAY",
                uri: contentBase.isEmpty ? baseURI : contentBase,
                headers: ["Range": "npt=0.000-", "Session": sessionID]
            )
        case "PLAY":
            onStatus("Đã xác thực camera • đang chờ hình trực tiếp")
            scheduleKeepalive()
        case "GET_PARAMETER":
            scheduleKeepalive()
        default:
            break
        }
    }

    private func sendRequest(
        method: String,
        uri: String,
        headers: [String: String] = [:],
        authorized: Bool? = nil
    ) {
        guard !stopped else { return }
        sequence += 1
        let shouldAuthorize = authorized ?? (authentication != nil)
        var requestHeaders = headers
        requestHeaders["CSeq"] = String(sequence)
        requestHeaders["User-Agent"] = "SE-Bambu-LiveView/1.0"
        if !sessionID.isEmpty, method == "GET_PARAMETER" {
            requestHeaders["Session"] = sessionID
        }
        if shouldAuthorize, let value = authorizationValue(method: method, uri: uri) {
            requestHeaders["Authorization"] = value
        }
        requestHeaders["Content-Length"] = "0"

        var text = "\(method) \(uri) RTSP/1.0\r\n"
        for key in requestHeaders.keys.sorted() {
            text += "\(key): \(requestHeaders[key]!)\r\n"
        }
        text += "\r\n"
        pendingRequests[sequence] = Request(
            method: method,
            uri: uri,
            headers: headers,
            authorized: shouldAuthorize
        )
        connection?.send(content: text.data(using: .utf8), completion: .contentProcessed {
            [weak self] error in
            guard let self, let error else { return }
            self.fail("Không gửi được yêu cầu camera (\(error.localizedDescription))")
        })
    }

    private func parseAuthentication(_ text: String) -> Authentication? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("basic") { return .basic }
        guard trimmed.lowercased().hasPrefix("digest") else { return nil }
        let start = trimmed.index(trimmed.startIndex, offsetBy: 6)
        return .digest(parseQuotedParameters(String(trimmed[start...])))
    }

    private func authorizationValue(method: String, uri: String) -> String? {
        guard let authentication else { return nil }
        switch authentication {
        case .basic:
            let credential = Data("bblp:\(accessCode)".utf8).base64EncodedString()
            return "Basic \(credential)"
        case .digest(let values):
            guard let realm = values["realm"], let nonce = values["nonce"] else { return nil }
            let ha1 = md5Hex("bblp:\(realm):\(accessCode)")
            let ha2 = md5Hex("\(method):\(uri)")
            let qop = values["qop"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .first(where: { $0 == "auth" })
            var response: String
            var additions: [String] = []
            if let qop {
                digestNonceCount += 1
                let nc = String(format: "%08x", digestNonceCount)
                let cnonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                response = md5Hex("\(ha1):\(nonce):\(nc):\(cnonce):\(qop):\(ha2)")
                additions = ["qop=\(qop)", "nc=\(nc)", "cnonce=\"\(cnonce)\""]
            } else {
                response = md5Hex("\(ha1):\(nonce):\(ha2)")
            }
            var fields = [
                "username=\"bblp\"",
                "realm=\"\(realm)\"",
                "nonce=\"\(nonce)\"",
                "uri=\"\(uri)\"",
                "response=\"\(response)\"",
                "algorithm=MD5"
            ]
            if let opaque = values["opaque"] { fields.append("opaque=\"\(opaque)\"") }
            fields.append(contentsOf: additions)
            return "Digest " + fields.joined(separator: ", ")
        }
    }

    private func configureFromSDP(_ data: Data, headers: [String: String]) -> Bool {
        guard let sdp = String(data: data, encoding: .utf8) else { return false }
        contentBase = normalizedRTSPURI(headers["content-base"] ?? baseURI)
        var inVideo = false
        var control = ""
        for rawLine in sdp.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("m=") { inVideo = line.hasPrefix("m=video") }
            guard inVideo else { continue }
            if line.hasPrefix("a=control:") {
                control = String(line.dropFirst("a=control:".count))
            }
            if let marker = line.range(of: "sprop-parameter-sets=") {
                let tail = line[marker.upperBound...]
                let encoded = tail.prefix { $0 != ";" && !$0.isWhitespace }
                let values = encoded.split(separator: ",", omittingEmptySubsequences: true)
                if values.count >= 2 {
                    sps = Data(base64Encoded: String(values[0]))
                    pps = Data(base64Encoded: String(values[1]))
                }
            }
        }
        guard !control.isEmpty else { return false }
        trackURI = resolvedTrackURI(control)
        if let sps, let pps { decoder.configure(sps: sps, pps: pps) }
        return true
    }

    private func resolvedTrackURI(_ control: String) -> String {
        if control.hasPrefix("rtsp://") || control.hasPrefix("rtsps://") {
            return normalizedRTSPURI(control)
        }
        if control.hasPrefix("/") { return "rtsps://\(host):322\(control)" }
        let base = contentBase.isEmpty ? baseURI : contentBase
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }

    private func normalizedRTSPURI(_ value: String) -> String {
        if value.hasPrefix("rtsp://") {
            return "rtsps://" + String(value.dropFirst("rtsp://".count))
        }
        return value
    }

    private func consumeRTPPacket(_ packet: Data) {
        guard packet.count >= 12, packet.byte(at: 0) >> 6 == 2 else { return }
        let first = packet.byte(at: 0)
        let second = packet.byte(at: 1)
        let hasPadding = first & 0x20 != 0
        let hasExtension = first & 0x10 != 0
        let csrcCount = Int(first & 0x0F)
        var offset = 12 + csrcCount * 4
        guard packet.count >= offset else { return }
        if hasExtension {
            guard packet.count >= offset + 4 else { return }
            let extensionWords = Int(packet.bigEndianUInt16(at: offset + 2))
            offset += 4 + extensionWords * 4
        }
        var end = packet.count
        if hasPadding, let padding = packet.last, Int(padding) <= end - offset {
            end -= Int(padding)
        }
        guard offset < end else { return }
        let timestamp = packet.bigEndianUInt32(at: 4)
        let marker = second & 0x80 != 0
        let payload = packet.subdata(in: offset..<end)

        if let currentTimestamp = accessUnitTimestamp, currentTimestamp != timestamp {
            flushAccessUnit(timestamp: currentTimestamp)
        }
        accessUnitTimestamp = timestamp
        consumeH264Payload(payload)
        if marker { flushAccessUnit(timestamp: timestamp) }
    }

    private func consumeH264Payload(_ payload: Data) {
        guard !payload.isEmpty else { return }
        let nalType = payload.byte(at: 0) & 0x1F
        switch nalType {
        case 1...23:
            appendNAL(payload)
        case 24: // STAP-A aggregation packet
            var offset = 1
            while offset + 2 <= payload.count {
                let length = Int(payload.bigEndianUInt16(at: offset))
                offset += 2
                guard length > 0, offset + length <= payload.count else { break }
                appendNAL(payload.subdata(in: offset..<(offset + length)))
                offset += length
            }
        case 28: // FU-A fragmented NAL unit
            guard payload.count >= 2 else { return }
            let indicator = payload.byte(at: 0)
            let header = payload.byte(at: 1)
            let isStart = header & 0x80 != 0
            let isEnd = header & 0x40 != 0
            if isStart {
                var nal = Data([indicator & 0xE0 | (header & 0x1F)])
                nal.append(payload.subdata(in: 2..<payload.count))
                fragmentedNAL = nal
            } else if fragmentedNAL != nil {
                fragmentedNAL?.append(payload.subdata(in: 2..<payload.count))
            }
            if isEnd, let nal = fragmentedNAL {
                fragmentedNAL = nil
                appendNAL(nal)
            }
        default:
            break
        }
    }

    private func appendNAL(_ nal: Data) {
        guard !nal.isEmpty else { return }
        switch nal.byte(at: 0) & 0x1F {
        case 7:
            if sps != nal {
                sps = nal
                if let pps { decoder.configure(sps: nal, pps: pps) }
            }
        case 8:
            if pps != nal {
                pps = nal
                if let sps { decoder.configure(sps: sps, pps: nal) }
            }
        default:
            break
        }
        accessUnitNALs.append(nal)
    }

    private func flushAccessUnit(timestamp: UInt32) {
        defer {
            accessUnitNALs.removeAll(keepingCapacity: true)
            fragmentedNAL = nil
            accessUnitTimestamp = nil
        }
        guard !accessUnitNALs.isEmpty else { return }
        decoder.decode(nals: accessUnitNALs, rtpTimestamp: timestamp)
        if !receivedVideo {
            receivedVideo = true
            onStatus("Đã nhận luồng H.264 từ camera máy in")
        }
    }

    private func scheduleKeepalive() {
        keepaliveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, !self.sessionID.isEmpty else { return }
            self.sendRequest(method: "GET_PARAMETER", uri: self.baseURI)
        }
        keepaliveWorkItem = item
        queue.asyncAfter(deadline: .now() + 20, execute: item)
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        stopped = true
        keepaliveWorkItem?.cancel()
        connection?.cancel()
        connection = nil
        decoder.invalidate()
        onFailure(message)
    }
}

private final class H264FrameDecoder {
    private let onFrame: (CGImage) -> Void
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var lastFrameTime: TimeInterval = 0

    init(onFrame: @escaping (CGImage) -> Void) {
        self.onFrame = onFrame
    }

    func configure(sps: Data, pps: Data) {
        invalidate()
        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsBase = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return OSStatus(kCMFormatDescriptionError_InvalidParameter)
                }
                var pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                var sizes = [sps.count, pps.count]
                return pointers.withUnsafeMutableBufferPointer { pointerBuffer in
                    sizes.withUnsafeMutableBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        }
        guard status == noErr, let videoDescription = description as? CMVideoFormatDescription else { return }
        formatDescription = videoDescription

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, imageBuffer, _, _ in
                guard status == noErr, let refcon, let imageBuffer else { return }
                let decoder = Unmanaged<H264FrameDecoder>.fromOpaque(refcon).takeUnretainedValue()
                decoder.deliver(imageBuffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var createdSession: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: videoDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &createdSession
        )
        if createStatus == noErr { session = createdSession }
    }

    func decode(nals: [Data], rtpTimestamp: UInt32) {
        guard let session, let formatDescription else { return }
        var accessUnit = Data()
        for nal in nals where !nal.isEmpty {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { accessUnit.append(contentsOf: $0) }
            accessUnit.append(nal)
        }
        guard !accessUnit.isEmpty else { return }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: accessUnit.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: accessUnit.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return }
        let copyStatus = accessUnit.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: accessUnit.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(rtpTimestamp), timescale: 90_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = accessUnit.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return }
        var flagsOut = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [.enableAsynchronousDecompression, .oneTimeRealTimePlayback],
            frameRefcon: nil,
            infoFlagsOut: &flagsOut
        )
    }

    func invalidate() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
    }

    private func deliver(_ pixelBuffer: CVPixelBuffer) {
        // Avoid driving SwiftUI faster than the display needs while keeping the
        // live view fluid on an older iPhone SE.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrameTime >= 1.0 / 12.0 else { return }
        lastFrameTime = now
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let output = ciContext.createCGImage(image, from: image.extent) else { return }
        onFrame(output)
    }
}

private func parseQuotedParameters(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    var index = text.startIndex
    while index < text.endIndex {
        while index < text.endIndex, text[index].isWhitespace || text[index] == "," {
            index = text.index(after: index)
        }
        let keyStart = index
        while index < text.endIndex, text[index] != "=", text[index] != "," {
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == "=" else { break }
        let key = text[keyStart..<index].trimmingCharacters(in: .whitespaces).lowercased()
        index = text.index(after: index)
        var value = ""
        if index < text.endIndex, text[index] == "\"" {
            index = text.index(after: index)
            while index < text.endIndex, text[index] != "\"" {
                value.append(text[index])
                index = text.index(after: index)
            }
            if index < text.endIndex { index = text.index(after: index) }
        } else {
            let valueStart = index
            while index < text.endIndex, text[index] != "," {
                index = text.index(after: index)
            }
            value = text[valueStart..<index].trimmingCharacters(in: .whitespaces)
        }
        if !key.isEmpty { result[key] = value }
    }
    return result
}

private func md5Hex(_ value: String) -> String {
    Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private extension Data {
    func byte(at offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(byte(at: offset)) |
            UInt32(byte(at: offset + 1)) << 8 |
            UInt32(byte(at: offset + 2)) << 16 |
            UInt32(byte(at: offset + 3)) << 24
    }

    func bigEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(byte(at: offset)) << 8 | UInt16(byte(at: offset + 1))
    }

    func bigEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(byte(at: offset)) << 24 |
            UInt32(byte(at: offset + 1)) << 16 |
            UInt32(byte(at: offset + 2)) << 8 |
            UInt32(byte(at: offset + 3))
    }

    mutating func writeLittleEndian(_ value: UInt32, at offset: Int) {
        self[index(startIndex, offsetBy: offset)] = UInt8(truncatingIfNeeded: value)
        self[index(startIndex, offsetBy: offset + 1)] = UInt8(truncatingIfNeeded: value >> 8)
        self[index(startIndex, offsetBy: offset + 2)] = UInt8(truncatingIfNeeded: value >> 16)
        self[index(startIndex, offsetBy: offset + 3)] = UInt8(truncatingIfNeeded: value >> 24)
    }

    mutating func replaceFixedASCII(_ value: String, at offset: Int, length: Int) {
        let bytes = Array(value.utf8.prefix(length))
        for position in 0..<length {
            self[index(startIndex, offsetBy: offset + position)] =
                position < bytes.count ? bytes[position] : 0
        }
    }
}
