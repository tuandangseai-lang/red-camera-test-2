import Foundation
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var ble = BLEManager()
    @State private var profileToRename: SavedScanProfile?
    @State private var renameDraft = ""

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
        .alert(
            "Đổi tên mẫu",
            isPresented: Binding(
                get: { profileToRename != nil },
                set: { if !$0 { profileToRename = nil } }
            )
        ) {
            TextField("Tên mới", text: $renameDraft)
            Button("Lưu") {
                if let profileToRename {
                    camera.renameProfile(profileToRename, to: renameDraft)
                }
                profileToRename = nil
            }
            Button("Hủy", role: .cancel) {
                profileToRename = nil
            }
        } message: {
            Text("Tối đa 28 ký tự")
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
                    let diameter = min(rect.width, rect.height)
                    Circle()
                        .stroke(
                            guideColor,
                            style: StrokeStyle(
                                lineWidth: camera.stage.isScanning ? 4 : 3,
                                dash: camera.hasSelectedSubject ? [] : [10, 6]
                            )
                        )
                        .frame(width: diameter, height: diameter)
                        .position(x: rect.midX, y: rect.midY)

                    Text(guideLabel)
                        .font(.caption.bold())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(guideColor, in: Capsule())
                        .position(x: rect.midX, y: max(18, rect.minY - 16))

                }

                if camera.stage == .tracking,
                   camera.targetRect != nil {
                    aiTrackingOverlay(in: geometry.size)
                }

                if camera.isServoTrajectorySearching,
                   let vector = camera.servoSearchVector {
                    servoTrajectorySearchOverlay(vector: vector, in: geometry.size)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Lớp AR chỉ nằm trong SwiftUI preview. Video được AVCaptureMovieFileOutput ghi
    /// trực tiếp từ camera nên mũi tên và nhãn ESP32 không xuất hiện trong file lưu.
    private func servoTrajectorySearchOverlay(
        vector: CGPoint,
        in size: CGSize
    ) -> some View {
        let magnitude = max(0.001, hypot(vector.x, vector.y))
        let dx = vector.x / magnitude
        let dy = vector.y / magnitude
        let angle = Angle.radians(Double(atan2(dy, dx)) + .pi / 2)
        let anchor = camera.servoSearchAnchor ?? CGPoint(x: 0.5, y: 0.45)
        let safeAnchor = CGPoint(
            x: min(0.78, max(0.22, anchor.x)),
            y: min(0.70, max(0.25, anchor.y))
        )
        let base = mappedPoint(safeAnchor, in: size)
        let travel = min(92.0, max(64.0, min(size.width, size.height) * 0.16))
        let arrowPoint = CGPoint(
            x: min(size.width - 42, max(42, base.x + dx * travel)),
            y: min(size.height - 130, max(105, base.y + dy * travel))
        )

        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                var trajectory = Path()
                trajectory.move(to: base)
                trajectory.addLine(to: arrowPoint)
                context.stroke(
                    trajectory,
                    with: .color(.cyan.opacity(0.82)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [7, 6])
                )

                let centerDot = CGRect(
                    x: base.x - 5,
                    y: base.y - 5,
                    width: 10,
                    height: 10
                )
                context.fill(Path(ellipseIn: centerDot), with: .color(.cyan))
            }

            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.92))
                Circle()
                    .stroke(Color.white.opacity(0.88), lineWidth: 2)
                Image(systemName: "arrow.up")
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(.white)
                    .rotationEffect(angle)
            }
            .frame(width: 58, height: 58)
            .shadow(color: .cyan.opacity(0.85), radius: 10)
            .position(arrowPoint)

            HStack(spacing: 5) {
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 7, height: 7)
                Text("ESP32 ĐANG TÌM")
                    .font(.system(size: 11, weight: .black, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.74), in: Capsule())
            .overlay(Capsule().stroke(Color.cyan.opacity(0.75), lineWidth: 1))
            .position(
                x: min(size.width - 78, max(78, arrowPoint.x)),
                y: min(size.height - 94, arrowPoint.y + 46)
            )
        }
        .transition(.scale(scale: 0.82).combined(with: .opacity))
        .animation(.easeOut(duration: 0.18), value: camera.isServoTrajectorySearching)
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
            Color.black.opacity(0.56)
            Image(uiImage: maskImage)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .luminanceToAlpha()
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .allowsHitTesting(false)
    }

    private func subjectContourOverlay(
        points: [CGPoint],
        in size: CGSize
    ) -> some View {
        Canvas { context, _ in
            let mapped = points.map { mappedPoint($0, in: size) }
            guard mapped.count >= 3 else { return }
            context.addFilter(.shadow(color: .mint.opacity(0.55), radius: 4))
            let outline = smoothClosedPath(mapped)
            context.stroke(
                outline,
                with: .color(.mint.opacity(0.42)),
                style: StrokeStyle(lineWidth: 5.0, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                outline,
                with: .color(.white.opacity(0.88)),
                style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
            )
        }
        .allowsHitTesting(false)
    }

    private func aiTrackingOverlay(in size: CGSize) -> some View {
        let rawRect = mappedRect(camera.targetRect ?? .zero, in: size)
        // Cho vật nhỏ một vùng nhìn rõ tối thiểu, nhưng tâm và kích thước thực
        // vẫn do detector/tracker quyết định chứ không còn tam giác đứng sai chỗ.
        let box = CGRect(
            x: rawRect.midX - max(20, rawRect.width / 2),
            y: rawRect.midY - max(20, rawRect.height / 2),
            width: max(40, rawRect.width),
            height: max(40, rawRect.height)
        ).insetBy(dx: -5, dy: -5)
        let confidence = Int(max(0, min(1, camera.trackingConfidence)) * 100)

        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                context.addFilter(.shadow(color: .green.opacity(0.92), radius: 5))
                let corner = min(22.0, max(10.0, min(box.width, box.height) * 0.23))
                var path = Path()
                path.move(to: CGPoint(x: box.minX, y: box.minY + corner))
                path.addLine(to: CGPoint(x: box.minX, y: box.minY))
                path.addLine(to: CGPoint(x: box.minX + corner, y: box.minY))
                path.move(to: CGPoint(x: box.maxX - corner, y: box.minY))
                path.addLine(to: CGPoint(x: box.maxX, y: box.minY))
                path.addLine(to: CGPoint(x: box.maxX, y: box.minY + corner))
                path.move(to: CGPoint(x: box.maxX, y: box.maxY - corner))
                path.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
                path.addLine(to: CGPoint(x: box.maxX - corner, y: box.maxY))
                path.move(to: CGPoint(x: box.minX + corner, y: box.maxY))
                path.addLine(to: CGPoint(x: box.minX, y: box.maxY))
                path.addLine(to: CGPoint(x: box.minX, y: box.maxY - corner))
                context.stroke(
                    path,
                    with: .color(.green),
                    style: StrokeStyle(lineWidth: 3, lineCap: .square, lineJoin: .miter)
                )

                if let predicted = camera.predictedTargetPoint {
                    let target = mappedPoint(predicted, in: size)
                    let center = CGPoint(x: box.midX, y: box.midY)
                    var direction = Path()
                    direction.move(to: center)
                    direction.addLine(to: target)
                    context.stroke(
                        direction,
                        with: .color(.yellow.opacity(0.90)),
                        style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [5, 4])
                    )
                }
            }

            Text("\(camera.detectedSubjectLabel.uppercased())  \(confidence)%")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundStyle(.black)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.green)
                .position(
                    x: max(74, min(size.width - 74, box.minX + 74)),
                    y: max(14, box.minY - 12)
                )
        }
        .allowsHitTesting(false)
    }

    private func smoothClosedPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        let firstMidpoint = CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2)
        path.move(to: firstMidpoint)
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            let midpoint = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.addQuadCurve(to: midpoint, control: current)
        }
        path.closeSubpath()
        return path
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
                        ? "ĐÃ ĐỦ"
                        : (camera.scanHasConfirmedTarget ? "7 ẢNH" : "XÁC NHẬN")
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
                return camera.scanHasConfirmedTarget
                    ? "ĐÃ XÁC NHẬN CHAI • \(camera.scanViewpointCount)/\(camera.referencePhotoTarget)"
                    : "ĐẶT CHAI TRONG VÒNG TRÒN"
            }
            return "CHỌN LOẠI • TẠO MẪU 7 ẢNH"
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

    private func mappedPoint(_ normalized: CGPoint, in viewSize: CGSize) -> CGPoint {
        let mapped = mappedRect(
            CGRect(x: normalized.x, y: normalized.y, width: 0, height: 0),
            in: viewSize
        )
        return mapped.origin
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
                        ? "\(camera.scanViewpointCount)/\(camera.referencePhotoTarget)"
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

            if camera.stage.isScanning
                || camera.stage == .verifying
                || camera.stage == .tracking
                || camera.stage == .lost {
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
                        Text("\(camera.scanViewpointCount)/\(camera.referencePhotoTarget)")
                            .font(.caption.monospacedDigit().bold())
                    }

                    HStack(spacing: 7) {
                        ForEach(0..<camera.referencePhotoTarget, id: \.self) { index in
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
                            if camera.scanViewpointCount >= camera.referencePhotoTarget {
                                camera.startReferenceVideoCapture()
                            } else {
                                camera.captureManualReferencePhoto()
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(
                                        camera.scanViewpointCount >= camera.referencePhotoTarget
                                            ? Color.red
                                            : Color.white
                                    )
                                    .frame(width: 76, height: 76)
                                Circle()
                                    .stroke(.black.opacity(0.70), lineWidth: 3)
                                    .frame(width: 64, height: 64)
                                if camera.scanViewpointCount >= camera.referencePhotoTarget {
                                    Image(systemName: camera.isCapturingReferenceVideo
                                          ? "record.circle.fill"
                                          : "video.fill")
                                        .font(.title2.bold())
                                        .foregroundStyle(.white)
                                }
                            }
                            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                        }
                        .buttonStyle(.plain)
                        .disabled(camera.isCapturingReferenceVideo)
                        .accessibilityLabel(
                            camera.scanViewpointCount >= camera.referencePhotoTarget
                                ? "Quay video mẫu 10 giây"
                                : "Chụp ảnh mẫu"
                        )

                        Spacer()

                        Image(systemName: "waterbottle.fill")
                            .font(.title3)
                            .foregroundStyle(.cyan)
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
                Button {
                    renameDraft = active.name
                    profileToRename = active
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.cyan)
                .accessibilityLabel("Đổi tên mẫu")

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
                        camera.selectSubjectKind(kind)
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
            .disabled(camera.isRecording || camera.stage.isScanning)

            Image(systemName: "viewfinder")
                .foregroundStyle(.yellow)
            Slider(value: $camera.scanBoxScale, in: 0.48...0.92)
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
            primaryButton("Tạo mẫu 7 ảnh", systemImage: "camera.on.rectangle") {
                camera.startShapeScan()
            }
            .disabled(!camera.isReady)

        case .waitingFar:
            primaryButton("Tạo mẫu 7 ảnh", systemImage: "camera.on.rectangle") {
                camera.startShapeScan()
            }

        case .waitingAround:
            primaryButton("Tạo mẫu 7 ảnh", systemImage: "camera.on.rectangle") {
                camera.startShapeScan()
            }

        case .ready:
            primaryButton("Khóa, bám & quay", systemImage: "scope") {
                camera.startTrackingAndRecording()
            }
            secondaryButton("Tạo lại mẫu 7 ảnh", systemImage: "trash") {
                camera.resetProfile()
            }

        case .verifying:
            VStack(spacing: 10) {
                ProgressView("Tự tìm liên tục theo quỹ đạo cuối...")
                    .tint(.white)
                    .foregroundStyle(.white)
                if camera.isRecording {
                    Button(role: .destructive) {
                        camera.stopRecording()
                    } label: {
                        Label("Dừng tìm và lưu video", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    secondaryButton("Dừng tìm mục tiêu", systemImage: "xmark.circle") {
                        camera.cancelTargetSearch()
                    }
                }
            }

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
