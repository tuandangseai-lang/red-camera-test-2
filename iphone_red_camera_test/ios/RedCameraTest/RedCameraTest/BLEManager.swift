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
    @Published private(set) var trackingState: GimbalTrackingState = .disconnected
    @Published private(set) var confidence = 0
    @Published private(set) var targetX = 0.5
    @Published private(set) var targetY = 0.5
    @Published private(set) var targetWidth = 0.08
    @Published private(set) var targetHeight = 0.08
    @Published private(set) var lockedTargetName = "Tên lửa nước"
    @Published private(set) var panAngle = 90.0
    @Published private(set) var tiltAngle = 30.0
    @Published private(set) var maixVersion = "Đang chờ MaixCAM"
    @Published private(set) var rigVersion = "Bánh răng P 3,20:1 • T 1,60:1"
    @Published private(set) var selectedMode: TrackingMode = .waterRocket
    @Published private(set) var isEnrolling = false
    @Published private(set) var isChoosingTarget = false
    @Published private(set) var isRefining = false
    @Published private(set) var candidates: [SelectionCandidate] = []
    @Published private(set) var selectedCandidateID: Int?
    @Published private(set) var enrollmentProgress = 0.0
    @Published private(set) var enrollmentStatus = "Giữ chủ thể trước MaixCAM"
    @Published private(set) var isCalibrating = false
    @Published private(set) var calibrationProgress = 0.0
    @Published private(set) var calibrationStatus = "Đặt cùng chủ thể vào tâm iPhone"

    private let serviceUUID = CBUUID(string: "7E57A000-8E3A-4D6A-9B2B-13B10A000001")
    private let eventUUID = CBUUID(string: "7E57A001-8E3A-4D6A-9B2B-13B10A000001")
    private let commandUUID = CBUUID(string: "7E57A002-8E3A-4D6A-9B2B-13B10A000001")

    private var central: CBCentralManager!
    private var trackerPeripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var lifecycleActive = true
    private var reconnectWorkItem: DispatchWorkItem?
    private var enrollmentCycle = 0

    var trackingTitle: String {
        switch trackingState {
        case .choose: return "Chạm vào khung của vật cần bám"
        case .refine: return "Đang tinh chỉnh: \(lockedTargetName)"
        case .lock: return "Đã khóa: \(lockedTargetName)"
        case .search: return "Đang bắt lại: \(lockedTargetName)"
        default: return trackingState.title
        }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func arm() {
        cancelCalibrationUI()
        beginEnrollmentUI()
        send("ARM")
        trackingState = .acquire
    }

    func stop() {
        cancelEnrollmentUI()
        cancelCalibrationUI()
        send("STOP")
        trackingState = .idle
    }

    func home() {
        cancelEnrollmentUI()
        cancelCalibrationUI()
        send("HOME")
        trackingState = .home
    }

    func calibrateCenter() {
        guard isConnected else { return }
        guard trackingState == .lock else {
            calibrationStatus = "Hãy khóa chủ thể trước khi căn tâm"
            return
        }
        isCalibrating = true
        calibrationProgress = 0
        calibrationStatus = "Giữ chủ thể đúng giữa màn hình iPhone"
        trackingState = .calibrate
        send("CALIBRATE_CENTER")
    }

    func selectCandidate(_ candidate: SelectionCandidate) {
        guard isConnected, isChoosingTarget else { return }
        selectedCandidateID = candidate.id
        lockedTargetName = candidate.label
        isChoosingTarget = false
        isRefining = true
        isEnrolling = true
        enrollmentProgress = 0
        enrollmentStatus = "Giữ \(candidate.label.lowercased()) ổn định để MaixCAM ghi nhớ"
        trackingState = .refine
        send("SELECT,\(candidate.id)")
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
        trackingState = .idle
        cancelEnrollmentUI()
        cancelCalibrationUI()
        send("MODE,\(mode.rawValue)")
    }

    private func beginEnrollmentUI() {
        enrollmentCycle += 1
        clearCandidateSelection()
        isEnrolling = true
        isRefining = false
        enrollmentProgress = 0
        enrollmentStatus = "Giữ \(selectedMode.title.lowercased()) trước MaixCAM"
    }

    private func cancelEnrollmentUI() {
        enrollmentCycle += 1
        clearCandidateSelection()
        isEnrolling = false
        isRefining = false
        enrollmentProgress = 0
        enrollmentStatus = "Giữ chủ thể trước MaixCAM"
    }

    private func clearCandidateSelection() {
        isChoosingTarget = false
        selectedCandidateID = nil
        candidates = []
    }

    private func cancelCalibrationUI() {
        isCalibrating = false
        calibrationProgress = 0
        calibrationStatus = "Đặt cùng chủ thể vào tâm iPhone"
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

    private func mapMaixPointToIPhone(_ raw: Double, scale: Double) -> Double {
        // Two fixed cameras have different fields of view. Calibration removes
        // the centre offset; this scale prevents raw Maix coordinates from
        // being drawn as if both sensors had identical optics.
        min(1, max(0, 0.5 + (raw - 0.5) * scale))
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
            case "IDLE", "HOME_DONE": trackingState = .idle
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
            maixVersion = fields.dropFirst().joined(separator: " • ")
        } else if head == "RIG", fields.count >= 7 {
            rigVersion = "Bánh răng P \(fields[2]):1 • T \(fields[3]):1"
        } else if head == "CALIBRATE", fields.count >= 2 {
            switch fields[1].uppercased() {
            case "START":
                isCalibrating = true
                calibrationProgress = 0
                calibrationStatus = "Giữ \(lockedTargetName.lowercased()) đúng tâm iPhone trong 2 giây"
                trackingState = .calibrate
            case "PROGRESS":
                isCalibrating = true
                if fields.count >= 3 {
                    calibrationProgress = min(1, max(0, (Double(fields[2]) ?? 0) / 100))
                }
                calibrationStatus = calibrationProgress > 0
                    ? "Đang đo độ lệch hai camera"
                    : "Đang chờ MaixCAM khóa đúng chủ thể"
            case "DONE":
                calibrationProgress = 1
                calibrationStatus = "Đã căn tâm hai camera"
                trackingState = .lock
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                    self?.isCalibrating = false
                }
            case "FAILED":
                isCalibrating = false
                calibrationProgress = 0
                calibrationStatus = fields.count >= 3 && fields[2] == "LOCK_FIRST"
                    ? "Hãy khóa chủ thể rồi căn tâm lại"
                    : "Không thấy chủ thể ổn định, hãy thử lại"
                trackingState = .acquire
            case "SAVED":
                break
            default:
                break
            }
        } else if head == "ENROLL", fields.count >= 4 {
            let progress = min(100, max(0, Double(fields[1]) ?? 0)) / 100
            if let mode = TrackingMode(rawValue: fields[2].uppercased()) {
                selectedMode = mode
            }
            let status = fields[3].uppercased()
            enrollmentProgress = progress
            switch status {
            case "READY":
                if fields.count >= 5 {
                    lockedTargetName = localizedTargetName(fields[4])
                }
                isEnrolling = false
                isRefining = false
                clearCandidateSelection()
                enrollmentProgress = 1
                enrollmentStatus = "MaixCAM đã khóa \(lockedTargetName.lowercased())"
                trackingState = .lock
            case "CHOOSE":
                isEnrolling = false
                isRefining = false
                isChoosingTarget = true
                selectedCandidateID = nil
                trackingState = .choose
                enrollmentStatus = "Chạm vào khung của đúng \(selectedMode.title.lowercased())"
            case "REFINE":
                isChoosingTarget = false
                isRefining = true
                isEnrolling = true
                trackingState = .refine
                if fields.count >= 5 {
                    lockedTargetName = localizedTargetName(fields[4])
                }
                enrollmentStatus = "MaixCAM đang đối chiếu và ghi nhớ \(lockedTargetName.lowercased())"
            case "RETRY":
                clearCandidateSelection()
                isEnrolling = true
                isRefining = false
                enrollmentProgress = 0
                enrollmentStatus = "Đưa \(selectedMode.title.lowercased()) vào giữa hình"
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
        } else if head == "CANDIDATE", fields.count >= 10,
                  let slot = Int(fields[1]) {
            let candidate = SelectionCandidate(
                id: slot,
                trackID: Int(fields[2]) ?? -1,
                classID: Int(fields[3]) ?? -1,
                label: localizedTargetName(fields[9]),
                confidence: min(100, max(0, Int(fields[4]) ?? 0)),
                x: mapMaixPointToIPhone((Double(fields[5]) ?? 500) / 1000, scale: 0.62),
                y: mapMaixPointToIPhone((Double(fields[6]) ?? 500) / 1000, scale: 0.48),
                width: min(0.42, max(0.05, ((Double(fields[7]) ?? 80) / 1000) * 0.62)),
                height: min(0.48, max(0.05, ((Double(fields[8]) ?? 80) / 1000) * 0.48))
            )
            if let index = candidates.firstIndex(where: { $0.id == slot }) {
                candidates[index] = candidate
            } else {
                candidates.append(candidate)
                candidates.sort { $0.id < $1.id }
            }
        } else if head == "SELECTION", fields.count >= 3,
                  fields[2].uppercased() == "REFINE" {
            isChoosingTarget = false
            isRefining = true
            isEnrolling = true
            enrollmentProgress = 0
            trackingState = .refine
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
        isConnected = true
        trackingState = .idle
        connectionText = "Đã kết nối ESP32 SE"
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnected = false
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
        trackingState = .disconnected
        cancelEnrollmentUI()
        cancelCalibrationUI()
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
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            } else if characteristic.uuid == commandUUID {
                commandCharacteristic = characteristic
                send("PING")
                send("MODE,\(selectedMode.rawValue)")
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
        parseEvent(message)
    }
}
