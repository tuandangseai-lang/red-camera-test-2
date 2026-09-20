import AVFoundation
import AudioToolbox
import CoreImage
import ImageIO
import Photos
import SwiftUI
import UIKit
import Vision

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
    @Published private(set) var canUseTorch = false
    @Published private(set) var isTorchEnabled = false
    /// Stable UI state for flash mode. Unlike `isTorchEnabled`, this does not
    /// toggle on every pulse of the physical film-shutter button.
    @Published private(set) var isFlashModeActive = false
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
        let motionScore: Double
    }

    private let sessionQueue = DispatchQueue(label: "vn.se.h2d.camera", qos: .userInitiated)
    private let frameProcessingQueue = DispatchQueue(label: "vn.se.h2d.frame-processing", qos: .userInitiated)
    private let renderQueue = DispatchQueue(label: "vn.se.h2d.render", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var captureDevice: AVCaptureDevice?
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
    private var brightnessBeforeFlashMode: CGFloat?
    private var lastJobID = ""
    private var monitorPreviewRequested = false
    private var captureRotationAngle: CGFloat = 270
    private var minimumAcceptedLayer = 1
    // Keep seven lightweight candidates, 0.15 s apart. This covers the 0.9 s
    // immediately before a confirmed layer change and gives the selector more
    // clean choices while the H2D toolhead crosses the phone's field of view.
    private let bufferedFrameLimit = 7
    private let bufferedFrameInterval: TimeInterval = 0.15
    private let cameraWarmupTimeout: TimeInterval = 1.8
    private var captureFrameWaitDeadline: Date?
    private var hardwareTorchGeneration = 0
    private var shutterSoundPlayer: AVAudioPlayer?
    private var effectSoundLevel: Float = 0.7

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
        // Use the bundled recording sound through AVAudioPlayer so it remains
        // audible even when the undocumented system-sound ID is unavailable.
        // A safe minimum volume makes the mode change unambiguous while the
        // ESP32 is still delivering its first potentiometer value.
        DispatchQueue.main.async { [weak self] in
            self?.playCameraSound(minimumVolume: 0.55)
        }
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

    func setEffectSoundLevel(_ normalizedLevel: Double) {
        let level = Float(min(1, max(0, normalizedLevel)))
        DispatchQueue.main.async { [weak self] in
            self?.effectSoundLevel = level
            self?.shutterSoundPlayer?.volume = level
        }
    }

    func disarm(deleteFrames: Bool = false) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.finishRequested = false
            self.pendingRequests.removeAll()
            self.currentRequest = nil
            self.captureFrameWaitDeadline = nil
            self.bufferedFrames.removeAll()
            self.monitorPreviewRequested = false
            self.hardwareTorchGeneration &+= 1
            self.applyTorch(false)
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
            setViewActive(true)
            if isArmed {
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
            setViewActive(false)
            sessionQueue.async { [weak self] in
                guard let self, self.previewSession.isRunning else { return }
                self.hardwareTorchGeneration &+= 1
                self.applyTorch(false)
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

    func setTorchEnabled(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, self.isArmed, !self.isRendering else { return }
            self.hardwareTorchGeneration &+= 1
            if enabled {
                self.enterFlashDisplayMode()
            } else {
                self.leaveFlashDisplayMode()
            }
            self.applyTorch(enabled)
        }
    }

    /// Applies the physical controls connected to the ESP32. A held button
    /// alternates the iPhone torch like a film projector; the left rotary
    /// position requests a steady torch even outside an armed timelapse.
    func setHardwareTorch(steady: Bool, blinking: Bool, keepCameraWarm: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.hardwareTorchGeneration &+= 1
            let generation = self.hardwareTorchGeneration

            guard steady || blinking else {
                self.leaveFlashDisplayMode()
                self.applyTorch(false)
                if !keepCameraWarm && !self.isArmed && self.previewSession.isRunning {
                    self.previewSession.stopRunning()
                    self.publishOnMain { self.isPreviewRunning = false }
                }
                return
            }

            // Dim once when the user enters either steady or pulsing flash.
            // The pulsing torch itself must never drive the SwiftUI artwork or
            // repeatedly write screen brightness.
            self.enterFlashDisplayMode()
            self.requestCameraPermission { [weak self] granted in
                guard let self else { return }
                self.sessionQueue.async {
                    guard generation == self.hardwareTorchGeneration else { return }
                    guard granted else {
                        self.leaveFlashDisplayMode()
                        self.publishStatus("Hãy cấp quyền Camera để công tắc điều khiển đèn flash")
                        return
                    }
                    self.configureIfNeeded()
                    self.startSessionIfNeeded()
                    if blinking {
                        self.runHardwareTorchBlink(generation: generation, turnOn: true)
                    } else {
                        self.applyTorch(steady)
                    }
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
            self.hardwareTorchGeneration &+= 1
            self.applyTorch(false)
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
        setViewActive(false)
    }

    func setViewActive(_ active: Bool) {
        DispatchQueue.main.async { [weak self] in
            UIApplication.shared.isIdleTimerDisabled = active
            if !active { self?.restoreDisplay() }
        }
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
        captureDevice = camera
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
            // The wide camera is too loose for a fixed printer shot. Start at
            // 1.5x while clamping to the active lens' supported range.
            camera.videoZoomFactor = min(
                max(1.5, camera.minAvailableVideoZoomFactor),
                camera.maxAvailableVideoZoomFactor
            )
            camera.isSubjectAreaChangeMonitoringEnabled = false
            camera.unlockForConfiguration()
        } catch {
            publishStatus("Camera dùng cấu hình an toàn")
        }

        configured = true
        DispatchQueue.main.async {
            self.isCameraReady = true
            self.canUseTorch = camera.hasTorch
            self.statusText = "Camera đã sẵn sàng • căn khung hình rồi bật chờ máy in"
        }
    }

    private func beginNewRun(startingAtLayer: Int) {
        pendingRequests.removeAll()
        currentRequest = nil
        captureFrameWaitDeadline = nil
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
        captureFrameWaitDeadline = Date().addingTimeInterval(cameraWarmupTimeout)
        startSessionIfNeeded()
        publishOnMain {
            self.isCapturing = true
            self.statusText = "Đang chọn ảnh lớp \(request.layer)/\(max(request.layer, request.totalLayers))"
        }

        if request.playsShutterSound, request.jobID != "TEST" {
            // Play the supplied iPhone shutter sample once per logical
            // layer. Reading seven temporary candidate frames remains silent.
            DispatchQueue.main.async { [weak self] in self?.playCameraSound() }
        }

        captureCurrentRequestWhenReady()
    }

    private func playCameraSound(minimumVolume: Float = 0) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
            let player: AVAudioPlayer
            if let loaded = shutterSoundPlayer {
                player = loaded
            } else {
                guard let url = Bundle.main.url(
                    forResource: "iphone-screenshot-shutter",
                    withExtension: "mp3"
                ) else {
                    AudioServicesPlaySystemSound(1108)
                    return
                }
                let created = try AVAudioPlayer(contentsOf: url)
                created.prepareToPlay()
                shutterSoundPlayer = created
                player = created
            }
            player.stop()
            player.currentTime = 0
            player.volume = max(minimumVolume, effectSoundLevel)
            player.play()
        } catch {
            AudioServicesPlaySystemSound(1108)
        }
    }

    private func captureCurrentRequestWhenReady() {
        guard isArmed, let request = currentRequest else { return }
        guard let selectedFrame = selectBestBufferedFrame() else {
            if Date() < (captureFrameWaitDeadline ?? .distantPast) {
                publishStatus("Lớp \(request.layer) • camera đang lấy khung hình")
                sessionQueue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.captureCurrentRequestWhenReady()
                }
            } else {
                finishCurrentCapture(success: false)
            }
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
        // Normally only the freshest sample can belong to the new layer, so
        // prefer the other six pre-transition frames. Keep a fallback for very
        // short first layers where the rolling buffer has not filled yet.
        let preTransitionCandidates = candidates.filter {
            CMTimeGetSeconds(newest.timestamp - $0.timestamp) >=
                bufferedFrameInterval * 0.8
        }
        let selectable = preTransitionCandidates.count >= 3
            ? preTransitionCandidates
            : candidates

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
        let medianMeanLuma = selectable.map(\.meanLuma).sorted()[selectable.count / 2]
        let quietestMotion = selectable.map(\.motionScore).min() ?? 0

        return selectable.min { left, right in
            selectionScore(
                left,
                medianSignature: medianSignature,
                brightestMean: brightestMean,
                brightestCenterMean: brightestCenterMean,
                leastCenterDarkRatio: leastCenterDarkRatio,
                medianMeanLuma: medianMeanLuma,
                quietestMotion: quietestMotion,
                previousAcceptedSignature: lastAcceptedSignature,
                previousAcceptedMeanLuma: lastAcceptedMeanLuma,
                newestTimestamp: newest.timestamp
            ) < selectionScore(
                right,
                medianSignature: medianSignature,
                brightestMean: brightestMean,
                brightestCenterMean: brightestCenterMean,
                leastCenterDarkRatio: leastCenterDarkRatio,
                medianMeanLuma: medianMeanLuma,
                quietestMotion: quietestMotion,
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
        medianMeanLuma: Double,
        quietestMotion: Double,
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
        // A large dark object entering one small area is the most reliable
        // signature of the print head. Looking at sliding local windows avoids
        // hiding that signal inside the average brightness of the whole frame.
        let medianObstruction = localizedDarkIntrusion(
            frame,
            reference: medianSignature,
            referenceMeanLuma: medianMeanLuma
        )
        let historyObstruction: Double
        if let previousAcceptedSignature {
            historyObstruction = localizedDarkIntrusion(
                frame,
                reference: previousAcceptedSignature,
                referenceMeanLuma: previousAcceptedMeanLuma
            )
        } else {
            historyObstruction = 0
        }
        let obstructionPenalty = max(medianObstruction, historyObstruction * 0.9)
        // The H2D carriage enters from an outer edge. A whole/centre average
        // can miss a small protruding nozzle, so inspect all edge corridors
        // separately and reject even a bright (not only dark) intrusion.
        let medianEdgeIntrusion = localizedEdgeIntrusion(
            frame,
            reference: medianSignature,
            referenceMeanLuma: medianMeanLuma
        )
        let historyEdgeIntrusion: Double
        if let previousAcceptedSignature {
            historyEdgeIntrusion = localizedEdgeIntrusion(
                frame,
                reference: previousAcceptedSignature,
                referenceMeanLuma: previousAcceptedMeanLuma
            )
        } else {
            historyEdgeIntrusion = 0
        }
        let edgeIntrusionPenalty = max(
            medianEdgeIntrusion,
            historyEdgeIntrusion * 0.82
        )
        let motionPenalty = max(0, frame.motionScore - quietestMotion)

        // After obstruction and motion are rejected, prefer the older clean
        // side of the 0.9-second window. This is before the layer transition,
        // while Smooth has already parked the carriage near its wipe tower.
        let age = max(0, CMTimeGetSeconds(newestTimestamp - frame.timestamp))
        let timingPenalty = abs(age - 0.75) * 0.8
        return averageDifference * 0.15 + referencePenalty * 2.2 +
            centerBrightnessPenalty + centerDarkPenalty + wholeFramePenalty +
            obstructionPenalty * 3.2 + edgeIntrusionPenalty * 4.8 +
            motionPenalty * 1.8 + timingPenalty
    }

    private func localizedEdgeIntrusion(
        _ frame: BufferedFrame,
        reference: [UInt8],
        referenceMeanLuma: Double
    ) -> Double {
        localizedEdgeIntrusion(
            signature: frame.lumaSignature,
            meanLuma: frame.meanLuma,
            reference: reference,
            referenceMeanLuma: referenceMeanLuma
        )
    }

    private func localizedEdgeIntrusion(
        signature: [UInt8],
        meanLuma: Double,
        reference: [UInt8],
        referenceMeanLuma: Double
    ) -> Double {
        let gridSize = 48
        let count = min(signature.count, reference.count)
        guard count >= gridSize * gridSize else { return 0 }
        let exposureShift = meanLuma - referenceMeanLuma
        var residual = [Double](repeating: 0, count: gridSize * gridSize)
        for index in 0..<(gridSize * gridSize) {
            residual[index] = abs(
                Double(signature[index]) -
                    (Double(reference[index]) + exposureShift)
            )
        }

        let windowSize = 6
        let corridorWidth = 17
        var strongestWindow = 0.0
        for row in stride(from: 1, through: gridSize - windowSize - 1, by: 2) {
            for column in stride(from: 1, through: gridSize - windowSize - 1, by: 2) {
                let touchesEntryCorridor =
                    column < corridorWidth ||
                    column + windowSize > gridSize - corridorWidth ||
                    row < 12 || row + windowSize > gridSize - 12
                guard touchesEntryCorridor else { continue }
                var total = 0.0
                var changedSamples = 0
                for localRow in 0..<windowSize {
                    for localColumn in 0..<windowSize {
                        let value = residual[
                            (row + localRow) * gridSize + column + localColumn
                        ]
                        total += value
                        if value > 16 { changedSamples += 1 }
                    }
                }
                let samples = Double(windowSize * windowSize)
                strongestWindow = max(
                    strongestWindow,
                    total / samples + Double(changedSamples) / samples * 28.0
                )
            }
        }
        return strongestWindow
    }

    private func localizedDarkIntrusion(
        _ frame: BufferedFrame,
        reference: [UInt8],
        referenceMeanLuma: Double
    ) -> Double {
        let gridSize = 48
        let count = min(frame.lumaSignature.count, reference.count)
        guard count >= gridSize * gridSize else { return 0 }

        // Remove a uniform exposure change. Only local regions that became
        // darker remain, which strongly separates the black toolhead from the
        // slowly growing printed model.
        let exposureShift = frame.meanLuma - referenceMeanLuma
        var darkResidual = [Double](repeating: 0, count: gridSize * gridSize)
        for index in 0..<(gridSize * gridSize) {
            let expected = Double(reference[index]) + exposureShift
            darkResidual[index] = max(0, expected - Double(frame.lumaSignature[index]))
        }

        let windowSize = 6
        let inset = 2
        var strongestWindow = 0.0
        for row in stride(
            from: inset,
            through: gridSize - inset - windowSize,
            by: 2
        ) {
            for column in stride(
                from: inset,
                through: gridSize - inset - windowSize,
                by: 2
            ) {
                var total = 0.0
                var stronglyDarkened = 0
                for localRow in 0..<windowSize {
                    for localColumn in 0..<windowSize {
                        let value = darkResidual[
                            (row + localRow) * gridSize + column + localColumn
                        ]
                        total += value
                        if value > 18 { stronglyDarkened += 1 }
                    }
                }
                let samples = Double(windowSize * windowSize)
                let mean = total / samples
                let density = Double(stronglyDarkened) / samples
                strongestWindow = max(strongestWindow, mean + density * 24.0)
            }
        }
        return strongestWindow
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
        captureFrameWaitDeadline = nil
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
        hardwareTorchGeneration &+= 1
        applyTorch(false)
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

        // A final temporal pass catches an occasional carriage frame even if
        // every one of the seven live candidates was imperfect. Isolated
        // outliers are replaced by the nearest clean neighbouring layer; the
        // frame count/timing stays unchanged, so print progress remains smooth.
        publishStatus("Đang lọc rung và đầu in khỏi video...")
        let renderFrameURLs = curatedFrameURLs(frameURLs)

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
            var previousRegistrationImage: CGImage?
            var accumulatedTranslation = CGPoint.zero
            for (index, url) in renderFrameURLs.enumerated() {
                while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.003) }
                autoreleasepool {
                    guard let image = UIImage(contentsOfFile: url.path),
                          let cgImage = normalizedCGImage(image),
                          let pool = adaptor.pixelBufferPool,
                          let buffer: CVPixelBuffer = {
                              if let previousRegistrationImage,
                                 let step = stabilizationTranslation(
                                    floating: cgImage,
                                    reference: previousRegistrationImage
                                 ) {
                                  // Reject a registration result that is too
                                  // large to be phone vibration. This prevents
                                  // growing model geometry from causing drift.
                                  let maxStepX = CGFloat(cgImage.width) * 0.035
                                  let maxStepY = CGFloat(cgImage.height) * 0.035
                                  if abs(step.x) <= maxStepX, abs(step.y) <= maxStepY {
                                      accumulatedTranslation.x += step.x
                                      accumulatedTranslation.y += step.y
                                  }
                                  let maxTotalX = CGFloat(cgImage.width) * 0.055
                                  let maxTotalY = CGFloat(cgImage.height) * 0.055
                                  accumulatedTranslation.x = min(
                                      maxTotalX,
                                      max(-maxTotalX, accumulatedTranslation.x)
                                  )
                                  accumulatedTranslation.y = min(
                                      maxTotalY,
                                      max(-maxTotalY, accumulatedTranslation.y)
                                  )
                              }
                              previousRegistrationImage = cgImage
                              return makePixelBuffer(
                                image: cgImage,
                                width: outputWidth,
                                height: outputHeight,
                                pool: pool,
                                stabilizationTranslation: accumulatedTranslation
                              )
                          }() else { return }
                    adaptor.append(
                        buffer,
                        withPresentationTime: CMTime(value: Int64(index), timescale: frameRate)
                    )
                }
                let progress = Double(index + 1) / Double(max(1, renderFrameURLs.count))
                if index % 12 == 0 || index == renderFrameURLs.count - 1 {
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

    private func stabilizationTranslation(
        floating: CGImage,
        reference: CGImage
    ) -> CGPoint? {
        let request = VNTranslationalImageRegistrationRequest(
            targetedCGImage: reference,
            options: [:]
        )
        let handler = VNImageRequestHandler(cgImage: floating, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return nil }
            let transform = observation.alignmentTransform
            return CGPoint(x: transform.tx, y: transform.ty)
        } catch {
            return nil
        }
    }

    private func curatedFrameURLs(_ frameURLs: [URL]) -> [URL] {
        guard frameURLs.count >= 7 else { return frameURLs }
        var signatures: [[UInt8]] = []
        var means: [Double] = []
        signatures.reserveCapacity(frameURLs.count)
        means.reserveCapacity(frameURLs.count)

        for url in frameURLs {
            let signature: [UInt8] = autoreleasepool {
                guard let image = UIImage(contentsOfFile: url.path),
                      let cgImage = normalizedCGImage(image) else { return [] }
                return makeLumaSignature(from: cgImage)
            }
            guard !signature.isEmpty else { return frameURLs }
            signatures.append(signature)
            means.append(signature.reduce(0.0) { $0 + Double($1) } /
                         Double(signature.count))
        }

        var rejected = Set<Int>()
        // Early layers can change a very large percentage of the tiny model
        // from one frame to the next. Let geometric stabilization handle that
        // opening section instead of mistaking real growth for an obstruction.
        let outlierFilterStart = max(3, Int(Double(signatures.count) * 0.20))
        for index in signatures.indices {
            guard index >= outlierFilterStart else { continue }
            let lower = max(0, index - 4)
            let upper = min(signatures.count - 1, index + 4)
            let neighbourIndices = (lower...upper).filter { $0 != index }
            guard neighbourIndices.count >= 4 else { continue }
            let median = temporalMedianSignature(
                indices: neighbourIndices,
                signatures: signatures
            )
            guard !median.isEmpty else { continue }
            let medianMean = median.reduce(0.0) { $0 + Double($1) } /
                Double(median.count)
            // Remove a small whole-frame camera shift before deciding that a
            // local object entered. Otherwise OIS vibration can look like a
            // toolhead along every high-contrast edge.
            let alignedCurrent = translationAlignedSignature(
                signatures[index],
                reference: median
            )
            let alignedMean = alignedCurrent.reduce(0.0) { $0 + Double($1) } /
                Double(alignedCurrent.count)
            let edgeIntrusion = localizedEdgeIntrusion(
                signature: alignedCurrent,
                meanLuma: alignedMean,
                reference: median,
                referenceMeanLuma: medianMean
            )
            let globalDifference = normalizedSignatureDifference(
                alignedCurrent,
                meanLuma: alignedMean,
                reference: median,
                referenceMeanLuma: medianMean
            )

            var temporalSpike = 0.0
            if index > 0, index + 1 < signatures.count {
                let beforeDifference = translationInvariantDifference(
                    signatures[index],
                    reference: signatures[index - 1]
                )
                let afterDifference = translationInvariantDifference(
                    signatures[index],
                    reference: signatures[index + 1]
                )
                let neighbourDifference = translationInvariantDifference(
                    signatures[index - 1],
                    reference: signatures[index + 1]
                )
                temporalSpike = min(beforeDifference, afterDifference) -
                    neighbourDifference * 0.58
            }

            // Two independent gates avoid deleting real geometry growth: a
            // large edge-local change must also be globally unusual, or it
            // must appear as an isolated temporal spike between clean layers.
            if (edgeIntrusion > 58 && globalDifference > 10) ||
                (edgeIntrusion > 42 && temporalSpike > 10) {
                rejected.insert(index)
            }
        }

        guard !rejected.isEmpty else { return frameURLs }
        var curated = frameURLs
        for index in rejected {
            for distance in 1...5 {
                let candidates = [index - distance, index + distance]
                if let replacement = candidates.first(where: {
                    $0 >= 0 && $0 < frameURLs.count && !rejected.contains($0)
                }) {
                    curated[index] = frameURLs[replacement]
                    break
                }
            }
        }
        return curated
    }

    private func temporalMedianSignature(
        indices: [Int],
        signatures: [[UInt8]]
    ) -> [UInt8] {
        guard let firstIndex = indices.first else { return [] }
        let count = signatures[firstIndex].count
        guard count > 0 else { return [] }
        var result = [UInt8](repeating: 0, count: count)
        for sample in 0..<count {
            let values = indices.map { signatures[$0][sample] }.sorted()
            result[sample] = values[values.count / 2]
        }
        return result
    }

    private func translationInvariantDifference(
        _ signature: [UInt8],
        reference: [UInt8]
    ) -> Double {
        let aligned = translationAlignedSignature(signature, reference: reference)
        guard !aligned.isEmpty, !reference.isEmpty else { return 0 }
        let alignedMean = aligned.reduce(0.0) { $0 + Double($1) } /
            Double(aligned.count)
        let referenceMean = reference.reduce(0.0) { $0 + Double($1) } /
            Double(reference.count)
        return normalizedSignatureDifference(
            aligned,
            meanLuma: alignedMean,
            reference: reference,
            referenceMeanLuma: referenceMean
        )
    }

    private func translationAlignedSignature(
        _ signature: [UInt8],
        reference: [UInt8]
    ) -> [UInt8] {
        let gridSize = 48
        guard signature.count >= gridSize * gridSize,
              reference.count >= gridSize * gridSize else { return signature }
        let signatureMean = signature.reduce(0.0) { $0 + Double($1) } /
            Double(signature.count)
        let referenceMean = reference.reduce(0.0) { $0 + Double($1) } /
            Double(reference.count)
        let exposureShift = signatureMean - referenceMean
        var bestOffset = (x: 0, y: 0)
        var bestDifference = Double.greatestFiniteMagnitude
        let margin = 5

        for offsetY in -2...2 {
            for offsetX in -2...2 {
                var difference = 0.0
                var samples = 0
                for row in margin..<(gridSize - margin) {
                    let sourceRow = row + offsetY
                    guard sourceRow >= 0, sourceRow < gridSize else { continue }
                    for column in margin..<(gridSize - margin) {
                        let sourceColumn = column + offsetX
                        guard sourceColumn >= 0, sourceColumn < gridSize else { continue }
                        difference += abs(
                            Double(signature[sourceRow * gridSize + sourceColumn]) -
                                exposureShift -
                                Double(reference[row * gridSize + column])
                        )
                        samples += 1
                    }
                }
                guard samples > 0 else { continue }
                let average = difference / Double(samples)
                if average < bestDifference {
                    bestDifference = average
                    bestOffset = (offsetX, offsetY)
                }
            }
        }

        var aligned = reference
        for row in 0..<gridSize {
            let sourceRow = row + bestOffset.y
            guard sourceRow >= 0, sourceRow < gridSize else { continue }
            for column in 0..<gridSize {
                let sourceColumn = column + bestOffset.x
                guard sourceColumn >= 0, sourceColumn < gridSize else { continue }
                aligned[row * gridSize + column] =
                    signature[sourceRow * gridSize + sourceColumn]
            }
        }
        return aligned
    }

    private func makeLumaSignature(from image: CGImage) -> [UInt8] {
        let width = 48
        let height = 48
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? pixels : []
    }

    private func makePixelBuffer(
        image: CGImage,
        width: Int,
        height: Int,
        pool: CVPixelBufferPool,
        stabilizationTranslation: CGPoint = .zero
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
        // A small invisible overscan provides room for translation correction
        // without exposing black edges. It is only 4.5%, on top of the user's
        // existing 1.5x camera zoom.
        let scale = max(CGFloat(width) / CGFloat(image.width),
                        CGFloat(height) / CGFloat(image.height)) * 1.045
        let drawWidth = CGFloat(image.width) * scale
        let drawHeight = CGFloat(image.height) * scale
        let rect = CGRect(
            x: (CGFloat(width) - drawWidth) / 2 + stabilizationTranslation.x * scale,
            y: (CGFloat(height) - drawHeight) / 2 - stabilizationTranslation.y * scale,
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

    private func runHardwareTorchBlink(generation: Int, turnOn: Bool) {
        guard generation == hardwareTorchGeneration, !isRendering else { return }
        applyTorch(turnOn)
        // Slightly asymmetric on/off timing resembles a moving film shutter
        // and remains responsive when the physical button is released.
        let delay = turnOn ? 0.11 : 0.08
        sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.hardwareTorchGeneration else { return }
            self.runHardwareTorchBlink(generation: generation, turnOn: !turnOn)
        }
    }

    private func enterFlashDisplayMode() {
        publishOnMain {
            if !self.isFlashModeActive {
                self.brightnessBeforeFlashMode = UIScreen.main.brightness
            }
            self.isFlashModeActive = true
            UIApplication.shared.isIdleTimerDisabled = true
            UIScreen.main.brightness = 0.0
        }
    }

    private func leaveFlashDisplayMode() {
        publishOnMain {
            guard self.isFlashModeActive || self.brightnessBeforeFlashMode != nil else { return }
            self.isFlashModeActive = false
            if let brightness = self.brightnessBeforeFlashMode {
                UIScreen.main.brightness = brightness
                self.brightnessBeforeFlashMode = nil
            }
        }
    }

    private func applyTorch(_ enabled: Bool) {
        guard let camera = captureDevice, camera.hasTorch else {
            publishOnMain {
                self.canUseTorch = false
                self.isTorchEnabled = false
            }
            return
        }
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            if enabled && camera.isTorchAvailable {
                try camera.setTorchModeOn(level: min(0.65, AVCaptureDevice.maxAvailableTorchLevel))
            } else {
                camera.torchMode = .off
            }
            let active = camera.torchMode == .on
            publishOnMain {
                self.canUseTorch = camera.isTorchAvailable || active
                self.isTorchEnabled = active
            }
        } catch {
            publishOnMain {
                self.isTorchEnabled = false
                self.statusText = "Không bật được đèn flash của iPhone"
            }
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
        let motionScore: Double
        if let previous = bufferedFrames.last {
            motionScore = normalizedSignatureDifference(
                signature,
                meanLuma: mean,
                reference: previous.lumaSignature,
                referenceMeanLuma: previous.meanLuma
            )
        } else {
            motionScore = 0
        }
        bufferedFrames.append(
            BufferedFrame(
                pixelBuffer: ownedPixelBuffer,
                timestamp: timestamp,
                lumaSignature: signature,
                meanLuma: mean,
                centerMeanLuma: centerStats.mean,
                centerDarkRatio: centerStats.darkRatio,
                motionScore: motionScore
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

    private func normalizedSignatureDifference(
        _ signature: [UInt8],
        meanLuma: Double,
        reference: [UInt8],
        referenceMeanLuma: Double
    ) -> Double {
        let count = min(signature.count, reference.count)
        guard count > 0 else { return 0 }
        let exposureShift = meanLuma - referenceMeanLuma
        var difference = 0.0
        for index in 0..<count {
            difference += abs(
                Double(signature[index]) -
                    (Double(reference[index]) + exposureShift)
            )
        }
        return difference / Double(count)
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
        // Leaving the view/app must never strand the phone at the minimum
        // brightness, even if the physical switch is still in flash mode.
        isFlashModeActive = false
        if let brightness = brightnessBeforeFlashMode {
            UIScreen.main.brightness = brightness
            brightnessBeforeFlashMode = nil
        }
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
