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

struct SelectionCandidate: Identifiable, Equatable {
    let id: Int
    let trackID: Int
    let classID: Int
    var label: String
    var confidence: Int
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

enum GimbalTrackingState: String {
    case disconnected
    case idle
    case acquire
    case choose
    case refine
    case lock
    case search
    case home
    case calibrate

    var title: String {
        switch self {
        case .disconnected: return "Chưa kết nối"
        case .idle: return "Sẵn sàng"
        case .acquire: return "Đang tìm"
        case .choose: return "Chạm chọn đúng mục tiêu"
        case .refine: return "Đang ghi nhớ mục tiêu"
        case .lock: return "Đã khóa mục tiêu"
        case .search: return "Đang bắt lại"
        case .home: return "Đang về Home"
        case .calibrate: return "Đang căn tâm hai camera"
        }
    }
}

final class BLEManager: NSObject, ObservableObject {
    @Published private(set) var connectionText = "Đang bật Bluetooth..."
    @Published private(set) var isConnected = false
    @Published private(set) var isSessionActive = false
    // Recording is a separate phase from setup. ARM only scans/selects; the
    // ESP32 raises this flag after centre calibration has really completed.
    @Published private(set) var shouldRecordVideo = false
    @Published private(set) var trackingState: GimbalTrackingState = .disconnected
    @Published private(set) var confidence = 0
    @Published private(set) var targetX = 0.5
    @Published private(set) var targetY = 0.5
    @Published private(set) var targetWidth = 0.08
    @Published private(set) var targetHeight = 0.08
    @Published private(set) var lockedTargetName = "Tên lửa nước"
    @Published private(set) var panAngle = 90.0
    @Published private(set) var tiltAngle = 120.0
    @Published private(set) var maixVersion = "Đang chờ MaixCAM"
    @Published private(set) var rigVersion = "Bánh răng P 3,20:1 • T 1,60:1"
    @Published private(set) var selectedMode: TrackingMode = .waterRocket
    @Published private(set) var isEnrolling = false
    @Published private(set) var isChoosingTarget = false
    @Published private(set) var isRefining = false
    @Published private(set) var candidates: [SelectionCandidate] = []
    @Published private(set) var expectedCandidateCount = 0
    @Published private(set) var selectedCandidateID: Int?
    @Published private(set) var hasSelectedCandidate = false
    @Published private(set) var isConfirmingCandidate = false
    @Published private(set) var enrollmentProgress = 0.0
    @Published private(set) var enrollmentStatus = "Giữ chủ thể trước MaixCAM"
    @Published private(set) var isCalibrating = false
    @Published private(set) var calibrationProgress = 0.0
    @Published private(set) var calibrationStatus = "Đặt mục tiêu vào dấu + giữa iPhone"
    @Published private(set) var needsCenterCalibration = false

    private let serviceUUID = CBUUID(string: "7E57A000-8E3A-4D6A-9B2B-13B10A000001")
    private let eventUUID = CBUUID(string: "7E57A001-8E3A-4D6A-9B2B-13B10A000001")
    private let commandUUID = CBUUID(string: "7E57A002-8E3A-4D6A-9B2B-13B10A000001")

    private var central: CBCentralManager!
    private var trackerPeripheral: CBPeripheral?
    private var eventCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var lifecycleActive = true
    private var reconnectWorkItem: DispatchWorkItem?
    private var enrollmentWatchdogWorkItem: DispatchWorkItem?
    private var selectionRetryWorkItem: DispatchWorkItem?
    private var selectionTimeoutWorkItem: DispatchWorkItem?
    private var enrollmentCycle = 0
    private var selectionCycle = 0
    private var awaitingSelectionAcknowledgement = false
    private var savedMaixCenterX = 0.5
    private var savedMaixCenterY = 0.5

    var trackingTitle: String {
        switch trackingState {
        case .choose: return "Chạm chọn một vật MaixCAM đã phát hiện"
        case .refine: return "Đang tinh chỉnh: \(lockedTargetName)"
        case .lock:
            return needsCenterCalibration
                ? "Đã chọn \(lockedTargetName) • tự đặt tại dấu + rồi bấm Căn tâm"
                : "Đã khóa: \(lockedTargetName)"
        case .search: return "Đang bắt lại: \(lockedTargetName)"
        default: return trackingState.title
        }
    }

    var canCalibrateCenter: Bool {
        isConnected && hasSelectedCandidate && needsCenterCalibration &&
            !isConfirmingCandidate && !isRefining && !isCalibrating
    }

    var isCandidateListReady: Bool {
        !candidates.isEmpty &&
            (expectedCandidateCount <= 0 || candidates.count >= expectedCandidateCount)
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func arm() {
        cancelCalibrationUI()
        shouldRecordVideo = false
        needsCenterCalibration = false
        beginEnrollmentUI()
        isSessionActive = true
        send("ARM")
        trackingState = .acquire
    }

    func stop() {
        cancelEnrollmentUI()
        cancelCalibrationUI()
        send("STOP")
        isSessionActive = false
        shouldRecordVideo = false
        trackingState = .idle
        needsCenterCalibration = false
    }

    func home() {
        cancelEnrollmentUI()
        cancelCalibrationUI()
        send("HOME")
        isSessionActive = false
        shouldRecordVideo = false
        trackingState = .home
        needsCenterCalibration = false
    }

    func calibrateCenter() {
        guard isConnected else { return }
        guard canCalibrateCenter else {
            calibrationStatus = hasSelectedCandidate
                ? "Hãy chờ MaixCAM ghi nhớ xong mục tiêu"
                : "Hãy quét 3 giây và chạm chọn chủ thể trước"
            return
        }
        isRefining = true
        isEnrolling = true
        enrollmentProgress = 0
        enrollmentStatus = "Đang tinh chỉnh đúng vật tại dấu +"
        trackingState = .refine
        send("CALIBRATE_CENTER")
    }

    func selectCandidate(_ candidate: SelectionCandidate) {
        guard isConnected, isChoosingTarget, isCandidateListReady,
              !isConfirmingCandidate else { return }
        selectionCycle += 1
        let cycle = selectionCycle
        selectedCandidateID = candidate.id
        hasSelectedCandidate = false
        lockedTargetName = candidate.label
        isChoosingTarget = true
        isRefining = false
        isEnrolling = false
        enrollmentProgress = 0
        enrollmentStatus = "Đã chọn \(candidate.label) • đang chờ MaixCAM xác nhận"
        trackingState = .choose
        isConfirmingCandidate = true
        awaitingSelectionAcknowledgement = true
        send("SELECT,\(candidate.id)")

        selectionRetryWorkItem?.cancel()
        let retry = DispatchWorkItem { [weak self] in
            guard let self,
                  self.selectionCycle == cycle,
                  self.awaitingSelectionAcknowledgement else { return }
            self.send("SELECT,\(candidate.id)")
            self.enrollmentStatus = "Đang xác nhận đúng \(candidate.label) với MaixCAM"
        }
        selectionRetryWorkItem = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: retry)

        selectionTimeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.selectionCycle == cycle,
                  self.awaitingSelectionAcknowledgement else { return }
            self.reopenCandidateSelection(
                status: "Chưa nhận được lựa chọn • chạm lại đúng vật cần bám"
            )
        }
        selectionTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: timeout)
    }

    func selectCandidate(atX x: Double, y: Double) {
        guard isConnected, isChoosingTarget, isCandidateListReady else { return }
        // The displayed boxes are projected from MaixCAM into the iPhone view.
        // Prefer a box containing the finger, otherwise choose the nearest one.
        let selected = candidates.min { first, second in
            candidateTapScore(first, x: x, y: y) < candidateTapScore(second, x: x, y: y)
        }
        if let selected { selectCandidate(selected) }
    }

    private func candidateTapScore(_ candidate: SelectionCandidate, x: Double, y: Double) -> Double {
        let halfWidth = max(0.035, candidate.width * 0.55)
        let halfHeight = max(0.035, candidate.height * 0.55)
        let dx = abs(candidate.x - x)
        let dy = abs(candidate.y - y)
        let insidePenalty = (dx <= halfWidth && dy <= halfHeight) ? 0.0 : 2.0
        return insidePenalty + hypot(dx / halfWidth, dy / halfHeight)
    }

    func selectMode(_ mode: TrackingMode) {
        guard selectedMode != mode else { return }
        selectedMode = mode
        confidence = 0
        targetX = 0.5
        targetY = 0.5
        targetWidth = 0.08
        targetHeight = 0.08
        lockedTargetName = mode.title
        shouldRecordVideo = false
        needsCenterCalibration = false
        trackingState = .idle
        cancelEnrollmentUI()
        cancelCalibrationUI()
        send("MODE,\(mode.rawValue)")
    }

    private func beginEnrollmentUI() {
        cancelSelectionAcknowledgement()
        enrollmentCycle += 1
        let cycle = enrollmentCycle
        enrollmentWatchdogWorkItem?.cancel()
        clearCandidateSelection()
        hasSelectedCandidate = false
        isEnrolling = true
        isRefining = false
        enrollmentProgress = 0
        enrollmentStatus = "Giữ \(selectedMode.title.lowercased()) trước MaixCAM"

        let watchdog = DispatchWorkItem { [weak self] in
            guard let self,
                  self.enrollmentCycle == cycle,
                  self.isEnrolling,
                  self.enrollmentProgress < 0.01 else { return }
            self.enrollmentStatus = "MaixCAM chưa phản hồi ổn định • đang thử kết nối lại"
            self.connectionText = "Đang kiểm tra đường truyền MaixCAM"
        }
        enrollmentWatchdogWorkItem = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.5, execute: watchdog)
    }

    private func cancelEnrollmentUI() {
        cancelSelectionAcknowledgement()
        enrollmentCycle += 1
        enrollmentWatchdogWorkItem?.cancel()
        enrollmentWatchdogWorkItem = nil
        clearCandidateSelection()
        hasSelectedCandidate = false
        isEnrolling = false
        isRefining = false
        enrollmentProgress = 0
        enrollmentStatus = "Giữ chủ thể trước MaixCAM"
    }

    private func clearCandidateSelection() {
        isChoosingTarget = false
        selectedCandidateID = nil
        candidates = []
        expectedCandidateCount = 0
    }

    private func finishCandidateSelection() {
        isChoosingTarget = false
        candidates = []
        expectedCandidateCount = 0
    }

    private func confirmCandidateSelection() {
        awaitingSelectionAcknowledgement = false
        isConfirmingCandidate = false
        selectionRetryWorkItem?.cancel()
        selectionRetryWorkItem = nil
        selectionTimeoutWorkItem?.cancel()
        selectionTimeoutWorkItem = nil
    }

    private func cancelSelectionAcknowledgement() {
        selectionCycle += 1
        confirmCandidateSelection()
    }

    private func reopenCandidateSelection(status: String) {
        cancelSelectionAcknowledgement()
        isConfirmingCandidate = false
        selectedCandidateID = nil
        hasSelectedCandidate = false
        isRefining = false
        isEnrolling = false
        isChoosingTarget = !candidates.isEmpty
        enrollmentProgress = 1
        enrollmentStatus = status
        trackingState = candidates.isEmpty ? .acquire : .choose
    }

    private func cancelCalibrationUI() {
        isCalibrating = false
        calibrationProgress = 0
        calibrationStatus = "Đặt mục tiêu vào dấu + giữa iPhone"
    }

    private func localizedTargetName(_ token: String) -> String {
        let key = token.uppercased()
        let known: [String: String] = [
            "WATER_ROCKET": "Tên lửa nước", "ROCKET": "Tên lửa nước",
            "PERSON": "Người", "DOG": "Chó", "CAT": "Mèo",
            "BIRD": "Chim", "HORSE": "Ngựa", "COW": "Bò",
            "SHEEP": "Cừu", "ELEPHANT": "Voi", "BEAR": "Gấu",
            "BOTTLE": "Chai", "CAR": "Ô tô", "MOTORCYCLE": "Xe máy",
            "BICYCLE": "Xe đạp", "CHAIR": "Ghế", "CELL_PHONE": "Điện thoại",
            "BACKPACK": "Ba lô", "UMBRELLA": "Ô", "OBJECT": "Vật"
        ]
        if let translated = known[key] { return translated }
        return key.replacingOccurrences(of: "_", with: " ").lowercased().capitalized
    }

    private func mapMaixPointToIPhone(_ raw: Double, scale: Double, center: Double = 0.5) -> Double {
        // Two fixed cameras have different fields of view. Calibration removes
        // the centre offset; this scale prevents raw Maix coordinates from
        // being drawn as if both sensors had identical optics.
        min(1, max(0, 0.5 + (raw - center) * scale))
    }

    private func activateTransportIfReady(_ peripheral: CBPeripheral) {
        guard peripheral.state == .connected,
              commandCharacteristic != nil,
              eventCharacteristic?.isNotifying == true else { return }
        let firstActivation = !isConnected
        isConnected = true
        trackingState = .idle
        connectionText = "Đã kết nối ESP32 SE • MaixCAM sẵn sàng"
        if firstActivation {
            send("APP_READY")
            send("MODE,\(selectedMode.rawValue)")
        }
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
            case "IDLE", "HOME_DONE":
                trackingState = .idle
                isSessionActive = false
                shouldRecordVideo = false
                cancelEnrollmentUI()
                cancelCalibrationUI()
            case "ACQUIRE":
                if isChoosingTarget {
                    trackingState = .choose
                } else if isRefining {
                    trackingState = .refine
                } else {
                    trackingState = .acquire
                }
            case "LOCK": trackingState = .lock
            case "SEARCH": trackingState = .search
            case "HOME": trackingState = .home
            case "CALIBRATE": trackingState = .calibrate
            default: break
            }
            confidence = Int(fields[2]) ?? 0
            if fields.count >= 5 {
                let maixX = (Double(fields[3]) ?? 500) / 1000
                let maixY = (Double(fields[4]) ?? 500) / 1000
                targetX = mapMaixPointToIPhone(maixX, scale: 0.62)
                targetY = mapMaixPointToIPhone(maixY, scale: 0.48)
            }
            if fields.count >= 7 {
                panAngle = Double(fields[5]) ?? panAngle
                tiltAngle = Double(fields[6]) ?? tiltAngle
            }
            if fields.count >= 9 {
                targetWidth = min(0.34, max(0.055,
                    ((Double(fields[7]) ?? 80) / 1000) * 0.62))
                targetHeight = min(0.42, max(0.055,
                    ((Double(fields[8]) ?? 80) / 1000) * 0.48))
            }
        } else if head == "MAIX" {
            enrollmentWatchdogWorkItem?.cancel()
            enrollmentWatchdogWorkItem = nil
            connectionText = "MaixCAM và ESP32 đang hoạt động"
            maixVersion = fields.dropFirst().joined(separator: " • ")
        } else if head == "RIG", fields.count >= 7 {
            rigVersion = "Bánh răng P \(fields[2]):1 • T \(fields[3]):1"
        } else if head == "CALIBRATE", fields.count >= 2 {
            let calibrationEvent = fields[1].uppercased()
            // SAVED is harmless connection metadata. Every active calibration
            // event must belong to the current session so STOP stays final.
            guard calibrationEvent == "SAVED" || isSessionActive else { return }
            switch calibrationEvent {
            case "PREPARE":
                isCalibrating = true
                let prepare = fields.count >= 3 ? (Double(fields[2]) ?? 0) / 100 : 0
                calibrationProgress = min(0.30, max(0, prepare * 0.30))
                calibrationStatus = "Đặt \(lockedTargetName.lowercased()) vào dấu + • cách ≥20 cm"
                trackingState = .calibrate
            case "START":
                isCalibrating = true
                calibrationProgress = 0
                calibrationStatus = "Giữ \(lockedTargetName.lowercased()) đúng dấu +"
                trackingState = .calibrate
            case "PROGRESS":
                isCalibrating = true
                if fields.count >= 3 {
                    let measured = (Double(fields[2]) ?? 0) / 100
                    calibrationProgress = min(0.99, max(0.30, 0.30 + measured * 0.70))
                }
                calibrationStatus = calibrationProgress > 0
                    ? "Đang đo và lọc độ lệch hai camera"
                    : "Đang chờ MaixCAM khóa đúng chủ thể"
            case "DONE":
                if fields.count >= 4 {
                    savedMaixCenterX = min(0.8, max(0.2, (Double(fields[2]) ?? 500) / 1000))
                    savedMaixCenterY = min(0.8, max(0.2, (Double(fields[3]) ?? 500) / 1000))
                }
                calibrationProgress = 1
                calibrationStatus = "Đã căn tâm hai camera"
                needsCenterCalibration = false
                trackingState = .lock
                shouldRecordVideo = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                    self?.isCalibrating = false
                }
            case "FAILED":
                shouldRecordVideo = false
                isCalibrating = false
                calibrationProgress = 0
                calibrationStatus = fields.count >= 3 && fields[2] == "LOCK_FIRST"
                    ? "Hãy khóa chủ thể rồi căn tâm lại"
                    : "Không thấy chủ thể ổn định, hãy thử lại"
                trackingState = .acquire
                needsCenterCalibration = true
            case "REQUIRED":
                isCalibrating = false
                calibrationProgress = 0
                needsCenterCalibration = true
                calibrationStatus = "Đặt \(lockedTargetName.lowercased()) đúng dấu + rồi bấm Căn tâm"
                trackingState = .lock
            case "SAVED":
                if fields.count >= 4 {
                    savedMaixCenterX = min(0.8, max(0.2, (Double(fields[2]) ?? 500) / 1000))
                    savedMaixCenterY = min(0.8, max(0.2, (Double(fields[3]) ?? 500) / 1000))
                }
            default:
                break
            }
        } else if head == "MEDIA", fields.count >= 2 {
            switch fields[1].uppercased() {
            case "RECORD_START":
                // Only this verified controller event is allowed to start a
                // saved movie; scan, selection and calibration stay preview-only.
                guard isSessionActive, !needsCenterCalibration else { return }
                shouldRecordVideo = true
            case "RECORD_STOP":
                shouldRecordVideo = false
            default:
                break
            }
        } else if head == "ENROLL", fields.count >= 4 {
            let progress = min(100, max(0, Double(fields[1]) ?? 0)) / 100
            if let mode = TrackingMode(rawValue: fields[2].uppercased()) {
                selectedMode = mode
            }
            let status = fields[3].uppercased()
            // STOP is authoritative. Ignore delayed scan/selection packets
            // that were already in UART/BLE queues when the user tapped pause.
            guard isSessionActive else { return }
            enrollmentProgress = progress
            if progress > 0 {
                enrollmentWatchdogWorkItem?.cancel()
                enrollmentWatchdogWorkItem = nil
                connectionText = "MaixCAM và ESP32 đang hoạt động"
            }
            switch status {
            case "READY":
                confirmCandidateSelection()
                if fields.count >= 5 {
                    lockedTargetName = localizedTargetName(fields[4])
                }
                isEnrolling = false
                isRefining = false
                finishCandidateSelection()
                enrollmentProgress = 1
                needsCenterCalibration = true
                calibrationStatus = "Đặt \(lockedTargetName.lowercased()) đúng dấu + rồi bấm Căn tâm"
                enrollmentStatus = "Đã nhớ màu và hình dạng • hãy căn tâm thủ công"
                trackingState = .lock
            case "CHOOSE":
                expectedCandidateCount = fields.count >= 5 ? max(0, Int(fields[4]) ?? 0) : 0
                // MaixCAM repeats CHOOSE for reliability. Do not let a repeat
                // erase the user's tap while SELECT acknowledgement is in flight.
                if isConfirmingCandidate || hasSelectedCandidate || isRefining {
                    break
                }
                cancelSelectionAcknowledgement()
                isEnrolling = false
                isRefining = false
                isChoosingTarget = true
                selectedCandidateID = nil
                hasSelectedCandidate = false
                trackingState = .choose
                enrollmentStatus = "Đã quét xong • đang nhận đủ danh sách vật"
            case "SELECTED":
                confirmCandidateSelection()
                if fields.count >= 5 {
                    lockedTargetName = localizedTargetName(fields[4])
                }
                hasSelectedCandidate = true
                isChoosingTarget = false
                isRefining = false
                isEnrolling = false
                finishCandidateSelection()
                needsCenterCalibration = true
                trackingState = .lock
                enrollmentStatus = "Đã chọn \(lockedTargetName) • tự đặt tại dấu + rồi bấm Căn tâm"
                calibrationStatus = "Đặt \(lockedTargetName.lowercased()) đúng dấu + rồi bấm Căn tâm"
            case "REFINE":
                confirmCandidateSelection()
                isChoosingTarget = false
                isRefining = true
                isEnrolling = true
                trackingState = .refine
                if fields.count >= 5 {
                    lockedTargetName = localizedTargetName(fields[4])
                }
                enrollmentStatus = "MaixCAM đang đối chiếu và ghi nhớ \(lockedTargetName.lowercased())"
            case "RETRY":
                cancelSelectionAcknowledgement()
                clearCandidateSelection()
                isEnrolling = true
                isRefining = false
                enrollmentProgress = 0
                enrollmentStatus = "Chưa thấy vật rõ • MaixCAM đang quét lại"
            case "START", "SCANNING":
                isEnrolling = true
                enrollmentStatus = "Giữ \(selectedMode.title.lowercased()) trước MaixCAM"
            default:
                break
            }
        } else if head == "MODE", fields.count >= 2,
                  let mode = TrackingMode(rawValue: fields[1].uppercased()) {
            selectedMode = mode
            lockedTargetName = mode.title
        } else if head == "TARGET", fields.count >= 2 {
            lockedTargetName = localizedTargetName(fields[1])
        } else if head == "CANDIDATES", fields.count >= 2,
                  fields[1].uppercased() == "CLEAR" {
            clearCandidateSelection()
        } else if head == "CANDIDATE", isSessionActive, fields.count >= 10,
                  let slot = Int(fields[1]) {
            let candidate = SelectionCandidate(
                id: slot,
                trackID: Int(fields[2]) ?? -1,
                classID: Int(fields[3]) ?? -1,
                label: localizedTargetName(fields[9]),
                confidence: min(100, max(0, Int(fields[4]) ?? 0)),
                x: mapMaixPointToIPhone((Double(fields[5]) ?? 500) / 1000,
                                        scale: 0.62, center: savedMaixCenterX),
                y: mapMaixPointToIPhone((Double(fields[6]) ?? 500) / 1000,
                                        scale: 0.48, center: savedMaixCenterY),
                width: min(0.42, max(0.05, ((Double(fields[7]) ?? 80) / 1000) * 0.62)),
                height: min(0.48, max(0.05, ((Double(fields[8]) ?? 80) / 1000) * 0.48))
            )
            // Candidate packets continue after the 3-second scan. Smooth the
            // geometry so boxes follow real objects instead of freezing at the
            // old snapshot, while retaining a stable slot for finger selection.
            if let index = candidates.firstIndex(where: { $0.id == slot }) {
                let old = candidates[index]
                candidates[index] = SelectionCandidate(
                    id: candidate.id,
                    trackID: candidate.trackID,
                    classID: candidate.classID,
                    label: candidate.label,
                    confidence: candidate.confidence,
                    x: old.x * 0.35 + candidate.x * 0.65,
                    y: old.y * 0.35 + candidate.y * 0.65,
                    width: old.width * 0.45 + candidate.width * 0.55,
                    height: old.height * 0.45 + candidate.height * 0.55
                )
            } else {
                candidates.append(candidate)
                candidates.sort { $0.id < $1.id }
            }
            // Candidate geometry may arrive while packets are being queued,
            // but it must never end the timed scan. Only the repeated CHOOSE
            // event from MaixCAM is authoritative after the full three seconds.
            if isChoosingTarget && trackingState == .choose {
                enrollmentStatus = isCandidateListReady
                    ? "Đã quét xong • chạm đúng vật cần theo dõi"
                    : "Đang nhận đủ danh sách vật từ MaixCAM"
            }
        } else if head == "SELECTION", fields.count >= 3,
                  let slot = Int(fields[1]) {
            switch fields[2].uppercased() {
            case "PENDING":
                selectedCandidateID = slot
                isConfirmingCandidate = true
                enrollmentStatus = "Đã gửi lựa chọn • đang chờ MaixCAM xác nhận"
            case "CENTER", "ACK":
                confirmCandidateSelection()
                selectedCandidateID = slot
                hasSelectedCandidate = true
                isChoosingTarget = false
                isRefining = false
                isEnrolling = false
                finishCandidateSelection()
                needsCenterCalibration = true
                trackingState = .lock
                enrollmentStatus = "Đã chọn \(lockedTargetName) • tự đặt tại dấu + rồi bấm Căn tâm"
                calibrationStatus = "Đặt \(lockedTargetName.lowercased()) đúng dấu + rồi bấm Căn tâm"
            case "REFINING", "REFINE":
                confirmCandidateSelection()
                selectedCandidateID = slot
                hasSelectedCandidate = true
                isChoosingTarget = false
                isRefining = true
                isEnrolling = true
                enrollmentProgress = 0
                trackingState = .refine
            case "RETRY", "ERROR":
                reopenCandidateSelection(
                    status: "MaixCAM chưa nhận lựa chọn • hãy chạm lại đúng vật"
                )
            default:
                break
            }
        } else if head == "LINK", fields.count >= 2 {
            switch fields[1].uppercased() {
            case "MAIX_TX_MISSING":
                // Never show a wiring fault after valid Maix data has already
                // arrived. Older firmware could race a delayed fault packet
                // against a healthy scan and falsely accuse the TX wire.
                if maixVersion == "Đang chờ MaixCAM" &&
                    enrollmentProgress < 0.01 && candidates.isEmpty {
                    enrollmentStatus = "Đang chờ dữ liệu MaixCAM"
                    connectionText = "Đang đồng bộ MaixCAM"
                }
            case "MAIX_OK":
                connectionText = "MaixCAM và ESP32 đang hoạt động"
            default:
                break
            }
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
        isConnected = false
        isSessionActive = false
        shouldRecordVideo = false
        trackingState = .disconnected
        connectionText = "Đã nối BLE • đang mở kênh MaixCAM..."
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnected = false
        isSessionActive = false
        shouldRecordVideo = false
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
        isSessionActive = false
        shouldRecordVideo = false
        trackingState = .disconnected
        cancelEnrollmentUI()
        cancelCalibrationUI()
        eventCharacteristic = nil
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
            connectionText = "Không mở được kênh dữ liệu MaixCAM"
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
