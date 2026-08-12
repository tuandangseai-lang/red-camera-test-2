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
    case waterRocket
    case person
    case animal
    case object

    var id: String { rawValue }

    var title: String {
        switch self {
        case .waterRocket: return "Tên lửa nước"
        case .person: return "Người"
        case .animal: return "Thú"
        case .object: return "Vật"
        }
    }

    var symbol: String {
        switch self {
        case .waterRocket: return "rocket.fill"
        case .person: return "person.fill"
        case .animal: return "pawprint.fill"
        case .object: return "shippingbox.fill"
        }
    }

    var compactTitle: String {
        self == .waterRocket ? "Tên lửa" : title
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
    @Published private(set) var isCapturingReferenceVideo = false
    @Published private(set) var referenceVideoProgress = 0.0
    @Published private(set) var referenceVideoFrameCount = 0
    @Published private(set) var referenceVideoDisplayStartedAt: Date?
    @Published private(set) var isAddingReferencePhoto = false
    @Published private(set) var isProcessingReferencePhoto = false
    @Published private(set) var isProfilePreparing = false
    @Published private(set) var trackingPreparationCountdown = 0
    @Published private(set) var surfacePointCount = 0
    @Published private(set) var scanHasConfirmedTarget = false
    @Published private(set) var targetConfirmationProgress = 0.0
    @Published private(set) var hasSelectedSubject = false
    @Published private(set) var selectedSubjectMaskImage: UIImage?
    @Published private(set) var selectedSubjectRect: CGRect?
    @Published private(set) var subjectContourPoints: [CGPoint] = []
    // Nhãn giao diện luôn đi theo tab đang chọn. Nhãn chi tiết của AI (chai,
    // chó, mèo...) chỉ dùng nội bộ, không được ghi đè tên tab.
    @Published private(set) var detectedSubjectLabel = "Tên lửa nước"
    @Published private(set) var detectedSubjectConfidence = 0.0
    @Published private(set) var isARScanning = false
    @Published private(set) var targetRect: CGRect?
    @Published private(set) var trackingPoints: [CGPoint] = []
    @Published private(set) var predictedTargetPoint: CGPoint?
    @Published private(set) var trackingConfidence = 0.0
    /// Hướng chuẩn hóa trên màn hình mà app đang gửi cho ESP32 khi tìm lại mục tiêu.
    /// Đây chỉ là trạng thái giao diện; AVCaptureMovieFileOutput không ghi lớp này vào video.
    @Published private(set) var servoSearchVector: CGPoint?
    @Published private(set) var servoSearchAnchor: CGPoint?
    @Published private(set) var isServoTrajectorySearching = false
    @Published private(set) var matchText = "Chưa có mẫu"
    @Published private(set) var frameAspectRatio: CGFloat = 9.0 / 16.0
    @Published private(set) var savedProfiles: [SavedScanProfile] = []
    @Published private(set) var activeProfileID: UUID?
    @Published var scanBoxScale = 0.76
    @Published var scanSubjectKind: ScanSubjectKind = .waterRocket
    @Published var voiceAnnouncementsEnabled = true

    /// Khóa ngay khi người dùng bấm dừng. Kết quả AI cũ đang chờ trên hàng đợi
    /// không được phép bật lại giao diện hoặc servo tìm mục tiêu.
    private var isStopRequested = false

    let crystalGridColumns = 16
    let crystalGridRows = 24

    var onEvent: ((String) -> Void)?
    var referencePhotoTarget: Int { manualPhotoTarget }

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
    private let profileQueue = DispatchQueue(
        label: "vn.rockettracker.profile.features",
        qos: .userInitiated
    )
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let voiceNotifier = VoiceNotifier()
    private let profileStore = ScanProfileStore()
    private let aiDetector = RocketAIDetector()
    // COCO đã học rất nhiều dạng chai ở nhiều góc và khoảng cách. Model này
    // chỉ sinh ứng viên; khóa cuối vẫn phải khớp bộ ảnh cá nhân.
    private let bottleDetector = RocketAIDetector(
        modelNames: ["BottleDetector"],
        acceptedLabels: ["bottle", "water_bottle"],
        acceptedClassIndices: [39],
        resultLabel: "bottle"
    )
    /// A full-screen candidate must be strong because sky highlights, people,
    /// and launch hardware can look rocket-like for one frame.  Once a target
    /// is locked, a weaker detector result is accepted only near the predicted
    /// trajectory and is still cross-checked by the Vision tracker.
    private let aiAcquisitionConfidence = 0.42
    private let aiReacquisitionConfidence = 0.16
    private let aiContinuationConfidence = 0.12
    /// Tracker Vision theo từng frame vẫn dùng 60% để không đứt bám vì nhòe chuyển động.
    /// Riêng bắt lại danh tính sau khi mất phải đạt 75% từ cả ảnh và video mẫu.
    private let hardTrackingConfidence = 0.60
    private let immediateReacquisitionSimilarity = 0.75

    private var videoDevice: AVCaptureDevice?
    private var ultraWideDeviceZoomFactor: CGFloat = 1.0
    private var mainDeviceZoomFactor: CGFloat = 1.96
    private var ultraWideDisplayZoomFactor: CGFloat = 0.5
    private var mainDisplayZoomFactor: CGFloat = 0.98
    private var isZoomedIn = false
    private var hasCompletedOneTimeZoom = false
    private var activeTrackingPreparationID = UUID()
    private var didRequestStart = false
    private var configured = false
    private var pendingArm = false

    // Các biến dưới đây chỉ được đọc/ghi trên videoQueue.
    private var processingMode: ProcessingMode = .idle
    private var processingRect = CGRect(x: 0.29, y: 0.15, width: 0.42, height: 0.70)
    private var featureSamples: [VNFeaturePrintObservation] = []
    private var contextFeatureSamples: [VNFeaturePrintObservation] = []
    private var photoFeatureSamples: [VNFeaturePrintObservation] = []
    private var videoFeatureSamples: [VNFeaturePrintObservation] = []
    private var photoContextFeatureSamples: [VNFeaturePrintObservation] = []
    private var videoContextFeatureSamples: [VNFeaturePrintObservation] = []
    private var freshScanSeedRect: CGRect?
    private var freshScanSeedTimestamp: TimeInterval = 0
    private var pendingFreshScanSeedRect: CGRect?
    private var stageStartingSampleCount = 0
    private var shapeScanCoverage = 0.0
    private var crystalBaseCells: [Int] = []
    private var lastShapeScanAt = 0.0
    private var frameCounter = 0
    private var featureFrameCounter = 0
    private var trackingFrameCounter = 0
    private var lowConfidenceFrames = 0
    private var trackingObservation: VNDetectedObjectObservation?
    private var trackingAnchorObservations: [VNDetectedObjectObservation] = []
    private var sequenceHandler = VNSequenceRequestHandler()
    private var shouldRecordAfterVerification = true
    private var previousTrackingCenter: CGPoint?
    private var smoothedTrackingVelocity = CGVector.zero
    private var trackingTrianglePoints: [CGPoint] = []
    private var lastTrackingBounds: CGRect?
    private var segmentationMissFrames = 0
    private var motionFilter = RocketMotionFilter()
    private var aiDetectionMisses = 0
    private var pendingAIDetectionRect: CGRect?
    private var pendingAIDetectionCount = 0
    private var identityGateStatus = ""
    private var parachuteDetected = false
    private var recoverySeedEstimate: RocketMotionEstimate?
    private var recoveryStartedAt: TimeInterval = 0
    private var isRecoveringLostTarget = false
    private var recoverySearchCommand = "SEARCH_START"
    private var lastSearchCommandSentAt: TimeInterval = 0

    // Quét 3D gần đúng trên iPhone không LiDAR: ARKit cung cấp vị trí camera và
    // điểm đặc trưng 3D, Vision giữ lại các điểm nằm trên mặt nạ chủ thể.
    private var activeARScanKind: ScanKind?
    private var estimatedObjectCenter: SIMD3<Float>?
    private var capturedAzimuthBins: Set<Int> = []
    private var accumulatedSurfacePoints: [SIMD3<Float>] = []
    private var scanReferenceImages: [Data] = []
    private var scanContextImages: [Data] = []
    private var targetCandidateCells: Set<Int> = []
    private var confirmedTargetCells: Set<Int> = []
    private var targetStableFrameCount = 0
    private var targetIsConfirmed = false
    private var acceptedViewMasks: [Set<Int>] = []
    private var lastAcceptedFeature: VNFeaturePrintObservation?
    private var voxelOccupancy: [Bool] = []
    private var selectedSubjectPoint = CGPoint(x: 0.5, y: 0.5)
    private var manualSelectionRequested = false
    private let manualCaptureLock = NSLock()
    private var manualCaptureRequested = false
    private var manualCaptureInFlight = false
    private var capturedReferencePhotoCount = 0
    private var referenceVideoStartedAt: TimeInterval?
    private var lastReferenceVideoSampleAt: TimeInterval = 0
    private var capturedReferenceVideoFrames = 0
    private var lastReferenceVideoRect: CGRect?
    private var lastARScanAt = 0.0
    private let requiredAzimuthBins = 8
    private let totalAzimuthBins = 10
    private let voxelColumns = 16
    private let voxelRows = 24
    private let voxelDepthLayers = 12
    // Model AI trong app đã biết hình dáng chung của tên lửa nước. Bộ ảnh cá
    // nhân dùng để nhận ra đúng chiếc tên lửa của người dùng ở sáu hướng và xa.
    // Sáu hướng quanh vật cộng thêm một ảnh xa để nhận lại khi tên lửa nhỏ.
    private let manualPhotoTarget = 7
    private let referenceVideoDuration: TimeInterval = 10.0
    private let referenceVideoTargetFrames = 24
    // Lưới đủ mịn để viền không bị vuông nhưng vẫn nhẹ cho iPhone 15.
    private let selectionGridColumns = 96
    private let selectionGridRows = 168

    private var zoomInWorkItem: DispatchWorkItem?
    private var zoomFinishedWorkItem: DispatchWorkItem?
    private var profileActivationID = UUID()

    override init() {
        super.init()
        arSession.delegate = self
        arSession.delegateQueue = videoQueue
        profileQueue.async { [weak self] in
            guard let self else { return }
            let profiles = self.profileStore.load()
            DispatchQueue.main.async {
                self.savedProfiles = profiles
            }
        }
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
            statusText = "Hãy tạo mẫu đủ 7 ảnh theo hướng dẫn trước"
            return
        }
        startTrackingAndRecording()
    }

    func startShapeScan() {
        guard isReady, !isRecording else { return }
        profileActivationID = UUID()
        isProfilePreparing = false
        isAddingReferencePhoto = false
        startScan(kind: .near, resetProfile: true)
    }

    func beginAddingReferencePhoto() {
        guard isReady,
              !isRecording,
              stage == .ready,
              activeProfileID != nil else { return }
        isAddingReferencePhoto = true
        stage = .scanningNear
        scanViewpointCount = 0
        scanHasConfirmedTarget = false
        hasSelectedSubject = false
        selectedSubjectRect = nil
        targetRect = scanRect
        scanIsSufficient = false
        scanNeedsNewAngle = false
        scanGuidanceText = "Đặt \(scanSubjectKind.title.lowercased()) ở góc cần bổ sung rồi bấm chụp"
        matchText = "CHỤP THÊM ẢNH ĐỐI CHỨNG"
        statusText = "Ảnh mới sẽ được ghép vào đúng mẫu đang chọn"
        resetManualCaptureRequest()
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.processingMode = .scanning(.near)
        }
        onEvent?("SUPPLEMENTAL_PHOTO_STARTED")
    }

    func selectSubjectKind(_ kind: ScanSubjectKind) {
        guard !isRecording, !stage.isScanning else { return }
        guard kind != scanSubjectKind else { return }
        // Không dùng chéo bộ ảnh Tên lửa nước / Người / Thú / Vật.
        resetProfile()
        scanSubjectKind = kind
        detectedSubjectLabel = kind.title
        matchText = "ĐÃ CHỌN \(kind.title.uppercased())"
        statusText = "Loại đã khóa: \(kind.title) • hãy tạo bộ ảnh riêng cho loại này"
        onEvent?("SUBJECT_KIND_\(kind.rawValue.uppercased())")
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
        isAddingReferencePhoto = false
        stopARScanAndResumeCamera()
        voiceNotifier.stop()
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.processingMode = .idle
            self.featureSamples.removeAll()
            self.contextFeatureSamples.removeAll()
            self.photoFeatureSamples.removeAll()
            self.videoFeatureSamples.removeAll()
            self.photoContextFeatureSamples.removeAll()
            self.videoContextFeatureSamples.removeAll()
            self.scanReferenceImages.removeAll()
            self.scanContextImages.removeAll()
            self.freshScanSeedRect = nil
            self.freshScanSeedTimestamp = 0
            self.pendingFreshScanSeedRect = nil
            self.targetCandidateCells.removeAll()
            self.confirmedTargetCells.removeAll()
            self.targetIsConfirmed = false
            self.acceptedViewMasks.removeAll()
            self.lastAcceptedFeature = nil
            self.voxelOccupancy.removeAll()
            self.manualSelectionRequested = false
            self.resetManualCaptureRequest()
            self.trackingObservation = nil
            self.trackingAnchorObservations.removeAll()
            self.trackingTrianglePoints.removeAll()
            self.lastTrackingBounds = nil
            self.segmentationMissFrames = 0
            self.previousTrackingCenter = nil
            self.smoothedTrackingVelocity = .zero
            self.motionFilter.clear()
            self.aiDetectionMisses = 0
            self.clearPendingAIDetection()
            self.clearRecoveryState()
            self.sequenceHandler = VNSequenceRequestHandler()
        }
        stage = .idle
        learnedSamples = 0
        scanProgress = 0
        scanSampleCount = 0
        scanSampleTarget = 0
        scanIsSufficient = false
        scanNeedsNewAngle = false
        scanGuidanceText = "Đưa \(scanSubjectKind.title.lowercased()) vào khung"
        crystalCells = []
        crystalDepths = [:]
        crystalFacets3D = []
        crystalCoverage = 0
        scanViewpointCount = 0
        isCapturingReferenceVideo = false
        referenceVideoProgress = 0
        referenceVideoFrameCount = 0
        referenceVideoDisplayStartedAt = nil
        trackingPreparationCountdown = 0
        surfacePointCount = 0
        scanHasConfirmedTarget = false
        targetConfirmationProgress = 0
        hasSelectedSubject = false
        selectedSubjectMaskImage = nil
        selectedSubjectRect = nil
        subjectContourPoints = []
        subjectContourPoints = []
        detectedSubjectLabel = scanSubjectKind.title
        detectedSubjectConfidence = 0
        targetRect = nil
        trackingPoints = []
        predictedTargetPoint = nil
        servoSearchVector = nil
        servoSearchAnchor = nil
        isServoTrajectorySearching = false
        trackingConfidence = 0
        matchText = "Chưa có mẫu"
        activeProfileID = nil
        statusText = "Bấm Tạo mẫu và chụp đủ 7 ảnh theo hướng dẫn"
        onEvent?("PROFILE_RESET")
    }

    func cancelShapeScan() {
        guard stage.isScanning else { return }
        if isAddingReferencePhoto {
            isAddingReferencePhoto = false
            resetManualCaptureRequest()
            videoQueue.async { [weak self] in
                self?.processingMode = .idle
            }
            stage = .ready
            scanIsSufficient = true
            targetRect = nil
            scanGuidanceText = "Đã hủy chụp thêm"
            matchText = "Mẫu hiện tại vẫn được giữ nguyên"
            statusText = "Có thể khóa, bám và quay"
            return
        }
        stopARScanAndResumeCamera()
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.processingMode = .idle
            self.activeARScanKind = nil
            self.scanReferenceImages.removeAll()
            self.scanContextImages.removeAll()
            self.freshScanSeedRect = nil
            self.freshScanSeedTimestamp = 0
            self.pendingFreshScanSeedRect = nil
            self.targetCandidateCells.removeAll()
            self.confirmedTargetCells.removeAll()
            self.targetIsConfirmed = false
            self.acceptedViewMasks.removeAll()
            self.lastAcceptedFeature = nil
            self.voxelOccupancy.removeAll()
            self.manualSelectionRequested = false
            self.resetManualCaptureRequest()
            self.capturedReferencePhotoCount = 0
            self.referenceVideoStartedAt = nil
            self.lastReferenceVideoSampleAt = 0
            self.capturedReferenceVideoFrames = 0
            self.lastReferenceVideoRect = nil
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
        isCapturingReferenceVideo = false
        referenceVideoProgress = 0
        referenceVideoFrameCount = 0
        referenceVideoDisplayStartedAt = nil
        trackingPreparationCountdown = 0
        surfacePointCount = 0
        scanHasConfirmedTarget = false
        targetConfirmationProgress = 0
        hasSelectedSubject = false
        selectedSubjectMaskImage = nil
        selectedSubjectRect = nil
        subjectContourPoints = []
        detectedSubjectLabel = scanSubjectKind.title
        detectedSubjectConfidence = 0
        targetRect = nil
        trackingPoints = []
        predictedTargetPoint = nil
        servoSearchVector = nil
        servoSearchAnchor = nil
        isServoTrajectorySearching = false
        statusText = "Đã dừng tạo mẫu"
        onEvent?("SCAN_CANCELLED")
    }

    func selectSubject(at normalizedPoint: CGPoint) {
        guard stage.isScanning, !isRecording else { return }
        let point = CGPoint(
            x: min(0.99, max(0.01, normalizedPoint.x)),
            y: min(0.99, max(0.01, normalizedPoint.y))
        )
        scanNeedsNewAngle = false
        scanGuidanceText = "Đang tách riêng \(scanSubjectKind.title.lowercased()) tại điểm bạn chạm..."
        statusText = "Đang xác định \(scanSubjectKind.title.lowercased()) trong ảnh"
        videoQueue.async { [weak self] in
            self?.selectedSubjectPoint = point
            self?.manualSelectionRequested = true
        }
    }

    func captureManualReferencePhoto() {
        guard stage.isScanning, !isRecording else { return }
        guard !isCapturingReferenceVideo else { return }
        if !isAddingReferencePhoto, scanViewpointCount >= manualPhotoTarget {
            startReferenceVideoCapture()
            return
        }
        guard requestManualCapture() else { return }
        isProcessingReferencePhoto = true
        scanNeedsNewAngle = false
        scanGuidanceText = "Đã nhận nút chụp • AI đang xử lý ảnh..."
        matchText = "ĐANG CHỤP \(scanSubjectKind.title.uppercased())"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// NÃºt chá»¥p cháº¡y trÃªn main thread, cÃ²n frame camera cháº¡y trÃªn `videoQueue`.
    /// DÃ¹ng khÃ³a nháº¹ Ä‘á»ƒ nháº­n nÃºt ngay, khÃ´ng pháº£i xáº¿p hÃ ng sau cÃ¡c táº¡c vá»¥ Vision.
    private func requestManualCapture() -> Bool {
        manualCaptureLock.lock()
        defer { manualCaptureLock.unlock() }
        guard !manualCaptureRequested, !manualCaptureInFlight else { return false }
        manualCaptureRequested = true
        return true
    }

    private func consumeManualCaptureRequest() -> Bool {
        manualCaptureLock.lock()
        defer { manualCaptureLock.unlock() }
        guard manualCaptureRequested, !manualCaptureInFlight else { return false }
        manualCaptureRequested = false
        manualCaptureInFlight = true
        return true
    }

    private func finishManualCaptureRequest() {
        manualCaptureLock.lock()
        manualCaptureInFlight = false
        manualCaptureLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.isProcessingReferencePhoto = false
        }
    }

    private func resetManualCaptureRequest() {
        manualCaptureLock.lock()
        manualCaptureRequested = false
        manualCaptureInFlight = false
        manualCaptureLock.unlock()
        if Thread.isMainThread {
            isProcessingReferencePhoto = false
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.isProcessingReferencePhoto = false
            }
        }
    }

    func startReferenceVideoCapture() {
        guard stage.isScanning,
              scanViewpointCount >= manualPhotoTarget,
              !isCapturingReferenceVideo else { return }
        isCapturingReferenceVideo = true
        referenceVideoProgress = 0
        referenceVideoFrameCount = 0
        referenceVideoDisplayStartedAt = Date()
        scanIsSufficient = false
        scanNeedsNewAngle = false
        scanGuidanceText = "Quay \(scanSubjectKind.title.lowercased()) từ từ trong 10 giây"
        matchText = "VIDEO MẪU 0,0/10,0 GIÂY"
        statusText = "AI sẽ lấy 24 khung và ghép với 7 ảnh đã chụp"
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.referenceVideoStartedAt = CACurrentMediaTime()
            self.lastReferenceVideoSampleAt = 0
            self.capturedReferenceVideoFrames = 0
            self.lastReferenceVideoRect = nil
        }
        announce(
            "Bắt đầu video mẫu \(scanSubjectKind.title.lowercased()). Hãy quay từ từ trong mười giây.",
            kind: .start
        )
        onEvent?("REFERENCE_VIDEO_START")
    }

    func activateProfile(_ profile: SavedScanProfile) {
        guard !isRecording, !stage.isScanning else { return }
        if activeProfileID == profile.id, !isProfilePreparing {
            matchText = "ÄÃƒ CHá»ŒN \(profile.name.uppercased())"
            statusText = "Máº«u nÃ y Ä‘Ã£ sáºµn sÃ ng; khÃ´ng cáº§n náº¡p láº¡i"
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }
        profileActivationID = UUID()
        let activationID = profileActivationID
        activeProfileID = profile.id
        stage = .ready
        isProfilePreparing = true
        learnedSamples = profile.referenceImages.count
        scanIsSufficient = true
        matchText = "ĐÃ CHỌN \(profile.name.uppercased())"
        statusText = "Đang chuẩn bị dữ liệu AI trong nền..."
        scanSubjectKind = profile.subjectKind

        profileQueue.async { [weak self] in
            guard let self else { return }
            var cachedProfiles: [SavedScanProfile]?
            let observations = self.decodeFeaturePrints(profile.referenceFeaturePrints)
                ?? profile.referenceImages.compactMap { self.featurePrint(fromJPEGData: $0) }
            let contextObservations = self.decodeFeaturePrints(profile.contextFeaturePrints)
                ?? (profile.contextImages ?? []).compactMap { self.featurePrint(fromJPEGData: $0) }
            guard !observations.isEmpty else {
                DispatchQueue.main.async {
                    guard self.profileActivationID == activationID else { return }
                    self.isProfilePreparing = false
                    self.statusText = "Mẫu này không còn dữ liệu ảnh hợp lệ"
                }
                return
            }

            if profile.referenceFeaturePrints?.count != observations.count
                || profile.contextFeaturePrints?.count != contextObservations.count {
                let references = observations.compactMap(self.encodeFeaturePrint)
                let contexts = contextObservations.compactMap(self.encodeFeaturePrint)
                if references.count == observations.count,
                   contexts.count == contextObservations.count {
                    cachedProfiles = self.profileStore.cacheFeaturePrints(
                        id: profile.id,
                        referenceFeaturePrints: references,
                        contextFeaturePrints: contexts
                    )
                }
            }

            let storedPhotoReferenceCount = min(
                profile.photoReferenceCount ?? min(self.manualPhotoTarget, observations.count),
                observations.count
            )
            let storedPhotoContextCount = min(
                profile.photoContextCount ?? min(self.manualPhotoTarget, contextObservations.count),
                contextObservations.count
            )
            self.videoQueue.async {
                guard self.profileActivationID == activationID else { return }
                self.featureSamples = observations
                self.contextFeatureSamples = contextObservations
                self.photoFeatureSamples = Array(observations.prefix(storedPhotoReferenceCount))
                self.videoFeatureSamples = Array(observations.dropFirst(storedPhotoReferenceCount))
                self.photoContextFeatureSamples = Array(contextObservations.prefix(storedPhotoContextCount))
                self.videoContextFeatureSamples = Array(contextObservations.dropFirst(storedPhotoContextCount))
                self.scanContextImages = profile.contextImages ?? []
                self.processingMode = .idle
                self.trackingObservation = nil
                self.sequenceHandler = VNSequenceRequestHandler()
                DispatchQueue.main.async {
                    guard self.profileActivationID == activationID else { return }
                    if let cachedProfiles {
                        self.savedProfiles = cachedProfiles
                    }
                self.learnedSamples = observations.count
                self.surfacePointCount = profile.surfacePointCount
                self.detectedSubjectLabel = profile.subjectKind.title
                self.detectedSubjectConfidence = 1
                self.scanHasConfirmedTarget = true
                self.targetConfirmationProgress = 1
                self.scanProgress = 0.8
                self.scanSampleCount = 80
                self.scanSampleTarget = 80
                self.scanIsSufficient = true
                self.scanNeedsNewAngle = false
                self.selectedSubjectRect = nil
                self.stage = .ready
                self.isProfilePreparing = false
                self.matchText = "Đã mở \(profile.name) • \(observations.count) góc"
                self.statusText = "Mẫu đã sẵn sàng để khóa, bám và quay"
                self.announce("Đã mở mẫu. Sẵn sàng bám mục tiêu.", kind: .success)
                self.onEvent?("PROFILE_LOADED")
                }
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
        guard !isProfilePreparing else {
            statusText = "Mẫu đang chuẩn bị dữ liệu AI; vui lòng chờ trong giây lát"
            return
        }
        isStopRequested = false
        hasCompletedOneTimeZoom = false
        activeTrackingPreparationID = UUID()
        let preparationID = activeTrackingPreparationID
        let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
        let recordAfterLock = !isRecording
        stage = .verifying
        targetRect = nil
        trackingPoints = []
        predictedTargetPoint = nil
        trackingConfidence = 0
        trackingPreparationCountdown = 3
        matchText = "ĐANG GHÉP ẢNH + VIDEO + AI • 3 GIÂY"
        statusText = "Chờ 3 giây để hợp nhất dữ liệu nhận diện trước khi quay"
        announce("Đang ghép dữ liệu nhận diện. Bắt đầu tìm mục tiêu sau ba giây.", kind: .start)

        videoQueue.async { [weak self] in
            guard let self else { return }
            // FeaturePrint đã có sẵn trong RAM hoặc cache của mẫu. Ba giây này chỉ
            // khóa trạng thái và hợp nhất bộ lọc, không chạy lại Vision cho 60+ ảnh.
            self.processingRect = fullFrame
            self.featureFrameCounter = 0
            self.aiDetectionMisses = 0
            self.identityGateStatus = ""
            // Mẫu vừa chụp đã có tọa độ đáng tin cậy. Giữ tọa độ đó cho frame
            // xác nhận đầu tiên thay vì vứt bỏ rồi bắt YOLO tìm lại từ số 0.
            let seedAge = CACurrentMediaTime() - self.freshScanSeedTimestamp
            self.pendingFreshScanSeedRect = (0...15).contains(seedAge)
                ? self.freshScanSeedRect
                : nil
            self.clearPendingAIDetection()
            self.clearRecoveryState()
            self.shouldRecordAfterVerification = recordAfterLock
            self.processingMode = .idle
        }
        for elapsedSecond in 1...3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(elapsedSecond)) { [weak self] in
                guard let self,
                      !self.isStopRequested,
                      self.activeTrackingPreparationID == preparationID else { return }
                self.trackingPreparationCountdown = max(0, 3 - elapsedSecond)
                if self.trackingPreparationCountdown > 0 {
                    self.matchText = "ĐANG GHÉP ẢNH + VIDEO + AI • \(self.trackingPreparationCountdown) GIÂY"
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self,
                  !self.isStopRequested,
                  self.activeTrackingPreparationID == preparationID else { return }
            self.onEvent?("TRACKING_STARTED")
            self.matchText = self.usesRocketSpecificDetector && self.aiDetector.isAvailable
                ? "AI + ảnh/video cá nhân đang tìm tên lửa..."
                : "Vision + ảnh/video cá nhân đang tìm \(self.scanSubjectKind.title.lowercased())..."
            self.statusText = "Đã hợp nhất dữ liệu • đang khóa mục tiêu để bắt đầu quay"
            self.videoQueue.async { [weak self] in
                self?.processingMode = .verifying
            }
        }
    }

    func reacquireTarget() {
        guard stage == .lost else { return }
        let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
        stage = .verifying
        targetRect = nil
        trackingPoints = []
        predictedTargetPoint = nil
        matchText = "Đang tìm lại \(detectedSubjectLabel) trên toàn màn hình..."
        statusText = "Có thể đặt \(scanSubjectKind.title.lowercased()) ở bất kỳ vị trí nào trong khung camera"
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.processingRect = fullFrame
            self.featureFrameCounter = 0
            self.aiDetectionMisses = 0
            self.identityGateStatus = ""
            self.pendingFreshScanSeedRect = nil
            self.clearPendingAIDetection()
            self.shouldRecordAfterVerification = false
            self.processingMode = .verifying
        }
    }

    func cancelTargetSearch() {
        guard stage == .verifying else { return }
        isStopRequested = true
        trackingPreparationCountdown = 0
        videoQueue.async { [weak self] in
            self?.processingMode = .idle
        }
        stage = isRecording ? .lost : .ready
        trackingPoints = []
        predictedTargetPoint = nil
        servoSearchVector = nil
        servoSearchAnchor = nil
        isServoTrajectorySearching = false
        matchText = isRecording ? "Đã dừng tìm lại mục tiêu" : "Mẫu đã sẵn sàng"
        statusText = isRecording ? "Mất mục tiêu • có thể bấm Bắt lại" : "Có thể bấm Khóa, bám & quay"
        onEvent?("SEARCH_STOP")
    }

    func stopRecording() {
        // Dừng UI và servo ngay khi chạm nút, không đợi movieOutput ghi xong file.
        isStopRequested = true
        trackingPreparationCountdown = 0
        activeTrackingPreparationID = UUID()
        cancelZoomSequence()
        voiceNotifier.stop()
        stage = .ready
        matchText = "ĐÃ DỪNG BÁM MỤC TIÊU"
        statusText = "Đang dừng và lưu video..."
        onEvent?("SEARCH_STOP")
        onEvent?("RECORDING_STOPPED")
        videoQueue.async { [weak self] in
            self?.processingMode = .idle
            self?.trackingObservation = nil
            self?.trackingAnchorObservations.removeAll()
            self?.trackingTrianglePoints.removeAll()
            self?.lastTrackingBounds = nil
            self?.segmentationMissFrames = 0
            self?.previousTrackingCenter = nil
            self?.smoothedTrackingVelocity = .zero
            self?.motionFilter.clear()
            self?.aiDetectionMisses = 0
            self?.clearPendingAIDetection()
            self?.clearRecoveryState()
        }
        targetRect = nil
        trackingPoints = []
        predictedTargetPoint = nil
        servoSearchVector = nil
        servoSearchAnchor = nil
        isServoTrajectorySearching = false
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
        resetManualCaptureRequest()

        switch kind {
        case .near:
            stage = .scanningNear
            statusText = "Đặt đúng \(scanSubjectKind.title.lowercased()) vào giữa vòng rồi bấm chụp"
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
        scanGuidanceText = "ẢNH 1/7 • CHỤP CHÍNH DIỆN"
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
        detectedSubjectLabel = scanSubjectKind.title
        detectedSubjectConfidence = 0
        targetRect = rect
        matchText = "CHỤP BÌNH THƯỜNG • AI TỰ CHỌN VẬT NHẤT QUÁN"

        videoQueue.async { [weak self] in
            guard let self else { return }
            if resetProfile {
                self.featureSamples.removeAll()
                self.contextFeatureSamples.removeAll()
                self.photoFeatureSamples.removeAll()
                self.videoFeatureSamples.removeAll()
                self.photoContextFeatureSamples.removeAll()
                self.videoContextFeatureSamples.removeAll()
                self.sequenceHandler = VNSequenceRequestHandler()
                self.trackingObservation = nil
                self.trackingAnchorObservations.removeAll()
                self.trackingTrianglePoints.removeAll()
                self.lastTrackingBounds = nil
                self.segmentationMissFrames = 0
                self.previousTrackingCenter = nil
                self.smoothedTrackingVelocity = .zero
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
            self.scanContextImages.removeAll()
            self.freshScanSeedRect = nil
            self.freshScanSeedTimestamp = 0
            self.pendingFreshScanSeedRect = nil
            self.targetCandidateCells.removeAll()
            self.confirmedTargetCells.removeAll()
            self.targetStableFrameCount = 0
            self.targetIsConfirmed = false
            self.acceptedViewMasks.removeAll()
            self.lastAcceptedFeature = nil
            self.voxelOccupancy.removeAll()
            self.manualSelectionRequested = false
            self.capturedReferencePhotoCount = 0
            self.referenceVideoStartedAt = nil
            self.lastReferenceVideoSampleAt = 0
            self.capturedReferenceVideoFrames = 0
            self.lastReferenceVideoRect = nil
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
                    contextImages: self.scanContextImages,
                    photoReferenceCount: min(
                        self.manualPhotoTarget,
                        self.scanReferenceImages.count
                    ),
                    photoContextCount: min(
                        self.manualPhotoTarget,
                        self.scanContextImages.count
                    ),
                    referenceFeaturePrints: self.featureSamples.count == self.scanReferenceImages.count
                        ? self.featureSamples.compactMap(self.encodeFeaturePrint)
                        : nil,
                    contextFeaturePrints: self.contextFeatureSamples.count == self.scanContextImages.count
                        ? self.contextFeatureSamples.compactMap(self.encodeFeaturePrint)
                        : nil,
                    surfacePointCount: self.scanReferenceImages.count,
                    voxelOccupancy: nil,
                    classificationLabel: self.scanSubjectKind.title
                )
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
                    self.activeProfileID = savedProfile.id
                }

                guard isComplete else {
                    self.stage = .idle
                    self.matchText = "ĐÃ CHỤP \(self.scanReferenceImages.count)/7 ẢNH"
                    self.statusText = "Chưa đủ 7 ảnh; hãy chụp bổ sung"
                    return
                }

                self.scanProgress = 1.0
                self.scanIsSufficient = true
                self.stage = .ready
                self.matchText = "7 ẢNH + VIDEO \(self.capturedReferenceVideoFrames) KHUNG • mẫu \(self.savedProfiles.count)/5"
                self.statusText = "Đã liên kết AI có sẵn, bộ ảnh và video 10 giây. Có thể khóa và quay"
                self.announce("Đã ghép bộ ảnh và video mẫu. Mô hình nhận diện đã sẵn sàng.", kind: .success)
                self.onEvent?("SHAPE_SCAN_DONE")
            }
            if let savedProfile {
                self.profileQueue.async { [weak self] in
                    guard let self else { return }
                    let updatedProfiles = self.profileStore.save(savedProfile)
                    DispatchQueue.main.async {
                        self.savedProfiles = updatedProfiles
                    }
                }
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
        let isCentered: Bool
        let contourPoints: [CGPoint]
    }

    private func rawSubjectSelection(
        from pixelBuffer: CVPixelBuffer,
        rect proposedRect: CGRect
    ) -> ManualSubjectMask? {
        let frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        let rect = proposedRect.intersection(frame)
        guard rect.width >= 0.08, rect.height >= 0.10,
              let jpeg = referenceJPEG(
                from: pixelBuffer,
                normalizedTopLeftRect: rect,
                orientation: .up
              ) else { return nil }

        var cells = Set<Int>()
        for row in 0..<selectionGridRows {
            for column in 0..<selectionGridColumns {
                let point = CGPoint(
                    x: (CGFloat(column) + 0.5) / CGFloat(selectionGridColumns),
                    y: (CGFloat(row) + 0.5) / CGFloat(selectionGridRows)
                )
                if rect.contains(point) {
                    cells.insert(row * selectionGridColumns + column)
                }
            }
        }
        let contour = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
        return ManualSubjectMask(
            cells: cells,
            boundingRect: rect,
            image: UIImage(),
            referenceJPEG: jpeg,
            removedHand: false,
            isCentered: true,
            contourPoints: contour
        )
    }

    /// Chỉ chọn chai/tên lửa đã được AI xác nhận và có tâm nằm trong vòng tròn.
    /// Các vật ở ngoài vòng hoặc ở bốn góc crop không được đưa vào bộ ảnh mẫu.
    private func automaticReferenceSelection(
        from pixelBuffer: CVPixelBuffer
    ) -> (selection: ManualSubjectMask, detection: WaterRocketDetection)? {
        let guide = scanRect
        let isFarPhoto = scanReferenceImages.count >= manualPhotoTarget - 1
        let minimumArea: CGFloat = isFarPhoto ? 0.00035 : 0.0025
        let detections = detectRocketOrBottle(
            in: pixelBuffer,
            minimumConfidence: isFarPhoto ? 0.06 : 0.10,
            regionOfInterest: guide
        ).filter {
            let normalizedX = ($0.rect.midX - guide.midX) / max(0.001, guide.width / 2)
            let normalizedY = ($0.rect.midY - guide.midY) / max(0.001, guide.height / 2)
            let insideCircle = normalizedX * normalizedX + normalizedY * normalizedY <= 1.0
            return insideCircle && $0.rect.width * $0.rect.height >= minimumArea
        }
        let center = CGPoint(x: 0.5, y: 0.5)
        let selected = detections.max { lhs, rhs in
            func score(_ detection: WaterRocketDetection) -> CGFloat {
                let distance = hypot(
                    detection.rect.midX - center.x,
                    detection.rect.midY - center.y
                )
                let area = min(0.55, detection.rect.width * detection.rect.height)
                let bottleBoost: CGFloat = detection.label
                    .lowercased().contains("bottle") ? 0.16 : 0.24
                return CGFloat(detection.confidence) * 0.55
                    + area * 0.85
                    + bottleBoost
                    - distance * 0.72
            }
            return score(lhs) < score(rhs)
        }

        if let detection = selected {
            let padX = max(0.025, detection.rect.width * 0.10)
            let padY = max(0.030, detection.rect.height * 0.08)
            let padded = detection.rect
                .insetBy(dx: -padX, dy: -padY)
                .intersection(guide)
            let cropWidth = max(0.08, padded.width)
            let cropHeight = max(0.10, padded.height)
            let crop = CGRect(
                x: padded.midX - cropWidth / 2,
                y: padded.midY - cropHeight / 2,
                width: cropWidth,
                height: cropHeight
            ).intersection(guide)
            guard let selection = rawSubjectSelection(
                from: pixelBuffer,
                rect: crop
            ) else { return nil }
            return (selection, detection)
        }
        return nil
    }

    private struct TrainingReferenceSelection {
        let selection: ManualSubjectMask
        let confidence: Double
        let label: String
        let kind: ScanSubjectKind
    }

    /// Người và thú được Vision đối chứng đúng loại; vật dùng mặt nạ chủ thể và
    /// loại vùng người/tay. Riêng tên lửa dạng chai vẫn ưu tiên hai model chuyên dụng.
    private func trainingReferenceSelection(
        from pixelBuffer: CVPixelBuffer
    ) -> TrainingReferenceSelection? {
        if scanSubjectKind == .waterRocket,
           let rocket = automaticReferenceSelection(from: pixelBuffer) {
            return TrainingReferenceSelection(
                selection: rocket.selection,
                confidence: rocket.detection.confidence,
                label: rocket.detection.label.lowercased().contains("bottle")
                    ? "chai nước"
                    : "tên lửa nước",
                kind: .waterRocket
            )
        }

        guard let selection = manualSubjectMask(
            from: pixelBuffer,
            at: selectedSubjectPoint
        ), selection.isCentered else { return nil }
        let classification = classifySubject(
            in: pixelBuffer,
            rect: selection.boundingRect,
            referenceJPEG: selection.referenceJPEG
        )
        guard classification.kind == scanSubjectKind else { return nil }
        return TrainingReferenceSelection(
            selection: selection,
            confidence: classification.confidence,
            label: classification.label,
            kind: classification.kind
        )
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
        guard scanSubjectKind != .person else { return [] }
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

            let horizontalPadding = max(5, selectionGridColumns / 12)
            let verticalPadding = max(7, selectionGridRows / 12)
            let minColumn = max(0, minimumColumn - horizontalPadding)
            let maxColumn = min(
                selectionGridColumns - 1,
                maximumColumn + horizontalPadding
            )
            let minRow = max(0, minimumRow - verticalPadding)
            let maxRow = min(
                selectionGridRows - 1,
                maximumRow + verticalPadding
            )
            for row in minRow...maxRow {
                for column in minColumn...maxColumn {
                    excluded.insert(row * selectionGridColumns + column)
                }
            }
        }
        return excluded
    }

    private func personExclusionCells(from pixelBuffer: CVPixelBuffer) -> Set<Int> {
        guard scanSubjectKind != .person else { return [] }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([request])
            guard let maskBuffer = request.results?.first?.pixelBuffer else { return [] }
            let rawMask = CIImage(cvPixelBuffer: maskBuffer)
            let normalizedMask = rawMask.transformed(by: CGAffineTransform(
                translationX: -rawMask.extent.minX,
                y: -rawMask.extent.minY
            ))
            let scaled = normalizedMask.transformed(by: CGAffineTransform(
                scaleX: CGFloat(selectionGridColumns) / normalizedMask.extent.width,
                y: CGFloat(selectionGridRows) / normalizedMask.extent.height
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
            var excluded = Set<Int>()
            for visualRow in 0..<selectionGridRows {
                let maskRow = selectionGridRows - 1 - visualRow
                for column in 0..<selectionGridColumns
                where bitmap[maskRow * selectionGridColumns + column] > 72 {
                    excluded.insert(visualRow * selectionGridColumns + column)
                }
            }
            return excluded
        } catch {
            return []
        }
    }

    private func connectedComponent(
        in cells: Set<Int>,
        nearestTo point: CGPoint
    ) -> Set<Int> {
        guard let seed = cells.min(by: { first, second in
            let firstPoint = normalizedGridPoint(for: first)
            let secondPoint = normalizedGridPoint(for: second)
            let firstDX = firstPoint.x - point.x
            let firstDY = firstPoint.y - point.y
            let secondDX = secondPoint.x - point.x
            let secondDY = secondPoint.y - point.y
            return firstDX * firstDX + firstDY * firstDY
                < secondDX * secondDX + secondDY * secondDY
        }) else { return [] }

        var visited: Set<Int> = [seed]
        var queue: [Int] = [seed]
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            let column = current % selectionGridColumns
            let row = current / selectionGridColumns
            for rowOffset in -1...1 {
                for columnOffset in -1...1 where rowOffset != 0 || columnOffset != 0 {
                    let nextColumn = column + columnOffset
                    let nextRow = row + rowOffset
                    guard (0..<selectionGridColumns).contains(nextColumn),
                          (0..<selectionGridRows).contains(nextRow) else { continue }
                    let next = nextRow * selectionGridColumns + nextColumn
                    if cells.contains(next), visited.insert(next).inserted {
                        queue.append(next)
                    }
                }
            }
        }
        return visited
    }

    private func normalizedGridPoint(for index: Int) -> CGPoint {
        CGPoint(
            x: (CGFloat(index % selectionGridColumns) + 0.5)
                / CGFloat(selectionGridColumns),
            y: (CGFloat(index / selectionGridColumns) + 0.5)
                / CGFloat(selectionGridRows)
        )
    }

    private func subjectOccupiesGuideCenter(_ cells: Set<Int>) -> Bool {
        // Chỉ bắt buộc một phần thật của vật đi qua lõi vòng tròn. Kích thước
        // toàn vật không bị giới hạn nên chai/tên lửa lớn vẫn được tràn ra ngoài.
        let horizontalRadius = max(0.055, scanRect.width * 0.22)
        let verticalRadius = max(0.035, scanRect.height * 0.22)
        return cells.contains { index in
            let column = index % selectionGridColumns
            let row = index / selectionGridColumns
            let x = (CGFloat(column) + 0.5) / CGFloat(selectionGridColumns)
            let y = (CGFloat(row) + 0.5) / CGFloat(selectionGridRows)
            let dx = (x - 0.5) / horizontalRadius
            let dy = (y - 0.5) / verticalRadius
            return dx * dx + dy * dy <= 1
        }
    }

    private func gridCells(in normalizedRect: CGRect) -> Set<Int> {
        let clipped = normalizedRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return [] }
        var result = Set<Int>()
        for row in 0..<selectionGridRows {
            let y = (CGFloat(row) + 0.5) / CGFloat(selectionGridRows)
            guard y >= clipped.minY, y <= clipped.maxY else { continue }
            for column in 0..<selectionGridColumns {
                let x = (CGFloat(column) + 0.5) / CGFloat(selectionGridColumns)
                if x >= clipped.minX, x <= clipped.maxX {
                    result.insert(row * selectionGridColumns + column)
                }
            }
        }
        return result
    }

    private func contourPoints(from cells: Set<Int>) -> [CGPoint] {
        guard cells.count >= 8 else { return [] }
        let locations = cells.map { index -> CGPoint in
            let column = index % selectionGridColumns
            let row = index / selectionGridColumns
            return CGPoint(
                x: (CGFloat(column) + 0.5) / CGFloat(selectionGridColumns),
                y: (CGFloat(row) + 0.5) / CGFloat(selectionGridRows)
            )
        }
        let center = CGPoint(
            x: locations.map(\.x).reduce(0, +) / CGFloat(locations.count),
            y: locations.map(\.y).reduce(0, +) / CGFloat(locations.count)
        )
        let bucketCount = 56
        var boundary: [Int: (point: CGPoint, radius: CGFloat)] = [:]
        for point in locations {
            let dx = point.x - center.x
            let dy = point.y - center.y
            var angle = atan2(dy, dx)
            if angle < 0 { angle += 2 * .pi }
            let bucket = min(
                bucketCount - 1,
                Int(angle / (2 * .pi) * CGFloat(bucketCount))
            )
            let radius = dx * dx + dy * dy
            if boundary[bucket] == nil || radius > boundary[bucket]!.radius {
                boundary[bucket] = (point, radius)
            }
        }
        return boundary.keys.sorted().compactMap { boundary[$0]?.point }
    }

    private func trianglePoints(from cells: Set<Int>) -> [CGPoint] {
        let outline = contourPoints(from: cells)
        guard outline.count >= 3 else { return [] }
        var best: [CGPoint] = []
        var bestArea: CGFloat = -1
        for first in 0..<(outline.count - 2) {
            for second in (first + 1)..<(outline.count - 1) {
                for third in (second + 1)..<outline.count {
                    let a = outline[first]
                    let b = outline[second]
                    let c = outline[third]
                    let area = abs(
                        (b.x - a.x) * (c.y - a.y)
                        - (b.y - a.y) * (c.x - a.x)
                    )
                    if area > bestArea {
                        bestArea = area
                        best = [a, b, c]
                    }
                }
            }
        }
        guard best.count == 3 else { return [] }
        let center = CGPoint(
            x: best.map(\.x).reduce(0, +) / 3,
            y: best.map(\.y).reduce(0, +) / 3
        )
        return best.sorted {
            atan2($0.y - center.y, $0.x - center.x)
                < atan2($1.y - center.y, $1.x - center.x)
        }
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

        // Tab người dùng chọn là nguồn sự thật. AI chỉ đặt tên chi tiết bên
        // trong tab đó, không tự đổi Vật thành Người vì thấy bàn tay đang cầm.
        switch scanSubjectKind {
        case .waterRocket:
            if let rocket = detectRocketOrBottle(
                in: pixelBuffer,
                minimumConfidence: 0.05,
                regionOfInterest: rect
                    .insetBy(dx: -0.06, dy: -0.06)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            ).max(by: { $0.confidence < $1.confidence }) {
                let isBottle = rocket.label.lowercased().contains("bottle")
                return (
                    .waterRocket,
                    isBottle ? "chai tên lửa" : "tên lửa nước",
                    rocket.confidence
                )
            }
            // Người dùng đã chủ động chọn tab chuyên dụng; vẫn cho phép chụp
            // mẫu nhỏ để 7 ảnh + video cá nhân hoàn thiện nhận dạng.
            return (.waterRocket, "tên lửa nước", 0.10)

        case .person:
            let confidence = personRequest.results?
                .map { Double($0.confidence) }
                .max() ?? 0.10
            return (.person, "người", confidence)

        case .animal:
            if let animal = animalRequest.results?.max(by: { $0.confidence < $1.confidence }),
               let label = animal.labels.first {
                return (
                    .animal,
                    friendlyClassificationName(label.identifier),
                    Double(animal.confidence)
                )
            }
            return (.animal, "thú", 0.10)

        case .object:
            break
        }

        guard let image = UIImage(data: referenceJPEG)?.cgImage else {
            return (.object, "vật thể", 0)
        }
        let classifyRequest = VNClassifyImageRequest()
        let classifyHandler = VNImageRequestHandler(cgImage: image, orientation: .up)
        do {
            try classifyHandler.perform([classifyRequest])
            if let result = classifyRequest.results?.first(where: { $0.confidence >= 0.05 }) {
                let label = friendlyClassificationName(result.identifier)
                let crossTypeLabels = ["người", "chó", "mèo", "chim"]
                return (
                    .object,
                    crossTypeLabels.contains(label) ? "vật thể" : label,
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

            // Với lớp tên lửa nước đã học sẵn, dùng hộp AI để cắt bớt tay và
            // nền ngay từ lúc người dùng chọn mẫu. Vision vẫn cung cấp viền mềm,
            // còn AI chỉ giới hạn đúng vùng của tên lửa ở tâm.
            let centeredRocket = aiDetector.detect(
                in: pixelBuffer,
                orientation: .up,
                minimumConfidence: 0.12
            ).first { detection in
                let expanded = detection.rect.insetBy(dx: -0.035, dy: -0.035)
                let containsTap = expanded.contains(point)
                let centerDistance = hypot(
                    detection.rect.midX - 0.5,
                    detection.rect.midY - 0.5
                )
                return containsTap || centerDistance < 0.23
            }
            if let centeredRocket {
                let rocketArea = gridCells(
                    in: centeredRocket.rect.insetBy(dx: -0.025, dy: -0.025)
                )
                let focusedRocket = cells.intersection(rocketArea)
                if focusedRocket.count >= 18 {
                    cells = focusedRocket
                }
            }

            let originalCells = cells
            let handCells = handExclusionCells(from: pixelBuffer)
            let personCells = personExclusionCells(from: pixelBuffer)
            let humanCells = handCells.union(personCells)
            let withoutHuman = cells.subtracting(humanCells)
            let minimumUsefulCount = max(24, originalCells.count / 12)
            let removedHand = !humanCells.isEmpty && withoutHuman.count >= minimumUsefulCount
            if removedHand { cells = withoutHuman }

            // Sau khi bỏ tay/người, chỉ giữ mảng liền khối gần tâm nhất. Điều này
            // loại cánh tay, nền và vật phụ ở xa nhưng không cắt phần vật tràn vòng.
            let focusedCells = connectedComponent(
                in: cells,
                nearestTo: CGPoint(x: 0.5, y: 0.5)
            )
            if focusedCells.count >= max(24, cells.count / 10) {
                cells = focusedCells
            } else if cells.count < 24 {
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
            let enlargedMask = lowResolutionMask.transformed(by: CGAffineTransform(
                scaleX: maskImage.extent.width / CGFloat(selectionGridColumns),
                y: maskImage.extent.height / CGFloat(selectionGridRows)
            ))
            // Làm mềm viền sau khi phóng lớn để không còn các ô vuông ghép thô.
            // Morphology lấp khe nhỏ, Gaussian tạo đường bo tự nhiên quanh vật.
            let selectionGate = enlargedMask
                .clampedToExtent()
                .applyingFilter(
                    "CIMorphologyMaximum",
                    parameters: [kCIInputRadiusKey: 2.2]
                )
                .applyingFilter(
                    "CIGaussianBlur",
                    parameters: [kCIInputRadiusKey: 7.0]
                )
                .cropped(to: maskImage.extent)
            let fullResolutionMask = maskImage
                .applyingFilter(
                    "CIMultiplyCompositing",
                    parameters: [kCIInputBackgroundImageKey: selectionGate]
                )
                .applyingFilter(
                    "CIGaussianBlur",
                    parameters: [kCIInputRadiusKey: 1.1]
                )
                .cropped(to: maskImage.extent)
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
                removedHand: removedHand,
                isCentered: subjectOccupiesGuideCenter(cells),
                contourPoints: contourPoints(from: cells)
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
                self.subjectContourPoints = []
                self.scanNeedsNewAngle = true
                self.scanGuidanceText = "Không tách được \(self.scanSubjectKind.title.lowercased()) • hãy chạm gần giữa chủ thể"
                self.statusText = "AI chưa xác định được \(self.scanSubjectKind.title.lowercased()) trong ảnh này"
            }
            return
        }

        guard selection.isCentered else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hasSelectedSubject = false
                self.selectedSubjectMaskImage = nil
                self.selectedSubjectRect = nil
                self.subjectContourPoints = []
                self.scanNeedsNewAngle = true
                self.scanGuidanceText = "Đưa một phần chính của \(self.scanSubjectKind.title.lowercased()) qua tâm vòng tròn"
                self.statusText = "Chủ thể được phép tràn khỏi vòng, nhưng tâm vòng phải chạm chủ thể"
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
            self.subjectContourPoints = selection.contourPoints
            self.scanHasConfirmedTarget = true
            self.targetConfirmationProgress = 1
            self.detectedSubjectLabel = self.scanSubjectKind.title
            self.detectedSubjectConfidence = classification.confidence
            self.scanNeedsNewAngle = false
            self.scanGuidanceText = self.nextReferenceGuidance(after: 0)
            self.matchText = "NHẬN DIỆN: \(self.scanSubjectKind.title.uppercased()) • \(Int(classification.confidence * 100))%"
            self.statusText = selection.removedHand
                ? "Đã loại vùng bàn tay; nếu chọn sai hãy chạm lại"
                : "Nếu chọn sai, chạm lại vào đúng \(self.scanSubjectKind.title.lowercased())"
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self.announce("Đã chọn đúng \(self.scanSubjectKind.title.lowercased()) cần chụp.", kind: .success)
            self.onEvent?("SUBJECT_SELECTED")
        }
    }

    private func nextReferenceGuidance(after capturedCount: Int) -> String {
        let instructions = [
            "chụp chính diện",
            "xoay mặt trái về camera",
            "xoay mặt phải về camera",
            "chụp mặt sau",
            "chụp từ trên xuống",
            "chụp từ dưới lên",
            "đưa chủ thể ra xa rồi chụp"
        ]
        guard capturedCount < instructions.count else { return "Đã đủ 7 ảnh" }
        return "Ảnh \(capturedCount + 1)/7 • \(instructions[capturedCount])"
    }

    private func captureManualPhoto(
        from pixelBuffer: CVPixelBuffer,
        kind: ScanKind
    ) {
        defer { finishManualCaptureRequest() }
        guard let reference = trainingReferenceSelection(from: pixelBuffer) else {
            DispatchQueue.main.async { [weak self] in
                self?.scanNeedsNewAngle = true
                self?.scanHasConfirmedTarget = false
                self?.matchText = "CHƯA XÁC NHẬN ĐÚNG \(self?.scanSubjectKind.title.uppercased() ?? "CHỦ THỂ")"
                self?.scanGuidanceText = "Đặt đúng chủ thể đã chọn vào giữa vòng tròn rồi chụp lại"
                self?.statusText = "Ảnh chưa được lưu để tránh lấy nhầm chủ thể khác"
            }
            return
        }
        let selection = reference.selection
        processingRect = selection.boundingRect
        // Người dùng chủ động chụp đúng vật theo từng hướng dẫn. Luôn nhận ảnh khi
        // bấm nút; không chặn vì trùng góc, ánh sáng hoặc khoảng cách feature.
        let capturedFeature = featurePrint(fromJPEGData: selection.referenceJPEG)
        if let feature = capturedFeature {
            lastAcceptedFeature = feature
            featureSamples.append(feature)
            photoFeatureSamples.append(feature)
        }
        acceptedViewMasks.append(selection.cells)
        scanReferenceImages.append(selection.referenceJPEG)
        let capturedContextJPEG = referenceJPEG(
            from: pixelBuffer,
            normalizedTopLeftRect: selection.boundingRect,
            orientation: .up
        )
        var capturedContextFeature: VNFeaturePrintObservation?
        if let contextJPEG = capturedContextJPEG {
            scanContextImages.append(contextJPEG)
            // Vá»›i tÃªn lá»­a/chai, áº£nh váº­t vÃ  áº£nh ngá»¯ cáº£nh thÆ°á»ng lÃ  cÃ¹ng má»™t crop.
            // TÃ¡i sá»­ dá»¥ng FeaturePrint Ä‘á»ƒ bá»›t má»™t láº§n Vision má»—i khi báº¥m chá»¥p.
            let contextFeature = contextJPEG == selection.referenceJPEG
                ? capturedFeature
                : featurePrint(fromJPEGData: contextJPEG)
            if let contextFeature {
                capturedContextFeature = contextFeature
                contextFeatureSamples.append(contextFeature)
                photoContextFeatureSamples.append(contextFeature)
            }
        }
        confirmedTargetCells = selection.cells

        if isAddingReferencePhoto, let profileID = activeProfileID {
            let referenceFeatureData = capturedFeature.flatMap(encodeFeaturePrint)
            let contextFeatureData = capturedContextFeature.flatMap(encodeFeaturePrint)
            processingMode = .idle
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isAddingReferencePhoto = false
                self.stage = .ready
                self.scanIsSufficient = true
                self.scanNeedsNewAngle = false
                self.scanHasConfirmedTarget = true
                self.scanViewpointCount = 0
                self.targetRect = nil
                self.learnedSamples = self.featureSamples.count
                self.matchText = "ĐÃ GHÉP THÊM 1 ẢNH VÀO MẪU"
                self.statusText = "Ảnh bổ sung đã được đối chiếu cùng bộ ảnh và video cũ"
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                self.announce("Đã thêm ảnh đối chứng vào mẫu.", kind: .success)
                self.onEvent?("SUPPLEMENTAL_PHOTO_ADDED")
            }
            profileQueue.async { [weak self] in
                guard let self else { return }
                let updatedProfiles = self.profileStore.addSupplementalPhoto(
                    id: profileID,
                    referenceImage: selection.referenceJPEG,
                    contextImage: capturedContextJPEG,
                    referenceFeaturePrint: referenceFeatureData,
                    contextFeaturePrint: contextFeatureData
                )
                DispatchQueue.main.async {
                    self.savedProfiles = updatedProfiles
                }
            }
            return
        }

        capturedReferencePhotoCount = min(
            manualPhotoTarget,
            capturedReferencePhotoCount + 1
        )
        let count = capturedReferencePhotoCount
        // 7 ảnh chiếm 70% tiến trình; video mẫu 10 giây hoàn tất 30% cuối.
        shapeScanCoverage = Double(count) / Double(manualPhotoTarget) * 0.70
        let coveragePercent = Int((shapeScanCoverage * 100).rounded())
        let photosComplete = count >= manualPhotoTarget

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasSelectedSubject = true
            self.selectedSubjectMaskImage = nil
            self.selectedSubjectRect = selection.boundingRect
            self.subjectContourPoints = []
            self.scanHasConfirmedTarget = true
            self.targetConfirmationProgress = 1
            self.detectedSubjectLabel = self.scanSubjectKind.title
            self.detectedSubjectConfidence = reference.confidence
            self.learnedSamples = count
            self.scanViewpointCount = count
            self.scanSampleCount = coveragePercent
            self.scanSampleTarget = 80
            self.scanProgress = self.shapeScanCoverage
            self.scanIsSufficient = false
            self.scanNeedsNewAngle = false
            self.matchText = "ĐÃ XÁC NHẬN \(self.scanSubjectKind.title.uppercased()) \(Int(reference.confidence * 100))% • \(count)/7"
            self.scanGuidanceText = photosComplete
                ? "Đã đủ 7 ảnh • bấm video và quay \(self.scanSubjectKind.title.lowercased()) trong 10 giây"
                : self.nextReferenceGuidance(after: count)
            self.statusText = photosComplete
                ? "Bước cuối: video \(self.scanSubjectKind.title.lowercased()) sẽ bổ sung góc chuyển tiếp cho AI"
                : "Ảnh đã lưu • làm theo hướng chụp tiếp theo"
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self.onEvent?("REFERENCE_PHOTO_\(count)")
        }

    }

    private func processReferenceVideoFrame(
        from pixelBuffer: CVPixelBuffer,
        kind: ScanKind
    ) {
        guard let startedAt = referenceVideoStartedAt else { return }
        let now = CACurrentMediaTime()
        let elapsed = max(0, now - startedAt)
        let progress = min(1, elapsed / referenceVideoDuration)

        // Lấy tối đa khoảng 24 frame trong 10 giây. Mỗi frame phải đúng loại
        // Người / Thú / Vật đã chọn; tên lửa dạng chai dùng model chuyên dụng.
        if now - lastReferenceVideoSampleAt >= 0.38,
           capturedReferenceVideoFrames < referenceVideoTargetFrames,
           let reference = trainingReferenceSelection(from: pixelBuffer) {
            let selection = reference.selection
            // Vật có thể xoay tại chỗ nên hộp detection gần như không di chuyển.
            // Lấy theo thời gian; feature-print ghi hình dạng/bề mặt mới ở mỗi góc.
            lastReferenceVideoSampleAt = now
            lastReferenceVideoRect = selection.boundingRect
            scanReferenceImages.append(selection.referenceJPEG)
            if let feature = featurePrint(fromJPEGData: selection.referenceJPEG) {
                featureSamples.append(feature)
                videoFeatureSamples.append(feature)
            }
            if let contextJPEG = referenceJPEG(
                from: pixelBuffer,
                normalizedTopLeftRect: selection.boundingRect,
                orientation: .up
            ) {
                scanContextImages.append(contextJPEG)
                if let feature = featurePrint(fromJPEGData: contextJPEG) {
                    contextFeatureSamples.append(feature)
                    videoContextFeatureSamples.append(feature)
                }
            }
            capturedReferenceVideoFrames += 1
            freshScanSeedRect = selection.boundingRect
            freshScanSeedTimestamp = now
            DispatchQueue.main.async { [weak self] in
                self?.detectedSubjectLabel = self?.scanSubjectKind.title ?? reference.kind.title
                self?.detectedSubjectConfidence = reference.confidence
            }
        }

        let frameCount = capturedReferenceVideoFrames
        shapeScanCoverage = min(1.0, 0.70 + progress * 0.30)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.referenceVideoProgress = progress
            self.referenceVideoFrameCount = frameCount
            self.scanProgress = self.shapeScanCoverage
            self.scanSampleCount = Int((self.shapeScanCoverage * 100).rounded())
            self.matchText = String(
                format: "VIDEO MẪU %.1f/10,0 GIÂY • %d KHUNG AI",
                min(self.referenceVideoDuration, elapsed),
                frameCount
            )
            self.scanGuidanceText = frameCount > 0
                ? "Tiếp tục quay chủ thể từ từ quanh vòng tròn"
                : "Giữ đúng chủ thể trong vòng tròn để AI lấy khung video"
        }

        guard elapsed >= referenceVideoDuration else { return }
        referenceVideoStartedAt = nil
        shapeScanCoverage = 1.0
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isCapturingReferenceVideo = false
            self.referenceVideoProgress = 1
            self.referenceVideoDisplayStartedAt = nil
            self.scanIsSufficient = true
            self.scanGuidanceText = "Đã ghép 7 ảnh + video 10 giây"
            self.statusText = "AI đã liên kết dữ liệu có sẵn, bộ ảnh và video \(self.scanSubjectKind.title.lowercased())"
            self.announce("Video mẫu hoàn tất. Mô hình nhận diện đã sẵn sàng.", kind: .success)
            self.onEvent?("REFERENCE_VIDEO_DONE")
        }
        finishScan(kind: kind)
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
            self.statusText = "Chọn đúng tab rồi tạo mẫu; camera góc rộng giúp tránh hụt mục tiêu"
            if self.pendingArm {
                self.pendingArm = false
                self.statusText = "Đã nhận ARM nhưng cần tạo mẫu \(self.scanSubjectKind.title.lowercased()) trước"
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

    private func encodeFeaturePrint(_ observation: VNFeaturePrintObservation) -> Data? {
        try? NSKeyedArchiver.archivedData(
            withRootObject: observation,
            requiringSecureCoding: true
        )
    }

    private func decodeFeaturePrint(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: VNFeaturePrintObservation.self,
            from: data
        )
    }

    private func decodeFeaturePrints(_ data: [Data]?) -> [VNFeaturePrintObservation]? {
        guard let data, !data.isEmpty else { return nil }
        let observations = data.compactMap(decodeFeaturePrint)
        return observations.count == data.count ? observations : nil
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

    private struct MultiViewMatch {
        let score: Float
        let bestDistance: Float
        let votes: Int
        let requiredVotes: Int
        let isAccepted: Bool

        /// Quy đổi khoảng cách FeaturePrint về 0...1 để toàn bộ pipeline dùng
        /// chung một thang phần trăm. Nhiều góc cùng bỏ phiếu được cộng nhẹ,
        /// nhưng không một ảnh đơn lẻ nào được phép tự quyết định kết quả.
        var similarity: Double {
            let distanceScore = max(0, min(1, 1 - Double(score / 100)))
            let bestScore = max(0, min(1, 1 - Double(bestDistance / 80)))
            let voteRatio = min(1, Double(votes) / Double(max(1, requiredVotes)))
            return max(0, min(1, distanceScore * 0.52 + bestScore * 0.28 + voteRatio * 0.20))
        }
    }

    private struct IdentityEvidenceMatch {
        let photo: MultiViewMatch
        let video: MultiViewMatch

        var score: Float { photo.score * 0.56 + video.score * 0.44 }
        var bestDistance: Float { max(photo.bestDistance, video.bestDistance) }
        var votes: Int { photo.votes + video.votes }
        var requiredVotes: Int { photo.requiredVotes + video.requiredVotes }
        var isAccepted: Bool {
            photo.isAccepted
                && video.isAccepted
                && photo.bestDistance <= 34
                && video.bestDistance <= 36
        }

        var similarity: Double {
            let combined = photo.similarity * 0.56 + video.similarity * 0.44
            // Tuyệt đối không cho một nguồn đơn lẻ vượt cổng bắt lại 75%.
            return isAccepted ? combined : min(0.74, combined)
        }
    }

    private func multiViewMatch(to candidate: VNFeaturePrintObservation) -> MultiViewMatch? {
        multiViewMatch(to: candidate, among: featureSamples)
    }

    private func multiViewMatch(
        to candidate: VNFeaturePrintObservation,
        among samples: [VNFeaturePrintObservation],
        requiredVotesOverride: Int? = nil
    ) -> MultiViewMatch? {
        var distances: [Float] = []
        for sample in samples {
            var distance: Float = 0
            if (try? candidate.computeDistance(&distance, to: sample)) != nil {
                distances.append(distance)
            }
        }
        return multiViewMatch(
            from: distances,
            requiredVotesOverride: requiredVotesOverride
        )
    }

    private func multiViewMatch(
        to candidate: VNFeaturePrintObservation,
        among groups: [[VNFeaturePrintObservation]],
        requiredVotesOverride: Int? = nil
    ) -> MultiViewMatch? {
        let distances = groups.compactMap { group -> Float? in
            var best: Float?
            for sample in group {
                var distance: Float = 0
                guard (try? candidate.computeDistance(&distance, to: sample)) != nil else {
                    continue
                }
                best = min(best ?? distance, distance)
            }
            return best
        }
        return multiViewMatch(
            from: distances,
            requiredVotesOverride: requiredVotesOverride
        )
    }

    private func multiViewMatch(
        from unsortedDistances: [Float],
        requiredVotesOverride: Int? = nil
    ) -> MultiViewMatch? {
        let distances = unsortedDistances.sorted()
        guard let best = distances.first else { return nil }
        let automaticRequiredVotes: Int
        if distances.count >= 9 {
            automaticRequiredVotes = 4
        } else if distances.count >= 5 {
            automaticRequiredVotes = 3
        } else if distances.count >= 3 {
            automaticRequiredVotes = 2
        } else {
            automaticRequiredVotes = 1
        }
        let requiredVotes = min(
            distances.count,
            max(1, requiredVotesOverride ?? automaticRequiredVotes)
        )
        let voteThreshold: Float = 44
        let votes = distances.filter { $0 <= voteThreshold }.count
        let selected = distances.prefix(min(requiredVotes, distances.count))
        let robustScore = selected.reduce(0, +) / Float(selected.count)
        // Không cho một ảnh trắng duy nhất quyết định. Mẫu phải nhận đủ phiếu
        // từ nhiều góc độc lập, đồng thời góc gần nhất cũng phải thật sự giống.
        let accepted = best <= 34
            && votes >= requiredVotes
            && robustScore <= 40
        return MultiViewMatch(
            score: robustScore,
            bestDistance: best,
            votes: votes,
            requiredVotes: requiredVotes,
            isAccepted: accepted
        )
    }

    private func temporalGroups(
        from samples: [VNFeaturePrintObservation],
        desiredGroupCount: Int = 6
    ) -> [[VNFeaturePrintObservation]] {
        guard !samples.isEmpty else { return [] }
        let groupCount = min(desiredGroupCount, max(1, samples.count))
        return (0..<groupCount).compactMap { groupIndex in
            let start = groupIndex * samples.count / groupCount
            let end = (groupIndex + 1) * samples.count / groupCount
            guard start < end else { return nil }
            return Array(samples[start..<end])
        }
    }

    private func identityEvidenceMatch(
        to candidate: VNFeaturePrintObservation,
        useContextSamples: Bool = false
    ) -> IdentityEvidenceMatch? {
        let photos = useContextSamples && !photoContextFeatureSamples.isEmpty
            ? photoContextFeatureSamples
            : photoFeatureSamples
        let videos = useContextSamples && !videoContextFeatureSamples.isEmpty
            ? videoContextFeatureSamples
            : videoFeatureSamples
        guard photos.count >= 3,
              videos.count >= 3,
              let photoMatch = multiViewMatch(
                to: candidate,
                among: photos,
                requiredVotesOverride: 2
              ),
              let videoMatch = multiViewMatch(
                to: candidate,
                among: temporalGroups(from: videos),
                requiredVotesOverride: 2
              ) else { return nil }
        return IdentityEvidenceMatch(photo: photoMatch, video: videoMatch)
    }

    private func personalizedSimilarity(
        in pixelBuffer: CVPixelBuffer,
        rect: CGRect
    ) -> Double? {
        let frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        let fullCrop = rect
            .insetBy(
                dx: -max(0.01, rect.width * 0.06),
                dy: -max(0.01, rect.height * 0.05)
            )
            .intersection(frame)
        var crops = [fullCrop]

        // Sau khi dù bung, hộp ứng viên có thể chứa một tán dù rộng phía trên và thân
        // tên lửa nhỏ phía dưới. Không so cả tán dù với mẫu trước phóng; thử tách phần
        // thân ở nửa dưới rồi vẫn bắt buộc thân đó vượt đồng thuận ảnh + video đã học.
        let isDescendingDuringRecovery = (recoverySeedEstimate?.velocity.dy ?? 0) > 0.00045
        if scanSubjectKind == .waterRocket,
           parachuteDetected || isDescendingDuringRecovery {
            crops.append(CGRect(
                x: rect.minX + rect.width * 0.18,
                y: rect.minY + rect.height * 0.36,
                width: rect.width * 0.64,
                height: rect.height * 0.64
            ).intersection(frame))
            crops.append(CGRect(
                x: rect.minX + rect.width * 0.28,
                y: rect.minY + rect.height * 0.52,
                width: rect.width * 0.44,
                height: rect.height * 0.48
            ).intersection(frame))
        }

        return crops.compactMap { crop -> Double? in
            guard crop.width > 0.01,
                  crop.height > 0.01,
                  let feature = featurePrint(
                    from: pixelBuffer,
                    normalizedTopLeftRect: crop
                  ), let match = identityEvidenceMatch(
                    to: feature,
                    useContextSamples: !contextFeatureSamples.isEmpty
                  ) else { return nil }
            return match.similarity
        }.max()
    }

    private func categoryConfidence(
        for rect: CGRect,
        in pixelBuffer: CVPixelBuffer
    ) -> Double? {
        func topLeft(_ visionRect: CGRect) -> CGRect {
            CGRect(
                x: visionRect.minX,
                y: 1 - visionRect.maxY,
                width: visionRect.width,
                height: visionRect.height
            )
        }
        func matches(_ candidate: CGRect) -> Bool {
            let distance = hypot(candidate.midX - rect.midX, candidate.midY - rect.midY)
            return intersectionOverUnion(candidate, rect) >= 0.08
                || distance <= max(0.12, max(rect.width, rect.height) * 0.8)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        switch scanSubjectKind {
        case .waterRocket:
            let detections = detectRocketOrBottle(
                in: pixelBuffer,
                minimumConfidence: 0.05
            )
            return detections
                .filter { matches($0.rect) }
                .map(\.confidence)
                .max()

        case .person:
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = false
            try? handler.perform([request])
            return request.results?
                .filter { matches(topLeft($0.boundingBox)) }
                .map { Double($0.confidence) }
                .max()

        case .animal:
            let request = VNRecognizeAnimalsRequest()
            try? handler.perform([request])
            return request.results?
                .filter { matches(topLeft($0.boundingBox)) }
                .map { Double($0.confidence) }
                .max()

        case .object:
            // Vật cá nhân được bộ ảnh/video quyết định. Chặn hộp người lớn phủ
            // gần hết ứng viên để tránh khóa nhầm cơ thể khi vật đang được cầm.
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = false
            try? handler.perform([request])
            let humanOverlap = request.results?
                .map { intersectionOverUnion(topLeft($0.boundingBox), rect) }
                .max() ?? 0
            return humanOverlap >= 0.72 ? nil : 1
        }
    }

    private var usesRocketSpecificDetector: Bool {
        scanSubjectKind == .waterRocket
    }

    private struct ForegroundCandidate {
        let rect: CGRect
        let feature: VNFeaturePrintObservation?
        let trianglePoints: [CGPoint]
    }

    private func foregroundCandidates(
        from pixelBuffer: CVPixelBuffer,
        includeFeaturePrints: Bool = true
    ) -> [ForegroundCandidate] {
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
                var cells = Set<Int>()
                for visualRow in 0..<selectionGridRows {
                    let maskRow = selectionGridRows - 1 - visualRow
                    for column in 0..<selectionGridColumns
                    where bitmap[maskRow * selectionGridColumns + column] > 48 {
                        cells.insert(visualRow * selectionGridColumns + column)
                        minColumn = min(minColumn, column)
                        maxColumn = max(maxColumn, column)
                        minRow = min(minRow, visualRow)
                        maxRow = max(maxRow, visualRow)
                    }
                }
                guard cells.count >= 24, minColumn <= maxColumn, minRow <= maxRow else {
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
                var feature: VNFeaturePrintObservation?
                if includeFeaturePrints {
                    let maskedBuffer = try observation.generateMaskedImage(
                        ofInstances: instances,
                        from: handler,
                        croppedToInstancesExtent: true
                    )
                    feature = featurePrint(
                        from: maskedBuffer,
                        normalizedTopLeftRect: CGRect(x: 0, y: 0, width: 1, height: 1)
                    )
                    guard feature != nil else { continue }
                }
                candidates.append(ForegroundCandidate(
                    rect: rect,
                    feature: feature,
                    trianglePoints: trianglePoints(from: cells)
                ))
            }
            return candidates
        } catch {
            return []
        }
    }

    /// Ảnh phản chiếu trên bảng/màn hình thường có hộp YOLO nhưng không tạo ra
    /// một khối tiền cảnh có kích thước tương ứng. Tên lửa rất nhỏ được miễn
    /// cổng này vì Vision không thể tách ổn định vật chỉ vài pixel trên trời.
    private func hasIndependentForegroundSupport(
        for rect: CGRect,
        in pixelBuffer: CVPixelBuffer,
        candidates precomputedCandidates: [ForegroundCandidate]? = nil
    ) -> Bool {
        let area = rect.width * rect.height
        if area < 0.0035 { return true }
        let candidates = precomputedCandidates ?? foregroundCandidates(
            from: pixelBuffer,
            includeFeaturePrints: false
        )
        return candidates.contains { candidate in
            let overlap = intersectionOverUnion(candidate.rect, rect)
            let distance = hypot(
                candidate.rect.midX - rect.midX,
                candidate.rect.midY - rect.midY
            )
            let candidateArea = max(0.00001, candidate.rect.width * candidate.rect.height)
            let targetArea = max(0.00001, area)
            let areaRatio = max(candidateArea, targetArea) / min(candidateArea, targetArea)
            let candidateAspect = candidate.rect.width / max(0.0001, candidate.rect.height)
            let targetAspect = rect.width / max(0.0001, rect.height)
            let aspectRatio = max(candidateAspect, targetAspect)
                / max(0.0001, min(candidateAspect, targetAspect))
            return (overlap >= 0.10 || distance <= max(0.06, max(rect.width, rect.height) * 0.55))
                && areaRatio <= 3.0
                && aspectRatio <= 2.3
        }
    }

    private func topLeftRect(from observation: VNDetectedObjectObservation) -> CGRect {
        CGRect(
            x: observation.boundingBox.minX,
            y: 1.0 - observation.boundingBox.maxY,
            width: observation.boundingBox.width,
            height: observation.boundingBox.height
        )
    }

    private func observation(fromTopLeftRect rect: CGRect) -> VNDetectedObjectObservation {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return VNDetectedObjectObservation(boundingBox: CGRect(
            x: clipped.minX,
            y: 1.0 - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        ))
    }

    private func trackingAnchorRects(in rect: CGRect) -> [CGRect] {
        let centers: [CGPoint]
        if rect.height > rect.width * 1.18 {
            centers = [
                CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.20),
                CGPoint(x: rect.midX, y: rect.midY),
                CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.80)
            ]
        } else if rect.width > rect.height * 1.18 {
            centers = [
                CGPoint(x: rect.minX + rect.width * 0.20, y: rect.midY),
                CGPoint(x: rect.midX, y: rect.midY),
                CGPoint(x: rect.minX + rect.width * 0.80, y: rect.midY)
            ]
        } else {
            centers = [
                CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.25),
                CGPoint(x: rect.minX + rect.width * 0.30, y: rect.minY + rect.height * 0.72),
                CGPoint(x: rect.minX + rect.width * 0.70, y: rect.minY + rect.height * 0.72)
            ]
        }

        let anchorWidth = max(0.035, min(0.15, rect.width * 0.58))
        let anchorHeight = max(0.035, min(0.15, rect.height * 0.24))
        return centers.map { center in
            CGRect(
                x: center.x - anchorWidth / 2,
                y: center.y - anchorHeight / 2,
                width: anchorWidth,
                height: anchorHeight
            ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    private func makeTrackingAnchors(in rect: CGRect) -> [VNDetectedObjectObservation] {
        trackingAnchorRects(in: rect).map { observation(fromTopLeftRect: $0) }
    }

    private func representativeTrackingPoints(in rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.10),
            CGPoint(x: rect.minX + rect.width * 0.12, y: rect.maxY - rect.height * 0.10),
            CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.maxY - rect.height * 0.10)
        ]
    }

    private func transformedTriangle(
        _ points: [CGPoint],
        from oldRect: CGRect,
        to newRect: CGRect
    ) -> [CGPoint] {
        guard points.count == 3, oldRect.width > 0.001, oldRect.height > 0.001 else {
            return representativeTrackingPoints(in: newRect)
        }
        return points.map { point in
            let relativeX = (point.x - oldRect.minX) / oldRect.width
            let relativeY = (point.y - oldRect.minY) / oldRect.height
            return CGPoint(
                x: newRect.minX + relativeX * newRect.width,
                y: newRect.minY + relativeY * newRect.height
            )
        }
    }

    private func alignedTriangle(_ points: [CGPoint], to reference: [CGPoint]) -> [CGPoint] {
        guard points.count == 3, reference.count == 3 else { return points }
        let permutations = [
            [0, 1, 2], [0, 2, 1], [1, 0, 2],
            [1, 2, 0], [2, 0, 1], [2, 1, 0]
        ]
        var best = points
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for order in permutations {
            let arranged = order.map { points[$0] }
            var distance: CGFloat = 0
            for index in 0..<3 {
                let dx = arranged[index].x - reference[index].x
                let dy = arranged[index].y - reference[index].y
                distance += dx * dx + dy * dy
            }
            if distance < bestDistance {
                bestDistance = distance
                best = arranged
            }
        }
        return best
    }

    private func smoothedTriangle(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count == 3 else { return trackingTrianglePoints }
        guard trackingTrianglePoints.count == 3 else {
            trackingTrianglePoints = points
            return points
        }
        let aligned = alignedTriangle(points, to: trackingTrianglePoints)
        var displacement: CGFloat = 0
        for index in 0..<3 {
            displacement += hypot(
                aligned[index].x - trackingTrianglePoints[index].x,
                aligned[index].y - trackingTrianglePoints[index].y
            )
        }
        let alpha: CGFloat = displacement / 3 > 0.025 ? 0.82 : 0.52
        let filtered = (0..<3).map { index in
            CGPoint(
                x: trackingTrianglePoints[index].x * (1 - alpha) + aligned[index].x * alpha,
                y: trackingTrianglePoints[index].y * (1 - alpha) + aligned[index].y * alpha
            )
        }
        trackingTrianglePoints = filtered
        return filtered
    }

    private func bestForegroundCandidate(
        near bounds: CGRect,
        in pixelBuffer: CVPixelBuffer
    ) -> ForegroundCandidate? {
        var best: ForegroundCandidate?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for candidate in foregroundCandidates(
            from: pixelBuffer,
            includeFeaturePrints: false
        ) {
            let centerDistance = hypot(
                candidate.rect.midX - bounds.midX,
                candidate.rect.midY - bounds.midY
            )
            let intersection = candidate.rect.intersection(bounds)
            let intersectionArea = intersection.isNull
                ? 0
                : intersection.width * intersection.height
            let unionArea = candidate.rect.width * candidate.rect.height
                + bounds.width * bounds.height - intersectionArea
            let overlap = unionArea > 0 ? intersectionArea / unionArea : 0
            let areaRatio = max(
                candidate.rect.width * candidate.rect.height,
                bounds.width * bounds.height
            ) / max(
                0.0001,
                min(
                    candidate.rect.width * candidate.rect.height,
                    bounds.width * bounds.height
                )
            )
            let allowedDistance = max(0.10, max(bounds.width, bounds.height) * 0.9)
            guard overlap > 0.015 || centerDistance <= allowedDistance else { continue }
            let score = centerDistance * 2.8 + min(areaRatio, 5) * 0.08 - overlap * 0.7
            if score < bestScore {
                bestScore = score
                best = candidate
            }
        }
        return best
    }

    private func bestIdentityCandidate(
        near bounds: CGRect,
        in pixelBuffer: CVPixelBuffer
    ) -> ForegroundCandidate? {
        var best: ForegroundCandidate?
        var bestScore = Float.greatestFiniteMagnitude
        for candidate in foregroundCandidates(from: pixelBuffer) {
            guard let feature = candidate.feature,
                  let match = identityEvidenceMatch(to: feature),
                  match.isAccepted else { continue }
            let centerDistance = hypot(
                candidate.rect.midX - bounds.midX,
                candidate.rect.midY - bounds.midY
            )
            let allowedDistance = max(0.14, max(bounds.width, bounds.height) * 1.25)
            guard centerDistance <= allowedDistance else { continue }
            let score = match.score + Float(centerDistance * 24)
            if score < bestScore {
                bestScore = score
                best = candidate
            }
        }
        return best
    }

    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }

    private func isSameCandidate(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let centerDistance = hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
        let allowedDistance = max(
            0.075,
            max(max(lhs.width, lhs.height), max(rhs.width, rhs.height)) * 1.35
        )
        return intersectionOverUnion(lhs, rhs) >= 0.08 || centerDistance <= allowedDistance
    }

    /// Không cho một frame AI đơn lẻ đổi mục tiêu. Mục tiêu mới hoặc mục tiêu
    /// ở xa dự đoán phải xuất hiện ổn định ở nhiều lần detector liên tiếp.
    private func confirmsAIDetection(_ rect: CGRect, requiredCount: Int) -> Bool {
        if let pending = pendingAIDetectionRect, isSameCandidate(pending, rect) {
            pendingAIDetectionCount += 1
            let blend: CGFloat = 0.62
            pendingAIDetectionRect = CGRect(
                x: pending.minX * (1 - blend) + rect.minX * blend,
                y: pending.minY * (1 - blend) + rect.minY * blend,
                width: pending.width * (1 - blend) + rect.width * blend,
                height: pending.height * (1 - blend) + rect.height * blend
            )
        } else {
            pendingAIDetectionRect = rect
            pendingAIDetectionCount = 1
        }
        return pendingAIDetectionCount >= requiredCount
    }

    private func clearPendingAIDetection() {
        pendingAIDetectionRect = nil
        pendingAIDetectionCount = 0
    }

    private func clearRecoveryState() {
        recoverySeedEstimate = nil
        recoveryStartedAt = 0
        isRecoveringLostTarget = false
        recoverySearchCommand = "SEARCH_START"
        lastSearchCommandSentAt = 0
    }

    private func trajectorySearchCommand(
        for estimate: RocketMotionEstimate?
    ) -> String {
        guard let estimate else { return "SEARCH_START" }
        let speed = hypot(estimate.velocity.dx, estimate.velocity.dy)
        guard speed >= 0.015 else { return "SEARCH_START" }
        let x = Int(max(0, min(999, estimate.predictedPoint.x * 999)).rounded())
        let y = Int(max(0, min(999, estimate.predictedPoint.y * 999)).rounded())
        let velocityScale: CGFloat = 99.0 / 3.0
        let vx = Int(max(-99, min(99, estimate.velocity.dx * velocityScale)).rounded())
        let vy = Int(max(-99, min(99, estimate.velocity.dy * velocityScale)).rounded())
        return String(format: "S,%03d,%03d,%+03d,%+03d", x, y, vx, vy)
    }

    /// Dùng đúng hướng ảnh mà firmware nhận trong gói S,x,y,vx,vy. Khi vận tốc cuối
    /// quá nhỏ, firmware dùng độ lệch của mục tiêu khỏi tâm nên giao diện cũng làm vậy.
    private func trajectoryScreenVector(
        for estimate: RocketMotionEstimate?
    ) -> CGPoint? {
        guard let estimate else { return nil }
        var dx = estimate.velocity.dx
        var dy = estimate.velocity.dy
        var magnitude = hypot(dx, dy)
        if magnitude < 0.015 {
            dx = estimate.predictedPoint.x - 0.5
            dy = estimate.predictedPoint.y - 0.5
            magnitude = hypot(dx, dy)
        }
        guard magnitude >= 0.002 else { return nil }
        return CGPoint(x: dx / magnitude, y: dy / magnitude)
    }

    private func sendSearchHeartbeatIfNeeded() {
        guard isRecoveringLostTarget, !isStopRequested else { return }
        let now = CACurrentMediaTime()
        guard now - lastSearchCommandSentAt >= 0.35 else { return }
        lastSearchCommandSentAt = now
        let command = recoverySearchCommand
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopRequested else { return }
            self.onEvent?(command)
        }
    }

    private func recoveryExpectedRect(at timestamp: TimeInterval) -> CGRect? {
        guard isRecoveringLostTarget, let seed = recoverySeedEstimate else { return nil }
        // Chỉ ưu tiên quỹ đạo cũ trong 0,3 giây đầu. Sau đó trả nil để detector quét toàn
        // màn hình: mục tiêu có thể quay lại ở bất kỳ vị trí nào vì servo đã chuyển góc.
        let recoveryAge = CGFloat(max(0, min(4.0, timestamp - recoveryStartedAt)))
        guard recoveryAge < 0.30 else { return nil }
        let elapsed = min(1.2, recoveryAge)
        let seedCenter = CGPoint(
            x: seed.filteredRect.midX,
            y: seed.filteredRect.midY
        )
        let ballisticCenter = CGPoint(
            x: max(0.015, min(0.985, seedCenter.x + seed.velocity.dx * elapsed)),
            y: max(0.015, min(0.985, seedCenter.y + seed.velocity.dy * elapsed))
        )
        let predictedCenter = ballisticCenter
        let uncertainty = min(2.2, 1.0 + elapsed * 0.9)
        let width = max(0.008, min(0.20, seed.filteredRect.width * uncertainty))
        let height = max(0.008, min(0.20, seed.filteredRect.height * uncertainty))
        return CGRect(
            x: predictedCenter.x - width / 2,
            y: predictedCenter.y - height / 2,
            width: width,
            height: height
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func searchROI(around expectedRect: CGRect) -> CGRect {
        let elapsed = isRecoveringLostTarget
            ? CGFloat(max(0, min(2.0, CACurrentMediaTime() - recoveryStartedAt)))
            : 0
        let side = min(
            0.58,
            max(
                0.28 + elapsed * 0.08,
                max(expectedRect.width, expectedRect.height) * 9.0
            )
        )
        let center = CGPoint(x: expectedRect.midX, y: expectedRect.midY)
        var originX = center.x - side / 2
        var originY = center.y - side / 2
        originX = max(0, min(1 - side, originX))
        originY = max(0, min(1 - side, originY))
        return CGRect(x: originX, y: originY, width: side, height: side)
    }

    private func bestIdentityAlignedDetection(
        among detections: [WaterRocketDetection],
        in pixelBuffer: CVPixelBuffer
    ) -> WaterRocketDetection? {
        guard !featureSamples.isEmpty else { return detections.first }
        guard !detections.isEmpty else {
            identityGateStatus = "AI chưa thấy hộp tên lửa đủ rõ"
            return nil
        }

        let candidates = foregroundCandidates(from: pixelBuffer)
        var best: WaterRocketDetection?
        var bestScore = Float.greatestFiniteMagnitude
        for candidate in candidates {
            guard let feature = candidate.feature,
                  let match = identityEvidenceMatch(to: feature),
                  match.isAccepted else { continue }
            for detection in detections.prefix(5) {
                let centerDistance = hypot(
                    candidate.rect.midX - detection.rect.midX,
                    candidate.rect.midY - detection.rect.midY
                )
                let overlap = intersectionOverUnion(candidate.rect, detection.rect)
                let allowedDistance = max(
                    0.10,
                    max(candidate.rect.width, candidate.rect.height) * 0.65
                )
                guard overlap >= 0.035 || centerDistance <= allowedDistance else { continue }
                let candidateArea = max(
                    0.00001,
                    candidate.rect.width * candidate.rect.height
                )
                let detectionArea = max(
                    0.00001,
                    detection.rect.width * detection.rect.height
                )
                let areaRatio = max(candidateArea, detectionArea)
                    / min(candidateArea, detectionArea)
                let candidateAspect = candidate.rect.width
                    / max(0.0001, candidate.rect.height)
                let detectionAspect = detection.rect.width
                    / max(0.0001, detection.rect.height)
                let aspectRatio = max(candidateAspect, detectionAspect)
                    / max(0.0001, min(candidateAspect, detectionAspect))
                guard areaRatio <= 4.0, aspectRatio <= 3.0 else { continue }
                let score = match.score
                    + Float(centerDistance * 34)
                    + Float(min(areaRatio - 1, 3) * 1.8)
                    + Float(min(aspectRatio - 1, 2) * 1.6)
                    - Float(detection.confidence * 8)
                if score < bestScore {
                    bestScore = score
                    best = detection
                }
            }
        }

        // Vision thường không tách được chai PET trong suốt. Khi đó vẫn đối chiếu
        // trực tiếp vùng YOLO, nhưng giữ ngưỡng đa góc chặt hơn để không biến nó
        // thành đường tắt chỉ dựa trên độ tin cậy của detector.
        if best == nil {
            for detection in detections.prefix(5) {
                let paddingX = max(0.012, detection.rect.width * 0.08)
                let paddingY = max(0.012, detection.rect.height * 0.06)
                let crop = detection.rect
                    .insetBy(dx: -paddingX, dy: -paddingY)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard let feature = featurePrint(
                    from: pixelBuffer,
                    normalizedTopLeftRect: crop
                ),
                let match = identityEvidenceMatch(
                    to: feature,
                    useContextSamples: !contextFeatureSamples.isEmpty
                ),
                match.isAccepted,
                match.bestDistance <= 31,
                match.votes >= match.requiredVotes else { continue }
                let score = match.score + 3.5 - Float(detection.confidence * 6)
                if score < bestScore {
                    bestScore = score
                    best = detection
                }
            }
        }

        identityGateStatus = best == nil
            ? "AI thấy vật nhưng chưa khớp đa số ảnh mẫu"
            : ""
        return best
    }

    private func detectRocketOrBottle(
        in pixelBuffer: CVPixelBuffer,
        minimumConfidence: Double,
        regionOfInterest: CGRect? = nil
    ) -> [WaterRocketDetection] {
        var detections = aiDetector.detect(
            in: pixelBuffer,
            minimumConfidence: minimumConfidence,
            regionOfInterest: regionOfInterest
        )
        // Chỉ gọi model chai khi model chuyên tên lửa hụt để không chạy hai
        // mạng 640×640 ở mọi frame lúc tên lửa đang bay nhanh.
        if detections.isEmpty, bottleDetector.isAvailable {
            detections.append(contentsOf: bottleDetector.detect(
                in: pixelBuffer,
                minimumConfidence: max(0.10, minimumConfidence * 0.72),
                regionOfInterest: regionOfInterest
            ))
        }

        // Hai model có thể cùng khoanh một chai. Giữ hộp tin cậy nhất để bộ
        // xác nhận nhiều frame không đếm trùng một vật hai lần.
        var merged: [WaterRocketDetection] = []
        for detection in detections.sorted(by: { $0.confidence > $1.confidence }) {
            if let index = merged.firstIndex(where: {
                intersectionOverUnion($0.rect, detection.rect) >= 0.62
            }) {
                if detection.confidence > merged[index].confidence {
                    merged[index] = detection
                }
            } else {
                merged.append(detection)
            }
        }
        return merged.sorted { $0.confidence > $1.confidence }
    }

    private func bestAIDetection(
        in pixelBuffer: CVPixelBuffer,
        near expectedRect: CGRect?
    ) -> WaterRocketDetection? {
        let expectedArea = expectedRect.map { $0.width * $0.height } ?? 1
        let isTinyContinuation = expectedRect != nil && expectedArea < 0.0035
        // Một tên lửa xa chỉ vài pixel thường có độ tin cậy thấp. Chỉ hạ ngưỡng
        // khi đã có quỹ đạo dự đoán; tìm mới toàn màn hình vẫn giữ ngưỡng cao để
        // cây và cờ không thể tự biến thành mục tiêu.
        let rocketAcquisitionConfidence = scanSubjectKind == .waterRocket
            ? 0.24
            : aiAcquisitionConfidence
        let minimumConfidence = expectedRect == nil
            ? (isRecoveringLostTarget ? aiReacquisitionConfidence : rocketAcquisitionConfidence)
            : (isTinyContinuation ? 0.05 : aiContinuationConfidence)
        let detections: [WaterRocketDetection]
        if let expectedRect, isTinyContinuation || isRecoveringLostTarget {
            let roi = searchROI(around: expectedRect)
            // Nhánh toàn khung giữ được dù/parachute lớn. Nếu nhánh này hụt mục tiêu
            // gần quỹ đạo, nhánh ROI mới phóng to vùng 3–6 px để cứu frame đó.
            let global = detectRocketOrBottle(
                in: pixelBuffer,
                minimumConfidence: isTinyContinuation ? 0.07 : minimumConfidence
            )
            let hasGlobalNearTrajectory = global.contains { detection in
                let center = CGPoint(x: detection.rect.midX, y: detection.rect.midY)
                return roi.contains(center)
                    && hypot(
                        center.x - expectedRect.midX,
                        center.y - expectedRect.midY
                    ) <= max(0.13, max(expectedRect.width, expectedRect.height) * 3.5)
            }
            if hasGlobalNearTrajectory {
                detections = global
            } else {
                let focused = detectRocketOrBottle(
                    in: pixelBuffer,
                    minimumConfidence: minimumConfidence,
                    regionOfInterest: roi
                )
                detections = focused + global
            }
        } else {
            detections = detectRocketOrBottle(
                in: pixelBuffer,
                minimumConfidence: minimumConfidence
            )
        }
        guard let expectedRect else {
            // Most false positives from the held-out launch videos enter from a
            // single image edge.  A real scan target may be larger than the old
            // guide circle, but its centre must still be on-screen.
            let onScreen = detections.filter { detection in
                let centre = CGPoint(x: detection.rect.midX, y: detection.rect.midY)
                return (0.055...0.945).contains(centre.x)
                    && (0.045...0.955).contains(centre.y)
            }
            if isRecoveringLostTarget {
                // Khi đã mất mục tiêu, điểm khớp bộ ảnh/video cá nhân là cổng quyết
                // định. Đạt 75% sẽ trả ứng viên ngay trong frame hiện tại.
                let verified = onScreen.compactMap { detection -> (WaterRocketDetection, Double)? in
                    let similarity = personalizedSimilarity(
                        in: pixelBuffer,
                        rect: detection.rect
                    ) ?? 0
                    guard similarity >= immediateReacquisitionSimilarity else { return nil }
                    return (detection, similarity * 0.72 + detection.confidence * 0.28)
                }
                return verified.max { $0.1 < $1.1 }?.0
            }
            return bestIdentityAlignedDetection(
                among: onScreen,
                in: pixelBuffer
            )
        }

        var best: WaterRocketDetection?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for detection in detections {
            let centerDistance = hypot(
                detection.rect.midX - expectedRect.midX,
                detection.rect.midY - expectedRect.midY
            )
            let overlap = intersectionOverUnion(detection.rect, expectedRect)
            let detectedArea = max(0.00001, detection.rect.width * detection.rect.height)
            let expectedArea = max(0.00001, expectedRect.width * expectedRect.height)
            let areaRatio = max(detectedArea, expectedArea) / min(detectedArea, expectedArea)
            let recoveryAllowance: CGFloat = isRecoveringLostTarget
                ? min(
                    0.28,
                    0.13 + CGFloat(CACurrentMediaTime() - recoveryStartedAt) * 0.055
                )
                : 0
            let allowedDistance = max(
                isTinyContinuation ? max(0.105, recoveryAllowance) : max(0.22, recoveryAllowance),
                max(expectedRect.width, expectedRect.height) * 3.2
            )
            guard centerDistance <= allowedDistance || overlap > 0 else { continue }

            let score = centerDistance * 3.0
                + min(areaRatio, 8) * 0.035
                - overlap * 0.85
                - CGFloat(detection.confidence) * 0.34
            if score < bestScore {
                bestScore = score
                best = detection
            }
        }
        return best
    }

    private func lockTarget(
        rect: CGRect,
        trianglePoints: [CGPoint],
        confidence: Double,
        matchDescription: String,
        statusDescription: String
    ) {
        let clippedRect = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        processingRect = clippedRect
        trackingObservation = observation(fromTopLeftRect: clippedRect)
        trackingAnchorObservations.removeAll()
        trackingTrianglePoints = trianglePoints.count == 3
            ? trianglePoints
            : representativeTrackingPoints(in: clippedRect)
        lastTrackingBounds = clippedRect
        segmentationMissFrames = 0
        aiDetectionMisses = 0
        identityGateStatus = ""
        freshScanSeedRect = nil
        freshScanSeedTimestamp = 0
        pendingFreshScanSeedRect = nil
        clearPendingAIDetection()
        sequenceHandler = VNSequenceRequestHandler()
        trackingFrameCounter = 0
        lowConfidenceFrames = 0
        previousTrackingCenter = CGPoint(x: clippedRect.midX, y: clippedRect.midY)
        smoothedTrackingVelocity = .zero
        motionFilter.reset(rect: clippedRect, timestamp: CACurrentMediaTime())
        parachuteDetected = false
        clearRecoveryState()
        processingMode = .tracking

        let shouldStartRecording = shouldRecordAfterVerification
        let initialPoints = trackingTrianglePoints
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.isStopRequested else { return }
            // Ưu tiên dừng searchMode trên ESP32 trước mọi cập nhật giao diện.
            self.onEvent?("TARGET_LOCKED")
            self.servoSearchVector = nil
            self.servoSearchAnchor = nil
            self.isServoTrajectorySearching = false
            self.stage = .tracking
            self.targetRect = clippedRect
            self.trackingPoints = initialPoints
            self.predictedTargetPoint = CGPoint(x: clippedRect.midX, y: clippedRect.midY)
            self.trackingConfidence = confidence
            self.matchText = matchDescription
            self.statusText = statusDescription
            if shouldStartRecording {
                self.beginRecording()
            } else if self.isRecording {
                self.scheduleZoomSequence(after: 0.5)
            }
        }
    }

    /// Trả về `true` khi app đã có model Core ML và frame này đã được xử lý.
    /// Khi đó không chạy bộ so ảnh cũ song song để tránh hai thuật toán giành mục tiêu.
    @discardableResult
    private func verifyWithAIDetector(pixelBuffer: CVPixelBuffer) -> Bool {
        guard aiDetector.isAvailable else { return false }
        let expectedRect = recoveryExpectedRect(at: CACurrentMediaTime())
        guard let detection = bestAIDetection(
            in: pixelBuffer,
            near: expectedRect
        ) else {
            pendingAIDetectionCount = max(0, pendingAIDetectionCount - 1)
            let message = isRecoveringLostTarget
                ? (expectedRect == nil
                    ? "AI đang quét nhanh toàn màn hình để bắt lại mục tiêu..."
                    : "AI đang kiểm tra quỹ đạo cũ để bắt lại mục tiêu...")
                : (identityGateStatus.isEmpty
                    ? "AI đang tìm ứng viên trên toàn màn hình..."
                    : identityGateStatus)
            publishSearchProgress(message: message)
            return true
        }

        let isGenericBottle = detection.label.lowercased().contains("bottle")
        let personalSimilarity = personalizedSimilarity(
            in: pixelBuffer,
            rect: detection.rect
        ) ?? 0
        // Khi bắt lại, mọi nhãn (kể cả tên lửa chuyên dụng) đều phải giống bộ
        // ảnh/video cá nhân. Không cho ảnh phản chiếu đi đường tắt bằng điểm YOLO.
        let reacquisitionSimilarity = personalSimilarity
        if isRecoveringLostTarget {
            guard reacquisitionSimilarity >= immediateReacquisitionSimilarity else {
                publishSearchProgress(
                    message: "Đang tìm • khớp \(Int(reacquisitionSimilarity * 100))% / cần 75%"
                )
                return true
            }
            lockTarget(
                rect: detection.rect,
                trianglePoints: representativeTrackingPoints(in: detection.rect),
                confidence: reacquisitionSimilarity,
                matchDescription: "BẮT LẠI NGAY • KHỚP \(Int(reacquisitionSimilarity * 100))%",
                statusDescription: "Đã đạt 75% — bám lại ngay"
            )
            return true
        }

        // Model chuyên tên lửa đã được huấn luyện riêng nên khóa ngay ở frame đầu.
        // Model chai COCO rộng hơn phải lặp lại 2 frame để tránh bắt chai khác.
        let confirmationCount = isRecoveringLostTarget
            ? (isGenericBottle ? 2 : 1)
            : 4
        guard confirmsAIDetection(
            detection.rect,
            requiredCount: confirmationCount
        ) else {
            publishSearchProgress(
                message: "AI xác nhận mục tiêu \(pendingAIDetectionCount)/\(confirmationCount) • \(Int(detection.confidence * 100))%"
            )
            return true
        }

        let wasRecovery = isRecoveringLostTarget
        lockTarget(
            rect: pendingAIDetectionRect ?? detection.rect,
            trianglePoints: representativeTrackingPoints(in: detection.rect),
            confidence: detection.confidence,
            matchDescription: wasRecovery
                ? "AI • đã bắt lại mục tiêu • \(Int(detection.confidence * 100))%"
                : "AI \(scanSubjectKind.title.lowercased()) + 7 ảnh mẫu • đã xác nhận \(confirmationCount) frame • \(Int(detection.confidence * 100))%",
            statusDescription: wasRecovery
                ? "Đã bắt lại \(scanSubjectKind.title.lowercased()) — tiếp tục bám liên tục"
                : "AI đã khóa đúng \(scanSubjectKind.title.lowercased()) — đang bám và dự đoán quỹ đạo"
        )
        return true
    }

    private func directionLabel(for velocity: CGVector) -> String {
        let speed = hypot(velocity.dx, velocity.dy)
        guard speed >= 0.0007 else { return "ổn định" }
        let angle = atan2(-velocity.dy, velocity.dx) * 180 / .pi
        switch angle {
        case -22.5..<22.5: return "sang phải →"
        case 22.5..<67.5: return "chéo lên phải ↗"
        case 67.5..<112.5: return "bay lên ↑"
        case 112.5..<157.5: return "chéo lên trái ↖"
        case -67.5 ..< -22.5: return "chéo xuống phải ↘"
        case -112.5 ..< -67.5: return "đi xuống ↓"
        case -157.5 ..< -112.5: return "chéo xuống trái ↙"
        default: return "sang trái ←"
        }
    }

    /// Chuyển thẳng vùng vật ở ảnh mẫu thứ năm sang tracker. Đây là một khóa
    /// một lần, chỉ hợp lệ trong 15 giây, và vẫn kiểm tra feature của crop hiện
    /// tại để tránh khóa vào nền nếu người dùng đã đưa vật ra khỏi chỗ cũ.
    @discardableResult
    private func verifyFreshScanSeed(pixelBuffer: CVPixelBuffer) -> Bool {
        guard let seed = pendingFreshScanSeedRect else { return false }
        pendingFreshScanSeedRect = nil
        freshScanSeedRect = nil
        freshScanSeedTimestamp = 0

        let padded = seed
            .insetBy(
                dx: -max(0.01, seed.width * 0.04),
                dy: -max(0.01, seed.height * 0.035)
            )
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let currentFeature = featurePrint(
            from: pixelBuffer,
            normalizedTopLeftRect: padded
        ) else { return false }

        if !contextFeatureSamples.isEmpty {
            guard let match = identityEvidenceMatch(
                to: currentFeature,
                useContextSamples: true
            ), match.isAccepted else {
                identityGateStatus = "Vật đã rời vị trí chụp • đang tìm lại toàn màn hình"
                return false
            }
        }

        lockTarget(
            rect: seed,
            trianglePoints: representativeTrackingPoints(in: seed),
            confidence: 0.98,
            matchDescription: "7 ảnh → tracker • khóa trực tiếp vật vừa chụp",
            statusDescription: "Đã nhận đúng vật vừa tạo mẫu — bắt đầu bám liên tục"
        )
        return true
    }

    private func verifyAndLock(pixelBuffer: CVPixelBuffer) {
        guard case .verifying = processingMode else { return }
        guard !featureSamples.isEmpty else {
            return
        }
        var bestCandidate: ForegroundCandidate?
        var bestMatch: IdentityEvidenceMatch?
        var closestRejected: IdentityEvidenceMatch?
        for candidate in foregroundCandidates(from: pixelBuffer) {
            guard let feature = candidate.feature,
                  let match = identityEvidenceMatch(to: feature) else { continue }
            if closestRejected == nil || match.score < closestRejected!.score {
                closestRejected = match
            }
            guard match.isAccepted else { continue }
            if bestMatch == nil || match.score < bestMatch!.score {
                bestMatch = match
                bestCandidate = candidate
            }
        }

        // Nhánh cá nhân không phụ thuộc YOLO hay tách nền. Mỗi lần chỉ thử hai
        // cửa sổ để giữ 60 fps; sau vài frame sẽ phủ vùng giữa, trái và phải.
        // Các feature ở đây được so với crop thật của bảy ảnh người dùng.
        if bestCandidate == nil, !contextFeatureSamples.isEmpty {
            let searchWindows = [
                CGRect(x: 0.04, y: 0.02, width: 0.92, height: 0.96),
                CGRect(x: 0.12, y: 0.06, width: 0.76, height: 0.88),
                CGRect(x: 0.22, y: 0.10, width: 0.56, height: 0.80),
                CGRect(x: 0.30, y: 0.15, width: 0.40, height: 0.70),
                CGRect(x: 0.03, y: 0.10, width: 0.62, height: 0.82),
                CGRect(x: 0.35, y: 0.10, width: 0.62, height: 0.82)
            ]
            let stride = isRecoveringLostTarget ? 6 : 12
            let start = ((featureFrameCounter / stride) * 2) % searchWindows.count
            for offset in 0..<2 {
                let rect = searchWindows[(start + offset) % searchWindows.count]
                guard let feature = featurePrint(
                    from: pixelBuffer,
                    normalizedTopLeftRect: rect
                ), let match = identityEvidenceMatch(
                    to: feature,
                    useContextSamples: true
                ) else { continue }
                if closestRejected == nil || match.score < closestRejected!.score {
                    closestRejected = match
                }
                guard match.isAccepted else { continue }
                if bestMatch == nil || match.score < bestMatch!.score {
                    bestMatch = match
                    bestCandidate = ForegroundCandidate(
                        rect: rect,
                        feature: feature,
                        trianglePoints: representativeTrackingPoints(in: rect)
                    )
                }
            }
        }
        guard let candidate = bestCandidate, let match = bestMatch else {
            if let rejected = closestRejected {
                publishSearchProgress(
                    message: String(
                        format: "Chưa đủ phiếu đa góc • %d/%d góc • %.1f",
                        rejected.votes,
                        rejected.requiredVotes,
                        rejected.score
                    )
                )
            } else {
                publishSearchProgress(message: "Đang tìm vật đã lưu trên toàn màn hình...")
            }
            return
        }

        let score = match.similarity
        if isRecoveringLostTarget,
           score < immediateReacquisitionSimilarity {
            publishSearchProgress(
                message: String(
                    format: "Đang đối chứng %@ • %.0f%% / cần 75%%",
                    scanSubjectKind.title,
                    score * 100
                )
            )
            return
        }

        // Khi đang cứu mục tiêu, một ứng viên khớp >=75% dừng servo ngay;
        // không chờ bộ đếm nhiều frame khiến tên lửa đã đi qua vị trí đó.
        if isRecoveringLostTarget,
           score >= immediateReacquisitionSimilarity {
            lockTarget(
                rect: candidate.rect,
                trianglePoints: candidate.trianglePoints,
                confidence: score,
                matchDescription: String(format: "BẮT LẠI NGAY • KHỚP %.0f%%", score * 100),
                statusDescription: "Đã đạt 75% — bám lại ngay"
            )
            return
        }

        let categoryIsCorrect = categoryConfidence(
            for: candidate.rect,
            in: pixelBuffer
        ) != nil
        guard categoryIsCorrect else {
            publishSearchProgress(message: "Ứng viên chưa đúng loại \(scanSubjectKind.title.lowercased())")
            return
        }

        guard confirmsAIDetection(candidate.rect, requiredCount: 2) else {
            publishSearchProgress(
                message: "Đang xác nhận mẫu đa góc \(pendingAIDetectionCount)/2 • không khóa từ một frame"
            )
            return
        }
        lockTarget(
            rect: pendingAIDetectionRect ?? candidate.rect,
            trianglePoints: candidate.trianglePoints,
            confidence: score,
            matchDescription: String(
                format: "Khớp đa góc %d/%d • %.0f%%",
                match.votes,
                match.requiredVotes,
                score * 100
            ),
            statusDescription: "Đã xác nhận liên tiếp \(detectedSubjectLabel) — đang bám mục tiêu"
        )
    }

    private func publishSearchProgress(message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.isStopRequested else { return }
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
        // Khi tên lửa chỉ còn là một chấm nhỏ trên trời, tracker nhanh dễ bỏ
        // qua vài pixel chuyển động. Chuyển sang mức chính xác và cho detector
        // kiểm tra dày hơn; vật lớn vẫn giữ chế độ nhanh để đảm bảo 60 fps.
        let observedArea = observation.boundingBox.width * observation.boundingBox.height
        // Khi quay từ bệ ở khoảng 2–3 m, tên lửa thường chỉ chiếm một vùng nhỏ.
        // Chế độ riêng chạy tracker chính xác + detector dày ngay từ ngưỡng 1,5% ảnh.
        let tinyTargetAreaThreshold: CGFloat = scanSubjectKind == .waterRocket
            ? 0.015
            : 0.0045
        let isTinyTarget = observedArea < tinyTargetAreaThreshold
        request.trackingLevel = (isTinyTarget || lowConfidenceFrames > 0) ? .accurate : .fast

        do {
            try sequenceHandler.perform([request], on: pixelBuffer, orientation: .up)
            guard let result = request.results?.first as? VNDetectedObjectObservation else {
                markTargetLost()
                return
            }
            trackingFrameCounter += 1

            // Dưới 60% là tracker không còn đủ chắc để điều khiển servo theo vật.
            // Chuyển sang tái tìm ngay và dùng Kalman cuối cho lệnh quỹ đạo.
            if Double(result.confidence) < hardTrackingConfidence {
                markTargetLost()
                return
            }
            lowConfidenceFrames = 0

            var targetBounds = topLeftRect(from: result)
            let previousBounds = lastTrackingBounds ?? targetBounds
            var rawTriangle = transformedTriangle(
                trackingTrianglePoints,
                from: previousBounds,
                to: targetBounds
            )
            var measurementConfidence = Double(result.confidence)
            var isDetectorMeasurement = false

            if usesRocketSpecificDetector && aiDetector.isAvailable {
                // Detector chạy khoảng 15 lần/giây ở camera 60 fps. Tracker chạy
                // các frame xen giữa; khi tracker yếu, detector được gọi ngay.
                let shouldRunDetector = (isTinyTarget && trackingFrameCounter % 2 == 0)
                    || trackingFrameCounter % 4 == 0
                    || lowConfidenceFrames > 0
                if shouldRunDetector {
                    let expectedRect = motionFilter.isInitialized
                        ? motionFilter.estimate(at: CACurrentMediaTime()).filteredRect
                        : targetBounds
                    if let detection = bestAIDetection(in: pixelBuffer, near: expectedRect) {
                        let centerDistance = hypot(
                            detection.rect.midX - expectedRect.midX,
                            detection.rect.midY - expectedRect.midY
                        )
                        let closeEnough = centerDistance <= max(
                            0.055,
                            max(expectedRect.width, expectedRect.height) * 1.05
                        ) || intersectionOverUnion(detection.rect, expectedRect) > 0.18

                        let detectionArea = detection.rect.width * detection.rect.height
                        let identitySupported = closeEnough
                            || detectionArea < 0.0035
                            || bestIdentityAlignedDetection(
                                among: [detection],
                                in: pixelBuffer
                            ) != nil

                        // Kết quả gần quỹ đạo được dùng ngay. Kết quả ở xa phải
                        // lặp lại hai lần, tránh đổi sang vật giống tên lửa.
                        if closeEnough || (
                            identitySupported
                                && confirmsAIDetection(detection.rect, requiredCount: 3)
                        ) {
                            targetBounds = closeEnough
                                ? detection.rect
                                : (pendingAIDetectionRect ?? detection.rect)
                            rawTriangle = representativeTrackingPoints(in: targetBounds)
                            measurementConfidence = detection.confidence
                            isDetectorMeasurement = true
                            trackingObservation = self.observation(fromTopLeftRect: targetBounds)
                            sequenceHandler = VNSequenceRequestHandler()
                            aiDetectionMisses = 0
                            lowConfidenceFrames = 0
                            clearPendingAIDetection()
                        } else {
                            trackingObservation = result
                        }
                    } else {
                        aiDetectionMisses += 1
                        pendingAIDetectionCount = max(0, pendingAIDetectionCount - 1)
                        trackingObservation = result
                    }
                } else {
                    trackingObservation = result
                }

                // Cho Kalman/Vision gần 0,25 giây để vượt qua nhòe chuyển động,
                // cột/cành cây hoặc thời điểm dù vừa bung rồi mới tuyên bố mất.
                if lowConfidenceFrames >= 14 && aiDetectionMisses >= 6 {
                    markTargetLost()
                    return
                }
            } else {
                // Chế độ dự phòng trước khi có model YOLO đã huấn luyện:
                // bỏ việc tách nền không xác thực mỗi 10 frame (nguồn gây nhảy
                // mục tiêu), chỉ dùng kết quả đạt đủ phiếu từ toàn bộ ảnh mẫu.
                if trackingFrameCounter % 12 == 0 {
                    if let candidate = bestIdentityCandidate(
                        near: targetBounds,
                        in: pixelBuffer
                    ) {
                        let centerDistance = hypot(
                            candidate.rect.midX - targetBounds.midX,
                            candidate.rect.midY - targetBounds.midY
                        )
                        let closeEnough = centerDistance <= max(
                            0.08,
                            max(targetBounds.width, targetBounds.height) * 1.25
                        )
                        if closeEnough || confirmsAIDetection(candidate.rect, requiredCount: 2) {
                            targetBounds = closeEnough
                                ? candidate.rect
                                : (pendingAIDetectionRect ?? candidate.rect)
                            rawTriangle = candidate.trianglePoints.count == 3
                                ? candidate.trianglePoints
                                : representativeTrackingPoints(in: candidate.rect)
                            measurementConfidence = max(measurementConfidence, 0.72)
                            isDetectorMeasurement = true
                            trackingObservation = self.observation(fromTopLeftRect: targetBounds)
                            sequenceHandler = VNSequenceRequestHandler()
                            segmentationMissFrames = 0
                            clearPendingAIDetection()
                        } else {
                            trackingObservation = result
                        }
                    } else {
                        segmentationMissFrames += 1
                        trackingObservation = result
                    }
                } else {
                    trackingObservation = result
                }

                if lowConfidenceFrames >= 5
                    || (segmentationMissFrames >= 5 && result.confidence < 0.32) {
                    markTargetLost()
                    return
                }
            }

            let timestamp = CACurrentMediaTime()
            let measuredBounds = targetBounds
            let estimate = motionFilter.update(
                rect: measuredBounds,
                confidence: measurementConfidence,
                timestamp: timestamp,
                isDetectorMeasurement: isDetectorMeasurement
            )
            targetBounds = estimate.filteredRect
            rawTriangle = transformedTriangle(
                rawTriangle,
                from: measuredBounds,
                to: targetBounds
            )
            let publishedPoints = smoothedTriangle(rawTriangle)
            lastTrackingBounds = targetBounds
            previousTrackingCenter = CGPoint(x: targetBounds.midX, y: targetBounds.midY)
            smoothedTrackingVelocity = estimate.velocity

            let predictedPoint = estimate.predictedPoint
            let confidence = max(0, min(1, measurementConfidence))
            let direction = directionLabel(for: estimate.velocity)
            let previousArea = max(0.00001, previousBounds.width * previousBounds.height)
            let currentArea = max(0.00001, targetBounds.width * targetBounds.height)
            let areaGrowth = currentArea / previousArea
            let aspect = targetBounds.width / max(0.0001, targetBounds.height)
            if estimate.velocity.dy > 0.00065,
               (areaGrowth > 1.22 || aspect > 0.72) {
                parachuteDetected = true
            }
            let flightPhase: String
            if parachuteDetected {
                flightPhase = "DÙ BUNG • ĐANG RƠI"
            } else if estimate.velocity.dy > 0.00065 {
                flightPhase = "ĐANG RƠI"
            } else if estimate.velocity.dy < -0.00065 {
                flightPhase = "ĐANG BAY LÊN"
            } else {
                flightPhase = "ĐANG GIỮ MỤC TIÊU"
            }

            var appearanceText: String?
            if trackingFrameCounter % 12 == 0 {
                appearanceText = String(
                    format: "%@ • %@ • Kalman %@ • tin cậy %.0f%%",
                    aiDetector.isAvailable ? "YOLO AI" : "Vision dự phòng",
                    flightPhase,
                    direction,
                    confidence * 100
                )
            }

            // Ở 60 fps, gửi tâm dự đoán + vận tốc về ESP32 khoảng 30 lần/giây.
            // Gói cố định 15 byte luôn nằm dưới giới hạn BLE 20 byte:
            // V xxxyyy cc vvvwww (x/y 000...999, confidence 00...99,
            // vx/vy -99...+99). Firmware vẫn nhận cả gói T cũ.
            let velocityScale: CGFloat = 99.0 / 3.0
            let telemetryVX = Int(max(
                -99,
                min(99, estimate.velocity.dx * velocityScale)
            ).rounded())
            let telemetryVY = Int(max(
                -99,
                min(99, estimate.velocity.dy * velocityScale)
            ).rounded())
            let telemetry: String? = trackingFrameCounter % 2 == 0
                ? String(
                    format: "V%03d%03d%02d%+03d%+03d",
                    Int(max(0, min(999, predictedPoint.x * 999))),
                    Int(max(0, min(999, predictedPoint.y * 999))),
                    Int(max(0, min(99, (confidence * 100).rounded()))),
                    telemetryVX,
                    telemetryVY
                )
                : nil

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.targetRect = targetBounds
                self.trackingPoints = publishedPoints
                self.predictedTargetPoint = predictedPoint
                self.trackingConfidence = confidence
                if let appearanceText { self.matchText = appearanceText }
                if let telemetry { self.onEvent?(telemetry) }

                let isNearEdge = !(0.12...0.88).contains(predictedPoint.x)
                    || !(0.10...0.90).contains(predictedPoint.y)
                if self.isZoomedIn && isNearEdge {
                    self.hasCompletedOneTimeZoom = true
                    self.returnToUltraWide()
                }
            }
        } catch {
            markTargetLost()
        }
    }

    private func markTargetLost() {
        guard !isStopRequested else { return }
        // Chuyển thẳng sang tìm lại tự động. Không yêu cầu người dùng bấm nút
        // hoặc đưa vật vào vòng tròn lần nữa.
        let lostAt = CACurrentMediaTime()
        if motionFilter.isInitialized {
            recoverySeedEstimate = motionFilter.estimate(at: lostAt)
        } else if let lastTrackingBounds {
            recoverySeedEstimate = RocketMotionEstimate(
                filteredRect: lastTrackingBounds,
                predictedPoint: CGPoint(
                    x: lastTrackingBounds.midX,
                    y: lastTrackingBounds.midY
                ),
                velocity: smoothedTrackingVelocity
            )
        }
        recoveryStartedAt = lostAt
        isRecoveringLostTarget = true
        recoverySearchCommand = trajectorySearchCommand(for: recoverySeedEstimate)
        let screenSearchVector = trajectoryScreenVector(for: recoverySeedEstimate)
        let screenSearchAnchor = recoverySeedEstimate?.predictedPoint
        lastSearchCommandSentAt = lostAt
        let searchCommand = recoverySearchCommand
        processingMode = .verifying
        featureFrameCounter = 0
        shouldRecordAfterVerification = false
        trackingObservation = nil
        trackingAnchorObservations.removeAll()
        trackingTrianglePoints.removeAll()
        lastTrackingBounds = nil
        segmentationMissFrames = 0
        previousTrackingCenter = nil
        smoothedTrackingVelocity = .zero
        motionFilter.clear()
        aiDetectionMisses = 0
        clearPendingAIDetection()
        sequenceHandler = VNSequenceRequestHandler()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.isStopRequested else {
                self.onEvent?("RECORDING_STOPPED")
                return
            }
            self.stage = .verifying
            self.targetRect = nil
            self.trackingPoints = []
            self.predictedTargetPoint = nil
            self.trackingConfidence = 0
            self.servoSearchVector = screenSearchVector
            self.servoSearchAnchor = screenSearchAnchor
            self.isServoTrajectorySearching = screenSearchVector != nil
            self.matchText = self.aiDetector.isAvailable
                ? "Mất mục tiêu • AI và servo đang đi tiếp theo quỹ đạo cuối"
                : "Mất mục tiêu • đang tự tìm lại mô hình đa góc"
            self.statusText = "Servo đi theo hướng bay trước đó; AI quét toàn màn hình để khóa lại"
            self.returnToUltraWide()
            self.announce("Mất mục tiêu. Đang tự tìm lại.", kind: .warning)
            self.onEvent?(searchCommand)
        }
    }

    private func beginRecording() {
        guard isReady, !isRecording else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rocket-track-\(UUID().uuidString).mov")
        statusText = "Đã khóa \(scanSubjectKind.title.lowercased()) — đang bắt đầu quay..."

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    private func scheduleZoomSequence(after delay: TimeInterval = 0.5) {
        guard !hasCompletedOneTimeZoom else { return }
        cancelZoomSequence()

        let zoomIn = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            guard !self.isZoomedIn else { return }
            guard self.stage == .tracking,
                  let target = self.targetRect,
                  (0.20...0.80).contains(target.midX),
                  (0.18...0.82).contains(target.midY) else {
                self.zoomText = "0.5× • chờ mục tiêu vào giữa"
                self.scheduleZoomSequence(after: 0.35)
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
                self.hasCompletedOneTimeZoom = true
                self.isZoomedIn = false
                self.zoomText = String(format: "%.1f× • đã zoom xong", self.ultraWideDisplayZoomFactor)
                self.onEvent?("CAMERA_ULTRAWIDE")
                self.rampZoom(to: self.ultraWideDeviceZoomFactor, rate: 1.8)
            }
            self.zoomFinishedWorkItem = finished
            // Khoảng 1,3 giây ramp đến 0,98×, giữ ổn định 3 giây, rồi trở về
            // 0,5× và không zoom thêm lần nào trong video hiện tại.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: finished)
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
        case .waterRocket:
            return !detectRocketOrBottle(
                in: pixelBuffer,
                minimumConfidence: 0.05,
                regionOfInterest: CGRect(
                    x: processingRect.minX,
                    y: processingRect.minY,
                    width: processingRect.width,
                    height: processingRect.height
                )
            ).isEmpty

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
            self.scanGuidanceText = "Đã xác nhận • giữ iPhone cố định và xoay \(self.scanSubjectKind.title.lowercased()) chậm"
            self.matchText = "ĐÃ KHÓA CHỦ THỂ • bắt đầu dựng khối 3D"
            self.announce("Đã xác nhận đúng \(self.scanSubjectKind.title.lowercased()). Hãy xoay chậm.", kind: .success)
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
                self?.scanGuidanceText = "Khung này chưa rõ • bạn vẫn có thể chụp lại"
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
                self.scanGuidanceText = "Xoay \(self.scanSubjectKind.title.lowercased()) thêm một chút • thay đổi \(changePercent)%"
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
                : "Đã nhận mặt \(acceptedViews)/8 • tiếp tục xoay \(self.scanSubjectKind.title.lowercased())"
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
            if referenceVideoStartedAt != nil {
                processReferenceVideoFrame(from: pixelBuffer, kind: kind)
                return
            }
            if manualSelectionRequested {
                manualSelectionRequested = false
                updateManualSubjectSelection(from: pixelBuffer)
            }
            if consumeManualCaptureRequest() {
                captureManualPhoto(from: pixelBuffer, kind: kind)
            }

        case .verifying:
            featureFrameCounter += 1
            sendSearchHeartbeatIfNeeded()
            if verifyFreshScanSeed(pixelBuffer: pixelBuffer) {
                return
            }
            if usesRocketSpecificDetector && aiDetector.isAvailable {
                // YOLO tìm lớp tên lửa; nhánh mẫu cá nhân vẫn chạy song song ở
                // nhịp thấp hơn, nên YOLO hụt vật gần hoặc chai trong suốt cũng
                // không còn chặn toàn bộ bảy ảnh người dùng.
                let aiStride = isRecoveringLostTarget ? 1 : 2
                if featureFrameCounter % aiStride == 0 {
                    verifyWithAIDetector(pixelBuffer: pixelBuffer)
                }
                // Feature-print đa góc là đường dự phòng nặng. Lúc cứu mục tiêu chỉ
                // chạy thưa để không chặn detector Core ML đang quét từng frame.
                let personalizedStride = isRecoveringLostTarget ? 6 : 12
                if featureFrameCounter % personalizedStride == 1 {
                    verifyAndLock(pixelBuffer: pixelBuffer)
                }
            } else {
                // Người / Thú / Vật dùng Vision phân loại + bộ ảnh/video cá nhân.
                // Khi đang tìm lại, chạy mỗi frame để ứng viên >=75% khóa tức thì.
                let categoryStride = isRecoveringLostTarget ? 1 : 4
                if featureFrameCounter % categoryStride == 0 {
                    verifyAndLock(pixelBuffer: pixelBuffer)
                }
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
            self?.trackingAnchorObservations.removeAll()
            self?.trackingTrianglePoints.removeAll()
            self?.lastTrackingBounds = nil
            self?.segmentationMissFrames = 0
            self?.previousTrackingCenter = nil
            self?.smoothedTrackingVelocity = .zero
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cancelZoomSequence()
            self.resetZoom()
            self.isRecording = false
            self.isZoomedIn = false
            self.zoomText = String(format: "%.1f×", self.ultraWideDisplayZoomFactor)
            self.targetRect = nil
            self.trackingPoints = []
            self.predictedTargetPoint = nil
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
