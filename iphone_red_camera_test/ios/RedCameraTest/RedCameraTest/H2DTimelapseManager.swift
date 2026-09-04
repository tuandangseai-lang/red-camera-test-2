import AVFoundation
import Photos
import SwiftUI
import UIKit

final class H2DTimelapseManager: NSObject, ObservableObject {
    @Published private(set) var isCameraReady = false
    @Published private(set) var isArmed = false
    @Published private(set) var isCapturing = false
    @Published private(set) var isRendering = false
    @Published private(set) var capturedFrameCount = 0
    @Published private(set) var lastCapturedLayer = 0
    @Published private(set) var statusText = "Căn khung hình rồi bật chờ H2D"
    @Published private(set) var lastVideoSaved = false

    let previewSession = AVCaptureSession()

    var didStoreFrame: ((Int, Bool) -> Void)?

    private struct CaptureRequest: Equatable {
        let layer: Int
        let totalLayers: Int
        let jobID: String
    }

    private let sessionQueue = DispatchQueue(label: "vn.se.h2d.camera", qos: .userInitiated)
    private let renderQueue = DispatchQueue(label: "vn.se.h2d.render", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private var configured = false
    private var preparing = false
    private var pendingRequests: [CaptureRequest] = []
    private var currentRequest: CaptureRequest?
    private var capturedLayers = Set<Int>()
    private var sessionDirectory: URL?
    private var finishRequested = false
    private var cameraStopWorkItem: DispatchWorkItem?
    private var originalBrightness: CGFloat?
    private var lastJobID = ""

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
            guard let self, !self.isArmed, self.previewSession.isRunning else { return }
            self.previewSession.stopRunning()
        }
    }

    func arm() {
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
                self.beginNewRun()
            }
        }
    }

    func disarm(deleteFrames: Bool = false) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.finishRequested = false
            self.pendingRequests.removeAll()
            self.currentRequest = nil
            self.cameraStopWorkItem?.cancel()
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
                self.statusText = deleteFrames
                    ? "Đã dừng và xóa ảnh của lần chụp này"
                    : "Đã dừng chờ H2D"
                self.restoreDisplay()
            }
        }
    }

    func handle(_ event: H2DTimelapseEvent) {
        switch event.kind {
        case .snapshot:
            enqueueSnapshot(layer: event.layer, totalLayers: event.totalLayers, jobID: event.jobID)
        case .finished:
            requestFinish(jobID: event.jobID)
        case .error:
            publishStatus(event.message)
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if isArmed {
                UIApplication.shared.isIdleTimerDisabled = true
                setDimmedDisplay()
            }
        case .inactive, .background:
            if isArmed {
                publishStatus("SE phải mở ở màn hình trước để iPhone được phép chụp")
            }
            sessionQueue.async { [weak self] in
                guard let self, self.previewSession.isRunning else { return }
                self.previewSession.stopRunning()
            }
        @unknown default:
            break
        }
    }

    func captureTestFrame() {
        guard isArmed else {
            publishStatus("Hãy bật chờ H2D trước khi chụp thử")
            return
        }
        let layer = max(1, lastCapturedLayer + 1)
        enqueueSnapshot(layer: layer, totalLayers: layer, jobID: "TEST")
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
        previewSession.sessionPreset = .photo

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
           previewSession.canAddOutput(photoOutput) else {
            publishStatus("Không mở được camera sau của iPhone")
            return
        }

        previewSession.addInput(input)
        previewSession.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .speed

        let dimensions = camera.activeFormat.supportedMaxPhotoDimensions
            .filter { Int64($0.width) * Int64($0.height) <= 8_500_000 }
            .max { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
        if let dimensions { photoOutput.maxPhotoDimensions = dimensions }

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
            self.statusText = "Camera đã sẵn sàng • căn khung hình rồi bật chờ H2D"
        }
    }

    private func beginNewRun() {
        cameraStopWorkItem?.cancel()
        pendingRequests.removeAll()
        currentRequest = nil
        capturedLayers.removeAll()
        capturedFrameCount = 0
        lastCapturedLayer = 0
        finishRequested = false
        lastVideoSaved = false
        lastJobID = ""

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SE-H2D-Timelapse", isDirectory: true)
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
            self.statusText = "Màn hình tối • đang chờ lớp in đầu tiên"
            self.setDimmedDisplay()
            UIApplication.shared.isIdleTimerDisabled = true
        }

        // Warm only for setup. It will sleep after the first quiet interval.
        startSessionIfNeeded()
        scheduleCameraSleep(after: 1.2)
    }

    private func enqueueSnapshot(layer: Int, totalLayers: Int, jobID: String) {
        sessionQueue.async { [weak self] in
            guard let self, self.isArmed, layer > 0,
                  !self.capturedLayers.contains(layer),
                  self.currentRequest?.layer != layer,
                  !self.pendingRequests.contains(where: { $0.layer == layer }) else { return }
            if !jobID.isEmpty, jobID != "0", jobID != "TEST" {
                self.lastJobID = jobID
            }
            self.pendingRequests.append(
                CaptureRequest(layer: layer, totalLayers: totalLayers, jobID: jobID)
            )
            self.pendingRequests.sort { $0.layer < $1.layer }
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
        cameraStopWorkItem?.cancel()
        startSessionIfNeeded()
        publishOnMain {
            self.isCapturing = true
            self.statusText = "Đang chụp lớp \(request.layer)/\(max(request.layer, request.totalLayers))"
        }

        // A short warm-up lets exposure settle after the low-heat camera sleep.
        sessionQueue.asyncAfter(deadline: .now() + 0.38) { [weak self] in
            guard let self, self.currentRequest == request,
                  self.previewSession.isRunning else {
                self?.finishCurrentCapture(success: false)
                return
            }
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                settings = AVCapturePhotoSettings(
                    format: [AVVideoCodecKey: AVVideoCodecType.jpeg]
                )
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.photoQualityPrioritization = .speed
            if self.photoOutput.maxPhotoDimensions.width > 0 {
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            }
            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func finishCurrentCapture(success: Bool) {
        let finishedLayer = currentRequest?.layer ?? 0
        currentRequest = nil
        publishOnMain {
            self.isCapturing = false
            if success {
                self.capturedFrameCount = self.capturedLayers.count
                self.lastCapturedLayer = max(self.lastCapturedLayer, finishedLayer)
                self.statusText = "Đã chụp lớp \(finishedLayer) • camera đang nghỉ"
            } else {
                self.statusText = "Chụp lớp \(finishedLayer) lỗi • chờ tín hiệu tiếp theo"
            }
            self.didStoreFrame?(finishedLayer, success)
        }
        if pendingRequests.isEmpty {
            scheduleCameraSleep(after: 0.9)
        }
        captureNextIfNeeded()
    }

    private func scheduleCameraSleep(after seconds: TimeInterval) {
        cameraStopWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.currentRequest == nil, self.pendingRequests.isEmpty,
                  self.previewSession.isRunning else { return }
            self.previewSession.stopRunning()
        }
        cameraStopWorkItem = item
        sessionQueue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func requestFinish(jobID: String) {
        sessionQueue.async { [weak self] in
            guard let self, self.isArmed else { return }
            self.finishRequested = true
            if !jobID.isEmpty, jobID != "0" { self.lastJobID = jobID }
            self.publishStatus("H2D đã in xong • đang hoàn tất ảnh cuối")
            self.completeRunIfPossible()
        }
    }

    private func completeRunIfPossible() {
        guard finishRequested, currentRequest == nil, pendingRequests.isEmpty,
              !isRendering else { return }
        finishRequested = false
        cameraStopWorkItem?.cancel()
        if previewSession.isRunning { previewSession.stopRunning() }
        guard let directory = sessionDirectory, !capturedLayers.isEmpty else {
            publishStatus("H2D đã xong nhưng chưa có ảnh để ghép")
            DispatchQueue.main.async {
                self.isArmed = false
                self.restoreDisplay()
            }
            return
        }

        DispatchQueue.main.async {
            self.isRendering = true
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
            .appendingPathComponent("SE-H2D-\(lastJobID.isEmpty ? UUID().uuidString : lastJobID).mp4")
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
                        ? "Đã ghép và lưu timelapse H2D vào Ảnh"
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
            self.lastVideoSaved = success
            self.statusText = message
            self.restoreDisplay()
        }
    }

    private func startSessionIfNeeded() {
        configureIfNeeded()
        guard configured, !previewSession.isRunning else { return }
        previewSession.startRunning()
    }

    private func setDimmedDisplay() {
        if originalBrightness == nil { originalBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = 0.01
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

extension H2DTimelapseManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        sessionQueue.async { [weak self] in
            guard let self, let request = self.currentRequest,
                  error == nil,
                  let data = photo.fileDataRepresentation(),
                  let directory = self.sessionDirectory else {
                self?.finishCurrentCapture(success: false)
                return
            }
            do {
                try data.write(to: self.frameURL(for: request.layer, in: directory), options: .atomic)
                self.capturedLayers.insert(request.layer)
                self.finishCurrentCapture(success: true)
            } catch {
                self.finishCurrentCapture(success: false)
            }
        }
    }
}

struct H2DCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.layerView.session = session
        view.layerView.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.layerView.session = session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var layerView: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
