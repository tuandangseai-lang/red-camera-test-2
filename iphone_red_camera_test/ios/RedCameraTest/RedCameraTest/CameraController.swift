import AVFoundation
import CoreImage
import ImageIO
import Photos
import QuartzCore
import SwiftUI
import Vision

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

    @Published private(set) var statusText = "Đang chuẩn bị camera..."
    @Published private(set) var zoomText = "1.0×"
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
    @Published private(set) var stage: RocketLearningStage = .idle
    @Published private(set) var learnedSamples = 0
    @Published private(set) var scanProgress = 0.0
    @Published private(set) var targetRect: CGRect?
    @Published private(set) var trackingConfidence = 0.0
    @Published private(set) var matchText = "Chưa có mẫu"
    @Published private(set) var frameAspectRatio: CGFloat = 9.0 / 16.0
    @Published var scanBoxScale = 0.42

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

    private var videoDevice: AVCaptureDevice?
    private var didRequestStart = false
    private var configured = false
    private var pendingArm = false

    // Các biến dưới đây chỉ được đọc/ghi trên videoQueue.
    private var processingMode: ProcessingMode = .idle
    private var processingRect = CGRect(x: 0.29, y: 0.15, width: 0.42, height: 0.70)
    private var featureSamples: [VNFeaturePrintObservation] = []
    private var stageStartingSampleCount = 0
    private var scanStartedAt = 0.0
    private var scanDuration = 5.0
    private var frameCounter = 0
    private var featureFrameCounter = 0
    private var trackingFrameCounter = 0
    private var lowConfidenceFrames = 0
    private var trackingObservation: VNDetectedObjectObservation?
    private var sequenceHandler = VNSequenceRequestHandler()
    private var shouldRecordAfterVerification = true

    private var scanFinishWorkItem: DispatchWorkItem?
    private var zoomInWorkItem: DispatchWorkItem?
    private var zoomOutWorkItem: DispatchWorkItem?
    private var zoomFinishedWorkItem: DispatchWorkItem?

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
            statusText = "Hãy hoàn thành Quét gần, Quét xa và Quét xung quanh trước"
            return
        }
        startTrackingAndRecording()
    }

    func startNearScan() {
        guard isReady, !isRecording else { return }
        startScan(kind: .near, duration: 5.0, resetProfile: true)
    }

    func startFarScan() {
        guard stage == .waitingFar, !isRecording else { return }
        startScan(kind: .far, duration: 5.0, resetProfile: false)
    }

    func startAroundScan() {
        guard (stage == .waitingAround || stage == .ready), !isRecording else { return }
        startScan(kind: .around, duration: 8.0, resetProfile: false)
    }

    func resetProfile() {
        guard !isRecording else { return }
        scanFinishWorkItem?.cancel()
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.processingMode = .idle
            self.featureSamples.removeAll()
            self.trackingObservation = nil
            self.sequenceHandler = VNSequenceRequestHandler()
        }
        stage = .idle
        learnedSamples = 0
        scanProgress = 0
        targetRect = nil
        trackingConfidence = 0
        matchText = "Chưa có mẫu"
        statusText = "Đặt tên lửa vào khung, chỉnh kích thước rồi bấm Quét gần"
        onEvent?("PROFILE_RESET")
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

    private func startScan(kind: ScanKind, duration: Double, resetProfile: Bool) {
        scanFinishWorkItem?.cancel()
        let rect = scanRect

        switch kind {
        case .near:
            stage = .scanningNear
            statusText = "Quét gần: giữ tên lửa đầy khung và xoay nhẹ"
        case .far:
            stage = .scanningFar
            statusText = "Quét xa: lùi ra, thu nhỏ khung cho vừa tên lửa"
        case .around:
            stage = .scanningAround
            statusText = "Quét xung quanh: đổi góc hoặc xoay tên lửa chậm"
        }

        scanProgress = 0
        targetRect = rect
        matchText = "Đang lấy mẫu hình ảnh..."

        videoQueue.async { [weak self] in
            guard let self else { return }
            if resetProfile {
                self.featureSamples.removeAll()
                self.sequenceHandler = VNSequenceRequestHandler()
                self.trackingObservation = nil
            }
            self.processingRect = rect
            self.stageStartingSampleCount = self.featureSamples.count
            self.scanStartedAt = CACurrentMediaTime()
            self.scanDuration = duration
            self.featureFrameCounter = 0
            self.processingMode = .scanning(kind)
        }

        let finish = DispatchWorkItem { [weak self] in
            self?.finishScan(kind: kind)
        }
        scanFinishWorkItem = finish
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: finish)
        onEvent?("SCAN_\(scanName(kind))_STARTED")
    }

    private func finishScan(kind: ScanKind) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            let newSampleCount = self.featureSamples.count - self.stageStartingSampleCount
            let totalSampleCount = self.featureSamples.count
            self.processingMode = .idle
            DispatchQueue.main.async {
                self.scanProgress = 1
                self.learnedSamples = totalSampleCount

                guard newSampleCount >= 3 else {
                    self.matchText = "Chưa lấy đủ mẫu"
                    switch kind {
                    case .near:
                        self.stage = .idle
                        self.statusText = "Không thấy đủ hình trong khung; hãy Quét gần lại"
                    case .far:
                        self.stage = .waitingFar
                        self.statusText = "Chưa đủ mẫu xa; hãy chỉnh khung nhỏ hơn và thử lại"
                    case .around:
                        self.stage = .waitingAround
                        self.statusText = "Chưa đủ góc nhìn; hãy quét xung quanh lại"
                    }
                    return
                }

                self.matchText = "Đã lưu \(totalSampleCount) mẫu"
                switch kind {
                case .near:
                    self.stage = .waitingFar
                    self.statusText = "Xong quét gần. Lùi ra xa, chỉnh khung rồi bấm Quét xa"
                case .far:
                    self.stage = .waitingAround
                    self.statusText = "Xong quét xa. Đổi nhiều góc rồi bấm Quét xung quanh"
                case .around:
                    self.stage = .ready
                    self.statusText = "Đã học xong. Đưa tên lửa vào khung rồi bấm Khóa và bám"
                }
                self.onEvent?("SCAN_\(self.scanName(kind))_DONE")
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

    private func configureSession(includeAudio: Bool) {
        guard !configured else { return }

        session.beginConfiguration()
        session.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ), let cameraInput = try? AVCaptureDeviceInput(device: camera),
           session.canAddInput(cameraInput) else {
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.statusText = "Không mở được camera sau"
            }
            return
        }

        session.addInput(cameraInput)
        videoDevice = camera

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
            self.statusText = "Đặt tên lửa vào khung, chỉnh kích thước rồi bấm Quét gần"
            if self.pendingArm {
                self.pendingArm = false
                self.statusText = "Đã nhận ARM nhưng cần quét tên lửa trước"
            }
        }
    }

    private func featurePrint(
        from pixelBuffer: CVPixelBuffer,
        normalizedTopLeftRect: CGRect
    ) -> VNFeaturePrintObservation? {
        let imageWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let imageHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
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

        let image = CIImage(cvPixelBuffer: pixelBuffer)
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

    private func minimumDistance(to candidate: VNFeaturePrintObservation) -> Float? {
        var best: Float?
        for sample in featureSamples {
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
            if trackingFrameCounter % 15 == 0,
               let candidate = featurePrint(from: pixelBuffer, normalizedTopLeftRect: topLeftRect),
               let distance = minimumDistance(to: candidate) {
                appearanceText = String(format: "Đang bám • sai khác %.1f", distance)
            }

            // Gửi tâm mục tiêu về ESP32 khoảng 6 lần/giây để điều khiển hai servo.
            // Tọa độ 0...999: x tăng từ trái sang phải, y tăng từ trên xuống dưới.
            let telemetry: String? = trackingFrameCounter % 5 == 0
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
            self.statusText = "Đưa tên lửa vào khung rồi bấm Bắt lại"
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

    private func scheduleZoomSequence() {
        cancelZoomSequence()

        let zoomIn = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            self.zoomText = "1× → 2×"
            self.onEvent?("ZOOM_IN")
            self.rampZoom(to: 2.0, rate: 0.4)
        }
        let zoomOut = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            self.zoomText = "2× → 1×"
            self.onEvent?("ZOOM_OUT")
            self.rampZoom(to: 1.0, rate: 0.4)
        }
        let zoomFinished = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            self.zoomText = "1.0×"
            self.onEvent?("ZOOM_CYCLE_DONE")
        }

        zoomInWorkItem = zoomIn
        zoomOutWorkItem = zoomOut
        zoomFinishedWorkItem = zoomFinished
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: zoomIn)
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.5, execute: zoomOut)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: zoomFinished)
    }

    private func cancelZoomSequence() {
        zoomInWorkItem?.cancel()
        zoomOutWorkItem?.cancel()
        zoomFinishedWorkItem?.cancel()
        zoomInWorkItem = nil
        zoomOutWorkItem = nil
        zoomFinishedWorkItem = nil
    }

    private func rampZoom(to requestedFactor: CGFloat, rate: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let maximum = min(device.activeFormat.videoMaxZoomFactor, 2.0)
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
                device.videoZoomFactor = 1.0
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
                    self.onEvent?("VIDEO_SAVED")
                } else {
                    self.statusText = "Quay xong nhưng chưa lưu được: \(error?.localizedDescription ?? "thiếu quyền Ảnh")"
                    self.onEvent?("SAVE_FAILED")
                }
            }
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

        case .scanning:
            featureFrameCounter += 1
            if featureFrameCounter % 5 == 0,
               featureSamples.count < 120,
               let feature = featurePrint(from: pixelBuffer, normalizedTopLeftRect: processingRect) {
                featureSamples.append(feature)
                let count = featureSamples.count
                DispatchQueue.main.async { [weak self] in
                    self?.learnedSamples = count
                    self?.matchText = "Đã lấy \(count) mẫu"
                }
            }

            if frameCounter % 3 == 0 {
                let progress = min(1.0, (CACurrentMediaTime() - scanStartedAt) / scanDuration)
                DispatchQueue.main.async { [weak self] in
                    self?.scanProgress = progress
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
            self.statusText = "Đang quay và bám — 5 giây nữa bắt đầu zoom"
            self.zoomText = "1.0×"
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
            self.zoomText = "1.0×"
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
