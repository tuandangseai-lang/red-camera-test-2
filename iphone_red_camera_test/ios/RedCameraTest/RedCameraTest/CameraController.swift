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

struct CrystalFacet3D: Equatable, Identifiable {
    let id: Int
    let a: CGPoint
    let b: CGPoint
    let c: CGPoint
    let depth: Double
    let light: Double
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
        case .ready, .verifying, .tracking, .lost:
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
    @Published private(set) var crystalFacets3D: [CrystalFacet3D] = []
    @Published private(set) var crystalCoverage = 0.0
    @Published private(set) var scanViewpointCount = 0
    @Published private(set) var surfacePointCount = 0
    @Published private(set) var scanHasConfirmedTarget = false
    @Published private(set) var targetConfirmationProgress = 0.0
    @Published private(set) var hasSelectedSubject = false
    @Published private(set) var selectedSubjectMaskImage: UIImage?
    @Published private(set) var selectedSubjectRect: CGRect?
    @Published private(set) var detectedSubjectLabel = "Chưa phân loại"
    @Published private(set) var detectedSubjectConfidence = 0.0
    @Published private(set) var isARScanning = false
    @Published private(set) var targetRect: CGRect?
    @Published private(set) var trackingConfidence = 0.0
    @Published private(set) var matchText = "Chưa có mẫu"
    @Published private(set) var frameAspectRatio: CGFloat = 9.0 / 16.0
    @Published private(set) var savedProfiles: [SavedScanProfile] = []
    @Published private(set) var activeProfileID: UUID?
    @Published var scanBoxScale = 0.76
    @Published var scanSubjectKind: ScanSubjectKind = .object
    @Published var voiceAnnouncementsEnabled = true

    let crystalGridColumns = 16
    let crystalGridRows = 24

    var onEvent: ((String) -> Void)?

    var scanRect: CGRect {
        let width = CGFloat(max(0.48, min(scanBoxScale, 0.92)))
        // Preview dọc có tỉ lệ rộng/cao xấp xỉ 9:16. Nhân theo tỉ lệ này
        // giúp khung chuẩn hóa hiển thị thành một vòng tròn thật trên màn hình.
        let height = min(0.70, max(0.27, width * 9.0 / 16.0))
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
    private var targetCandidateCells: Set<Int> = []
    private var confirmedTargetCells: Set<Int> = []
    private var targetStableFrameCount = 0
    private var targetIsConfirmed = false
    private var acceptedViewMasks: [Set<Int>] = []
    private var lastAcceptedFeature: VNFeaturePrintObservation?
    private var voxelOccupancy: [Bool] = []
    private var selectedSubjectPoint = CGPoint(x: 0.5, y: 0.5)
    private var manualSelectionRequested = false
    private var manualCaptureRequested = false
    private var lastARScanAt = 0.0
    private let requiredAzimuthBins = 8
    private let totalAzimuthBins = 10
    private let voxelColumns = 16
    private let voxelRows = 24
    private let voxelDepthLayers = 12
    private let manualPhotoTarget = 6
    private let selectionGridColumns = 32
    private let selectionGridRows = 56

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
            statusText = "Hãy tạo mẫu đủ 6 ảnh trước"
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
            self.targetCandidateCells.removeAll()
            self.confirmedTargetCells.removeAll()
            self.targetIsConfirmed = false
            self.acceptedViewMasks.removeAll()
            self.lastAcceptedFeature = nil
            self.voxelOccupancy.removeAll()
            self.manualSelectionRequested = false
            self.manualCaptureRequested = false
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
        crystalFacets3D = []
        crystalCoverage = 0
        scanViewpointCount = 0
        surfacePointCount = 0
        scanHasConfirmedTarget = false
        targetConfirmationProgress = 0
        hasSelectedSubject = false
        selectedSubjectMaskImage = nil
        selectedSubjectRect = nil
        detectedSubjectLabel = "Chưa phân loại"
        detectedSubjectConfidence = 0
        targetRect = nil
        trackingConfidence = 0
        matchText = "Chưa có mẫu"
        activeProfileID = nil
        statusText = "Chọn loại rồi bấm Tạo mẫu từ 6 ảnh"
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
            self.targetCandidateCells.removeAll()
            self.confirmedTargetCells.removeAll()
            self.targetIsConfirmed = false
            self.acceptedViewMasks.removeAll()
            self.lastAcceptedFeature = nil
            self.voxelOccupancy.removeAll()
            self.manualSelectionRequested = false
            self.manualCaptureRequested = false
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
        crystalFacets3D = []
        crystalCoverage = 0
        scanViewpointCount = 0
        surfacePointCount = 0
        scanHasConfirmedTarget = false
        targetConfirmationProgress = 0
        hasSelectedSubject = false
        selectedSubjectMaskImage = nil
        selectedSubjectRect = nil
        detectedSubjectLabel = "Chưa phân loại"
        detectedSubjectConfidence = 0
        targetRect = nil
        statusText = "Đã dừng quét 3D gần đúng"
        onEvent?("SCAN_CANCELLED")
    }

    func selectSubject(at normalizedPoint: CGPoint) {
        guard stage.isScanning, !isRecording else { return }
        let point = CGPoint(
            x: min(0.99, max(0.01, normalizedPoint.x)),
            y: min(0.99, max(0.01, normalizedPoint.y))
        )
        scanNeedsNewAngle = false
        scanGuidanceText = "Đang tách riêng vật tại điểm bạn chạm..."
        statusText = "Đang chọn đúng vật và làm tối phần xung quanh"
        videoQueue.async { [weak self] in
            self?.selectedSubjectPoint = point
            self?.manualSelectionRequested = true
        }
    }

    func captureManualReferencePhoto() {
        guard stage.isScanning, !isRecording else { return }
        guard hasSelectedSubject else {
            statusText = "Hãy chạm vào vật trên màn hình trước"
            scanGuidanceText = "CHẠM VÀO VẬT CẦN CHỤP"
            return
        }
        scanNeedsNewAngle = false
        scanGuidanceText = "Đang kiểm tra ảnh..."
        videoQueue.async { [weak self] in
            guard let self, !self.manualCaptureRequested else { return }
            self.manualCaptureRequested = true
        }
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
            if let storedVoxels = profile.voxelOccupancy,
               storedVoxels.count == self.voxelColumns * self.voxelRows * self.voxelDepthLayers {
                self.voxelOccupancy = storedVoxels
            } else {
                self.voxelOccupancy.removeAll()
            }
            let storedFacets = self.makeCrystalFacets(viewIndex: 0)
            self.processingMode = .idle
            self.trackingObservation = nil
            self.sequenceHandler = VNSequenceRequestHandler()

            DispatchQueue.main.async {
                self.activeProfileID = profile.id
                self.learnedSamples = observations.count
                self.surfacePointCount = profile.surfacePointCount
                self.detectedSubjectLabel = profile.classificationLabel ?? profile.subjectKind.title
                self.detectedSubjectConfidence = 1
                self.crystalFacets3D = storedFacets
                self.scanHasConfirmedTarget = true
                self.targetConfirmationProgress = 1
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

    func renameProfile(_ profile: SavedScanProfile, to proposedName: String) {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(trimmed.prefix(28))
        guard !name.isEmpty else { return }
        savedProfiles = profileStore.rename(id: profile.id, to: name)
        statusText = "Đã đổi tên mẫu thành \(name)"
        onEvent?("PROFILE_RENAMED")
    }

    func startTrackingAndRecording() {
        guard isReady, !isRecording, (stage == .ready || stage == .lost) else { return }
        let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
        let recordAfterLock = !isRecording
        stage = .verifying
        targetRect = nil
        trackingConfidence = 0
        matchText = "Đang tìm \(detectedSubjectLabel) trên toàn màn hình..."
        statusText = "Không cần đưa vật vào vòng tròn • app đang tự tìm mục tiêu"

        videoQueue.async { [weak self] in
            guard let self else { return }
            self.processingRect = fullFrame
            self.featureFrameCounter = 0
            self.shouldRecordAfterVerification = recordAfterLock
            self.processingMode = .verifying
        }
    }

    func reacquireTarget() {
        guard stage == .lost else { return }
        let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
        stage = .verifying
        targetRect = nil
        matchText = "Đang tìm lại \(detectedSubjectLabel) trên toàn màn hình..."
        statusText = "Có thể đặt vật ở bất kỳ vị trí nào trong khung camera"
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.processingRect = fullFrame
            self.featureFrameCounter = 0
            self.shouldRecordAfterVerification = false
            self.processingMode = .verifying
        }
    }

    func cancelTargetSearch() {
        guard stage == .verifying else { return }
        videoQueue.async { [weak self] in
            self?.processingMode = .idle
        }
        stage = isRecording ? .lost : .ready
        matchText = isRecording ? "Đã dừng tìm lại mục tiêu" : "Mẫu đã sẵn sàng"
        statusText = isRecording ? "Mất mục tiêu • có thể bấm Bắt lại" : "Có thể bấm Khóa, bám & quay"
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
        let rect = scanRect
        let requiredSamples = sampleTarget(for: kind)

        switch kind {
        case .near:
            stage = .scanningNear
            statusText = "Chạm trực tiếp vào vật cần chụp trên màn hình"
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
        scanGuidanceText = "CHẠM VÀO VẬT CẦN CHỤP"
        crystalCells = []
        crystalDepths = [:]
        crystalFacets3D = []
        crystalCoverage = 0
        scanViewpointCount = 0
        surfacePointCount = 0
        scanHasConfirmedTarget = false
        targetConfirmationProgress = 0
        hasSelectedSubject = false
        selectedSubjectMaskImage = nil
        selectedSubjectRect = nil
        detectedSubjectLabel = "Chưa phân loại"
        detectedSubjectConfidence = 0
        targetRect = rect
        matchText = "CHƯA CHỌN VẬT • cần 6 ảnh"

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
            self.targetCandidateCells.removeAll()
            self.confirmedTargetCells.removeAll()
            self.targetStableFrameCount = 0
            self.targetIsConfirmed = false
            self.acceptedViewMasks.removeAll()
            self.lastAcceptedFeature = nil
            self.voxelOccupancy.removeAll()
            self.manualSelectionRequested = false
            self.manualCaptureRequested = false
            self.estimatedObjectCenter = nil
            self.featureFrameCounter = 0
            self.lastShapeScanAt = 0
            self.lastARScanAt = 0
            self.activeARScanKind = nil
            self.processingMode = .scanning(kind)
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
                    name: "\(self.detectedSubjectLabel.capitalized) \(formatter.string(from: Date()))",
                    createdAt: Date(),
                    subjectKind: self.scanSubjectKind,
                    referenceImages: self.scanReferenceImages,
                    surfacePointCount: self.scanReferenceImages.count,
                    voxelOccupancy: nil,
                    classificationLabel: self.detectedSubjectLabel
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
                self.matchText = "ĐÃ LƯU 6 GÓC • mẫu \(self.savedProfiles.count)/5"
                self.statusText = "Đã ghép 6 ảnh thành mẫu nhận diện. Có thể khóa và quay"
                self.announce("Đã chụp đủ sáu góc. Mẫu nhận diện đã sẵn sàng.", kind: .success)
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

    private struct ManualSubjectMask {
        let cells: Set<Int>
        let boundingRect: CGRect
        let image: UIImage
        let referenceJPEG: Data
        let removedHand: Bool
    }

    private func instanceLabel(
        at normalizedTopLeftPoint: CGPoint,
        in instanceMask: CVPixelBuffer
    ) -> Int {
        CVPixelBufferLockBaseAddress(instanceMask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(instanceMask, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(instanceMask) else { return 0 }

        let width = CVPixelBufferGetWidth(instanceMask)
        let height = CVPixelBufferGetHeight(instanceMask)
        let rowBytes = CVPixelBufferGetBytesPerRow(instanceMask)
        let pixelFormat = CVPixelBufferGetPixelFormatType(instanceMask)
        let centerX = min(width - 1, max(0, Int(normalizedTopLeftPoint.x * CGFloat(width))))
        let directY = min(height - 1, max(0, Int(normalizedTopLeftPoint.y * CGFloat(height))))
        let candidateYs = [directY, height - 1 - directY]

        func value(x: Int, y: Int) -> Int {
            let row = baseAddress.advanced(by: y * rowBytes)
            if pixelFormat == kCVPixelFormatType_OneComponent32Float
                || rowBytes / max(1, width) >= 4 {
                let pixels = row.assumingMemoryBound(to: Float32.self)
                return Int(pixels[x].rounded())
            }
            let pixels = row.assumingMemoryBound(to: UInt8.self)
            return Int(pixels[x])
        }

        for centerY in candidateYs {
            for radius in 0...4 {
                for offsetY in -radius...radius {
                    for offsetX in -radius...radius {
                        let x = min(width - 1, max(0, centerX + offsetX))
                        let y = min(height - 1, max(0, centerY + offsetY))
                        let label = value(x: x, y: y)
                        if label > 0 { return label }
                    }
                }
            }
        }
        return 0
    }

    private func handExclusionCells(from pixelBuffer: CVPixelBuffer) -> Set<Int> {
        guard scanSubjectKind == .object else { return [] }
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        var excluded = Set<Int>()
        for observation in request.results ?? [] {
            guard let points = try? observation.recognizedPoints(.all) else { continue }
            let visible = points.values.filter { $0.confidence >= 0.22 }
            guard visible.count >= 4 else { continue }
            let columns = visible.map {
                Int($0.location.x * CGFloat(selectionGridColumns))
            }
            let rows = visible.map {
                Int((1.0 - $0.location.y) * CGFloat(selectionGridRows))
            }
            guard let minimumColumn = columns.min(), let maximumColumn = columns.max(),
                  let minimumRow = rows.min(), let maximumRow = rows.max() else { continue }

            let minColumn = max(0, minimumColumn - 3)
            let maxColumn = min(selectionGridColumns - 1, maximumColumn + 3)
            let minRow = max(0, minimumRow - 3)
            let maxRow = min(selectionGridRows - 1, maximumRow + 4)
            for row in minRow...maxRow {
                for column in minColumn...maxColumn {
                    excluded.insert(row * selectionGridColumns + column)
                }
            }
        }
        return excluded
    }

    private func friendlyClassificationName(_ identifier: String) -> String {
        let lowercased = identifier.lowercased()
        let translations: [(needle: String, name: String)] = [
            ("water bottle", "chai nước"),
            ("bottle", "chai"),
            ("rocket", "tên lửa"),
            ("missile", "tên lửa"),
            ("person", "người"),
            ("dog", "chó"),
            ("cat", "mèo"),
            ("bird", "chim"),
            ("ball", "quả bóng"),
            ("car", "xe ô tô"),
            ("motorcycle", "xe máy"),
            ("bicycle", "xe đạp"),
            ("computer", "máy tính"),
            ("phone", "điện thoại"),
            ("camera", "máy ảnh")
        ]
        return translations.first(where: { lowercased.contains($0.needle) })?.name
            ?? identifier.replacingOccurrences(of: "_", with: " ")
    }

    private func classifySubject(
        in pixelBuffer: CVPixelBuffer,
        rect: CGRect,
        referenceJPEG: Data
    ) -> (kind: ScanSubjectKind, label: String, confidence: Double) {
        let visionRect = CGRect(
            x: rect.minX,
            y: 1.0 - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let personRequest = VNDetectHumanRectanglesRequest()
        personRequest.regionOfInterest = visionRect
        personRequest.upperBodyOnly = false
        let animalRequest = VNRecognizeAnimalsRequest()
        animalRequest.regionOfInterest = visionRect
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([personRequest, animalRequest])

        if let person = personRequest.results?.max(by: { $0.confidence < $1.confidence }),
           person.confidence >= 0.48 {
            return (.person, "người", Double(person.confidence))
        }
        if let animal = animalRequest.results?.max(by: { $0.confidence < $1.confidence }),
           let label = animal.labels.first,
           animal.confidence >= 0.30 {
            return (
                .animal,
                friendlyClassificationName(label.identifier),
                Double(animal.confidence)
            )
        }

        guard let image = UIImage(data: referenceJPEG)?.cgImage else {
            return (.object, "vật thể", 0)
        }
        let classifyRequest = VNClassifyImageRequest()
        let classifyHandler = VNImageRequestHandler(cgImage: image, orientation: .up)
        do {
            try classifyHandler.perform([classifyRequest])
            if let result = classifyRequest.results?.first(where: { $0.confidence >= 0.05 }) {
                return (
                    .object,
                    friendlyClassificationName(result.identifier),
                    Double(result.confidence)
                )
            }
        } catch { }
        return (.object, "vật thể", 0)
    }

    private func manualSubjectMask(
        from pixelBuffer: CVPixelBuffer,
        at point: CGPoint
    ) -> ManualSubjectMask? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up
        )

        do {
            try handler.perform([request])
            guard let observation = request.results?.first,
                  !observation.allInstances.isEmpty else { return nil }
            let tappedLabel = instanceLabel(at: point, in: observation.instanceMask)
            let selectedLabel: Int
            if tappedLabel > 0, observation.allInstances.contains(tappedLabel) {
                selectedLabel = tappedLabel
            } else if observation.allInstances.count == 1,
                      let onlyLabel = observation.allInstances.first {
                selectedLabel = onlyLabel
            } else {
                return nil
            }

            let selectedInstances = IndexSet(integer: selectedLabel)
            let maskBuffer = try observation.generateScaledMaskForImage(
                forInstances: selectedInstances,
                from: handler
            )
            let rawMask = CIImage(cvPixelBuffer: maskBuffer)
            let maskImage = rawMask.transformed(by: CGAffineTransform(
                translationX: -rawMask.extent.minX,
                y: -rawMask.extent.minY
            ))
            let scaled = maskImage.transformed(by: CGAffineTransform(
                scaleX: CGFloat(selectionGridColumns) / maskImage.extent.width,
                y: CGFloat(selectionGridRows) / maskImage.extent.height
            ))
            var bitmap = [UInt8](
                repeating: 0,
                count: selectionGridColumns * selectionGridRows
            )
            ciContext.render(
                scaled,
                toBitmap: &bitmap,
                rowBytes: selectionGridColumns,
                bounds: CGRect(
                    x: 0,
                    y: 0,
                    width: selectionGridColumns,
                    height: selectionGridRows
                ),
                format: .L8,
                colorSpace: nil
            )

            var cells = Set<Int>()
            for visualRow in 0..<selectionGridRows {
                let maskRow = selectionGridRows - 1 - visualRow
                for column in 0..<selectionGridColumns {
                    if bitmap[maskRow * selectionGridColumns + column] > 48 {
                        cells.insert(visualRow * selectionGridColumns + column)
                    }
                }
            }

            let originalCells = cells
            let handCells = handExclusionCells(from: pixelBuffer)
            let cleanedCells = cells.subtracting(handCells)
            let removedHand = !handCells.isEmpty && cleanedCells.count >= 18
            if removedHand {
                cells = cleanedCells
            } else {
                cells = originalCells
            }

            var minimumColumn = selectionGridColumns
            var maximumColumn = 0
            var minimumRow = selectionGridRows
            var maximumRow = 0
            for index in cells {
                let column = index % selectionGridColumns
                let row = index / selectionGridColumns
                minimumColumn = min(minimumColumn, column)
                maximumColumn = max(maximumColumn, column)
                minimumRow = min(minimumRow, row)
                maximumRow = max(maximumRow, row)
            }
            guard cells.count >= 18,
                  minimumColumn <= maximumColumn,
                  minimumRow <= maximumRow else { return nil }

            let padding: CGFloat = 0.035
            let rawRect = CGRect(
                x: CGFloat(minimumColumn) / CGFloat(selectionGridColumns),
                y: CGFloat(minimumRow) / CGFloat(selectionGridRows),
                width: CGFloat(maximumColumn - minimumColumn + 1) / CGFloat(selectionGridColumns),
                height: CGFloat(maximumRow - minimumRow + 1) / CGFloat(selectionGridRows)
            )
            let boundingRect = rawRect
                .insetBy(dx: -padding, dy: -padding)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

            var cleanBitmap = [UInt8](
                repeating: 0,
                count: selectionGridColumns * selectionGridRows
            )
            for index in cells {
                let visualRow = index / selectionGridColumns
                let column = index % selectionGridColumns
                let maskRow = selectionGridRows - 1 - visualRow
                cleanBitmap[maskRow * selectionGridColumns + column] = 255
            }
            let cleanMaskData = Data(cleanBitmap)
            let lowResolutionMask = CIImage(
                bitmapData: cleanMaskData,
                bytesPerRow: selectionGridColumns,
                size: CGSize(width: selectionGridColumns, height: selectionGridRows),
                format: .L8,
                colorSpace: nil
            )
            let fullResolutionMask = lowResolutionMask.transformed(by: CGAffineTransform(
                scaleX: maskImage.extent.width / CGFloat(selectionGridColumns),
                y: maskImage.extent.height / CGFloat(selectionGridRows)
            ))
            guard let cgMask = ciContext.createCGImage(
                fullResolutionMask,
                from: maskImage.extent
            ) else {
                return nil
            }

            let rawSource = CIImage(cvPixelBuffer: pixelBuffer)
            let sourceImage = rawSource.transformed(by: CGAffineTransform(
                translationX: -rawSource.extent.minX,
                y: -rawSource.extent.minY
            ))
            guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return nil }
            blendFilter.setValue(sourceImage, forKey: kCIInputImageKey)
            blendFilter.setValue(
                CIImage(color: .black).cropped(to: sourceImage.extent),
                forKey: kCIInputBackgroundImageKey
            )
            blendFilter.setValue(fullResolutionMask, forKey: kCIInputMaskImageKey)
            guard let maskedImage = blendFilter.outputImage else { return nil }
            let cropRect = CGRect(
                x: boundingRect.minX * sourceImage.extent.width,
                y: (1.0 - boundingRect.maxY) * sourceImage.extent.height,
                width: boundingRect.width * sourceImage.extent.width,
                height: boundingRect.height * sourceImage.extent.height
            ).integral
            let cropped = maskedImage
                .cropped(to: cropRect)
                .transformed(by: CGAffineTransform(
                    translationX: -cropRect.minX,
                    y: -cropRect.minY
                ))
            guard let referenceImage = ciContext.createCGImage(cropped, from: cropped.extent),
                  let referenceJPEG = UIImage(cgImage: referenceImage)
                    .jpegData(compressionQuality: 0.78) else { return nil }
            return ManualSubjectMask(
                cells: cells,
                boundingRect: boundingRect,
                image: UIImage(cgImage: cgMask),
                referenceJPEG: referenceJPEG,
                removedHand: removedHand
            )
        } catch {
            return nil
        }
    }

    private func updateManualSubjectSelection(from pixelBuffer: CVPixelBuffer) {
        guard let selection = manualSubjectMask(
            from: pixelBuffer,
            at: selectedSubjectPoint
        ) else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hasSelectedSubject = false
                self.selectedSubjectMaskImage = nil
                self.selectedSubjectRect = nil
                self.scanNeedsNewAngle = true
                self.scanGuidanceText = "Không tách được vật • hãy chạm gần giữa vật"
                self.statusText = "Nền nên khác màu vật và không có vật khác chạm vào"
            }
            return
        }

        processingRect = selection.boundingRect
        confirmedTargetCells = selection.cells
        let classification = classifySubject(
            in: pixelBuffer,
            rect: selection.boundingRect,
            referenceJPEG: selection.referenceJPEG
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasSelectedSubject = true
            self.selectedSubjectMaskImage = selection.image
            self.selectedSubjectRect = selection.boundingRect
            self.scanHasConfirmedTarget = true
            self.targetConfirmationProgress = 1
            self.scanSubjectKind = classification.kind
            self.detectedSubjectLabel = classification.label
            self.detectedSubjectConfidence = classification.confidence
            self.scanNeedsNewAngle = false
            self.scanGuidanceText = "Đã chọn vật • bấm nút tròn để chụp ảnh 1/6"
            self.matchText = "NHẬN DIỆN: \(classification.label.uppercased()) • \(Int(classification.confidence * 100))%"
            self.statusText = selection.removedHand
                ? "Đã loại vùng bàn tay; nếu chọn sai hãy chạm lại"
                : "Nếu chọn sai, chạm lại vào đúng vật"
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self.announce("Đã chọn vật cần chụp.", kind: .success)
            self.onEvent?("SUBJECT_SELECTED")
        }
    }

    private func captureManualPhoto(
        from pixelBuffer: CVPixelBuffer,
        kind: ScanKind
    ) {
        guard let selection = manualSubjectMask(
            from: pixelBuffer,
            at: selectedSubjectPoint
        ) else {
            DispatchQueue.main.async { [weak self] in
                self?.scanNeedsNewAngle = true
                self?.scanGuidanceText = "Không thấy vật đã chọn • chạm lại vào vật"
            }
            return
        }
        processingRect = selection.boundingRect
        guard let feature = featurePrint(fromJPEGData: selection.referenceJPEG) else {
            DispatchQueue.main.async { [weak self] in
                self?.scanGuidanceText = "Ảnh chưa rõ • giữ máy chắc rồi chụp lại"
            }
            return
        }

        if let previousFeature = lastAcceptedFeature {
            var lastDistance: Float = 0
            do {
                try feature.computeDistance(&lastDistance, to: previousFeature)
            } catch { }
            let minimumPreviousDistance = minimumDistance(to: feature) ?? lastDistance
            let previousMask = acceptedViewMasks.last ?? confirmedTargetCells
            let overlap = maskOverlap(selection.cells, previousMask)

            guard minimumPreviousDistance <= 45 else {
                DispatchQueue.main.async { [weak self] in
                    self?.scanNeedsNewAngle = true
                    self?.scanGuidanceText = "Ảnh có vẻ là vật khác • hãy chụp lại đúng vật"
                }
                return
            }
            guard lastDistance >= 0.55 || overlap <= 0.96 else {
                DispatchQueue.main.async { [weak self] in
                    self?.scanNeedsNewAngle = true
                    self?.scanGuidanceText = "Ảnh gần như trùng • xoay vật thêm rồi chụp"
                }
                return
            }
        }

        lastAcceptedFeature = feature
        featureSamples.append(feature)
        acceptedViewMasks.append(selection.cells)
        scanReferenceImages.append(selection.referenceJPEG)
        confirmedTargetCells = selection.cells

        let count = min(manualPhotoTarget, scanReferenceImages.count)
        shapeScanCoverage = min(
            0.8,
            Double(count) / Double(manualPhotoTarget) * 0.8
        )
        let coveragePercent = Int((shapeScanCoverage * 100).rounded())
        let sufficient = count >= manualPhotoTarget

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasSelectedSubject = true
            self.selectedSubjectMaskImage = selection.image
            self.selectedSubjectRect = selection.boundingRect
            self.scanHasConfirmedTarget = true
            self.targetConfirmationProgress = 1
            self.learnedSamples = count
            self.scanViewpointCount = count
            self.scanSampleCount = coveragePercent
            self.scanSampleTarget = 80
            self.scanProgress = self.shapeScanCoverage
            self.scanIsSufficient = sufficient
            self.scanNeedsNewAngle = false
            self.matchText = "ĐÃ CHỤP \(count)/6 ẢNH CÙNG MỘT VẬT"
            self.scanGuidanceText = sufficient
                ? "Đã đủ 6 ảnh"
                : "Ảnh \(count)/6 đã lưu • xoay vật rồi bấm chụp tiếp"
            self.statusText = sufficient
                ? "Đang ghép sáu ảnh thành mẫu nhận diện..."
                : "Giữ vật trong vùng sáng; có thể giữ iPhone cố định"
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self.onEvent?("REFERENCE_PHOTO_\(count)")
        }

        if sufficient {
            finishScan(kind: kind)
        }
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

    private struct ForegroundCandidate {
        let rect: CGRect
        let feature: VNFeaturePrintObservation
    }

    private func foregroundCandidates(from pixelBuffer: CVPixelBuffer) -> [ForegroundCandidate] {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return [] }
            var candidates: [ForegroundCandidate] = []
            for instance in observation.allInstances.prefix(8) {
                let instances = IndexSet(integer: instance)
                let maskBuffer = try observation.generateScaledMaskForImage(
                    forInstances: instances,
                    from: handler
                )
                let maskImage = CIImage(cvPixelBuffer: maskBuffer)
                let scaled = maskImage.transformed(by: CGAffineTransform(
                    scaleX: CGFloat(selectionGridColumns) / maskImage.extent.width,
                    y: CGFloat(selectionGridRows) / maskImage.extent.height
                ))
                var bitmap = [UInt8](
                    repeating: 0,
                    count: selectionGridColumns * selectionGridRows
                )
                ciContext.render(
                    scaled,
                    toBitmap: &bitmap,
                    rowBytes: selectionGridColumns,
                    bounds: CGRect(
                        x: 0,
                        y: 0,
                        width: selectionGridColumns,
                        height: selectionGridRows
                    ),
                    format: .L8,
                    colorSpace: nil
                )

                var minColumn = selectionGridColumns
                var maxColumn = 0
                var minRow = selectionGridRows
                var maxRow = 0
                var count = 0
                for visualRow in 0..<selectionGridRows {
                    let maskRow = selectionGridRows - 1 - visualRow
                    for column in 0..<selectionGridColumns
                    where bitmap[maskRow * selectionGridColumns + column] > 48 {
                        count += 1
                        minColumn = min(minColumn, column)
                        maxColumn = max(maxColumn, column)
                        minRow = min(minRow, visualRow)
                        maxRow = max(maxRow, visualRow)
                    }
                }
                guard count >= 12, minColumn <= maxColumn, minRow <= maxRow else {
                    continue
                }
                let padding: CGFloat = 0.025
                let rawRect = CGRect(
                    x: CGFloat(minColumn) / CGFloat(selectionGridColumns),
                    y: CGFloat(minRow) / CGFloat(selectionGridRows),
                    width: CGFloat(maxColumn - minColumn + 1) / CGFloat(selectionGridColumns),
                    height: CGFloat(maxRow - minRow + 1) / CGFloat(selectionGridRows)
                )
                let rect = rawRect
                    .insetBy(dx: -padding, dy: -padding)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                let maskedBuffer = try observation.generateMaskedImage(
                    ofInstances: instances,
                    from: handler,
                    croppedToInstancesExtent: true
                )
                guard let feature = featurePrint(
                    from: maskedBuffer,
                    normalizedTopLeftRect: CGRect(x: 0, y: 0, width: 1, height: 1)
                ) else { continue }
                candidates.append(ForegroundCandidate(rect: rect, feature: feature))
            }
            return candidates
        } catch {
            return []
        }
    }

    private func verifyAndLock(pixelBuffer: CVPixelBuffer) {
        guard !featureSamples.isEmpty else {
            return
        }
        var bestCandidate: ForegroundCandidate?
        var bestDistance: Float?
        for candidate in foregroundCandidates(from: pixelBuffer) {
            guard let distance = minimumDistance(to: candidate.feature) else { continue }
            if bestDistance == nil || distance < bestDistance! {
                bestDistance = distance
                bestCandidate = candidate
            }
        }
        guard let candidate = bestCandidate, let distance = bestDistance else {
            publishSearchProgress(message: "Đang tìm vật đã lưu trên toàn màn hình...")
            return
        }

        // Ảnh mẫu đã được tách nền nên có thể tìm lại vật ở bất kỳ vị trí nào.
        let threshold: Float = 45.0
        let score = max(0.0, min(1.0, 1.0 - Double(distance / threshold)))
        guard distance <= threshold else {
            publishSearchProgress(
                message: String(format: "Đang tìm %@ • gần nhất %.1f", detectedSubjectLabel, distance)
            )
            return
        }

        processingRect = candidate.rect

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
            self.statusText = "Đã tự tìm thấy \(self.detectedSubjectLabel) — đang bám mục tiêu"
            self.onEvent?("TARGET_LOCKED")
            if shouldStartRecording {
                self.beginRecording()
            } else if self.isRecording {
                self.scheduleZoomSequence(after: 2.0)
            }
        }
    }

    private func publishSearchProgress(message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stage = .verifying
            self.matchText = message
            self.statusText = "Không cần đưa vào khung • app đang quét toàn màn hình"
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

    private func maskOverlap(_ first: Set<Int>, _ second: Set<Int>) -> Double {
        guard !first.isEmpty, !second.isEmpty else { return 0 }
        let intersection = first.intersection(second).count
        let union = first.union(second).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    private func voxelIndex(x: Int, y: Int, z: Int) -> Int {
        (z * voxelRows + y) * voxelColumns + x
    }

    private func voxelIsOccupied(x: Int, y: Int, z: Int) -> Bool {
        guard x >= 0, x < voxelColumns,
              y >= 0, y < voxelRows,
              z >= 0, z < voxelDepthLayers else { return false }
        let index = voxelIndex(x: x, y: y, z: z)
        return index < voxelOccupancy.count && voxelOccupancy[index]
    }

    private func carveVisualHull(with mask: Set<Int>, viewIndex: Int) {
        guard voxelOccupancy.count == voxelColumns * voxelRows * voxelDepthLayers else {
            return
        }
        let angle = Float(viewIndex) * 2 * .pi / Float(requiredAzimuthBins)
        let cosine = cos(angle)
        let sine = sin(angle)

        for z in 0..<voxelDepthLayers {
            let normalizedZ = (
                (Float(z) + 0.5) / Float(voxelDepthLayers) - 0.5
            ) * 1.55
            for y in 0..<voxelRows {
                for x in 0..<voxelColumns {
                    let index = voxelIndex(x: x, y: y, z: z)
                    guard voxelOccupancy[index] else { continue }
                    let normalizedX = (
                        (Float(x) + 0.5) / Float(voxelColumns) - 0.5
                    ) * 2.0
                    let projectedX = cosine * normalizedX + sine * normalizedZ
                    let projectedColumn = Int(
                        ((projectedX + 1.0) * 0.5 * Float(crystalGridColumns)).rounded(.down)
                    )
                    guard projectedColumn >= 0, projectedColumn < crystalGridColumns,
                          mask.contains(y * crystalGridColumns + projectedColumn) else {
                        voxelOccupancy[index] = false
                        continue
                    }
                }
            }
        }
    }

    private func makeCrystalFacets(viewIndex: Int) -> [CrystalFacet3D] {
        guard !voxelOccupancy.isEmpty else { return [] }
        let angle = Float(viewIndex) * 2 * .pi / Float(requiredAzimuthBins)
        let cosine = cos(angle)
        let sine = sin(angle)
        let directions = [
            (dx: -1, dy: 0, dz: 0), (dx: 1, dy: 0, dz: 0),
            (dx: 0, dy: -1, dz: 0), (dx: 0, dy: 1, dz: 0),
            (dx: 0, dy: 0, dz: -1), (dx: 0, dy: 0, dz: 1)
        ]

        func worldVertex(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Float> {
            SIMD3<Float>(
                Float(x) / Float(voxelColumns) * 2.0 - 1.0,
                Float(y) / Float(voxelRows) * 2.0 - 1.0,
                (Float(z) / Float(voxelDepthLayers) - 0.5) * 1.55
            )
        }

        func rotate(_ point: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(
                cosine * point.x + sine * point.z,
                point.y,
                -sine * point.x + cosine * point.z
            )
        }

        func project(_ point: SIMD3<Float>) -> CGPoint {
            let rotated = rotate(point)
            let perspective = 1.0 + Double(rotated.z) * 0.075
            return CGPoint(
                x: 0.5 + Double(rotated.x) * 0.48 * perspective,
                y: 0.5 + Double(rotated.y) * 0.48 * perspective
            )
        }

        var facets: [CrystalFacet3D] = []
        var nextID = 0
        for z in 0..<voxelDepthLayers {
            for y in 0..<voxelRows {
                for x in 0..<voxelColumns where voxelIsOccupied(x: x, y: y, z: z) {
                    let cubeCorners = [
                        worldVertex(x, y, z),
                        worldVertex(x + 1, y, z),
                        worldVertex(x + 1, y + 1, z),
                        worldVertex(x, y + 1, z),
                        worldVertex(x, y, z + 1),
                        worldVertex(x + 1, y, z + 1),
                        worldVertex(x + 1, y + 1, z + 1),
                        worldVertex(x, y + 1, z + 1)
                    ]
                    let faceCornerIndices = [
                        [0, 4, 7, 3], [1, 2, 6, 5],
                        [0, 1, 5, 4], [3, 7, 6, 2],
                        [0, 3, 2, 1], [4, 5, 6, 7]
                    ]

                    for face in 0..<directions.count {
                        let direction = directions[face]
                        guard !voxelIsOccupied(
                            x: x + direction.dx,
                            y: y + direction.dy,
                            z: z + direction.dz
                        ) else { continue }

                        let normal = rotate(SIMD3<Float>(
                            Float(direction.dx),
                            Float(direction.dy),
                            Float(direction.dz)
                        ))
                        guard normal.z >= -0.08 else { continue }
                        let corners = faceCornerIndices[face].map { cubeCorners[$0] }
                        let projected = corners.map(project)
                        let averageDepth = corners.map { Double(rotate($0).z) }
                            .reduce(0, +) / 4.0
                        let light = min(
                            1.0,
                            max(0.18, 0.40 + Double(normal.z) * 0.42 - Double(normal.y) * 0.18)
                        )
                        facets.append(CrystalFacet3D(
                            id: nextID,
                            a: projected[0],
                            b: projected[1],
                            c: projected[2],
                            depth: averageDepth,
                            light: light
                        ))
                        nextID += 1
                        facets.append(CrystalFacet3D(
                            id: nextID,
                            a: projected[0],
                            b: projected[2],
                            c: projected[3],
                            depth: averageDepth,
                            light: light * 0.92
                        ))
                        nextID += 1
                    }
                }
            }
        }

        let sorted = facets.sorted { $0.depth < $1.depth }
        guard sorted.count > 1_800 else { return sorted }
        let stride = Int(ceil(Double(sorted.count) / 1_800.0))
        return sorted.enumerated().compactMap { offset, facet in
            offset.isMultiple(of: stride) ? facet : nil
        }
    }

    private func confirmTargetIfStable(
        mask: Set<Int>,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        frame: ARFrame,
        kind: ScanKind
    ) -> Bool {
        guard !targetIsConfirmed else { return true }
        let usableSize = mask.count >= 18
            && mask.count <= Int(Double(crystalGridColumns * crystalGridRows) * 0.88)
        guard usableSize else {
            targetStableFrameCount = 0
            targetCandidateCells = mask
            DispatchQueue.main.async { [weak self] in
                self?.targetConfirmationProgress = 0
                self?.scanGuidanceText = "Đưa trọn chủ thể vào khung, không chạm mép"
            }
            return false
        }

        let overlap = maskOverlap(mask, targetCandidateCells)
        if targetCandidateCells.isEmpty || overlap < 0.78 {
            targetCandidateCells = mask
            targetStableFrameCount = 1
        } else {
            targetStableFrameCount = min(3, targetStableFrameCount + 1)
            targetCandidateCells = mask
        }
        let confirmation = Double(targetStableFrameCount) / 3.0

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.targetConfirmationProgress = confirmation
            self.crystalCells = self.connectedCrystalCells(
                from: Array(mask),
                coverage: max(0.10, confirmation * 0.28)
            )
            self.scanGuidanceText = "Đang xác nhận đúng \(self.scanSubjectKind.title.lowercased()) • \(Int(confirmation * 100))%"
            self.matchText = "GIỮ YÊN ĐỂ XÁC NHẬN • \(Int(confirmation * 100))%"
        }

        guard targetStableFrameCount >= 3,
              let feature = featurePrint(
                from: pixelBuffer,
                normalizedTopLeftRect: processingRect,
                orientation: orientation
              ) else { return false }

        targetIsConfirmed = true
        confirmedTargetCells = mask
        lastAcceptedFeature = feature
        featureSamples.append(feature)
        acceptedViewMasks.append(mask)
        carveVisualHull(with: mask, viewIndex: 0)
        if let imageData = referenceJPEG(
            from: pixelBuffer,
            normalizedTopLeftRect: processingRect,
            orientation: orientation
        ) {
            scanReferenceImages.append(imageData)
        }

        let transform = frame.camera.transform
        let position = cameraPosition(from: transform)
        let distance = estimatedDistanceToSubject(in: frame, allowedCells: mask)
        estimatedObjectCenter = position + cameraForward(from: transform) * distance
        if let objectCenter = estimatedObjectCenter {
            let relative = position - objectCenter
            var azimuth = atan2(relative.x, relative.z)
            if azimuth < 0 { azimuth += 2 * .pi }
            let bin = min(
                totalAzimuthBins - 1,
                Int(azimuth / (2 * .pi) * Float(totalAzimuthBins))
            )
            capturedAzimuthBins.insert(bin)
        }

        shapeScanCoverage = 0.10
        let facets = makeCrystalFacets(viewIndex: 0)
        let voxelCount = voxelOccupancy.filter { $0 }.count
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scanHasConfirmedTarget = true
            self.targetConfirmationProgress = 1
            self.scanProgress = 0.10
            self.scanSampleCount = 10
            self.scanViewpointCount = 1
            self.crystalCoverage = 0.10
            self.crystalFacets3D = facets
            self.surfacePointCount = voxelCount
            self.learnedSamples = self.featureSamples.count
            self.scanNeedsNewAngle = false
            self.scanGuidanceText = "Đã xác nhận • giữ iPhone cố định và xoay vật chậm"
            self.matchText = "ĐÃ KHÓA CHỦ THỂ • bắt đầu dựng khối 3D"
            self.announce("Đã xác nhận đúng chủ thể. Hãy xoay vật chậm.", kind: .success)
            self.onEvent?("SCAN_TARGET_CONFIRMED")
        }
        return true
    }

    private func processARScanFrame(_ frame: ARFrame, kind: ScanKind) {
        guard shapeScanCoverage < 0.8 else { return }
        guard frame.timestamp - lastARScanAt >= 0.45 else { return }
        lastARScanAt = frame.timestamp

        guard case .normal = frame.camera.trackingState else {
            DispatchQueue.main.async { [weak self] in
                self?.scanNeedsNewAngle = true
                self?.scanGuidanceText = "Giữ máy ổn định để camera lấy lại vị trí"
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
                self?.scanGuidanceText = "Đổi nền hoặc ánh sáng để tách rõ chủ thể"
            }
            return
        }
        let mask = Set(detectedCells)
        guard confirmTargetIfStable(
            mask: mask,
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            frame: frame,
            kind: kind
        ) else { return }
        guard acceptedViewMasks.count < requiredAzimuthBins else { return }

        guard let feature = featurePrint(
            from: pixelBuffer,
            normalizedTopLeftRect: processingRect,
            orientation: orientation
        ) else {
            DispatchQueue.main.async { [weak self] in
                self?.scanGuidanceText = "Giữ hình rõ một chút rồi tiếp tục xoay"
            }
            return
        }

        let lastDistance: Float
        if let lastAcceptedFeature {
            var measured: Float = 0
            do {
                try feature.computeDistance(&measured, to: lastAcceptedFeature)
                lastDistance = measured
            } catch {
                lastDistance = 0
            }
        } else {
            lastDistance = 99
        }
        let minimumPreviousDistance = minimumDistance(to: feature) ?? 99
        let lastMask = acceptedViewMasks.last ?? confirmedTargetCells
        let overlap = maskOverlap(mask, lastMask)

        var cameraMovedToNewAngle = false
        if let objectCenter = estimatedObjectCenter {
            let relative = cameraPosition(from: frame.camera.transform) - objectCenter
            var azimuth = atan2(relative.x, relative.z)
            if azimuth < 0 { azimuth += 2 * .pi }
            let bin = min(
                totalAzimuthBins - 1,
                Int(azimuth / (2 * .pi) * Float(totalAzimuthBins))
            )
            cameraMovedToNewAngle = capturedAzimuthBins.insert(bin).inserted
        }

        let appearanceChanged = lastDistance >= 2.2
            && (minimumPreviousDistance >= 1.15 || overlap <= 0.86)
        guard appearanceChanged || cameraMovedToNewAngle else {
            let changePercent = Int(min(99, max(0, Double(lastDistance / 2.2) * 100)))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scanNeedsNewAngle = true
                self.scanGuidanceText = "Xoay vật thêm một chút • thay đổi \(changePercent)%"
            }
            return
        }

        let viewIndex = acceptedViewMasks.count
        acceptedViewMasks.append(mask)
        lastAcceptedFeature = feature
        featureSamples.append(feature)
        if let imageData = referenceJPEG(
            from: pixelBuffer,
            normalizedTopLeftRect: processingRect,
            orientation: orientation
        ) {
            scanReferenceImages.append(imageData)
        }
        carveVisualHull(with: mask, viewIndex: viewIndex)

        let acceptedViews = acceptedViewMasks.count
        shapeScanCoverage = min(
            0.8,
            Double(acceptedViews) / Double(requiredAzimuthBins) * 0.8
        )
        let facets = makeCrystalFacets(viewIndex: viewIndex)
        let voxelCount = voxelOccupancy.filter { $0 }.count
        let coveragePercent = Int((shapeScanCoverage * 100).rounded())
        let sufficient = acceptedViews >= requiredAzimuthBins
        let totalSamples = featureSamples.count

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.learnedSamples = totalSamples
            self.scanSampleCount = coveragePercent
            self.scanSampleTarget = 80
            self.scanProgress = self.shapeScanCoverage
            self.crystalCoverage = self.shapeScanCoverage
            self.crystalCells = detectedCells
            self.crystalFacets3D = facets
            self.scanViewpointCount = acceptedViews
            self.surfacePointCount = voxelCount
            self.scanIsSufficient = sufficient
            self.scanNeedsNewAngle = false
            self.scanGuidanceText = sufficient
                ? "Đã dựng đủ khối 3D cần thiết"
                : "Đã nhận mặt \(acceptedViews)/8 • tiếp tục xoay vật"
            self.matchText = "KHỐI 3D \(coveragePercent)% • \(voxelCount) voxel bề mặt"
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
            if manualSelectionRequested {
                manualSelectionRequested = false
                updateManualSubjectSelection(from: pixelBuffer)
            }
            if manualCaptureRequested {
                manualCaptureRequested = false
                captureManualPhoto(from: pixelBuffer, kind: kind)
            }

        case .verifying:
            // Tách nền toàn khung khá nặng. Quét cách vài frame để camera vẫn mượt,
            // nhưng tiếp tục tìm cho đến khi thấy vật hoặc người dùng hủy.
            featureFrameCounter += 1
            if featureFrameCounter % 6 == 1 {
                verifyAndLock(pixelBuffer: pixelBuffer)
            }

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
