import AVFoundation
import AudioToolbox
import CoreImage
import ImageIO
import Photos
import SwiftUI
import UIKit

struct H2DCapturedFramePreview: Identifiable {
    let layer: Int
    let image: UIImage

    var id: Int { layer }
}

final class H2DTimelapseManager: NSObject, ObservableObject {
    @Published private(set) var isCameraReady = false
    @Published private(set) var isPreviewRunning = false
    @Published private(set) var isArmed = false
    @Published private(set) var isCapturing = false
    @Published private(set) var isRendering = false
    @Published private(set) var isStopping = false
    @Published private(set) var isLiveMonitorVisible = false
    // The preview is always portrait when the iPhone is mounted vertically.
    // Capture output keeps its own angle because the sensor image was mounted
    // upside down in the previous bracket.
    @Published private(set) var cameraRotationAngle: CGFloat = 90
    @Published private(set) var capturedFrameCount = 0
    @Published private(set) var lastCapturedLayer = 0
    @Published private(set) var recentFramePreviews: [H2DCapturedFramePreview] = []
    @Published private(set) var statusText = "Căn khung hình rồi bật chờ máy in"
    @Published private(set) var lastVideoSaved = false

    let previewSession = AVCaptureSession()

    var didStoreFrame: ((Int, Bool) -> Void)?

    private struct CaptureRequest: Equatable {
        let layer: Int
        let totalLayers: Int
        let jobID: String
        let playsShutterSound: Bool
    }

    private struct BufferedFrame {
        let pixelBuffer: CVPixelBuffer
        let timestamp: CMTime
        let lumaSignature: [UInt8]
        let meanLuma: Double
        let centerMeanLuma: Double
        let centerDarkRatio: Double
    }

    private let sessionQueue = DispatchQueue(label: "vn.se.h2d.camera", qos: .userInitiated)
    private let frameProcessingQueue = DispatchQueue(label: "vn.se.h2d.frame-processing", qos: .userInitiated)
    private let renderQueue = DispatchQueue(label: "vn.se.h2d.render", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var configured = false
    private var preparing = false
    private var pendingRequests: [CaptureRequest] = []
    private var currentRequest: CaptureRequest?
    private var bufferedFrames: [BufferedFrame] = []
    // The last photo that was actually accepted is a much stronger clean-scene
    // reference than brightness alone. Consecutive printed layers change only
    // slightly, while a toolhead crossing the frame changes a large region.
    private var lastAcceptedSignature: [UInt8]?
    private var lastAcceptedMeanLuma = 0.0
    private var capturedLayers = Set<Int>()
    private var sessionDirectory: URL?
    private var finishRequested = false
    private var originalBrightness: CGFloat?
    private var lastJobID = ""
    private var monitorPreviewRequested = false
    private var captureRotationAngle: CGFloat = 270
    private var minimumAcceptedLayer = 1
    // Keep exactly five lightweight preview frames, sampled every quarter
    // second. They cover the one second immediately before a confirmed layer
    // change; only the clearest pre-transition candidate reaches disk.
    private let bufferedFrameLimit = 5
    private let bufferedFrameInterval: TimeInterval = 0.25

    func preparePreview() {
        requestCameraPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.publishStatus("Hãy cấp quyền Camera cho SE")
                return
            }
            self.sessionQueue.async {
                self.configureIfNeeded()
                self.startSessionIfNeeded()
            }
        }
    }

    func stopPreview() {
        sessionQueue.async { [weak self] in
            guard let self, !self.isArmed else { return }
            if self.previewSession.isRunning { self.previewSession.stopRunning() }
            self.publishOnMain { self.isPreviewRunning = false }
        }
    }

    func arm(startingAtLayer: Int = 0) {
        guard !isArmed, !isRendering else { return }
        requestCameraPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.publishStatus("Không thể chụp vì SE chưa có quyền Camera")
                return
            }
            self.sessionQueue.async {
                self.configureIfNeeded()
                guard self.configured else { return }
                self.beginNewRun(startingAtLayer: startingAtLayer)
            }
        }
    }

    func disarm(deleteFrames: Bool = false) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.finishRequested = false
            self.pendingRequests.removeAll()
            self.currentRequest = nil
            self.bufferedFrames.removeAll()
            self.monitorPreviewRequested = false
            if self.previewSession.isRunning { self.previewSession.stopRunning() }
            let directory = self.sessionDirectory
            self.sessionDirectory = nil
            self.capturedLayers.removeAll()
            if deleteFrames, let directory {
                try? FileManager.default.removeItem(at: directory)
            }
            DispatchQueue.main.async {
                self.isArmed = false
                self.isCapturing = false
                self.isStopping = false
                self.isLiveMonitorVisible = false
                self.recentFramePreviews = []
                self.statusText = deleteFrames
                    ? "Đã dừng và xóa ảnh của lần chụp này"
                    : "Đã dừng chờ máy in"
                self.restoreDisplay()
            }
        }
    }

    func handle(_ event: H2DTimelapseEvent) {
        switch event.kind {
        case .snapshot:
            enqueueSnapshot(
                layer: event.layer,
                totalLayers: event.totalLayers,
                jobID: event.jobID,
                playsShutterSound: event.playsShutterSound
            )
        case .finished:
            requestFinish(jobID: event.jobID)
        case .error:
            publishStatus(event.message)
        }
    }

    func handleScenePhase(_ phase: ScenePhase, allowSetupPreview: Bool) {
        switch phase {
        case .active:
            if isArmed {
                UIApplication.shared.isIdleTimerDisabled = true
                sessionQueue.async { [weak self] in self?.startSessionIfNeeded() }
                if isLiveMonitorVisible {
                    showMonitorDisplay()
                } else {
                    setDimmedDisplay()
                }
            } else if !isRendering && allowSetupPreview {
                preparePreview()
            }
        case .inactive, .background:
            if isArmed {
                publishStatus("SE phải mở ở màn hình trước để iPhone được phép chụp")
            }
            // Never leave the user's iPhone dim after switching apps or
            // leaving this screen. Re-entering an armed session will dim it
            // again from the same restored level.
            DispatchQueue.main.async { [weak self] in self?.restoreDisplay() }
            sessionQueue.async { [weak self] in
                guard let self, self.previewSession.isRunning else { return }
                self.previewSession.stopRunning()
                self.publishOnMain { self.isPreviewRunning = false }
            }
        @unknown default:
            break
        }
    }

    func captureTestFrame() {
        guard isArmed else {
            publishStatus("Hãy bật chờ máy in trước khi chụp thử")
            return
        }
        let layer = max(1, lastCapturedLayer + 1)
        enqueueSnapshot(layer: layer, totalLayers: layer, jobID: "TEST")
    }

    func setLiveMonitorVisible(_ visible: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, self.isArmed, !self.isRendering else { return }
            self.monitorPreviewRequested = visible
            if visible { self.startSessionIfNeeded() }
            self.publishOnMain {
                self.isLiveMonitorVisible = visible
                if visible {
                    self.showMonitorDisplay()
                } else {
                    self.setDimmedDisplay()
                }
            }
        }
    }

    func rotateCamera180() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.captureRotationAngle = self.captureRotationAngle == 270 ? 90 : 270
            self.bufferedFrames.removeAll()
            self.lastAcceptedSignature = nil
            self.lastAcceptedMeanLuma = 0
            if let connection = self.videoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(self.captureRotationAngle) {
                connection.videoRotationAngle = self.captureRotationAngle
            }
            let previewAngle: CGFloat = self.captureRotationAngle == 270 ? 90 : 270
            self.publishOnMain { self.cameraRotationAngle = previewAngle }
        }
    }

    func finishEarlyAndRender() {
        sessionQueue.async { [weak self] in
            guard let self, self.isArmed, !self.isRendering else { return }
            self.finishRequested = true
            self.pendingRequests.removeAll()
            self.monitorPreviewRequested = false
            self.publishOnMain {
                self.isStopping = true
                self.isLiveMonitorVisible = false
                self.statusText = "Đã dừng chụp • đang ghép các ảnh đã có"
                self.restoreDisplay()
            }
            self.completeRunIfPossible()
        }
    }

    func restoreDisplayWhenLeaving() {
        DispatchQueue.main.async { [weak self] in self?.restoreDisplay() }
    }

    private func requestCameraPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in completion(granted) }
        default:
            completion(false)
        }
    }

    private func configureIfNeeded() {
        guard !configured, !preparing else { return }
        preparing = true
        previewSession.beginConfiguration()
        // The finished timelapse is 1080p, so buffering larger photo frames
        // would only add heat and memory pressure without improving the video.
        previewSession.sessionPreset = .hd1920x1080

        defer {
            previewSession.commitConfiguration()
            preparing = false
        }

        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ), let input = try? AVCaptureDeviceInput(device: camera),
           previewSession.canAddInput(input),
           previewSession.canAddOutput(videoOutput) else {
            publishStatus("Không mở được camera sau của iPhone")
            return
        }

        previewSession.addInput(input)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        previewSession.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(captureRotationAngle) {
            connection.videoRotationAngle = captureRotationAngle
        }

        do {
            try camera.lockForConfiguration()
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            camera.videoZoomFactor = 1.0
            camera.isSubjectAreaChangeMonitoringEnabled = false
            camera.unlockForConfiguration()
        } catch {
            publishStatus("Camera dùng cấu hình an toàn")
        }

        configured = true
        DispatchQueue.main.async {
            self.isCameraReady = true
            self.statusText = "Camera đã sẵn sàng • căn khung hình rồi bật chờ máy in"
        }
    }

    private func beginNewRun(startingAtLayer: Int) {
        pendingRequests.removeAll()
        currentRequest = nil
        bufferedFrames.removeAll()
        lastAcceptedSignature = nil
        lastAcceptedMeanLuma = 0
        capturedLayers.removeAll()
        monitorPreviewRequested = false
        capturedFrameCount = 0
        lastCapturedLayer = 0
        finishRequested = false
        lastVideoSaved = false
        lastJobID = ""
        minimumAcceptedLayer = max(1, startingAtLayer)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SE-Bambu-Timelapse", isDirectory: true)
            .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            sessionDirectory = directory
        } catch {
            publishStatus("Không tạo được thư mục ảnh timelapse")
            return
        }

        DispatchQueue.main.async {
            self.isArmed = true
            self.isStopping = false
            self.isLiveMonitorVisible = false
            self.recentFramePreviews = []
            self.statusText = "Màn hình tối • đang chờ lớp in đầu tiên"
            self.setDimmedDisplay()
            UIApplication.shared.isIdleTimerDisabled = true
        }

        // Keep the capture session warm for the whole armed run. Previously it
        // slept after 1.2 s, and waking it again cost roughly one second. That
        // is why the first few Smooth frames were correct but later ones were
        // taken after the printer had already started the next layer.
        startSessionIfNeeded()
    }

    private func enqueueSnapshot(
        layer: Int,
        totalLayers: Int,
        jobID: String,
        playsShutterSound: Bool = true
    ) {
        sessionQueue.async { [weak self] in
            guard let self, self.isArmed, layer >= self.minimumAcceptedLayer,
                  !self.capturedLayers.contains(layer),
                  self.currentRequest?.layer != layer,
                  !self.pendingRequests.contains(where: { $0.layer == layer }) else { return }
            if !jobID.isEmpty, jobID != "0", jobID != "TEST" {
                self.lastJobID = jobID
            }
            let request = CaptureRequest(
                layer: layer,
                totalLayers: totalLayers,
                jobID: jobID,
                playsShutterSound: playsShutterSound
            )
            // Never build a catch-up queue after a reconnect. If several old
            // notifications arrive together, retain only the newest eligible
            // layer; normal prints still deliver one event per layer.
            if let current = self.currentRequest {
                guard layer > current.layer else { return }
                self.pendingRequests = [request]
            } else {
                self.pendingRequests = [request]
            }
            if jobID != "TEST" {
                self.publishStatus("Lớp \(layer) • đang chọn khung không bị đầu in che")
            }
            self.captureNextIfNeeded()
        }
    }

    private func captureNextIfNeeded() {
        guard isArmed, currentRequest == nil, let request = pendingRequests.first else {
            completeRunIfPossible()
            return
        }
        pendingRequests.removeFirst()
        currentRequest = request
        startSessionIfNeeded()
        publishOnMain {
            self.isCapturing = true
            self.statusText = "Đang chọn ảnh lớp \(request.layer)/\(max(request.layer, request.totalLayers))"
        }

        if request.playsShutterSound, request.jobID != "TEST" {
            DispatchQueue.main.async {
                // Play once when the printer reports the new layer. Reading
                // five temporary frames never produces five shutter sounds.
                AudioServicesPlaySystemSound(1108)
            }
        }

        guard let selectedFrame = selectBestBufferedFrame() else {
            finishCurrentCapture(success: false)
            return
        }
        frameProcessingQueue.async { [weak self] in
            guard let self,
                  let data = self.makeJPEGData(from: selectedFrame.pixelBuffer) else {
                self?.sessionQueue.async { self?.finishCurrentCapture(success: false) }
                return
            }
            self.sessionQueue.async { [weak self] in
                guard let self, self.currentRequest == request,
                      let directory = self.sessionDirectory else {
                    self?.finishCurrentCapture(success: false)
                    return
                }
                do {
                    try data.write(
                        to: self.frameURL(for: request.layer, in: directory),
                        options: .atomic
                    )
                    self.capturedLayers.insert(request.layer)
                    self.lastAcceptedSignature = selectedFrame.lumaSignature
                    self.lastAcceptedMeanLuma = selectedFrame.meanLuma
                    let preview = self.makePreview(from: data, layer: request.layer)
                    self.finishCurrentCapture(success: true, preview: preview)
                } catch {
                    self.finishCurrentCapture(success: false)
                }
            }
        }
    }

    private func selectBestBufferedFrame() -> BufferedFrame? {
        let candidates = Array(bufferedFrames.suffix(bufferedFrameLimit))
        guard let newest = candidates.last else { return nil }
        guard candidates.count > 1 else { return newest }

        // A BLE notification arrives just after Bambu confirms the next layer.
        // Exclude the freshest sample when older choices exist so the
        // saved photo represents the completed layer, not the next layer that
        // has already started moving.
        let earlyCandidates = candidates.filter {
            CMTimeGetSeconds(newest.timestamp - $0.timestamp) >= 0.45
        }
        let selectable = earlyCandidates.count >= 2 ? earlyCandidates : candidates

        let signatureLength = selectable.map(\.lumaSignature.count).min() ?? 0
        guard signatureLength > 0 else { return newest }
        var medianSignature = [UInt8](repeating: 0, count: signatureLength)
        for index in 0..<signatureLength {
            let sortedValues = selectable.map { $0.lumaSignature[index] }.sorted()
            medianSignature[index] = sortedValues[sortedValues.count / 2]
        }
        let brightestMean = selectable.map(\.meanLuma).max() ?? newest.meanLuma
        let brightestCenterMean = selectable.map(\.centerMeanLuma).max() ?? newest.centerMeanLuma
        let leastCenterDarkRatio = selectable.map(\.centerDarkRatio).min() ?? newest.centerDarkRatio

        return selectable.min { left, right in
            selectionScore(
                left,
                medianSignature: medianSignature,
                brightestMean: brightestMean,
                brightestCenterMean: brightestCenterMean,
                leastCenterDarkRatio: leastCenterDarkRatio,
                previousAcceptedSignature: lastAcceptedSignature,
                previousAcceptedMeanLuma: lastAcceptedMeanLuma,
                newestTimestamp: newest.timestamp
            ) < selectionScore(
                right,
                medianSignature: medianSignature,
                brightestMean: brightestMean,
                brightestCenterMean: brightestCenterMean,
                leastCenterDarkRatio: leastCenterDarkRatio,
                previousAcceptedSignature: lastAcceptedSignature,
                previousAcceptedMeanLuma: lastAcceptedMeanLuma,
                newestTimestamp: newest.timestamp
            )
        }
    }

    private func selectionScore(
        _ frame: BufferedFrame,
        medianSignature: [UInt8],
        brightestMean: Double,
        brightestCenterMean: Double,
        leastCenterDarkRatio: Double,
        previousAcceptedSignature: [UInt8]?,
        previousAcceptedMeanLuma: Double,
        newestTimestamp: CMTime
    ) -> Double {
        let count = min(frame.lumaSignature.count, medianSignature.count)
        guard count > 0 else { return .greatestFiniteMagnitude }
        var difference = 0.0
        for index in 0..<count {
            difference += abs(
                Double(frame.lumaSignature[index]) - Double(medianSignature[index])
            )
        }
        let averageDifference = difference / Double(count)
        // In the supplied test video, obstructed frames were 7-12 luma points
        // darker in the central print area while whole-frame averages differed
        // very little. Make that central region the primary toolhead detector.
        let centerBrightnessPenalty =
            max(0, brightestCenterMean - frame.centerMeanLuma) * 2.8
        let centerDarkPenalty =
            max(0, frame.centerDarkRatio - leastCenterDarkRatio) * 180.0
        let wholeFramePenalty = max(0, brightestMean - frame.meanLuma) * 0.8
        let referencePenalty: Double
        if let previousAcceptedSignature {
            referencePenalty = normalizedReferenceDifference(
                frame,
                reference: previousAcceptedSignature,
                referenceMeanLuma: previousAcceptedMeanLuma
            )
        } else {
            referencePenalty = 0
        }
        // Prefer the older part of the one-second window after obstruction is
        // rejected. Similarity is deliberately secondary because a toolhead
        // parked in several consecutive frames can otherwise become median.
        let age = max(0, CMTimeGetSeconds(newestTimestamp - frame.timestamp))
        let timingPenalty = abs(age - 0.75) * 0.9
        return averageDifference * 0.2 + referencePenalty * 2.4 +
            centerBrightnessPenalty + centerDarkPenalty + wholeFramePenalty +
            timingPenalty
    }

    private func normalizedReferenceDifference(
        _ frame: BufferedFrame,
        reference: [UInt8],
        referenceMeanLuma: Double
    ) -> Double {
        let gridSize = 48
        let count = min(frame.lumaSignature.count, reference.count)
        guard count >= gridSize * gridSize else { return 0 }

        // Remove a uniform exposure change first. The remaining difference is
        // physical scene change: most importantly the moving H2D toolhead.
        let exposureShift = frame.meanLuma - referenceMeanLuma
        let centerMargin = 8
        var wholeDifference = 0.0
        var centerDifference = 0.0
        var centerCount = 0
        for index in 0..<count {
            let difference = abs(
                Double(frame.lumaSignature[index]) -
                    (Double(reference[index]) + exposureShift)
            )
            wholeDifference += difference
            let row = index / gridSize
            let column = index % gridSize
            if row >= centerMargin, row < gridSize - centerMargin,
               column >= centerMargin, column < gridSize - centerMargin {
                centerDifference += difference
                centerCount += 1
            }
        }
        let wholeMean = wholeDifference / Double(count)
        let centerMean = centerCount > 0
            ? centerDifference / Double(centerCount)
            : wholeMean
        return wholeMean * 0.8 + centerMean * 1.2
    }

    private func makeJPEGData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.94)
    }

    private func finishCurrentCapture(
        success: Bool,
        preview: H2DCapturedFramePreview? = nil
    ) {
        let finishedLayer = currentRequest?.layer ?? 0
        let storedFrameCount = capturedLayers.count
        currentRequest = nil
        publishOnMain {
            self.isCapturing = false
            if success {
                self.capturedFrameCount = storedFrameCount
                self.lastCapturedLayer = max(self.lastCapturedLayer, finishedLayer)
                self.statusText = "Đã chụp lớp \(finishedLayer) • camera sẵn sàng cho lớp kế tiếp"
                if let preview {
                    self.recentFramePreviews.removeAll { $0.layer == preview.layer }
                    self.recentFramePreviews.insert(preview, at: 0)
                    self.recentFramePreviews = Array(self.recentFramePreviews.prefix(8))
                }
            } else {
                self.statusText = "Chụp lớp \(finishedLayer) lỗi • chờ tín hiệu tiếp theo"
            }
            self.didStoreFrame?(finishedLayer, success)
        }
        captureNextIfNeeded()
    }

    private func makePreview(from data: Data, layer: Int) -> H2DCapturedFramePreview? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return H2DCapturedFramePreview(layer: layer, image: UIImage(cgImage: thumbnail))
    }

    private func requestFinish(jobID: String) {
        sessionQueue.async { [weak self] in
            guard let self, self.isArmed else { return }
            self.finishRequested = true
            if !jobID.isEmpty, jobID != "0" { self.lastJobID = jobID }
            self.publishStatus("Máy in đã in xong • đang hoàn tất ảnh cuối")
            self.completeRunIfPossible()
        }
    }

    private func completeRunIfPossible() {
        guard finishRequested, currentRequest == nil, pendingRequests.isEmpty,
              !isRendering else { return }
        finishRequested = false
        monitorPreviewRequested = false
        if previewSession.isRunning { previewSession.stopRunning() }
        guard let directory = sessionDirectory, !capturedLayers.isEmpty else {
            let emptyDirectory = sessionDirectory
            sessionDirectory = nil
            capturedLayers.removeAll()
            if let emptyDirectory {
                try? FileManager.default.removeItem(at: emptyDirectory)
            }
            publishStatus("Máy in đã xong nhưng chưa có ảnh để ghép")
            DispatchQueue.main.async {
                self.isArmed = false
                self.isCapturing = false
                self.isStopping = false
                self.isLiveMonitorVisible = false
                self.restoreDisplay()
            }
            return
        }

        DispatchQueue.main.async {
            self.isRendering = true
            self.isLiveMonitorVisible = false
            self.statusText = "Đang ghép \(self.capturedLayers.count) lớp thành video..."
        }
        renderQueue.async { [weak self] in
            self?.renderVideo(from: directory)
        }
    }

    private func frameURL(for layer: Int, in directory: URL) -> URL {
        directory.appendingPathComponent(String(format: "layer-%06d.jpg", layer))
    }

    private func renderVideo(from directory: URL) {
        let frameURLs = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        guard let firstURL = frameURLs.first,
              let firstImage = UIImage(contentsOfFile: firstURL.path),
              let firstCGImage = normalizedCGImage(firstImage) else {
            finishRender(success: false, videoURL: nil, directory: directory,
                         message: "Không đọc được ảnh timelapse")
            return
        }

        let landscape = firstCGImage.width >= firstCGImage.height
        let outputWidth = landscape ? 1920 : 1080
        let outputHeight = landscape ? 1080 : 1920
        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SE-Bambu-\(lastJobID.isEmpty ? UUID().uuidString : lastJobID).mp4")
        try? FileManager.default.removeItem(at: videoURL)

        do {
            let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: outputWidth,
                AVVideoHeightKey: outputHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 30
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: attributes
            )
            guard writer.canAdd(input) else { throw RenderError.cannotCreateWriter }
            writer.add(input)
            guard writer.startWriting() else {
                throw writer.error ?? RenderError.cannotCreateWriter
            }
            writer.startSession(atSourceTime: .zero)

            let frameRate: Int32 = 30
            for (index, url) in frameURLs.enumerated() {
                while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.003) }
                autoreleasepool {
                    guard let image = UIImage(contentsOfFile: url.path),
                          let cgImage = normalizedCGImage(image),
                          let pool = adaptor.pixelBufferPool,
                          let buffer = makePixelBuffer(
                            image: cgImage,
                            width: outputWidth,
                            height: outputHeight,
                            pool: pool
                          ) else { return }
                    adaptor.append(
                        buffer,
                        withPresentationTime: CMTime(value: Int64(index), timescale: frameRate)
                    )
                }
                let progress = Double(index + 1) / Double(max(1, frameURLs.count))
                if index % 12 == 0 || index == frameURLs.count - 1 {
                    publishStatus("Đang ghép video • \(Int(progress * 100))%")
                }
            }
            input.markAsFinished()
            writer.finishWriting { [weak self] in
                guard let self else { return }
                if writer.status == .completed {
                    self.saveVideoToPhotos(videoURL, sourceDirectory: directory)
                } else {
                    self.finishRender(
                        success: false,
                        videoURL: videoURL,
                        directory: directory,
                        message: "Ghép video chưa thành công"
                    )
                }
            }
        } catch {
            finishRender(
                success: false,
                videoURL: videoURL,
                directory: directory,
                message: "Không tạo được video timelapse"
            )
        }
    }

    private func normalizedCGImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cgImage = image.cgImage { return cgImage }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }.cgImage
    }

    private func makePixelBuffer(
        image: CGImage,
        width: Int,
        height: Int,
        pool: CVPixelBufferPool
    ) -> CVPixelBuffer? {
        var optionalBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
              let buffer = optionalBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                    CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else { return nil }

        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = max(CGFloat(width) / CGFloat(image.width),
                        CGFloat(height) / CGFloat(image.height))
        let drawWidth = CGFloat(image.width) * scale
        let drawHeight = CGFloat(image.height) * scale
        let rect = CGRect(
            x: (CGFloat(width) - drawWidth) / 2,
            y: (CGFloat(height) - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let flippedRect = CGRect(
            x: rect.origin.x,
            y: CGFloat(height) - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        context.draw(image, in: flippedRect)
        return buffer
    }

    private func saveVideoToPhotos(_ videoURL: URL, sourceDirectory: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                self.finishRender(
                    success: false,
                    videoURL: videoURL,
                    directory: sourceDirectory,
                    message: "Hãy cấp quyền thêm video vào Ảnh"
                )
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            } completionHandler: { success, _ in
                self.finishRender(
                    success: success,
                    videoURL: videoURL,
                    directory: sourceDirectory,
                    message: success
                        ? "Đã ghép và lưu timelapse vào Ảnh"
                        : "Không lưu được video vào Ảnh"
                )
            }
        }
    }

    private func finishRender(
        success: Bool,
        videoURL: URL?,
        directory: URL,
        message: String
    ) {
        if let videoURL { try? FileManager.default.removeItem(at: videoURL) }
        if success { try? FileManager.default.removeItem(at: directory) }
        DispatchQueue.main.async {
            self.isRendering = false
            self.isArmed = false
            self.isCapturing = false
            self.isStopping = false
            self.isLiveMonitorVisible = false
            self.lastVideoSaved = success
            self.statusText = message
            self.restoreDisplay()
        }
    }

    private func startSessionIfNeeded() {
        configureIfNeeded()
        guard configured else {
            publishOnMain { self.isPreviewRunning = false }
            return
        }
        if !previewSession.isRunning { previewSession.startRunning() }
        let running = previewSession.isRunning
        publishOnMain {
            self.isPreviewRunning = running
            if !running { self.statusText = "Camera chưa phát hình • đang thử mở lại" }
        }
    }

    private func appendBufferedFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard isArmed else { return }
        if let previous = bufferedFrames.last {
            let elapsed = CMTimeGetSeconds(timestamp - previous.timestamp)
            guard elapsed >= bufferedFrameInterval - 0.04 else { return }
        }
        // AVCaptureVideoDataOutput owns the pixel buffer received by this
        // callback. Retaining five of those buffers can exhaust its small
        // internal pool, after which the camera silently stops delivering
        // frames. Keep an app-owned copy instead so the capture pipeline is
        // immediately free to reuse its own memory.
        guard let ownedPixelBuffer = copyPixelBuffer(pixelBuffer) else { return }
        let signature = makeLumaSignature(from: ownedPixelBuffer)
        guard !signature.isEmpty else { return }
        let mean = signature.reduce(0.0) { $0 + Double($1) } / Double(signature.count)
        let centerStats = centerLumaStats(from: signature)
        bufferedFrames.append(
            BufferedFrame(
                pixelBuffer: ownedPixelBuffer,
                timestamp: timestamp,
                lumaSignature: signature,
                meanLuma: mean,
                centerMeanLuma: centerStats.mean,
                centerDarkRatio: centerStats.darkRatio
            )
        )
        if bufferedFrames.count > bufferedFrameLimit {
            bufferedFrames.removeFirst(bufferedFrames.count - bufferedFrameLimit)
        }
    }

    private func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ] as CFDictionary
        var destination: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes,
            &destination
        ) == kCVReturnSuccess, let destination else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        let planeCount = CVPixelBufferGetPlaneCount(source)
        guard planeCount == CVPixelBufferGetPlaneCount(destination) else { return nil }
        if planeCount > 0 {
            for plane in 0..<planeCount {
                guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else {
                    return nil
                }
                let rows = min(
                    CVPixelBufferGetHeightOfPlane(source, plane),
                    CVPixelBufferGetHeightOfPlane(destination, plane)
                )
                let sourceBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let destinationBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                let bytesToCopy = min(sourceBytesPerRow, destinationBytesPerRow)
                for row in 0..<rows {
                    destinationBase.advanced(by: row * destinationBytesPerRow).copyMemory(
                        from: UnsafeRawPointer(sourceBase.advanced(by: row * sourceBytesPerRow)),
                        byteCount: bytesToCopy
                    )
                }
            }
        } else {
            guard let sourceBase = CVPixelBufferGetBaseAddress(source),
                  let destinationBase = CVPixelBufferGetBaseAddress(destination) else { return nil }
            let rows = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination))
            let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
            let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
            let bytesToCopy = min(sourceBytesPerRow, destinationBytesPerRow)
            for row in 0..<rows {
                destinationBase.advanced(by: row * destinationBytesPerRow).copyMemory(
                    from: UnsafeRawPointer(sourceBase.advanced(by: row * sourceBytesPerRow)),
                    byteCount: bytesToCopy
                )
            }
        }
        return destination
    }

    private func centerLumaStats(from signature: [UInt8]) -> (mean: Double, darkRatio: Double) {
        let gridSize = 48
        guard signature.count >= gridSize * gridSize else { return (0, 1) }
        let margin = 8
        var total = 0.0
        var darkCount = 0
        var sampleCount = 0
        for row in margin..<(gridSize - margin) {
            for column in margin..<(gridSize - margin) {
                let value = signature[row * gridSize + column]
                total += Double(value)
                if value < 70 { darkCount += 1 }
                sampleCount += 1
            }
        }
        guard sampleCount > 0 else { return (0, 1) }
        return (
            total / Double(sampleCount),
            Double(darkCount) / Double(sampleCount)
        )
    }

    private func makeLumaSignature(from pixelBuffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let isPlanar = CVPixelBufferGetPlaneCount(pixelBuffer) > 0
        let width = isPlanar
            ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetWidth(pixelBuffer)
        let height = isPlanar
            ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = isPlanar
            ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow > 0,
              let baseAddress = isPlanar
                ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
                : CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }

        let columns = 48
        let rows = 48
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        let bytesPerPixel = isPlanar ? 1 : 4
        var signature: [UInt8] = []
        signature.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let y = min(height - 1, (row * height + height / 2) / rows)
            for column in 0..<columns {
                let x = min(width - 1, (column * width + width / 2) / columns)
                let offset = y * bytesPerRow + x * bytesPerPixel
                if isPlanar {
                    signature.append(bytes[offset])
                } else {
                    let blue = UInt16(bytes[offset])
                    let green = UInt16(bytes[offset + 1])
                    let red = UInt16(bytes[offset + 2])
                    signature.append(UInt8((red * 54 + green * 183 + blue * 19) >> 8))
                }
            }
        }
        return signature
    }

    private func setDimmedDisplay() {
        if originalBrightness == nil { originalBrightness = UIScreen.main.brightness }
        // Timelapse mode keeps the app in the foreground for iOS camera access.
        // Use the actual minimum instead of leaving a visible 1% glow.
        UIScreen.main.brightness = 0.0
    }

    private func showMonitorDisplay() {
        let preferred = originalBrightness ?? UIScreen.main.brightness
        UIScreen.main.brightness = max(0.28, preferred)
    }

    private func restoreDisplay() {
        UIApplication.shared.isIdleTimerDisabled = false
        if let brightness = originalBrightness {
            UIScreen.main.brightness = brightness
            originalBrightness = nil
        }
    }

    private func publishStatus(_ text: String) {
        publishOnMain { self.statusText = text }
    }

    private func publishOnMain(_ update: @escaping () -> Void) {
        DispatchQueue.main.async(execute: update)
    }

    private enum RenderError: Error {
        case cannotCreateWriter
    }
}

extension H2DTimelapseManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        appendBufferedFrame(
            pixelBuffer,
            timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
    }
}

struct H2DCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let rotationAngle: CGFloat

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.layerView.session = session
        view.layerView.videoGravity = .resizeAspectFill
        view.rotationAngle = rotationAngle
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.layerView.session = session
        uiView.rotationAngle = rotationAngle
        uiView.updateRotation()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var layerView: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var rotationAngle: CGFloat = 90

        override func layoutSubviews() {
            super.layoutSubviews()
            updateRotation()
        }

        func updateRotation() {
            guard let connection = layerView.connection,
                  connection.isVideoRotationAngleSupported(rotationAngle) else { return }
            connection.videoRotationAngle = rotationAngle
        }
    }
}
