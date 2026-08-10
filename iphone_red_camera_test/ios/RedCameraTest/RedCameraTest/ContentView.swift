import Foundation
import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var ble = BLEManager()

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            trackingOverlay
                .ignoresSafeArea()

            VStack(spacing: 12) {
                statusPanel
                Spacer()
                controls
            }
            .padding()
        }
        .background(Color.black)
        .onAppear {
            ble.onArm = { [weak camera] in
                camera?.arm()
            }
            camera.onEvent = { [weak ble] message in
                ble?.sendStatus(message)
            }
            camera.start()
        }
    }

    private var trackingOverlay: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if camera.stage.showsGuide {
                    let rect = mappedRect(camera.scanRect, in: geometry.size)
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            camera.stage == .ready ? Color.green : Color.yellow,
                            style: StrokeStyle(lineWidth: 3, dash: [10, 6])
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)

                    Text(guideLabel)
                        .font(.caption.bold())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(camera.stage == .ready ? Color.green : Color.yellow, in: Capsule())
                        .position(x: rect.midX, y: max(18, rect.minY - 16))
                }

                if let target = camera.targetRect, camera.stage == .tracking {
                    let rect = mappedRect(target, in: geometry.size)
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.green, lineWidth: 4)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)

                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var guideLabel: String {
        switch camera.stage {
        case .idle, .scanningNear:
            return "KHUNG QUÉT GẦN"
        case .waitingFar, .scanningFar:
            return "KHUNG QUÉT XA"
        case .waitingAround, .scanningAround:
            return "ĐỔI GÓC / XOAY QUANH"
        case .ready, .verifying, .lost:
            return "ĐẶT TÊN LỬA VÀO ĐÂY"
        case .tracking:
            return ""
        }
    }

    private func mappedRect(_ normalized: CGRect, in viewSize: CGSize) -> CGRect {
        let sourceWidth = max(0.1, camera.frameAspectRatio)
        let sourceHeight: CGFloat = 1.0
        let scale = max(viewSize.width / sourceWidth, viewSize.height / sourceHeight)
        let displayedWidth = sourceWidth * scale
        let displayedHeight = sourceHeight * scale
        let offsetX = (viewSize.width - displayedWidth) / 2.0
        let offsetY = (viewSize.height - displayedHeight) / 2.0
        return CGRect(
            x: offsetX + normalized.minX * displayedWidth,
            y: offsetY + normalized.minY * displayedHeight,
            width: normalized.width * displayedWidth,
            height: normalized.height * displayedHeight
        )
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                ble.connectionText,
                systemImage: ble.isConnected
                    ? "antenna.radiowaves.left.and.right"
                    : "bolt.horizontal.circle"
            )
            Text(camera.statusText)
                .font(.headline)
            HStack {
                Text("Mẫu học: \(camera.learnedSamples)")
                Spacer()
                Text("Zoom: \(camera.zoomText)")
                    .monospacedDigit()
            }
            Text(camera.matchText)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            if camera.stage.isScanning {
                ProgressView(value: camera.scanProgress)
                    .tint(.yellow)
                    .padding(.horizontal)
                Text("Giữ tên lửa nằm trọn trong khung cho đến khi quét xong")
                    .font(.footnote)
                    .foregroundStyle(.white)
            } else {
                scanSizeControl
                actionButtons
            }

            Text("Tên lửa có thể là bất kỳ màu nào • giữ app mở và màn hình không khóa")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.58), in: Capsule())
        }
        .padding(12)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
    }

    private var scanSizeControl: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $camera.scanBoxScale, in: 0.12...0.62)
                    .tint(.yellow)
                Image(systemName: "plus.magnifyingglass")
            }
            Text("Chỉnh khung vừa sát thân tên lửa trước khi quét/khóa")
                .font(.caption)
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch camera.stage {
        case .idle:
            primaryButton("Quét gần 5 giây", systemImage: "viewfinder") {
                camera.startNearScan()
            }
            .disabled(!camera.isReady)

        case .waitingFar:
            primaryButton("Quét xa 5 giây", systemImage: "arrow.up.left.and.arrow.down.right") {
                camera.startFarScan()
            }

        case .waitingAround:
            primaryButton("Quét xung quanh 8 giây", systemImage: "rotate.3d") {
                camera.startAroundScan()
            }

        case .ready:
            primaryButton("Khóa, bám và bắt đầu quay", systemImage: "scope") {
                camera.startTrackingAndRecording()
            }
            HStack {
                secondaryButton("Quét thêm góc", systemImage: "camera.viewfinder") {
                    camera.startAroundScan()
                }
                secondaryButton("Học lại", systemImage: "trash") {
                    camera.resetProfile()
                }
            }

        case .verifying:
            ProgressView("Đang xác minh mục tiêu...")
                .tint(.white)
                .foregroundStyle(.white)

        case .tracking:
            if camera.isRecording {
                Button(role: .destructive) {
                    camera.stopRecording()
                } label: {
                    Label("Dừng và lưu video", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

        case .lost:
            primaryButton("Bắt lại mục tiêu", systemImage: "scope") {
                camera.reacquireTarget()
            }
            if camera.isRecording {
                Button(role: .destructive) {
                    camera.stopRecording()
                } label: {
                    Label("Dừng và lưu video", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

        case .scanningNear, .scanningFar, .scanningAround:
            EmptyView()
        }
    }

    private func primaryButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    private func secondaryButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.white)
    }
}
