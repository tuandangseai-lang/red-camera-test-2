import Foundation
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var ble = BLEManager()

    var body: some View {
        ZStack {
            if camera.isARScanning {
                ARScanPreview(session: camera.arSession)
                    .ignoresSafeArea()
            } else {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
            }

            trackingOverlay
                .ignoresSafeArea()

            if camera.stage.isScanning {
                subjectTapLayer
                    .ignoresSafeArea()
            }

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
                if camera.stage.isScanning,
                   let maskImage = camera.selectedSubjectMaskImage {
                    subjectSpotlight(maskImage: maskImage, in: geometry.size)
                }

                if camera.stage.showsGuide {
                    let guideRect = camera.selectedSubjectRect ?? camera.scanRect
                    let rect = mappedRect(guideRect, in: geometry.size)
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

    private var subjectTapLayer: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            camera.selectSubject(
                                at: normalizedPoint(value.location, in: geometry.size)
                            )
                        }
                )
        }
    }

    private func subjectSpotlight(maskImage: UIImage, in size: CGSize) -> some View {
        ZStack {
            Color.black.opacity(0.72)
            Image(uiImage: maskImage)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .luminanceToAlpha()
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .overlay {
            Image(uiImage: maskImage)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .luminanceToAlpha()
                .colorMultiply(.cyan)
                .opacity(0.14)
        }
        .allowsHitTesting(false)
    }

    private var scanProgressRing: some View {
        let displayedProgress = camera.scanHasConfirmedTarget
            ? camera.scanProgress
            : camera.targetConfirmationProgress
        let progress = max(0, min(displayedProgress, 1))
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
                        ? "ĐÃ PHỦ"
                        : (camera.scanHasConfirmedTarget ? "DỰNG 3D" : "XÁC NHẬN")
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
        if camera.scanHasConfirmedTarget { return .cyan }
        return .yellow
    }

    private func scanRingX(for rect: CGRect, viewWidth: CGFloat) -> CGFloat {
        let right = rect.maxX + 46
        if right <= viewWidth - 40 { return right }
        return max(40, rect.minX - 46)
    }

    private func crystalMesh(in rect: CGRect) -> some View {
        Canvas { context, _ in
            let columns = camera.crystalGridColumns
            let rows = camera.crystalGridRows
            let cellWidth = rect.width / CGFloat(columns)
            let cellHeight = rect.height / CGFloat(rows)
            context.addFilter(.shadow(color: .cyan.opacity(0.65), radius: 2))

            for index in camera.crystalCells {
                let column = index % columns
                let row = index / columns
                let tile = CGRect(
                    x: rect.minX + CGFloat(column) * cellWidth,
                    y: rect.minY + CGFloat(row) * cellHeight,
                    width: cellWidth + 0.7,
                    height: cellHeight + 0.7
                ).insetBy(dx: 0.35, dy: 0.35)

                var first = Path()
                first.move(to: CGPoint(x: tile.minX, y: tile.minY))
                first.addLine(to: CGPoint(x: tile.maxX, y: tile.minY))
                first.addLine(to: CGPoint(x: tile.minX, y: tile.maxY))
                first.closeSubpath()

                var second = Path()
                second.move(to: CGPoint(x: tile.maxX, y: tile.minY))
                second.addLine(to: CGPoint(x: tile.maxX, y: tile.maxY))
                second.addLine(to: CGPoint(x: tile.minX, y: tile.maxY))
                second.closeSubpath()

                let firstColor: Color = index.isMultiple(of: 3) ? .mint : .cyan
                let secondColor: Color = index.isMultiple(of: 2) ? .blue : .teal
                let depth = camera.crystalDepths[index] ?? 0.5
                let nearOpacity = 0.82 - depth * 0.28
                context.fill(first, with: .color(firstColor.opacity(nearOpacity)))
                context.fill(second, with: .color(secondColor.opacity(nearOpacity * 0.92)))
                context.stroke(first, with: .color(.white.opacity(0.72)), lineWidth: 0.65)
                context.stroke(second, with: .color(.cyan.opacity(0.85)), lineWidth: 0.55)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.28), value: camera.crystalCells.count)
        .allowsHitTesting(false)
    }

    private func crystalVolumeMesh(in rect: CGRect) -> some View {
        Canvas { context, _ in
            context.addFilter(.shadow(color: .cyan.opacity(0.50), radius: 2.5))
            for facet in camera.crystalFacets3D {
                func mapped(_ point: CGPoint) -> CGPoint {
                    CGPoint(
                        x: rect.minX + point.x * rect.width,
                        y: rect.minY + point.y * rect.height
                    )
                }

                var triangle = Path()
                triangle.move(to: mapped(facet.a))
                triangle.addLine(to: mapped(facet.b))
                triangle.addLine(to: mapped(facet.c))
                triangle.closeSubpath()

                let light = max(0.15, min(1.0, facet.light))
                let depthTint = max(0, min(1, (facet.depth + 0.8) / 1.6))
                let color = Color(
                    hue: 0.48 + depthTint * 0.10,
                    saturation: 0.78,
                    brightness: 0.42 + light * 0.52
                )
                context.fill(triangle, with: .color(color.opacity(0.52 + light * 0.30)))
                context.stroke(
                    triangle,
                    with: .color(.white.opacity(0.20 + light * 0.48)),
                    lineWidth: 0.55
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.34), value: camera.crystalFacets3D.count)
        .allowsHitTesting(false)
    }

    private var guideLabel: String {
        switch camera.stage {
        case .idle, .scanningNear, .waitingFar, .scanningFar, .waitingAround, .scanningAround:
            if camera.stage.isScanning {
                return camera.hasSelectedSubject
                    ? "CÙNG MỘT VẬT • \(camera.scanViewpointCount)/6 ẢNH"
                    : "CHẠM VÀO VẬT CẦN CHỤP"
            }
            return "CHỌN LOẠI • TẠO MẪU 6 ẢNH"
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

    private func normalizedPoint(_ point: CGPoint, in viewSize: CGSize) -> CGPoint {
        let sourceWidth = max(0.1, camera.frameAspectRatio)
        let scale = max(viewSize.width / sourceWidth, viewSize.height)
        let displayedWidth = sourceWidth * scale
        let displayedHeight = scale
        let offsetX = (viewSize.width - displayedWidth) / 2.0
        let offsetY = (viewSize.height - displayedHeight) / 2.0
        return CGPoint(
            x: min(1, max(0, (point.x - offsetX) / displayedWidth)),
            y: min(1, max(0, (point.y - offsetY) / displayedHeight))
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
                Label(
                    camera.stage.isScanning
                        ? "\(camera.scanViewpointCount)/6"
                        : "\(camera.learnedSamples)",
                    systemImage: camera.stage.isScanning
                        ? "photo.stack.fill"
                        : "square.stack.3d.up"
                )
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(.white.opacity(0.12), lineWidth: 0.7)
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 8) {
            if camera.stage.isScanning {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(
                            systemName: camera.scanIsSufficient
                                ? "checkmark.circle.fill"
                                : (camera.scanNeedsNewAngle
                                   ? "exclamationmark.circle.fill"
                                   : "camera.viewfinder")
                        )
                        .foregroundStyle(scanStatusColor)
                        Text(camera.scanGuidanceText)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.78)
                        Spacer(minLength: 4)
                        Text("\(camera.scanViewpointCount)/6")
                            .font(.caption.monospacedDigit().bold())
                    }

                    HStack(spacing: 7) {
                        ForEach(0..<6, id: \.self) { index in
                            Circle()
                                .fill(
                                    index < camera.scanViewpointCount
                                        ? Color.cyan
                                        : Color.white.opacity(0.20)
                                )
                                .frame(width: 9, height: 9)
                        }
                    }

                    HStack {
                        Button(role: .cancel) {
                            camera.cancelShapeScan()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.headline.bold())
                                .frame(width: 42, height: 42)
                                .background(.black.opacity(0.42), in: Circle())
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            camera.captureManualReferencePhoto()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(
                                        camera.hasSelectedSubject
                                            ? Color.white
                                            : Color.gray
                                    )
                                    .frame(width: 76, height: 76)
                                Circle()
                                    .stroke(.black.opacity(0.70), lineWidth: 3)
                                    .frame(width: 64, height: 64)
                            }
                            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                        }
                        .buttonStyle(.plain)
                        .disabled(!camera.hasSelectedSubject)
                        .accessibilityLabel("Chụp ảnh mẫu")

                        Spacer()

                        Image(systemName: "hand.tap.fill")
                            .font(.title3)
                            .foregroundStyle(camera.hasSelectedSubject ? .cyan : .yellow)
                            .frame(width: 42, height: 42)
                    }
                }
                .foregroundStyle(.white)
            } else {
                if !camera.savedProfiles.isEmpty {
                    profileTabs
                }
                compactSettings
                actionButtons
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.12), lineWidth: 0.7)
        }
        .animation(
            .spring(response: 0.32, dampingFraction: 0.86),
            value: camera.stage
        )
        .animation(
            .easeInOut(duration: 0.22),
            value: camera.activeProfileID
        )
    }

    private var profileTabs: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(camera.savedProfiles) { profile in
                        let isActive = camera.activeProfileID == profile.id
                        Button {
                            camera.activateProfile(profile)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: profile.subjectKind.symbol)
                                Text(profile.shortName)
                                    .lineLimit(1)
                            }
                            .font(.caption.bold())
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .foregroundStyle(isActive ? .black : .white)
                            .background(
                                isActive ? Color.cyan : Color.white.opacity(0.10),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let activeID = camera.activeProfileID,
               let active = camera.savedProfiles.first(where: { $0.id == activeID }) {
                Button(role: .destructive) {
                    camera.deleteProfile(active)
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .accessibilityLabel("Xóa mẫu đang chọn")
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var compactSettings: some View {
        HStack(spacing: 9) {
            Menu {
                ForEach(ScanSubjectKind.allCases) { kind in
                    Button {
                        camera.scanSubjectKind = kind
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
            } label: {
                Label(camera.scanSubjectKind.title, systemImage: camera.scanSubjectKind.symbol)
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

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
            primaryButton("Tạo mẫu từ 6 ảnh", systemImage: "camera.on.rectangle") {
                camera.startShapeScan()
            }
            .disabled(!camera.isReady)

        case .waitingFar:
            primaryButton("Tạo mẫu từ 6 ảnh", systemImage: "camera.on.rectangle") {
                camera.startShapeScan()
            }

        case .waitingAround:
            primaryButton("Tạo mẫu từ 6 ảnh", systemImage: "camera.on.rectangle") {
                camera.startShapeScan()
            }

        case .ready:
            primaryButton("Khóa, bám & quay", systemImage: "scope") {
                camera.startTrackingAndRecording()
            }
            secondaryButton("Tạo lại mẫu 6 ảnh", systemImage: "trash") {
                camera.resetProfile()
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
