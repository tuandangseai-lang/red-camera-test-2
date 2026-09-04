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

struct SavedTrackingProfile: Identifiable, Codable, Equatable {
    let slot: Int
    var name: String
    var modeRawValue: String
    var updatedAt: Date

    var id: Int { slot }
    var mode: TrackingMode { TrackingMode(rawValue: modeRawValue) ?? .object }
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

enum GimbalTrackingState: String {
    case disconnected
    case idle
    case acquire
    case choose
    case refine
    case multiView
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
        case .multiView: return "Đang học vật đa góc"
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
    @Published private(set) var rigVersion = "Bánh răng P 2,00:1 • T 1,60:1"
    @Published private(set) var selectedMode: TrackingMode = .waterRocket
    @Published private(set) var isEnrolling = false
    @Published private(set) var isChoosingTarget = false
    @Published private(set) var isRefining = false
    @Published private(set) var isMultiViewCapturing = false
    @Published private(set) var multiViewProgress = 0.0
    @Published private(set) var multiViewStatus = "Xoay và nghiêng vật chậm trong 3 giây"
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
    @Published private(set) var savedProfiles: [SavedTrackingProfile] = []
    @Published private(set) var activeProfileSlot: Int?
    @Published private(set) var isProfileLoading = false
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
    private var trackerPeripheral: CBPeripheral?
    private var eventCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var lifecycleActive = true
    private var reconnectWorkItem: DispatchWorkItem?
    private var enrollmentWatchdogWorkItem: DispatchWorkItem?
    private var scanCompletionWorkItem: DispatchWorkItem?
    private var selectionRetryWorkItem: DispatchWorkItem?
    private var selectionTimeoutWorkItem: DispatchWorkItem?
    private var enrollmentCycle = 0
    private var selectionCycle = 0
    private var awaitingSelectionAcknowledgement = false
    private var savedMaixCenterX = 0.5
    private var savedMaixCenterY = 0.5
    private var calibrationWasRecording = false
    private let savedProfilesKey = "SE.savedTrackingProfiles.v1"

    var trackingTitle: String {
        switch trackingState {
        case .choose: return "Chạm chọn một vật MaixCAM đã phát hiện"
        case .refine: return "Đang tinh chỉnh: \(lockedTargetName)"
        case .multiView: return "Đang học đa góc: \(lockedTargetName)"
        case .lock:
            return needsCenterCalibration
                ? "Đã chọn \(lockedTargetName) • tự đặt tại dấu + rồi bấm Căn tâm"
                : "Đã khóa: \(lockedTargetName)"
        case .search: return "Đang bắt lại: \(lockedTargetName)"
        default: return trackingState.title
        }
    }

    var canCalibrateCenter: Bool {
        // Centre alignment is intentionally repeatable. The physical relation
        // between the iPhone and MaixCAM may be adjusted after recording has
        // started, so the button must remain available for the whole session.
        isConnected && isSessionActive && hasSelectedCandidate &&
            !isConfirmingCandidate && !isRefining && !isCalibrating &&
            !isMultiViewCapturing && !isProfileLoading
    }

    var canSaveCurrentProfile: Bool {
        isConnected && isSessionActive && hasSelectedCandidate &&
            !needsCenterCalibration && !isRefining && !isCalibrating &&
            !isMultiViewCapturing && !isProfileLoading
    }

    var isCandidateListReady: Bool {
        // A dropped BLE candidate packet must not freeze the selector forever.
        // Every box already received is immediately valid and tappable.
        !candidates.isEmpty
    }

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: savedProfilesKey),
           let profiles = try? JSONDecoder().decode([SavedTrackingProfile].self, from: data) {
            savedProfiles = profiles
                .filter { (1...2).contains($0.slot) }
                .sorted { $0.slot < $1.slot }
        }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func profile(in slot: Int) -> SavedTrackingProfile? {
        savedProfiles.first { $0.slot == slot }
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

    private func base64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    func saveCurrentProfile(in slot: Int) {
        guard (1...2).contains(slot), canSaveCurrentProfile else { return }
        let existingName = profile(in: slot)?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultName = lockedTargetName.isEmpty ? String(format: "Mẫu %d", slot) : lockedTargetName
        let saved = SavedTrackingProfile(
            slot: slot,
            name: (existingName?.isEmpty == false ? existingName! : defaultName),
            modeRawValue: selectedMode.rawValue,
            updatedAt: Date()
        )
        savedProfiles.removeAll { $0.slot == slot }
        savedProfiles.append(saved)
        savedProfiles.sort { $0.slot < $1.slot }
        activeProfileSlot = slot
        persistSavedProfiles()
        send("PROFILE_SAVE,\(slot)")
    }

    func renameProfile(in slot: Int, to proposedName: String) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = savedProfiles.firstIndex(where: { $0.slot == slot }) else { return }
        savedProfiles[index].name = String(name.prefix(32))
        savedProfiles[index].updatedAt = Date()
        if activeProfileSlot == slot { lockedTargetName = savedProfiles[index].name }
        persistSavedProfiles()
    }

    func deleteProfile(in slot: Int) {
        savedProfiles.removeAll { $0.slot == slot }
        if activeProfileSlot == slot { activeProfileSlot = nil }
        persistSavedProfiles()
        send("PROFILE_DELETE,\(slot)")
    }

    func useProfile(_ profile: SavedTrackingProfile) {
        guard isConnected, (1...2).contains(profile.slot) else { return }
        if isSessionActive { send("STOP") }
        cancelEnrollmentUI()
        cancelCalibrationUI()
        selectedMode = profile.mode
        lockedTargetName = profile.name
        activeProfileSlot = profile.slot
        isProfileLoading = true
        isSessionActive = true
        shouldRecordVideo = false
        hasSelectedCandidate = true
        selectedCandidateID = profile.slot
        needsCenterCalibration = true
        trackingState = .acquire
        enrollmentStatus = "Đang mở \(profile.name) trên MaixCAM"
        calibrationStatus = "Đưa \(profile.name.lowercased()) vào dấu + rồi bấm Căn tâm"
        send("PROFILE_LOAD,\(profile.slot),\(profile.mode.rawValue)")
    }

    private func persistSavedProfiles() {
        if let data = try? JSONEncoder().encode(savedProfiles) {
            UserDefaults.standard.set(data, forKey: savedProfilesKey)
        }
    }

    private func currentProfileDisplayName(for fallbackToken: String) -> String {
        if let slot = activeProfileSlot, let profile = profile(in: slot) {
            return profile.name
        }
        return localizedTargetName(fallbackToken)
    }

    func arm() {
        cancelCalibrationUI()
        shouldRecordVideo = false
        needsCenterCalibration = false
        calibrationWasRecording = false
        activeProfileSlot = nil
        isProfileLoading = false
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
        calibrationWasRecording = false
        activeProfileSlot = nil
        isProfileLoading = false
    }

    func home() {
        cancelEnrollmentUI()
        cancelCalibrationUI()
        send("HOME")
        isSessionActive = false
        shouldRecordVideo = false
        trackingState = .home
        needsCenterCalibration = false
        calibrationWasRecording = false
        activeProfileSlot = nil
        isProfileLoading = false
    }

    func calibrateCenter() {
        guard isConnected else { return }
        guard canCalibrateCenter else {
            calibrationStatus = hasSelectedCandidate
                ? "Hãy chờ MaixCAM ghi nhớ xong mục tiêu"
                : "Hãy quét 3 giây và chạm chọn chủ thể trước"
            return
        }
        calibrationWasRecording = shouldRecordVideo
        isRefining = false
        isEnrolling = false
        isCalibrating = true
        calibrationProgress = 0
        calibrationStatus = "Đang chuẩn bị căn lại tâm iPhone và MaixCAM"
        trackingState = .calibrate
        send("CALIBRATE_CENTER")
    }

    func selectCandidate(_ candidate: SelectionCandidate) {
        guard isConnected, isChoosingTarget, isCandidateListReady,
              !isConfirmingCandidate else { return }
        cancelSelectionAcknowledgement()
        selectedCandidateID = candidate.id
        hasSelectedCandidate = true
        lockedTargetName = candidate.label
        isChoosingTarget = false
        isRefining = false
        isEnrolling = false
        enrollmentProgress = 1
        needsCenterCalibration = true
        trackingState = .lock
        enrollmentStatus = "Đã chọn \(candidate.label) • tự đặt tại dấu + rồi bấm Căn tâm"
        calibrationStatus = "Đặt \(candidate.label.lowercased()) đúng dấu + rồi bấm Căn tâm"
        finishCandidateSelection()

        // Optimistic local selection: UART still receives the identity, but the
        // UI never waits for another acknowledgement before enabling Căn tâm.
        send("SELECT,\(candidate.id)")
    }

    func selectCandidate(atX x: Double, y: Double) {
        guard isConnected, isChoosingTarget else { return }
        if candidates.isEmpty {
            selectManualPoint(atX: x, y: y)
            return
        }
        // The displayed boxes are projected from MaixCAM into the iPhone view.
        // Prefer a box containing the finger, otherwise choose the nearest one.
        let selected = candidates.min { first, second in
            candidateTapScore(first, x: x, y: y) < candidateTapScore(second, x: x, y: y)
        }
        if let selected { selectCandidate(selected) }
    }

    private func selectManualPoint(atX x: Double, y: Double) {
        cancelSelectionAcknowledgement()
        selectedCandidateID = 0
        hasSelectedCandidate = true
        lockedTargetName = selectedMode.title
        isChoosingTarget = false
        isRefining = false
        isEnrolling = false
        enrollmentProgress = 1
        needsCenterCalibration = true
        trackingState = .lock
        enrollmentStatus = "Đã chọn vùng \(selectedMode.title.lowercased()) • đưa vào dấu + rồi bấm Căn tâm"
        calibrationStatus = "Đưa \(selectedMode.title.lowercased()) đúng dấu + rồi bấm Căn tâm"
        finishCandidateSelection()

        // Inverse of the fixed-camera projection used for MaixCAM boxes.
        let rawX = min(0.95, max(0.05, savedMaixCenterX + (x - 0.5) / 0.62))
        let rawY = min(0.95, max(0.05, savedMaixCenterY + (y - 0.5) / 0.48))
        send("SELECT_POINT,\(Int((rawX * 1000).rounded())),\(Int((rawY * 1000).rounded()))")
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
        activeProfileSlot = nil
        isProfileLoading = false
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
        scanCompletionWorkItem?.cancel()
        clearCandidateSelection()
        hasSelectedCandidate = false
        isEnrolling = true
        isRefining = false
        isMultiViewCapturing = false
        multiViewProgress = 0
        enrollmentProgress = 0
        enrollmentStatus = "Giữ \(selectedMode.title.lowercased()) trước MaixCAM"

        // The visible scan is exactly three seconds. Never leave the UI waiting
        // forever for one CHOOSE packet or for a detector class it does not know.
        let completion = DispatchWorkItem { [weak self] in
            guard let self,
                  self.enrollmentCycle == cycle,
                  self.isSessionActive,
                  !self.hasSelectedCandidate,
                  !self.isRefining else { return }
            self.isEnrolling = false
            self.isChoosingTarget = true
            self.enrollmentProgress = 1
            self.trackingState = .choose
            self.enrollmentStatus = self.candidates.isEmpty
                ? "Đã quét xong • chạm trực tiếp lên vật cần theo dõi"
                : "Đã quét xong • chạm đúng ô cần theo dõi"
        }
        scanCompletionWorkItem = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.25, execute: completion)

        let watchdog = DispatchWorkItem { [weak self] in
            guard let self,
                  self.enrollmentCycle == cycle,
                  self.isEnrolling,
                  self.enrollmentProgress < 0.01 else { return }
            self.enrollmentStatus = "Đang hoàn tất danh sách vật • có thể dừng và quét lại"
        }
        enrollmentWatchdogWorkItem = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.5, execute: watchdog)
    }

    private func cancelEnrollmentUI() {
        cancelSelectionAcknowledgement()
        enrollmentCycle += 1
        enrollmentWatchdogWorkItem?.cancel()
        enrollmentWatchdogWorkItem = nil
        scanCompletionWorkItem?.cancel()
        scanCompletionWorkItem = nil
        clearCandidateSelection()
        hasSelectedCandidate = false
        isEnrolling = false
        isRefining = false
        isMultiViewCapturing = false
        multiViewProgress = 0
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
        connectionText = "Đã kết nối bộ điều khiển ESP32 SE"
        if firstActivation {
            send("APP_READY")
            send("MODE,\(selectedMode.rawValue)")
            send("H2D_STATUS")
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

        if head == "H2D" {
            parseH2DEvent(fields)
            return
        } else if head == "STATE", fields.count >= 3 {
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
                isRefining = false
                isEnrolling = false
                isCalibrating = true
                let prepare = fields.count >= 3 ? (Double(fields[2]) ?? 0) / 100 : 0
                calibrationProgress = min(0.30, max(0, prepare * 0.30))
                calibrationStatus = "Đặt \(lockedTargetName.lowercased()) vào dấu + • cách ≥20 cm"
                trackingState = .calibrate
            case "START":
                isRefining = false
                isEnrolling = false
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
                isRefining = false
                isEnrolling = false
                trackingState = .lock
                // The first alignment is followed by a separate three-second
                // multi-view learning phase. Only a repeated alignment during
                // an existing movie resumes recording immediately.
                shouldRecordVideo = calibrationWasRecording
                calibrationWasRecording = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                    self?.isCalibrating = false
                }
            case "FAILED":
                shouldRecordVideo = calibrationWasRecording
                isCalibrating = false
                isRefining = false
                isEnrolling = false
                calibrationProgress = 0
                calibrationStatus = fields.count >= 3 && fields[2] == "LOCK_FIRST"
                    ? "Hãy khóa chủ thể rồi căn tâm lại"
                    : "Không thấy chủ thể ổn định, hãy thử lại"
                trackingState = calibrationWasRecording ? .search : .acquire
                needsCenterCalibration = !calibrationWasRecording
                calibrationWasRecording = false
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
        } else if head == "MULTIVIEW", fields.count >= 4 {
            guard isSessionActive else { return }
            let progress = min(100, max(0, Double(fields[1]) ?? 0)) / 100
            let status = fields[3].uppercased()
            multiViewProgress = progress
            switch status {
            case "START", "CAPTURE":
                isCalibrating = false
                isRefining = false
                isEnrolling = false
                isMultiViewCapturing = true
                shouldRecordVideo = false
                trackingState = .multiView
                multiViewStatus = "Xoay, nghiêng \(lockedTargetName.lowercased()) để học nhiều góc"
            case "READY":
                isMultiViewCapturing = false
                multiViewProgress = 1
                multiViewStatus = "Đã học thêm nhiều góc của \(lockedTargetName.lowercased())"
                trackingState = .lock
                shouldRecordVideo = true
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
        } else if head == "PROFILE", fields.count >= 3,
                  let slot = Int(fields[1]) {
            let status = fields[2].uppercased()
            switch status {
            case "LOADING":
                isProfileLoading = true
                shouldRecordVideo = false
                trackingState = .acquire
                enrollmentStatus = "Đang mở mẫu đã lưu trên MaixCAM"
            case "LOADED":
                isProfileLoading = false
                activeProfileSlot = slot
                if fields.count >= 4,
                   let mode = TrackingMode(rawValue: fields[3].uppercased()) {
                    selectedMode = mode
                }
                lockedTargetName = profile(in: slot)?.name ??
                    (fields.count >= 5 ? localizedTargetName(fields[4]) : selectedMode.title)
                hasSelectedCandidate = true
                selectedCandidateID = slot
                needsCenterCalibration = true
                isEnrolling = false
                isRefining = false
                trackingState = .lock
                enrollmentStatus = "Đã mở \(lockedTargetName) • đặt vào dấu + rồi bấm Căn tâm"
                calibrationStatus = "Căn tâm và học bổ sung \(lockedTargetName.lowercased()) trong 3 giây"
            case "SAVED":
                activeProfileSlot = slot
                connectionText = "Đã lưu mẫu \(profile(in: slot)?.name ?? String(slot))"
            case "DELETED":
                if activeProfileSlot == slot { activeProfileSlot = nil }
            case "ERROR":
                isProfileLoading = false
                if fields.count >= 4, fields[3].uppercased() == "LOAD" {
                    isSessionActive = false
                    hasSelectedCandidate = false
                    needsCenterCalibration = false
                    trackingState = .idle
                    enrollmentStatus = "Không mở được mẫu • hãy lưu lại mẫu này"
                }
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
                scanCompletionWorkItem?.cancel()
                confirmCandidateSelection()
                if fields.count >= 5 {
                    lockedTargetName = currentProfileDisplayName(for: fields[4])
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
                scanCompletionWorkItem?.cancel()
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
                scanCompletionWorkItem?.cancel()
                confirmCandidateSelection()
                if fields.count >= 5 {
                    lockedTargetName = currentProfileDisplayName(for: fields[4])
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
                    lockedTargetName = currentProfileDisplayName(for: fields[4])
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
            lockedTargetName = currentProfileDisplayName(for: fields[1])
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
                // Selection is already final locally. Never re-open a blocking
                // acknowledgement state because of a delayed transport packet.
                isConfirmingCandidate = false
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
                if hasSelectedCandidate {
                    isConfirmingCandidate = false
                    isChoosingTarget = false
                    needsCenterCalibration = true
                    trackingState = .lock
                    enrollmentStatus = "Đã chọn \(lockedTargetName) • đặt tại dấu + rồi bấm Căn tâm"
                } else {
                    reopenCandidateSelection(status: "Chạm lại đúng vật cần theo dõi")
                }
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
                    enrollmentStatus = "Đang chờ danh sách vật từ MaixCAM"
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

    private func parseH2DEvent(_ fields: [String]) {
        guard fields.count >= 2 else { return }
        isH2DBridge = true
        connectionText = "Đã kết nối ESP32 • cầu nối H2D"

        switch fields[1].uppercased() {
        case "STATUS":
            guard fields.count >= 3 else { return }
            let status = fields[2].uppercased()
            let known: [String: String] = [
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
        isH2DBridge = false
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
        isH2DBridge = false
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
        isH2DBridge = false
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
        h2dBridgeStatus = "ESP32 đã ngắt • đang kết nối lại"
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
