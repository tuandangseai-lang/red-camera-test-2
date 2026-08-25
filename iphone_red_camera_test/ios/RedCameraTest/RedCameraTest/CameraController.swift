import AVFoundation
import Photos
import SwiftUI
import UIKit

final class CameraController: NSObject, ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
    @Published private(set) var statusText = "Đang chuẩn bị camera 0,5×..."
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var lastSaveSucceeded = false

    let session = AVCaptureSession()

    // On a physical ultra-wide camera, AVFoundation factor 1.0 is the
    // user-facing 0.5× view. Never ramp or switch lenses while tracking:
    // changing geometry would make the MaixCAM/iPhone alignment appear to jump.
    private static let lockedUltraWideZoomFactor: CGFloat = 1.0

    private let sessionQueue = DispatchQueue(label: "vn.se.camera.session", qos: .userInitiated)
    private let movieOutput = AVCaptureMovieFileOutput()
    private let voice = VoiceNotifier()
    private var configured = false
    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?
    private var activeTemporaryURL: URL?

    func prepare() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    self.statusText = "Hãy cấp quyền Camera cho SE"
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.sessionQueue.async {
                    self.configureIfNeeded()
                    self.startSessionIfNeeded()
                }
            }
        }
    }

    func resume() {
        sessionQueue.async { [weak self] in
            self?.startSessionIfNeeded()
        }
    }

    func suspend() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        sessionQueue.async { [weak self] in
            guard let self, self.configured, !self.movieOutput.isRecording else { return }
            self.startSessionIfNeeded()
            guard self.session.isRunning else { return }

            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("SE-\(UUID().uuidString).mov")
            self.activeTemporaryURL = temporaryURL
            self.configureRecordingConnection()
            self.movieOutput.startRecording(to: temporaryURL, recordingDelegate: self)
            DispatchQueue.main.async {
                self.isRecording = true
                self.lastSaveSucceeded = false
                self.statusText = "Đang quay • MaixCAM bám mục tiêu"
                self.recordingStartedAt = Date()
                self.elapsedSeconds = 0
                self.startElapsedTimer()
                self.voice.speak("Bắt đầu quay và bám mục tiêu", kind: .start)
            }
        }
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
            DispatchQueue.main.async {
                self.statusText = "Đang lưu video..."
                self.stopElapsedTimer()
            }
        }
    }

    func announceHome() {
        voice.speak("Về lại trạng thái đầu", kind: .success)
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        defer { session.commitConfiguration() }

        guard let camera = AVCaptureDevice.default(
            .builtInUltraWideCamera,
            for: .video,
            position: .back
        ) ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
        let videoInput = try? AVCaptureDeviceInput(device: camera),
        session.canAddInput(videoInput) else {
            DispatchQueue.main.async { self.statusText = "Không mở được camera sau" }
            return
        }
        session.addInput(videoInput)
        configureCamera(camera)

        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let microphone = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        guard session.canAddOutput(movieOutput) else {
            DispatchQueue.main.async { self.statusText = "Không tạo được đầu ghi video" }
            return
        }
        session.addOutput(movieOutput)
        movieOutput.movieFragmentInterval = .invalid
        configureRecordingConnection()
        configured = true
        DispatchQueue.main.async {
            self.isReady = true
            self.statusText = "Camera 0,5× cố định • sẵn sàng"
        }
    }

    private func configureCamera(_ camera: AVCaptureDevice) {
        // MaixCAM performs all AI work.  Recording 4K60 on the iPhone adds no
        // tracking accuracy but is the dominant source of heat and throttling.
        // 1080p60 preserves the fast water-rocket motion while using far less
        // encoder bandwidth and memory pressure.
        let preferred = camera.formats
            .filter { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dimensions.width == 1920, dimensions.height == 1080 else { return false }
                return format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 59.0 }
            }
            .max { lhs, rhs in
                lhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                    < rhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            }
            ?? camera.formats
                .filter { format in
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    return dimensions.width == 1920 && dimensions.height == 1080
                }
                .max { lhs, rhs in
                    let left = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                    let right = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                    return left.width * left.height < right.width * right.height
                }

        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            if let preferred {
                camera.activeFormat = preferred
                if preferred.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 59.0 }) {
                    camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
                    camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
                } else {
                    camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                    camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                }
            }
            camera.cancelVideoZoomRamp()
            camera.videoZoomFactor = min(
                camera.maxAvailableVideoZoomFactor,
                max(camera.minAvailableVideoZoomFactor,
                    Self.lockedUltraWideZoomFactor)
            )
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
        } catch {
            DispatchQueue.main.async {
                self.statusText = "Camera dùng cấu hình an toàn"
            }
        }
    }

    private func configureRecordingConnection() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoStabilizationSupported {
            // The phone is already on a powered gimbal. Standard stabilization
            // avoids the extra crop/compute cost of Cinematic stabilization.
            connection.preferredVideoStabilizationMode = .standard
        }
        if movieOutput.availableVideoCodecTypes.contains(.hevc) {
            movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
        }
    }

    private func startSessionIfNeeded() {
        configureIfNeeded()
        guard configured, !session.isRunning else { return }
        session.startRunning()
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let started = self.recordingStartedAt else { return }
            self.elapsedSeconds = max(0, Int(Date().timeIntervalSince(started)))
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartedAt = nil
    }

    private func saveVideo(at url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.statusText = "Hãy cấp quyền thêm video vào Ảnh"
                    self.isRecording = false
                }
                try? FileManager.default.removeItem(at: url)
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, _ in
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.lastSaveSucceeded = success
                    self.statusText = success ? "Đã lưu video vào Ảnh" : "Lưu video chưa thành công"
                    self.voice.speak(
                        success ? "Đã dừng quay và lưu video" : "Không lưu được video",
                        kind: success ? .success : .warning
                    )
                }
            }
        }
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        DispatchQueue.main.async {
            self.stopElapsedTimer()
        }
        if let error,
           (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true {
            try? FileManager.default.removeItem(at: outputFileURL)
            DispatchQueue.main.async {
                self.isRecording = false
                self.statusText = "Video bị gián đoạn"
                self.voice.speak("Video bị gián đoạn", kind: .warning)
            }
            return
        }
        saveVideo(at: outputFileURL)
    }
}
