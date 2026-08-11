import AVFoundation
import ARKit
import CoreImage
import ImageIO
import Photos
import QuartzCore
import simd
import SwiftUI
import UIKit
import Vision

enum ScanSubjectKind: String, CaseIterable, Codable, Identifiable {
    case person
    case animal
    case object

    var id: String { rawValue }

    var title: String {
        switch self {
        case .person: return "Người"
        case .animal: return "Thú"
        case .object: return "Vật"
        }
    }

    var symbol: String {
        switch self {
        case .person: return "person.fill"
        case .animal: return "pawprint.fill"
        case .object: return "shippingbox.fill"
        }
    }
}

enum RocketLearningStage: Equatable {
    case idle
    case scanningNear
    case waitingFar
    case scanningFar
    case waitingAround
    case scanningAround
    case ready
    case verifying
    case tracking
    case lost

    var isScanning: Bool {
        switch self {
        case .scanningNear, .scanningFar, .scanningAround:
            return true
        default:
            return false
        }
    }

    var showsGuide: Bool {
        switch self {
        case .tracking:
            return false
        default:
            return true
        }
    }
}

final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    let arSession = ARSession()

    @Published private(set) var statusText = "Đang chuẩn bị camera..."
    @Published private(set) var zoomText = "0.5×"
    @Published private(set) var captureModeText = "Đang chọn camera 0,5× / 60 fps..."
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
    @Published private(set) var stage: RocketLearningStage = .idle
    @Published private(set) var learnedSamples = 0
    @Published private(set) var scanProgress = 0.0
    @Published private(set) var scanSampleCount = 0
    @Published private(set) var scanSampleTarget = 0
    @Published private(set) var scanIsSufficient = false
    @Published private(set) var scanNeedsNewAngle = false
    @Published private(set) var scanGuidanceText = "Đưa tên lửa vào khung"
    @Published private(set) var crystalCells: [Int] = []
    @Published private(set) var crystalDepths: [Int: Double] = [:]
    @Published private(set) var crystalCoverage = 0.0
    @Published private(set) var scanViewpointCount = 0
    @Published private(set) var surfacePointCount = 0
    @Published private(set) var isARScanning = false
    @Published private(set) var targetRect: CGRect?
    @Published private(set) var trackingConfidence = 0.0
    @Published private(set) var matchText = "Chưa có mẫu"
    @Published private(set) var frameAspectRatio: CGFloat = 9.0 / 16.0
    @Published private(set) var savedProfiles: [SavedScanProfile] = []
    @Published private(set) var activeProfileID: UUID?
    @Published var scanBoxScale = 0.42
    @Published var scanSubjectKind: ScanSubjectKind = .object
    @Published var voiceAnnouncementsEnabled = true

    let crystalGridColumns = 16
    let crystalGridRows = 24

    var onEvent: ((String) -> Void)?

    var scanRect: CGRect {
        let width = CGFloat(max(0.12, min(scanBoxScale, 0.62)))
        let height = min(0.86, max(0.24, width * 1.65))
        return CGRect(
            x: (1.0 - width) / 2.0,
            y: (1.0 - height) / 2.0,
            width: width,
            height: height
        )
    }

    private enum ScanKind: Equatable {
        case near
        case far
        case around
    }

    private enum ProcessingMode {
        case idle
        case scanning(ScanKind)
        case verifying
        case tracking
        case lost
    }

    private let sessionQueue = DispatchQueue(label: "vn.rockettracker.camera.session")
    private let videoQueue = DispatchQueue(label: "vn.rockettracker.camera.frames")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let voiceNotifier = VoiceNotifier()
    private let profileStore = ScanProfileStore()

    private var videoDevice: AVCaptureDevice?
    private var ultraWideDeviceZoomFactor: CGFloat = 1.0
    private var mainDeviceZoomFactor: CGFloat = 1.96
    private var ultraWideDisplayZoomFactor: CGFloat = 0.5
    private var mainDisplayZoomFactor: CGFloat = 0.98
    private var isZoomedIn = false
    private var didRequestStart = false
    private var configured = false
    private var pendingArm = false

    // Các biến dưới đây chỉ được đọc/ghi trên videoQueue.
    private var processingMode: ProcessingMode = .idle
    private var processingRect = CGRect(x: 0.29, y: 0.15, width: 0.42, height: 0.70)
    private var featureSamples: [VNFeaturePrintObservation] = []
    private var stageStartingSampleCount = 0
    private var shapeScanCoverage = 0.0
    private var crystalBaseCells: [Int] = []
    private var lastShapeScanAt = 0.0
    private var frameCounter = 0
    private var featureFrameCounter = 0
    private var trackingFrameCounter = 0
    private var lowConfidenceFrames = 0
    private var trackingObservation: VNDetectedObjectObservation?
    private var sequenceHandler = VNSequenceRequestHandler()
    private var shouldRecordAfterVerification = true

    // Quét 3D gần đúng trên iPhone không LiDAR: ARKit cung cấp vị trí camera và
    // điểm đặc trưng 3D, Vision giữ lại các điểm nằm trên mặt nạ chủ thể.
    private var activeARScanKind: ScanKind?
    private var estimatedObjectCenter: SIMD3<Float>?
    private var capturedAzimuthBins: Set<Int> = []
    private var accumulatedSurfacePoints: [SIMD3<Float>] = []
    private var scanReferenceImages: [Data] = []
    private var lastARScanAt = 0.0
    private let requiredAzimuthBins = 8
    private let totalAzimuthBins = 10

    private var zoomInWorkItem: DispatchWorkItem?
    private var zoomFinishedWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        arSession.delegate = self
        arSession.delegateQueue = videoQueue
        savedProfiles = profileStore.load()
    }

    func start() {
        guard !didRequestStart else { return }
        didRequestStart = true

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }

        AVCaptureDevice.requestAccess(for: .video) { [weak self] cameraGranted in
            guard let self else { return }
            guard cameraGranted else {
                DispatchQueue.main.async {
                    self.statusText = "Hãy cấp quyền Camera trong Cài đặt"
                }
                return
            }

            AVCaptureDevice.requestAccess(for: .audio) { [weak self] microphoneGranted in
                guard let self else { return }
                self.sessionQueue.async {
                    self.configureSession(includeAudio: microphoneGranted)
                }
            }
        }
    }

    // ESP32 gửi ARM sẽ dùng mẫu đã học để khóa và bắt đầu quay.
    func arm() {
        guard !isRecording else { return }
        guard isReady else {
            pendingArm = true
            statusText = "Đã nhận ARM; đang chờ camera sẵn sàng..."
            return
        }
        guard stage == .ready || stage == .lost else {
            statusText = "Hãy quét hình dạng tới khi tinh thể phủ 80% trước"
            return
        }
        startTrackingAndRecording()
    }

    func startShapeScan() {
        guard isReady, !isRecording else { return }
        startScan(kind: .near, resetProfile: true)
    }

    func startFarScan() {
        guard stage == .waitingFar, !isRecording else { return }
        startScan(kind: .far, resetProfile: false)
    }

    func startAroundScan() {
        guard (stage == .waitingAround || stage == .ready), !isRecording else { return }
        startScan(kind: .around, resetProfile: false)
    }

    func resetProfile() {
        guard !isRecording else { return }
        stopARScanAndResumeCamera()
        voiceNotifier.stop()
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.processingMode = .idle
            self.featureSamples.removeAll()
            self.scanReferenceImages.removeAll()
            self.trackingObservation = nil
            self.sequenceHandler = VNSequenceRequestHandler()
        }
        stage = .idle
        learnedSamples = 0
        scanProgress = 0
        scanSampleCount = 0
        scanSampleTarget = 0
        scanIsSufficient = false
        scanNeedsNewAngle = false
        scanGuidanceText = "Đưa tên lửa vào khung"
        crystalCells = []
        crystalDepths = [:]
        crystalCoverage = 0
        scanViewpointCount = 0
        surfacePointCount = 0
        targetRect = nil
        trackingConfidence = 0
        matchText = "Chưa có mẫu"
        activeProfileID = nil
        statusText = "Đặt tên lửa vào khung, chỉnh kích thước rồi bấm Quét hình dạng"
        onEvent?("PROFILE_RESET")
    }

    func cancelShapeScan() {
        guard stage.isScanning else { return }
        stopARScanAndResumeCamera()
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.processingMode = .idle
            self.activeARScanKind = nil
            self.scanReferenceImages.removeAll()
        }
        stage = .idle
        scanProgress = 0
        scanSampleCount = 0
        scanSampleTarget = 80
        scanIsSufficient = false
        scanNeedsNewAngle = false
        scanGuidanceText = "Đã dừng quét"
        crystalCells = []
        crystalDepths = [:]
        crystalCoverage = 0
        scanViewpointCount = 0
        surfacePointCount = 0
        targetRect = nil
        statusText = "Đã dừng quét 3D gần đúng"
        onEvent?("SCAN_CANCELLED")
    }

    func activateProfile(_ profile: SavedScanProfile) {
        guard !isRecording, !stage.isScanning else { return }
        statusText = "Đang mở \(profile.name)..."
        scanSubjectKind = profile.subjectKind

        videoQueue.async { [weak self] in
            guard let self else { return }
            let observations = profile.referenceImages.compactMap {
                self.featurePrint(fromJPEGData: $0)
            }
            guard !observations.isEmpty else {
                DispatchQueue.main.async {
                    self.statusText = "Mẫu này không còn dữ liệu ảnh hợp lệ"
                }
                return
            }

            self.featureSamples = observations
            self.processingMode = .idle
            self.trackingObservation = nil
            self.sequenceHandler = VNSequenceRequestHandler()

            DispatchQueue.main.async {
                self.activeProfileID = profile.id
                self.learnedSamples = observations.count
                self.surfacePointCount = profile.surfacePointCount
                self.scanProgress = 0.8
                self.scanSampleCount = 80
                self.scanSampleTarget = 80
                self.scanIsSufficient = true
                self.scanNeedsNewAngle = false
                self.stage = .ready
                self.matchText = "Đã mở \(profile.name) • \(observations.count) góc"
                self.statusText = "Mẫu đã sẵn sàng để khóa, bám và quay"
                self.announce("Đã mở mẫu. Sẵn sàng bám mục tiêu.", kind: .success)
                self.onEvent?("PROFILE_LOADED")
            }
        }
    }

    func deleteProfile(_ profile: SavedScanProfile) {
        guard !isRecording, !stage.isScanning else { return }
        savedProfiles = profileStore.delete(id: profile.id)
        guard activeProfileID == profile.id else { return }
        resetProfile()
        statusText = "Đã xóa \(profile.name)"
    }

    func startTrackingAndRecording() {
        guard isReady, !isRecording, (stage == .ready || stage == .lost) else { return }
        let rect = scanRect
        let recordAfterLock = !isRecording
        stage = .verifying
        targetRect = rect
        trackingConfidence = 0
        matchText = "Đang so với mẫu đã học..."
        statusText = "Giữ tên lửa trong khung để xác minh và khóa mục tiêu"

        videoQueue.async { [weak self] in
            guard let self else { return }
            self.processingRect = rect
            self.shouldRecordAfterVerification = recordAfterLock
            self.processingMode = .verifying
        }
    }

    func reacquireTarget() {
        guard stage == .lost else { return }
        let rect = scanRect
        stage = .verifying
        targetRect = rect
        matchText = "Đang bắt lại mục tiêu..."
        statusText = "Đưa tên lửa vào khung để bắt lại"
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.processingRect = rect
            self.shouldRecordAfterVerification = false
            self.processingMode = .verifying
        }
    }

    func stopRecording() {
        cancelZoomSequence()
        videoQueue.async { [weak self] in
            self?.processingMode = .idle
            self?.trackingObservation = nil
        }
        targetRect = nil
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
        }
    }

    private func startScan(kind: ScanKind, resetProfile: Bool) {
        guard ARWorldTrackingConfiguration.isSupported else {
            statusText = "Máy không hỗ trợ ARKit World Tracking"
            return
        }
        let rect = scanRect
        let requiredSamples = sampleTarget(for: kind)

        switch kind {
        case .near:
            stage = .scanningNear
            statusText = "Đi chậm vòng quanh chủ thể • giữ chủ thể đứng yên trong khung"
        case .far:
            stage = .scanningFar
            statusText = "Quét xa không giới hạn thời gian • làm theo mũi chỉ dẫn"
        case .around:
            stage = .scanningAround
            statusText = "Quét xung quanh không giới hạn thời gian • làm theo mũi chỉ dẫn"
        }

        scanProgress = 0
        scanSampleCount = 0
        scanSampleTarget = requiredSamples
        scanIsSufficient = false
        scanNeedsNewAngle = false
        scanGuidanceText = "Giữ đúng chủ thể trong khung để lấy góc 3D đầu tiên"
        crystalCells = []
        crystalDepths = [:]
        crystalCoverage = 0
        scanViewpointCount = 0
        surfacePointCount = 0
        targetRect = rect
        matchText = "3D AR 0% • 0/8 góc"

        videoQueue.async { [weak self] in
            guard let self else { return }
            if resetProfile {
                self.featureSamples.removeAll()
                self.sequenceHandler = VNSequenceRequestHandler()
                self.trackingObservation = nil
            } else if self.featureSamples.count > 180 {
                self.featureSamples.removeFirst(self.featureSamples.count - 180)
            }
            self.processingRect = rect
            self.stageStartingSampleCount = self.featureSamples.count
            self.shapeScanCoverage = 0
            self.crystalBaseCells.removeAll()
            self.capturedAzimuthBins.removeAll()
            self.accumulatedSurfacePoints.removeAll()
            self.scanReferenceImages.removeAll()
            self.estimatedObjectCenter = nil
            self.featureFrameCounter = 0
            self.lastShapeScanAt = 0
            self.lastARScanAt = 0
            self.activeARScanKind = kind
            self.processingMode = .idle
            self.beginARScan()
        }

        onEvent?("SCAN_\(scanName(kind))_STARTED")
    }

    private func finishScan(kind: ScanKind) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            let totalSampleCount = self.featureSamples.count
            let coveragePercent = Int((self.shapeScanCoverage * 100).rounded())
            let isComplete = self.shapeScanCoverage >= 0.8
            let publishedCoverage = self.shapeScanCoverage
            self.processingMode = .idle
            self.activeARScanKind = nil
            var savedProfile: SavedScanProfile?
            var updatedProfiles = self.savedProfiles
            if isComplete, !self.scanReferenceImages.isEmpty {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "vi_VN")
                formatter.dateFormat = "dd/MM HH:mm"
                let profile = SavedScanProfile(
                    id: UUID(),
                    name: "\(self.scanSubjectKind.title) \(formatter.string(from: Date()))",
                    createdAt: Date(),
                    subjectKind: self.scanSubjectKind,
                    referenceImages: self.scanReferenceImages,
                    surfacePointCount: self.accumulatedSurfacePoints.count
                )
                updatedProfiles = self.profileStore.save(profile)
                savedProfile = profile
            }
            DispatchQueue.main.async {
                self.stopARScanAndResumeCamera()
                self.scanSampleCount = coveragePercent
                self.scanSampleTarget = 80
                self.scanProgress = publishedCoverage
                self.scanIsSufficient = isComplete
                self.scanNeedsNewAngle = false
                self.learnedSamples = totalSampleCount
                if let savedProfile {
                    self.savedProfiles = updatedProfiles
                    self.activeProfileID = savedProfile.id
                }

                guard isComplete else {
                    self.stage = .idle
                    self.matchText = "TINH THỂ \(coveragePercent)% • chưa đạt 80%"
                    self.statusText = "Đặt tên lửa gọn trong khung rồi quét lại hình dạng"
                    return
                }

                self.scanProgress = 0.8
                self.scanIsSufficient = true
                self.stage = .ready
                self.matchText = "3D AR 80% • đã tự lưu mẫu \(self.savedProfiles.count)/5"
                self.statusText = "Đã lưu mẫu. Có thể khóa, bám và quay"
                self.announce("Đã quét đủ các góc 3D. Sẵn sàng bám mục tiêu.", kind: .success)
                self.onEvent?("SHAPE_SCAN_DONE")
            }
        }
    }

    private func scanName(_ kind: ScanKind) -> String {
        switch kind {
        case .near: return "NEAR"
        case .far: return "FAR"
        case .around: return "AROUND"
        }
    }

    private func sampleTarget(for kind: ScanKind) -> Int {
        80
    }

    private func beginARScan() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }

            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravity
            configuration.isAutoFocusEnabled = true
            self.arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])

            DispatchQueue.main.async {
                self.isARScanning = true
            }
        }
    }

    private func stopARScanAndResumeCamera() {
        arSession.pause()
        if isARScanning {
            isARScanning = false
        }
        sessionQueue.async { [weak self] in
            guard let self, self.configured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    private func foregroundCrystalCells(
        from pixelBuffer: CVPixelBuffer,
        normalizedTopLeftRect rect: CGRect,
        orientation: CGImagePropertyOrientation = .up
    ) -> [Int]? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        request.regionOfInterest = CGRect(
            x: rect.minX,
            y: 1.0 - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)

        do {
            try handler.perform([request])
            guard let observation = request.results?.first,
                  !observation.allInstances.isEmpty else { return nil }
            let maskBuffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances,
                from: handler
            )
            let maskImage = CIImage(cvPixelBuffer: maskBuffer).oriented(orientation)
            let extent = maskImage.extent
            let cropRect = CGRect(
                x: extent.minX + rect.minX * extent.width,
                y: extent.minY + (1.0 - rect.maxY) * extent.height,
                width: rect.width * extent.width,
                height: rect.height * extent.height
            ).intersection(extent)
            guard cropRect.width > 1, cropRect.height > 1 else { return nil }

            let moved = maskImage
                .cropped(to: cropRect)
                .transformed(by: CGAffineTransform(
                    translationX: -cropRect.minX,
                    y: -cropRect.minY
                ))
            let scaled = moved.transformed(by: CGAffineTransform(
                scaleX: CGFloat(crystalGridColumns) / cropRect.width,
                y: CGFloat(crystalGridRows) / cropRect.height
            ))
            var bitmap = [UInt8](
                repeating: 0,
                count: crystalGridColumns * crystalGridRows
            )
            ciContext.render(
                scaled,
                toBitmap: &bitmap,
                rowBytes: crystalGridColumns,
                bounds: CGRect(
                    x: 0,
                    y: 0,
                    width: crystalGridColumns,
                    height: crystalGridRows
                ),
                format: .L8,
                colorSpace: nil
            )

            var cells: [Int] = []
            for visualRow in 0..<crystalGridRows {
                let maskRow = crystalGridRows - 1 - visualRow
                for column in 0..<crystalGridColumns {
                    let maskIndex = maskRow * crystalGridColumns + column
                    if bitmap[maskIndex] > 48 {
                        cells.append(visualRow * crystalGridColumns + column)
                    }
                }
            }
            return cells.count >= 8 ? cells : nil
        } catch {
            return nil
        }
    }

    private func fallbackRocketCells() -> [Int] {
        var cells: [Int] = []
        for row in 0..<crystalGridRows {
            let y = (Double(row) + 0.5) / Double(crystalGridRows)
            let halfWidth: Double
            if y < 0.16 {
                halfWidth = 0.04 + y * 0.75
            } else if y > 0.80 {
                halfWidth = 0.16 + (y - 0.80) * 0.65
            } else {
                halfWidth = 0.16
            }
            for column in 0..<crystalGridColumns {
                let x = (Double(column) + 0.5) / Double(crystalGridColumns)
                if abs(x - 0.5) <= halfWidth {
                    cells.append(row * crystalGridColumns + column)
                }
            }
        }
        return cells
    }

    private func connectedCrystalCells(from cells: [Int], coverage: Double) -> [Int] {
        let available = Set(cells)
        guard !available.isEmpty else { return [] }

        let centerColumn = crystalGridColumns / 2
        let centerRow = crystalGridRows / 2
        func distanceToCenter(_ index: Int) -> Int {
            let column = index % crystalGridColumns
            let row = index / crystalGridColumns
            return abs(column - centerColumn) + abs(row - centerRow)
        }

        var remaining = available
        var ordered: [Int] = []
        while !remaining.isEmpty {
            guard let seed = remaining.min(by: {
                distanceToCenter($0) < distanceToCenter($1)
            }) else { break }
            var queue = [seed]
            remaining.remove(seed)
            var cursor = 0
            while cursor < queue.count {
                let current = queue[cursor]
                cursor += 1
                ordered.append(current)
                let column = current % crystalGridColumns
                let row = current / crystalGridColumns
                for rowOffset in -1...1 {
                    for columnOffset in -1...1 where rowOffset != 0 || columnOffset != 0 {
                        let nextColumn = column + columnOffset
                        let nextRow = row + rowOffset
                        guard nextColumn >= 0, nextColumn < crystalGridColumns,
                              nextRow >= 0, nextRow < crystalGridRows else { continue }
                        let next = nextRow * crystalGridColumns + nextColumn
                        if remaining.remove(next) != nil {
                            queue.append(next)
                        }
                    }
                }
            }
        }

        let visibleCount = max(1, min(
            ordered.count,
            Int((Double(ordered.count) * min(0.8, coverage)).rounded())
        ))
        return Array(ordered.prefix(visibleCount))
    }

    private func configureSession(includeAudio: Bool) {
        guard !configured else { return }

        session.beginConfiguration()
        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
        } else {
            session.sessionPreset = .high
        }

        let dualWideCamera = AVCaptureDevice.default(
            .builtInDualWideCamera,
            for: .video,
            position: .back
        )
        let camera = dualWideCamera
            ?? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)

        guard let camera,
           let cameraInput = try? AVCaptureDeviceInput(device: camera),
           session.canAddInput(cameraInput) else {
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.statusText = "Không mở được camera sau"
            }
            return
        }

        session.addInput(cameraInput)
        videoDevice = camera
        configureFastWideCapture(camera, isDualWide: dualWideCamera != nil)
        configureAudioSession(includeAudio: includeAudio)

        if includeAudio,
           let microphone = AVCaptureDevice.default(for: .audio),
           let microphoneInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(microphoneInput) {
            session.addInput(microphoneInput)
        }

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }

        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoDataOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        }

        if let movieConnection = movieOutput.connection(with: .video),
           movieConnection.isVideoOrientationSupported {
            movieConnection.videoOrientation = .portrait
        }
        if let dataConnection = videoDataOutput.connection(with: .video),
           dataConnection.isVideoOrientationSupported {
            dataConnection.videoOrientation = .portrait
        }

        session.commitConfiguration()
        configured = true
        session.startRunning()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isReady = true
            self.statusText = "Đặt tên lửa vào khung; app đang dùng góc siêu rộng để tránh hụt mục tiêu"
            if self.pendingArm {
                self.pendingArm = false
                self.statusText = "Đã nhận ARM nhưng cần quét tên lửa trước"
            }
        }
    }

    private func configureAudioSession(includeAudio: Bool) {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            if includeAudio {
                session.automaticallyConfiguresApplicationAudioSession = false
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .videoRecording,
                    options: [.defaultToSpeaker, .duckOthers]
                )
            } else {
                try audioSession.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
            }
            try audioSession.setActive(true)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.captureModeText += " • chưa mở được loa báo"
            }
        }
    }

    private func announce(_ text: String, kind: VoiceNotifier.FeedbackKind) {
        guard voiceAnnouncementsEnabled else { return }
        voiceNotifier.speak(text, kind: kind)
    }

    private func configureFastWideCapture(_ camera: AVCaptureDevice, isDualWide: Bool) {
        let desiredFPS = 60.0
        let formatsAt60FPS = camera.formats
            .filter { format in
                format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= desiredFPS && $0.maxFrameRate >= desiredFPS
                }
            }
        let preferred4KFormat = formatsAt60FPS.last { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width == 3840 && dimensions.height == 2160
        }
        let preferredFullHDFormat = formatsAt60FPS.last { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width == 1920 && dimensions.height == 1080
        }
        let preferredFormat = preferred4KFormat ?? preferredFullHDFormat

        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }

            if let preferredFormat {
                camera.activeFormat = preferredFormat
                let duration = CMTime(value: 1, timescale: 60)
                camera.activeVideoMinFrameDuration = duration
                camera.activeVideoMaxFrameDuration = duration
            }
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            camera.isSubjectAreaChangeMonitoringEnabled = true

            ultraWideDeviceZoomFactor = max(1.0, camera.minAvailableVideoZoomFactor)
            let firstSwitchOverFactor = camera.virtualDeviceSwitchOverVideoZoomFactors.first
                .map { CGFloat(truncating: $0) }

            let displayMultiplier: CGFloat
            if #available(iOS 18.0, *) {
                displayMultiplier = camera.displayVideoZoomFactorMultiplier
            } else {
                // Trên iOS 17 chưa có displayVideoZoomFactorMultiplier.
                // Camera kép/siêu rộng dùng hệ số 0,5×; camera thường dùng 1×.
                displayMultiplier = (
                    isDualWide || camera.deviceType == .builtInUltraWideCamera
                ) ? 0.5 : 1.0
            }

            // 0,98× nằm ngay dưới ngưỡng 1× nên camera kép không đổi sang ống kính thường.
            let maximumSmoothDisplayZoom: CGFloat = 0.98
            let requestedDeviceZoom = maximumSmoothDisplayZoom / max(displayMultiplier, 0.01)
            let safeSwitchLimit = firstSwitchOverFactor.map { $0 * 0.98 }
                ?? camera.maxAvailableVideoZoomFactor
            mainDeviceZoomFactor = max(
                ultraWideDeviceZoomFactor,
                min(
                    requestedDeviceZoom,
                    min(safeSwitchLimit, camera.maxAvailableVideoZoomFactor)
                )
            )
            ultraWideDisplayZoomFactor = ultraWideDeviceZoomFactor * displayMultiplier
            mainDisplayZoomFactor = mainDeviceZoomFactor * displayMultiplier
            camera.videoZoomFactor = ultraWideDeviceZoomFactor

            let configuredFPS = preferredFormat == nil ? 30 : 60
            let configuredResolution: String
            if let preferredFormat {
                let dimensions = CMVideoFormatDescriptionGetDimensions(preferredFormat.formatDescription)
                configuredResolution = dimensions.width >= 3840 ? "4K" : "1080p"
            } else {
                configuredResolution = "tự động"
            }
            let mode = isDualWide
                ? String(
                    format: "%@ %d fps • zoom %.1f× → %.2f× • không đổi cam",
                    configuredResolution,
                    configuredFPS,
                    ultraWideDisplayZoomFactor,
                    mainDisplayZoomFactor
                )
                : "Camera dự phòng • \(configuredResolution) \(configuredFPS) fps"
            DispatchQueue.main.async { [weak self] in
                self?.captureModeText = mode
                self?.zoomText = String(format: "%.1f×", self?.ultraWideDisplayZoomFactor ?? 0.5)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.captureModeText = "Không đặt được 60 fps; đang dùng cấu hình tự động"
            }
        }
    }

    private func featurePrint(
        from pixelBuffer: CVPixelBuffer,
        normalizedTopLeftRect: CGRect,
        orientation: CGImagePropertyOrientation = .up
    ) -> VNFeaturePrintObservation? {
        let orientedImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let image = orientedImage.transformed(by: CGAffineTransform(
            translationX: -orientedImage.extent.minX,
            y: -orientedImage.extent.minY
        ))
        let imageWidth = image.extent.width
        let imageHeight = image.extent.height
        guard imageWidth > 0, imageHeight > 0 else { return nil }

        let normalized = normalizedTopLeftRect.intersection(
            CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        guard normalized.width > 0.02, normalized.height > 0.02 else { return nil }

        // CIImage dùng gốc tọa độ ở góc dưới trái.
        let cropRect = CGRect(
            x: normalized.minX * imageWidth,
            y: (1.0 - normalized.maxY) * imageHeight,
            width: normalized.width * imageWidth,
            height: normalized.height * imageHeight
        ).integral

        guard let cgImage = ciContext.createCGImage(image.cropped(to: cropRect), from: cropRect) else {
            return nil
        }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            return request.results?.first
        } catch {
            return nil
        }
    }

    private func referenceJPEG(
        from pixelBuffer: CVPixelBuffer,
        normalizedTopLeftRect: CGRect,
        orientation: CGImagePropertyOrientation
    ) -> Data? {
        let orientedImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let image = orientedImage.transformed(by: CGAffineTransform(
            translationX: -orientedImage.extent.minX,
            y: -orientedImage.extent.minY
        ))
        let normalized = normalizedTopLeftRect.intersection(
            CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        guard normalized.width > 0.02, normalized.height > 0.02 else { return nil }

        let cropRect = CGRect(
            x: normalized.minX * image.extent.width,
            y: (1.0 - normalized.maxY) * image.extent.height,
            width: normalized.width * image.extent.width,
            height: normalized.height * image.extent.height
        ).integral
        let cropped = image
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(
                translationX: -cropRect.minX,
                y: -cropRect.minY
            ))
        let longestSide = max(cropped.extent.width, cropped.extent.height)
        let scale = min(1.0, 640.0 / max(1.0, longestSide))
        let resized = cropped.transformed(by: CGAffineTransform(
            scaleX: scale,
            y: scale
        ))
        guard let cgImage = ciContext.createCGImage(resized, from: resized.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.76)
    }

    private func featurePrint(fromJPEGData data: Data) -> VNFeaturePrintObservation? {
        guard let image = UIImage(data: data)?.cgImage else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        do {
            try handler.perform([request])
            return request.results?.first
        } catch {
            return nil
        }
    }

    private func minimumDistance(to candidate: VNFeaturePrintObservation) -> Float? {
        minimumDistance(to: candidate, among: featureSamples[...])
    }

    private func minimumDistance(
        to candidate: VNFeaturePrintObservation,
        among samples: ArraySlice<VNFeaturePrintObservation>
    ) -> Float? {
        var best: Float?
        for sample in samples {
            var distance: Float = 0
            do {
                try candidate.computeDistance(&distance, to: sample)
                if best == nil || distance < best! { best = distance }
            } catch { }
        }
        return best
    }

    private func verifyAndLock(pixelBuffer: CVPixelBuffer) {
        guard !featureSamples.isEmpty,
              let candidate = featurePrint(from: pixelBuffer, normalizedTopLeftRect: processingRect),
              let distance = minimumDistance(to: candidate) else {
            publishVerificationFailure(message: "Chưa đọc được hình trong khung")
            return
        }

        // Khoảng cách feature print càng nhỏ thì ảnh càng giống mẫu đã quét.
        let threshold: Float = 35.0
        let score = max(0.0, min(1.0, 1.0 - Double(distance / threshold)))
        guard distance <= threshold else {
            publishVerificationFailure(
                message: String(format: "Vật trong khung chưa giống mẫu (%.1f)", distance)
            )
            return
        }

        let visionRect = CGRect(
            x: processingRect.minX,
            y: 1.0 - processingRect.maxY,
            width: processingRect.width,
            height: processingRect.height
        )
        trackingObservation = VNDetectedObjectObservation(boundingBox: visionRect)
        sequenceHandler = VNSequenceRequestHandler()
        trackingFrameCounter = 0
        lowConfidenceFrames = 0
        processingMode = .tracking

        let shouldStartRecording = shouldRecordAfterVerification
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stage = .tracking
            self.targetRect = self.processingRect
            self.trackingConfidence = score
            self.matchText = String(format: "Khớp mẫu %.0f%%", score * 100)
            self.statusText = "Đã khóa đúng tên lửa — đang bám mục tiêu"
            self.onEvent?("TARGET_LOCKED")
            if shouldStartRecording {
                self.beginRecording()
            } else if self.isRecording {
                self.scheduleZoomSequence(after: 2.0)
            }
        }
    }

    private func publishVerificationFailure(message: String) {
        processingMode = .idle
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stage = self.isRecording ? .lost : .ready
            self.matchText = message
            self.statusText = "Chưa khóa được. Căn tên lửa vừa khung rồi thử lại"
        }
    }

    private func track(pixelBuffer: CVPixelBuffer) {
        guard let observation = trackingObservation else {
            markTargetLost()
            return
        }

        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = .fast

        do {
            try sequenceHandler.perform([request], on: pixelBuffer, orientation: .up)
            guard let result = request.results?.first as? VNDetectedObjectObservation else {
                markTargetLost()
                return
            }

            trackingObservation = result
            trackingFrameCounter += 1

            if result.confidence < 0.12 {
                lowConfidenceFrames += 1
            } else {
                lowConfidenceFrames = 0
            }
            if lowConfidenceFrames >= 4 {
                markTargetLost()
                return
            }

            let topLeftRect = CGRect(
                x: result.boundingBox.minX,
                y: 1.0 - result.boundingBox.maxY,
                width: result.boundingBox.width,
                height: result.boundingBox.height
            )

            var appearanceText: String?
            if trackingFrameCounter % 60 == 0,
               let candidate = featurePrint(from: pixelBuffer, normalizedTopLeftRect: topLeftRect),
               let distance = minimumDistance(to: candidate) {
                appearanceText = String(format: "Đang bám • sai khác %.1f", distance)
            }

            // Ở 60 fps, gửi tâm mục tiêu về ESP32 khoảng 20 lần/giây.
            // Tọa độ 0...999: x tăng từ trái sang phải, y tăng từ trên xuống dưới.
            let telemetry: String? = trackingFrameCounter % 3 == 0
                ? String(
                    format: "T,%03d,%03d,%02d",
                    Int(max(0, min(999, topLeftRect.midX * 999))),
                    Int(max(0, min(999, topLeftRect.midY * 999))),
                    Int(max(0, min(99, Double(result.confidence) * 99)))
                )
                : nil

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.targetRect = topLeftRect
                self.trackingConfidence = Double(result.confidence)
                if let appearanceText { self.matchText = appearanceText }
                if let telemetry { self.onEvent?(telemetry) }

                let isNearEdge = !(0.12...0.88).contains(topLeftRect.midX)
                    || !(0.10...0.90).contains(topLeftRect.midY)
                if self.isZoomedIn && isNearEdge {
                    self.returnToUltraWide()
                    if self.isRecording {
                        self.scheduleZoomSequence(after: 1.5)
                    }
                }
            }
        } catch {
            markTargetLost()
        }
    }

    private func markTargetLost() {
        processingMode = .lost
        trackingObservation = nil
        sequenceHandler = VNSequenceRequestHandler()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stage = .lost
            self.targetRect = nil
            self.trackingConfidence = 0
            self.matchText = "Đã mất mục tiêu"
            self.statusText = "Đã trở về góc rộng 0,5×; đưa tên lửa vào khung rồi bấm Bắt lại"
            self.returnToUltraWide()
            self.announce("Mất mục tiêu. Đã trở về góc rộng.", kind: .warning)
            self.onEvent?("TARGET_LOST")
        }
    }

    private func beginRecording() {
        guard isReady, !isRecording else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rocket-track-\(UUID().uuidString).mov")
        statusText = "Đã khóa tên lửa — đang bắt đầu quay..."

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    private func scheduleZoomSequence(after delay: TimeInterval = 5.0) {
        cancelZoomSequence()

        let zoomIn = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            guard !self.isZoomedIn else { return }
            guard self.stage == .tracking,
                  let target = self.targetRect,
                  (0.20...0.80).contains(target.midX),
                  (0.18...0.82).contains(target.midY) else {
                self.zoomText = "0.5× • chờ mục tiêu vào giữa"
                self.scheduleZoomSequence(after: 0.5)
                return
            }

            self.zoomText = String(
                format: "%.1f× → %.2f×",
                self.ultraWideDisplayZoomFactor,
                self.mainDisplayZoomFactor
            )
            self.onEvent?("ZOOM_098")
            self.isZoomedIn = true
            self.rampZoom(to: self.mainDeviceZoomFactor, rate: 0.75)

            let finished = DispatchWorkItem { [weak self] in
                guard let self, self.isRecording else { return }
                self.zoomText = String(format: "%.2f×", self.mainDisplayZoomFactor)
            }
            self.zoomFinishedWorkItem = finished
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: finished)
        }

        zoomInWorkItem = zoomIn
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: zoomIn)
    }

    private func cancelZoomSequence() {
        zoomInWorkItem?.cancel()
        zoomFinishedWorkItem?.cancel()
        zoomInWorkItem = nil
        zoomFinishedWorkItem = nil
    }

    private func returnToUltraWide() {
        cancelZoomSequence()
        isZoomedIn = false
        zoomText = String(format: "%.1f×", ultraWideDisplayZoomFactor)
        onEvent?("CAMERA_ULTRAWIDE")
        rampZoom(to: ultraWideDeviceZoomFactor, rate: 2.0)
    }

    private func rampZoom(to requestedFactor: CGFloat, rate: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let maximum = device.maxAvailableVideoZoomFactor
                let target = max(1.0, min(requestedFactor, maximum))
                device.cancelVideoZoomRamp()
                device.ramp(toVideoZoomFactor: target, withRate: rate)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.statusText = "Không điều khiển được zoom: \(error.localizedDescription)"
                }
            }
        }
    }

    private func resetZoom() {
        sessionQueue.async { [weak self] in
            guard let device = self?.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                device.cancelVideoZoomRamp()
                device.videoZoomFactor = self?.ultraWideDeviceZoomFactor ?? 1.0
                device.unlockForConfiguration()
            } catch { }
        }
    }

    private func saveVideoToPhotos(_ url: URL) {
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        } completionHandler: { [weak self] saved, error in
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                guard let self else { return }
                if saved {
                    self.statusText = "Đã lưu video. Có thể khóa và quay lượt tiếp theo"
                    self.announce("Đã lưu video.", kind: .success)
                    self.onEvent?("VIDEO_SAVED")
                } else {
                    self.statusText = "Quay xong nhưng chưa lưu được: \(error?.localizedDescription ?? "thiếu quyền Ảnh")"
                    self.onEvent?("SAVE_FAILED")
                }
            }
        }
    }

    private var visionScanROI: CGRect {
        CGRect(
            x: processingRect.minX,
            y: 1.0 - processingRect.maxY,
            width: processingRect.width,
            height: processingRect.height
        )
    }

    private func selectedCategoryIsPresent(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> Bool {
        switch scanSubjectKind {
        case .object:
            return true

        case .person:
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = false
            request.regionOfInterest = visionScanROI
            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: orientation
            )
            do {
                try handler.perform([request])
                return request.results?.contains(where: { $0.confidence >= 0.35 }) == true
            } catch {
                return false
            }

        case .animal:
            let request = VNRecognizeAnimalsRequest()
            request.regionOfInterest = visionScanROI
            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: orientation
            )
            do {
                try handler.perform([request])
                return request.results?.contains(where: { $0.confidence >= 0.25 }) == true
            } catch {
                return false
            }
        }
    }

    private func cameraPosition(from transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
    }

    private func cameraForward(from transform: simd_float4x4) -> SIMD3<Float> {
        -simd_normalize(SIMD3<Float>(
            transform.columns.2.x,
            transform.columns.2.y,
            transform.columns.2.z
        ))
    }

    private func projectedCrystalCell(
        for worldPoint: SIMD3<Float>,
        camera: ARCamera,
        allowedCells: Set<Int>
    ) -> (index: Int, depth: Float)? {
        let viewport = CGSize(width: 900, height: 1600)
        let point = camera.projectPoint(
            worldPoint,
            orientation: .portrait,
            viewportSize: viewport
        )
        let normalized = CGPoint(
            x: point.x / viewport.width,
            y: point.y / viewport.height
        )
        guard processingRect.contains(normalized) else { return nil }

        let localX = (normalized.x - processingRect.minX) / processingRect.width
        let localY = (normalized.y - processingRect.minY) / processingRect.height
        let column = min(
            crystalGridColumns - 1,
            max(0, Int(localX * CGFloat(crystalGridColumns)))
        )
        let row = min(
            crystalGridRows - 1,
            max(0, Int(localY * CGFloat(crystalGridRows)))
        )
        let index = row * crystalGridColumns + column
        guard allowedCells.contains(index) else { return nil }

        let cameraSpace = simd_inverse(camera.transform) * SIMD4<Float>(
            worldPoint.x,
            worldPoint.y,
            worldPoint.z,
            1
        )
        let depth = -cameraSpace.z
        guard depth > 0.08, depth < 4.0 else { return nil }
        return (index, depth)
    }

    private func estimatedDistanceToSubject(
        in frame: ARFrame,
        allowedCells: Set<Int>
    ) -> Float {
        guard let pointCloud = frame.rawFeaturePoints else { return 0.8 }
        let cameraPosition = cameraPosition(from: frame.camera.transform)
        let distances = pointCloud.points.compactMap { point -> Float? in
            guard projectedCrystalCell(
                for: point,
                camera: frame.camera,
                allowedCells: allowedCells
            ) != nil else { return nil }
            return simd_distance(cameraPosition, point)
        }.sorted()

        guard !distances.isEmpty else { return 0.8 }
        return min(2.5, max(0.30, distances[distances.count / 2]))
    }

    private func collectSurfacePoints(
        from frame: ARFrame,
        allowedCells: Set<Int>
    ) -> [Int: Double] {
        var depthSums: [Int: Float] = [:]
        var depthCounts: [Int: Int] = [:]

        if let pointCloud = frame.rawFeaturePoints {
            for (offset, point) in pointCloud.points.enumerated() where offset.isMultiple(of: 2) {
                guard let projected = projectedCrystalCell(
                    for: point,
                    camera: frame.camera,
                    allowedCells: allowedCells
                ) else { continue }

                depthSums[projected.index, default: 0] += projected.depth
                depthCounts[projected.index, default: 0] += 1

                let recentPoints = accumulatedSurfacePoints.suffix(240)
                let isNewPoint = !recentPoints.contains {
                    simd_distance($0, point) < 0.018
                }
                if isNewPoint, accumulatedSurfacePoints.count < 1_800 {
                    accumulatedSurfacePoints.append(point)
                }
            }
        }

        var normalizedDepths: [Int: Double] = [:]
        for cell in allowedCells {
            if let sum = depthSums[cell], let count = depthCounts[cell], count > 0 {
                let depth = sum / Float(count)
                normalizedDepths[cell] = Double(min(1, max(0, (depth - 0.25) / 1.75)))
            } else {
                let column = cell % crystalGridColumns
                let centerDistance = abs(
                    Double(column) / Double(max(1, crystalGridColumns - 1)) - 0.5
                )
                normalizedDepths[cell] = min(1, 0.28 + centerDistance * 0.9)
            }
        }
        return normalizedDepths
    }

    private func processARScanFrame(_ frame: ARFrame, kind: ScanKind) {
        guard shapeScanCoverage < 0.8 else { return }
        guard frame.timestamp - lastARScanAt >= 0.45 else { return }
        lastARScanAt = frame.timestamp

        guard case .normal = frame.camera.trackingState else {
            DispatchQueue.main.async { [weak self] in
                self?.scanNeedsNewAngle = true
                self?.scanGuidanceText = "Di chuyển chậm hơn để AR ổn định"
            }
            return
        }

        let pixelBuffer = frame.capturedImage
        let orientation: CGImagePropertyOrientation = .right
        guard selectedCategoryIsPresent(in: pixelBuffer, orientation: orientation) else {
            let selectedTitle = scanSubjectKind.title.lowercased()
            DispatchQueue.main.async { [weak self] in
                self?.scanNeedsNewAngle = true
                self?.scanGuidanceText = "Chưa nhận ra \(selectedTitle) trong khung"
            }
            return
        }

        guard let detectedCells = foregroundCrystalCells(
            from: pixelBuffer,
            normalizedTopLeftRect: processingRect,
            orientation: orientation
        ) else {
            DispatchQueue.main.async { [weak self] in
                self?.scanNeedsNewAngle = true
                self?.scanGuidanceText = "Đổi nền hoặc ánh sáng để tách rõ bề mặt"
            }
            return
        }

        let allowedCells = Set(detectedCells)
        let transform = frame.camera.transform
        let position = cameraPosition(from: transform)
        if estimatedObjectCenter == nil {
            let distance = estimatedDistanceToSubject(
                in: frame,
                allowedCells: allowedCells
            )
            estimatedObjectCenter = position + cameraForward(from: transform) * distance
        }
        guard let objectCenter = estimatedObjectCenter else { return }

        let relative = position - objectCenter
        var azimuth = atan2(relative.x, relative.z)
        if azimuth < 0 { azimuth += 2 * .pi }
        let bin = min(
            totalAzimuthBins - 1,
            Int(azimuth / (2 * .pi) * Float(totalAzimuthBins))
        )

        let depthMap = collectSurfacePoints(from: frame, allowedCells: allowedCells)
        let currentVisibleCells = connectedCrystalCells(
            from: detectedCells,
            coverage: max(0.10, shapeScanCoverage)
        )

        guard !capturedAzimuthBins.contains(bin) else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.crystalCells = currentVisibleCells
                self.crystalDepths = depthMap
                self.surfacePointCount = self.accumulatedSurfacePoints.count
                self.scanNeedsNewAngle = true
                self.scanGuidanceText = "Góc này đã quét • hãy đi vòng sang bên quanh chủ thể"
            }
            return
        }

        guard let feature = featurePrint(
            from: pixelBuffer,
            normalizedTopLeftRect: processingRect,
            orientation: orientation
        ) else {
            DispatchQueue.main.async { [weak self] in
                self?.scanGuidanceText = "Giữ máy chắc để ghi nhận chi tiết bề mặt"
            }
            return
        }

        capturedAzimuthBins.insert(bin)
        featureSamples.append(feature)
        if let imageData = referenceJPEG(
            from: pixelBuffer,
            normalizedTopLeftRect: processingRect,
            orientation: orientation
        ) {
            scanReferenceImages.append(imageData)
        }
        crystalBaseCells = detectedCells
        let acceptedViews = min(requiredAzimuthBins, capturedAzimuthBins.count)
        shapeScanCoverage = min(
            0.8,
            Double(acceptedViews) / Double(requiredAzimuthBins) * 0.8
        )
        let visibleCells = connectedCrystalCells(
            from: detectedCells,
            coverage: shapeScanCoverage
        )
        let coveragePercent = Int((shapeScanCoverage * 100).rounded())
        let pointCount = accumulatedSurfacePoints.count
        let totalSamples = featureSamples.count
        let sufficient = acceptedViews >= requiredAzimuthBins

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.learnedSamples = totalSamples
            self.scanSampleCount = coveragePercent
            self.scanSampleTarget = 80
            self.scanProgress = self.shapeScanCoverage
            self.crystalCoverage = self.shapeScanCoverage
            self.crystalCells = visibleCells
            self.crystalDepths = depthMap
            self.scanViewpointCount = acceptedViews
            self.surfacePointCount = pointCount
            self.scanIsSufficient = sufficient
            self.scanNeedsNewAngle = false
            self.scanGuidanceText = sufficient
                ? "Đã đủ các mặt 3D cần thiết"
                : "Đã nhận góc \(acceptedViews)/8 • tiếp tục đi vòng quanh chủ thể"
            self.matchText = "3D AR \(coveragePercent)% • \(acceptedViews)/8 góc • \(pointCount) điểm"
        }

        onEvent?("SCAN_3D_VIEW_\(acceptedViews)")
        if sufficient {
            finishScan(kind: kind)
        }
    }
}

extension CameraController: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let kind = activeARScanKind else { return }
        processARScanFrame(frame, kind: kind)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scanNeedsNewAngle = true
            self.scanGuidanceText = "AR gặp lỗi: \(error.localizedDescription)"
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameCounter += 1

        if frameCounter % 30 == 1 {
            let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
            let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            let aspect = min(width, height) / max(width, height)
            DispatchQueue.main.async { [weak self] in
                self?.frameAspectRatio = aspect
            }
        }

        switch processingMode {
        case .idle, .lost:
            return

        case .scanning(let kind):
            featureFrameCounter += 1
            let now = CACurrentMediaTime()
            if featureFrameCounter % 6 == 0,
               shapeScanCoverage < 0.8,
               now - lastShapeScanAt >= 0.55 {
                lastShapeScanAt = now
                if let feature = featurePrint(
                    from: pixelBuffer,
                    normalizedTopLeftRect: processingRect
                ) {
                    featureSamples.append(feature)
                    if let detectedCells = foregroundCrystalCells(
                        from: pixelBuffer,
                        normalizedTopLeftRect: processingRect
                    ) {
                        crystalBaseCells = detectedCells
                    } else if crystalBaseCells.isEmpty {
                        crystalBaseCells = fallbackRocketCells()
                    }

                    shapeScanCoverage = min(0.8, shapeScanCoverage + 0.10)
                    let visibleCells = connectedCrystalCells(
                        from: crystalBaseCells,
                        coverage: shapeScanCoverage
                    )
                    let publishedCoverage = shapeScanCoverage
                    let totalCount = featureSamples.count
                    let coveragePercent = Int((shapeScanCoverage * 100).rounded())
                    let sufficient = shapeScanCoverage >= 0.8
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.learnedSamples = totalCount
                        self.scanSampleCount = coveragePercent
                        self.scanSampleTarget = 80
                        self.scanProgress = publishedCoverage
                        self.crystalCoverage = publishedCoverage
                        self.crystalCells = visibleCells
                        self.scanIsSufficient = sufficient
                        self.scanNeedsNewAngle = false
                        self.scanGuidanceText = sufficient
                            ? "Tinh thể đã liên kết và phủ gần đủ vật thể"
                            : "Giữ trong khung, xoay nhẹ để tinh thể phủ tiếp"
                        self.matchText = "TINH THỂ \(coveragePercent)% • mục tiêu 80%"
                    }
                    if sufficient {
                        finishScan(kind: kind)
                    }
                }
            }

        case .verifying:
            processingMode = .idle
            verifyAndLock(pixelBuffer: pixelBuffer)

        case .tracking:
            track(pixelBuffer: pixelBuffer)
        }
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRecording = true
            self.statusText = "Đang quay 4K/60 fps nếu máy hỗ trợ; zoom tối đa 0,98×, không đổi camera"
            self.zoomText = String(format: "%.1f×", self.ultraWideDisplayZoomFactor)
            self.announce("Bắt đầu quay.", kind: .start)
            self.onEvent?("RECORDING_STARTED")
            self.scheduleZoomSequence()
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        videoQueue.async { [weak self] in
            self?.processingMode = .idle
            self?.trackingObservation = nil
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cancelZoomSequence()
            self.resetZoom()
            self.isRecording = false
            self.isZoomedIn = false
            self.zoomText = String(format: "%.1f×", self.ultraWideDisplayZoomFactor)
            self.targetRect = nil
            self.stage = .ready
            self.statusText = "Đã dừng, đang lưu video..."
            self.onEvent?("RECORDING_STOPPED")

            if let error {
                self.statusText = "Lỗi quay video: \(error.localizedDescription)"
                try? FileManager.default.removeItem(at: outputFileURL)
            } else {
                self.saveVideoToPhotos(outputFileURL)
            }
        }
    }
}
