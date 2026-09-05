import AVFoundation
import Combine
import CoreMedia
import CryptoKit
import Network
import Security
import UIKit

/// A small H2D-specific RTSPS client. H2D combines Digest authentication with
/// a printer-local TLS certificate; that combination is rejected by some
/// VLCKit/iOS builds even after the certificate dialog is accepted. This
/// client talks to the LAN endpoint directly, trusts only this user-selected
/// local connection, and feeds the H.264 RTP frames to iOS' hardware decoder.
final class H2DNativeRTSPPlayer: ObservableObject {
    @Published private(set) var statusText = "Đang mở camera H2D trực tiếp…"
    @Published private(set) var isPlaying = false
    @Published private(set) var hasError = false

    private struct Response {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private let networkQueue = DispatchQueue(label: "vn.se.h2d.rtsps")
    private weak var videoView: H2DDecodedVideoView?
    private var connection: NWConnection?
    private var incoming = Data()
    private var responseHandler: ((Response?) -> Void)?
    private var host = ""
    private var password = ""
    private var baseURL = ""
    private var realm = "LIVE555 Streaming Media"
    private var nonce = ""
    private var session = ""
    private var cseq = 0
    private var stopped = true
    private var retryCount = 0

    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var accessUnitTimestamp: UInt32?
    private var accessUnit: [Data] = []
    private var fuTimestamp: UInt32?
    private var fuNAL = Data()

    func attach(to view: H2DDecodedVideoView, printerIP: String, accessCode: String) {
        videoView = view
        host = printerIP.trimmingCharacters(in: .whitespacesAndNewlines)
        password = accessCode
            .filter { $0.isNumber || ($0.isASCII && $0.isLetter) }
            .lowercased()
        start()
    }

    func start() {
        stopConnection(clearScreen: true)
        guard !host.isEmpty, !password.isEmpty else {
            publish("Thiếu IP hoặc Access Code của H2D", error: true)
            return
        }
        stopped = false
        retryCount = 0
        connect()
    }

    func stop() {
        stopped = true
        stopConnection(clearScreen: true)
    }

    private func connect() {
        guard !stopped, let port = NWEndpoint.Port(rawValue: 322) else { return }
        publish("Đang bắt tay TLS trực tiếp với H2D…")

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, completion in completion(true) },
            networkQueue
        )
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let next = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        connection = next
        next.stateUpdateHandler = { [weak self, weak next] state in
            guard let self, let next, self.connection === next, !self.stopped else { return }
            switch state {
            case .ready:
                self.incoming.removeAll(keepingCapacity: true)
                self.receiveMore()
                self.beginHandshake()
            case .waiting:
                self.publish("Đang chờ camera H2D trong mạng LAN…")
            case .failed(let error):
                self.retry("Camera H2D không kết nối được: \(error.localizedDescription)")
            case .cancelled:
                break
            default:
                break
            }
        }
        next.start(queue: networkQueue)
    }

    private func beginHandshake() {
        baseURL = "rtsps://\(host):322/streaming/live/1"
        cseq = 0
        nonce = ""
        session = ""
        publish("Đang xác thực Access Code camera H2D…")

        request(method: "DESCRIBE", uri: baseURL, authenticated: false,
                headers: ["Accept": "application/sdp"]) { [weak self] first in
            guard let self, let first, first.statusCode == 401,
                  let challenge = first.headers["www-authenticate"],
                  let parsedNonce = self.quotedValue("nonce", in: challenge) else {
                self?.retry("H2D không trả về yêu cầu đăng nhập camera hợp lệ")
                return
            }
            self.nonce = parsedNonce
            self.realm = self.quotedValue("realm", in: challenge) ?? self.realm
            self.describeAuthenticated()
        }
    }

    private func describeAuthenticated() {
        request(method: "DESCRIBE", uri: baseURL, authenticated: true,
                headers: ["Accept": "application/sdp"]) { [weak self] response in
            guard let self, let response, response.statusCode == 200,
                  let sdp = String(data: response.body, encoding: .utf8) else {
                self?.retry("Access Code camera không đúng hoặc Liveview LAN chưa bật")
                return
            }
            self.readParameterSets(from: sdp)
            let control = sdp.split(whereSeparator: \Character.isNewline)
                .map(String.init)
                .first { $0.lowercased().hasPrefix("a=control:") && !$0.hasSuffix("*") }?
                .split(separator: ":", maxSplits: 1)
                .last.map(String.init) ?? "track1"
            let trackURL: String
            if control.lowercased().hasPrefix("rtsp") {
                trackURL = control
            } else if control.hasPrefix("/") {
                trackURL = "rtsps://\(self.host):322\(control)"
            } else {
                trackURL = self.baseURL + "/" + control
            }
            self.setup(trackURL: trackURL)
        }
    }

    private func setup(trackURL: String) {
        request(
            method: "SETUP",
            uri: trackURL,
            authenticated: true,
            headers: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"]
        ) { [weak self] response in
            guard let self, let response, response.statusCode == 200,
                  let rawSession = response.headers["session"] else {
                self?.retry("H2D không tạo được phiên camera trực tiếp")
                return
            }
            self.session = rawSession.split(separator: ";", maxSplits: 1).first.map(String.init) ?? rawSession
            self.play()
        }
    }

    private func play() {
        request(
            method: "PLAY",
            uri: baseURL,
            authenticated: true,
            headers: ["Session": session, "Range": "npt=0.000-"]
        ) { [weak self] response in
            guard let self, let response, response.statusCode == 200 else {
                self?.retry("H2D từ chối phát luồng camera")
                return
            }
            self.publish("Camera H2D • trực tiếp qua LAN", playing: true)
            self.parseIncoming()
        }
    }

    private func request(
        method: String,
        uri: String,
        authenticated: Bool,
        headers: [String: String],
        completion: @escaping (Response?) -> Void
    ) {
        guard let connection, responseHandler == nil else {
            completion(nil)
            return
        }
        cseq += 1
        var lines = [
            "\(method) \(uri) RTSP/1.0",
            "CSeq: \(cseq)",
            "User-Agent: SE-H2D/9.16"
        ]
        if authenticated {
            lines.append("Authorization: \(digestAuthorization(method: method, uri: uri))")
        }
        for (name, value) in headers { lines.append("\(name): \(value)") }
        responseHandler = completion
        let packet = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if error != nil {
                let handler = self?.responseHandler
                self?.responseHandler = nil
                handler?(nil)
            }
        })
    }

    private func receiveMore() {
        guard let connection, !stopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, self.connection === connection, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.incoming.append(data)
                self.parseIncoming()
            }
            if complete || error != nil {
                self.retry("Luồng camera H2D bị ngắt")
            } else {
                self.receiveMore()
            }
        }
    }

    private func parseIncoming() {
        while !incoming.isEmpty {
            if incoming[0] == 0x24 { // '$': RTP interleaved frame
                guard incoming.count >= 4 else { return }
                let channel = incoming[1]
                let length = Int(incoming[2]) << 8 | Int(incoming[3])
                guard incoming.count >= 4 + length else { return }
                let packet = incoming.subdata(in: 4..<(4 + length))
                incoming.removeSubrange(0..<(4 + length))
                if channel == 0 { consumeRTP(packet) }
                continue
            }

            guard let headerEnd = incoming.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headerData = incoming.subdata(in: 0..<headerEnd.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8),
                  headerText.hasPrefix("RTSP/") else {
                incoming.removeFirst()
                continue
            }
            let headers = parseHeaders(headerText)
            let bodyLength = Int(headers["content-length"] ?? "0") ?? 0
            let consumed = headerEnd.upperBound + bodyLength
            guard incoming.count >= consumed else { return }
            let firstLine = headerText.split(whereSeparator: \Character.isNewline).first.map(String.init) ?? ""
            let status = Int(firstLine.split(separator: " ").dropFirst().first ?? "0") ?? 0
            let body = bodyLength > 0
                ? incoming.subdata(in: headerEnd.upperBound..<consumed)
                : Data()
            incoming.removeSubrange(0..<consumed)
            let handler = responseHandler
            responseHandler = nil
            handler?(Response(statusCode: status, headers: headers, body: body))
        }
    }

    private func parseHeaders(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \Character.isNewline).dropFirst() {
            guard let split = line.firstIndex(of: ":") else { continue }
            let name = line[..<split].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespacesAndNewlines)
            result[name] = value
        }
        return result
    }

    private func quotedValue(_ key: String, in value: String) -> String? {
        let marker = "\(key)=\""
        guard let start = value.range(of: marker, options: .caseInsensitive) else { return nil }
        let tail = value[start.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        return String(tail[..<end])
    }

    private func digestAuthorization(method: String, uri: String) -> String {
        let ha1 = md5("bblp:\(realm):\(password)")
        let ha2 = md5("\(method):\(uri)")
        let response = md5("\(ha1):\(nonce):\(ha2)")
        return "Digest username=\"bblp\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\", response=\"\(response)\""
    }

    private func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func readParameterSets(from sdp: String) {
        guard let marker = sdp.range(of: "sprop-parameter-sets=") else { return }
        let value = sdp[marker.upperBound...].prefix { $0 != ";" && !$0.isNewline }
        let parts = value.split(separator: ",")
        if parts.count >= 2 {
            sps = Data(base64Encoded: String(parts[0]))
            pps = Data(base64Encoded: String(parts[1]))
            rebuildFormatDescription()
        }
    }

    private func consumeRTP(_ packet: Data) {
        guard packet.count >= 12, packet[0] >> 6 == 2 else { return }
        let csrcCount = Int(packet[0] & 0x0F)
        var offset = 12 + csrcCount * 4
        guard packet.count > offset else { return }
        if packet[0] & 0x10 != 0 {
            guard packet.count >= offset + 4 else { return }
            let words = Int(packet[offset + 2]) << 8 | Int(packet[offset + 3])
            offset += 4 + words * 4
            guard packet.count > offset else { return }
        }
        let marker = packet[1] & 0x80 != 0
        let timestamp = UInt32(packet[4]) << 24 | UInt32(packet[5]) << 16 |
            UInt32(packet[6]) << 8 | UInt32(packet[7])
        let payload = packet.subdata(in: offset..<packet.count)
        guard let first = payload.first else { return }
        let type = first & 0x1F

        if accessUnitTimestamp != timestamp {
            if !accessUnit.isEmpty { emitAccessUnit() }
            accessUnitTimestamp = timestamp
            accessUnit.removeAll(keepingCapacity: true)
        }

        switch type {
        case 1...23:
            appendNAL(payload)
        case 24: // STAP-A
            var cursor = 1
            while cursor + 2 <= payload.count {
                let size = Int(payload[cursor]) << 8 | Int(payload[cursor + 1])
                cursor += 2
                guard size > 0, cursor + size <= payload.count else { break }
                appendNAL(payload.subdata(in: cursor..<(cursor + size)))
                cursor += size
            }
        case 28: // FU-A
            guard payload.count >= 2 else { return }
            let fuHeader = payload[1]
            let reconstructed = (first & 0xE0) | (fuHeader & 0x1F)
            if fuHeader & 0x80 != 0 {
                fuTimestamp = timestamp
                fuNAL = Data([reconstructed])
                fuNAL.append(payload.subdata(in: 2..<payload.count))
            } else if fuTimestamp == timestamp, !fuNAL.isEmpty {
                fuNAL.append(payload.subdata(in: 2..<payload.count))
            }
            if fuHeader & 0x40 != 0, fuTimestamp == timestamp, !fuNAL.isEmpty {
                appendNAL(fuNAL)
                fuNAL.removeAll(keepingCapacity: true)
                fuTimestamp = nil
            }
        default:
            break
        }

        if marker { emitAccessUnit() }
    }

    private func appendNAL(_ nal: Data) {
        guard let first = nal.first else { return }
        switch first & 0x1F {
        case 7:
            sps = nal
            rebuildFormatDescription()
        case 8:
            pps = nal
            rebuildFormatDescription()
        case 9:
            break
        default:
            accessUnit.append(nal)
        }
    }

    private func rebuildFormatDescription() {
        guard let sps, let pps else { return }
        sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsPointer = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPointer = ppsBytes.bindMemory(to: UInt8.self).baseAddress else { return }
                let pointers = [spsPointer, ppsPointer]
                let sizes = [sps.count, pps.count]
                var description: CMFormatDescription?
                let status = pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
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
                if status == noErr { formatDescription = description }
            }
        }
    }

    private func emitAccessUnit() {
        defer { accessUnit.removeAll(keepingCapacity: true) }
        guard !accessUnit.isEmpty, let formatDescription else { return }
        var avcc = Data()
        for nal in accessUnit {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return }
        let copyStatus = avcc.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }
        CMSetAttachment(
            sampleBuffer,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: .shouldNotPropagate
        )
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped, let layer = self.videoView?.displayLayer else { return }
            if layer.status == .failed { layer.flushAndRemoveImage() }
            layer.enqueue(sampleBuffer)
            if !self.isPlaying {
                self.statusText = "Camera H2D • trực tiếp qua LAN"
                self.isPlaying = true
                self.hasError = false
            }
        }
    }

    private func retry(_ message: String) {
        guard !stopped else { return }
        stopConnection(clearScreen: false)
        guard retryCount < 2 else {
            publish(message, error: true)
            return
        }
        retryCount += 1
        publish("\(message) • thử lại \(retryCount)/2")
        networkQueue.asyncAfter(deadline: .now() + Double(retryCount)) { [weak self] in
            self?.connect()
        }
    }

    private func stopConnection(clearScreen: Bool) {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        responseHandler = nil
        incoming.removeAll(keepingCapacity: false)
        accessUnit.removeAll(keepingCapacity: false)
        fuNAL.removeAll(keepingCapacity: false)
        accessUnitTimestamp = nil
        fuTimestamp = nil
        if clearScreen {
            DispatchQueue.main.async { [weak self] in
                self?.videoView?.displayLayer.flushAndRemoveImage()
                self?.isPlaying = false
            }
        }
    }

    private func publish(_ text: String, playing: Bool = false, error: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            self?.statusText = text
            self?.isPlaying = playing
            self?.hasError = error
        }
    }
}

final class H2DDecodedVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }
}

/// A1/P1-style LAN cameras send a sequence of JPEG frames after one small TLS
/// authentication packet. Keeping this backend separate prevents SE from
/// sending H2D's RTSP commands to an A1 or P2S selected by the user.
final class BambuJPEGCameraPlayer: ObservableObject {
    @Published private(set) var statusText = "Đang mở Live View LAN…"
    @Published private(set) var image: UIImage?
    @Published private(set) var isPlaying = false
    @Published private(set) var hasError = false

    private let queue = DispatchQueue(label: "vn.se.bambu.jpeg-camera")
    private var connection: NWConnection?
    private var buffer = Data()
    private var stopped = true
    private var host = ""
    private var password = ""
    private var model: BambuPrinterKind = .a1

    func start(printerIP: String, accessCode: String, model: BambuPrinterKind) {
        stop()
        host = printerIP.trimmingCharacters(in: .whitespacesAndNewlines)
        password = accessCode
            .filter { $0.isNumber || ($0.isASCII && $0.isLetter) }
            .lowercased()
        self.model = model
        guard !host.isEmpty, !password.isEmpty else {
            publish("Thiếu IP hoặc Access Code của \(model.rawValue)", error: true)
            return
        }
        stopped = false
        guard let port = NWEndpoint.Port(rawValue: 6000) else { return }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, complete in complete(true) },
            queue
        )
        let next = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        )
        connection = next
        publish("Đang đăng nhập camera \(model.rawValue) qua LAN…")
        next.stateUpdateHandler = { [weak self, weak next] state in
            guard let self, let next, self.connection === next, !self.stopped else { return }
            switch state {
            case .ready:
                next.send(content: self.authenticationPacket(), completion: .contentProcessed { error in
                    if let error {
                        self.publish("Không gửi được Access Code: \(error.localizedDescription)", error: true)
                    } else {
                        self.receiveMore()
                    }
                })
            case .failed(let error):
                self.publish("\(model.rawValue) không mở cổng Live View LAN: \(error.localizedDescription)", error: true)
            case .waiting:
                self.publish("Đang chờ \(model.rawValue) trong mạng LAN…")
            default:
                break
            }
        }
        next.start(queue: queue)
    }

    func stop() {
        stopped = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll(keepingCapacity: false)
        DispatchQueue.main.async { [weak self] in
            self?.isPlaying = false
            self?.image = nil
        }
    }

    private func authenticationPacket() -> Data {
        var packet = Data()
        for raw in [UInt32(0x40), UInt32(0x3000), 0, 0] {
            var value = raw.littleEndian
            withUnsafeBytes(of: &value) { packet.append(contentsOf: $0) }
        }
        func fixed(_ value: String) -> Data {
            var data = Data(value.utf8.prefix(31))
            if data.count < 32 { data.append(Data(repeating: 0, count: 32 - data.count)) }
            return data
        }
        packet.append(fixed("bblp"))
        packet.append(fixed(password))
        return packet
    }

    private func receiveMore() {
        guard let connection, !stopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, self.connection === connection, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.extractJPEGFrames()
            }
            if complete || error != nil {
                self.publish("Luồng camera \(self.model.rawValue) bị ngắt", error: true)
            } else {
                self.receiveMore()
            }
        }
    }

    private func extractJPEGFrames() {
        let startMarker = Data([0xFF, 0xD8])
        let endMarker = Data([0xFF, 0xD9])
        while let start = buffer.range(of: startMarker),
              let end = buffer.range(of: endMarker, in: start.lowerBound..<buffer.endIndex) {
            let frameEnd = end.upperBound
            let jpeg = buffer.subdata(in: start.lowerBound..<frameEnd)
            buffer.removeSubrange(0..<frameEnd)
            guard let decoded = UIImage(data: jpeg) else { continue }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.image = decoded
                self.isPlaying = true
                self.hasError = false
                self.statusText = "Camera \(self.model.rawValue) • trực tiếp qua LAN"
            }
        }
        if buffer.count > 4_000_000 {
            buffer = Data(buffer.suffix(2))
        }
    }

    private func publish(_ text: String, error: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            self?.statusText = text
            self?.hasError = error
            if error { self?.isPlaying = false }
        }
    }
}
