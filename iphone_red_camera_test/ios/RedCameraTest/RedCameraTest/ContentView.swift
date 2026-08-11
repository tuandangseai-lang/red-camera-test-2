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
                    let guideColor: Color = camera.stage.isScanning
                        ? scanStatusColor
                        : (camera.stage == .ready ? .green : .yellow)
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            guideColor,
                            style: StrokeStyle(
                                lineWidth: camera.stage.isScanning ? 4 : 3,
                                dash: camera.stage.isScanning ? [] : [10, 6]
                            )
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)

                    Text(guideLabel)
                        .font(.caption.bold())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(guideColor, in: Capsule())
                        .position(x: rect.midX, y: max(18, rect.minY - 16))

                    if camera.stage.isScanning {
                        scanProgressRing
                            .position(
                                x: scanRingX(for: rect, viewWidth: geometry.size.width),
                                y: max(54, rect.minY + 44)
                            )
                    }
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

    private var scanProgressRing: some View {
        let progress = max(0, min(camera.scanProgress, 1))
        let color = scanStatusColor

        return ZStack {
            Circle()
                .fill(.black.opacity(0.68))
            Circle()
                .stroke(.white.opacity(0.22), lineWidth: 7)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 1) {
                if camera.scanIsSufficient {
                    Image(systemName: "checkmark")
                        .font(.title2.bold())
                } else {
                    Text("\(Int(progress * 100))%")
                        .font(.headline.monospacedDigit())
                }
                Text(
                    camera.scanIsSufficient
                        ? "ĐÃ ĐỦ"
                        : (camera.scanNeedsNewAngle ? "GÓC TRÙNG" : "CHƯA ĐỦ")
                )
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(color)
        }
        .frame(width: 76, height: 76)
        .shadow(color: color.opacity(0.45), radius: 8)
    }

    private var scanStatusColor: Color {
        if camera.scanIsSufficient { return .green }
        if camera.scanNeedsNewAngle { return .orange }
        return .yellow
    }

    private func scanRingX(for rect: CGRect, viewWidth: CGFloat) -> CGFloat {
        let right = rect.maxX + 46
        if right <= viewWidth - 40 { return right }
        return max(40, rect.minX - 46)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Label(
                    ble.connectionText,
                    systemImage: ble.isConnected
                        ? "antenna.radiowaves.left.and.right"
                        : "bolt.horizontal.circle"
                )
                .lineLimit(1)
                Spacer(minLength: 4)
                Label("\(camera.learnedSamples)", systemImage: "square.stack.3d.up")
                Text(camera.zoomText)
                    .monospacedDigit()
            }
            .font(.caption.bold())

            Text(camera.statusText)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            if camera.stage == .verifying || camera.stage == .tracking || camera.stage == .lost {
                Text(camera.matchText)
                    .font(.caption)
                    .foregroundStyle(.cyan)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.70), in: RoundedRectangle(cornerRadius: 13))
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 8) {
            if camera.stage.isScanning {
                HStack(spacing: 8) {
                    Image(
                        systemName: camera.scanIsSufficient
                            ? "checkmark.circle.fill"
                            : (camera.scanNeedsNewAngle
                               ? "arrow.triangle.2.circlepath.circle.fill"
                               : "viewfinder.circle")
                    )
                    .foregroundStyle(scanStatusColor)
                    Text(camera.scanGuidanceText)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(camera.scanSampleCount)/\(camera.scanSampleTarget)")
                        .font(.caption.monospacedDigit().bold())
                }
                .foregroundStyle(.white)
            } else {
                compactSettings
                actionButtons
            }
        }
        .padding(8)
        .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 14))
    }

    private var compactSettings: some View {
        HStack(spacing: 9) {
            Image(systemName: "viewfinder")
                .foregroundStyle(.yellow)
            Slider(value: $camera.scanBoxScale, in: 0.12...0.62)
                .tint(.yellow)
            Button {
                camera.voiceAnnouncementsEnabled.toggle()
            } label: {
                Image(systemName: camera.voiceAnnouncementsEnabled
                      ? "speaker.wave.2.fill"
                      : "speaker.slash.fill")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(camera.voiceAnnouncementsEnabled ? .green : .gray)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch camera.stage {
        case .idle:
            primaryButton("Quét gần 5s", systemImage: "viewfinder") {
                camera.startNearScan()
            }
            .disabled(!camera.isReady)

        case .waitingFar:
            primaryButton("Quét xa 5s", systemImage: "arrow.up.left.and.arrow.down.right") {
                camera.startFarScan()
            }

        case .waitingAround:
            primaryButton("Quét xung quanh 8s", systemImage: "rotate.3d") {
                camera.startAroundScan()
            }

        case .ready:
            primaryButton("Khóa, bám & quay", systemImage: "scope") {
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
        .controlSize(.regular)
        .font(.subheadline.bold())
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
        .controlSize(.small)
        .font(.caption.bold())
    }
}
