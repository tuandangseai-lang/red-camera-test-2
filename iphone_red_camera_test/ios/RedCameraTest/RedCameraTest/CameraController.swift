import AVFoundation
import Photos
import SwiftUI

final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var statusText = "Đang chuẩn bị camera..."
    @Published private(set) var redPercent = 0.0
    @Published private(set) var zoomText = "1.0×"
    @Published private(set) var isReady = false
    @Published private(set) var isArmed = false
    @Published private(set) var isRecording = false
    @Published private(set) var canRetry = false

    var onEvent: ((String) -> Void)?

    private let sessionQueue = DispatchQueue(label: "vn.rockettracker.camera.session")
    private let videoQueue = DispatchQueue(label: "vn.rockettracker.camera.frames")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()

    private var videoDevice: AVCaptureDevice?
    private var didRequestStart = false
    private var configured = false
    private var pendingArm = false
    private var armedForDetection = false
    private var recordingActive = false
    private var alreadyTriggered = false
    private var analyzedFrameNumber = 0
    private var consecutiveRedFrames = 0
    private var outputURL: URL?

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

    func arm() {
        guard !isRecording else { return }
        guard isReady else {
            pendingArm = true
            statusText = "Đã nhận ARM; đang chờ camera sẵn sàng..."
            return
        }

        pendingArm = false

        videoQueue.async { [weak self] in
            guard let self else { return }
            self.armedForDetection = true
            self.alreadyTriggered = false
            self.consecutiveRedFrames = 0
            self.analyzedFrameNumber = 0
        }

        isArmed = true
        canRetry = false
        redPercent = 0
        statusText = "Đang chờ thấy vật màu đỏ..."
        onEvent?("ARMED")
    }

    func retryTest() {
        guard !isRecording else { return }
        arm()
    }

    func stopRecording() {
        cancelZoomSequence()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
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
            if self.pendingArm {
                self.arm()
            } else {
                self.statusText = "Camera sẵn sàng; đang chờ lệnh ARM từ ESP32"
            }
        }
    }

    private func beginRecording() {
        guard isReady, !isRecording else { return }

        isArmed = false
        canRetry = false
        statusText = "Đã thấy màu đỏ — đang bắt đầu quay..."
        onEvent?("RED_DETECTED")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rocket-test-\(UUID().uuidString).mov")
        outputURL = url

        videoQueue.async { [weak self] in
            self?.recordingActive = true
            self?.armedForDetection = false
        }

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

        // 0...5 s: 1×; 5...7,5 s: lên 2×; 7,5...10 s: trở về 1×.
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
                self.canRetry = true
                if saved {
                    self.statusText = "Đã lưu video vào ứng dụng Ảnh"
                    self.onEvent?("VIDEO_SAVED")
                } else {
                    self.statusText = "Quay xong nhưng chưa lưu được: \(error?.localizedDescription ?? "thiếu quyền Ảnh")"
                    self.onEvent?("SAVE_FAILED")
                }
            }
        }
    }

    private func redPixelRatio(in pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)

        // Bỏ viền ngoài 10%, lấy mẫu cách 6 pixel để giảm tải cho iPhone.
        let xStart = width / 10
        let xEnd = width - xStart
        let yStart = height / 10
        let yEnd = height - yStart
        let sampleStep = 6
        var redCount = 0
        var sampleCount = 0

        for y in stride(from: yStart, to: yEnd, by: sampleStep) {
            let row = pixels.advanced(by: y * bytesPerRow)
            for x in stride(from: xStart, to: xEnd, by: sampleStep) {
                let offset = x * 4
                let blue = Int(row[offset])
                let green = Int(row[offset + 1])
                let red = Int(row[offset + 2])
                sampleCount += 1

                let stronglyRed = red >= 150
                    && red >= Int(Double(green) * 1.50)
                    && red >= Int(Double(blue) * 1.35)
                    && red - max(green, blue) >= 45
                if stronglyRed { redCount += 1 }
            }
        }

        guard sampleCount > 0 else { return 0 }
        return Double(redCount) / Double(sampleCount)
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard armedForDetection, !recordingActive, !alreadyTriggered else { return }

        analyzedFrameNumber += 1
        guard analyzedFrameNumber % 3 == 0,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ratio = redPixelRatio(in: pixelBuffer)
        DispatchQueue.main.async { [weak self] in
            self?.redPercent = ratio * 100
        }

        if ratio >= 0.025 {
            consecutiveRedFrames += 1
        } else {
            consecutiveRedFrames = 0
        }

        // 4 khung phân tích liên tiếp giúp tránh lóe đỏ gây quay nhầm.
        if consecutiveRedFrames >= 4 {
            alreadyTriggered = true
            armedForDetection = false
            DispatchQueue.main.async { [weak self] in
                self?.beginRecording()
            }
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
            self.statusText = "Đang quay — 5 giây nữa bắt đầu zoom"
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
            self?.recordingActive = false
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cancelZoomSequence()
            self.resetZoom()
            self.isRecording = false
            self.zoomText = "1.0×"
            self.statusText = "Đã dừng, đang lưu video..."
            self.onEvent?("RECORDING_STOPPED")

            if let error {
                self.canRetry = true
                self.statusText = "Lỗi quay video: \(error.localizedDescription)"
                try? FileManager.default.removeItem(at: outputFileURL)
            } else {
                self.saveVideoToPhotos(outputFileURL)
            }
        }
    }
}
