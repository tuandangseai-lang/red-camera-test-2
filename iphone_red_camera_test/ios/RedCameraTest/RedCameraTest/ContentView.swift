import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var bluetooth = BLEManager()
    @Environment(\.scenePhase) private var scenePhase
    @State private var enrollmentPhaseStartedAt = Date()
    @State private var calibrationPhaseStartedAt = Date()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()

                LinearGradient(
                    colors: [.black.opacity(0.72), .clear, .black.opacity(0.78)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                trackingOverlay(in: geometry.size)
                controls
                if bluetooth.isEnrolling {
                    enrollmentOverlay
                }
                if bluetooth.isCalibrating {
                    calibrationOverlay
                }
                // Selection must be the topmost interactive layer.  The old
                // ordering placed it under the recording controls, so candidate
                // boxes could be visible but taps were swallowed by the UI.
                if bluetooth.isChoosingTarget {
                    candidateSelectionOverlay(in: geometry.size)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            camera.prepare()
            bluetooth.resumeFromForeground()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                camera.resume()
                bluetooth.resumeFromForeground()
            case .inactive, .background:
                camera.suspend()
                bluetooth.suspendForBackground()
            @unknown default:
                break
            }
        }
        .onChange(of: bluetooth.isEnrolling) { _, active in
            if active { enrollmentPhaseStartedAt = Date() }
        }
        .onChange(of: bluetooth.isRefining) { _, active in
            if active { enrollmentPhaseStartedAt = Date() }
        }
        .onChange(of: bluetooth.isCalibrating) { _, active in
            if active { calibrationPhaseStartedAt = Date() }
        }
    }

    private var enrollmentOverlay: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            let duration = bluetooth.isRefining ? 2.0 : 3.0
            let elapsed = max(0, timeline.date.timeIntervalSince(enrollmentPhaseStartedAt))
            // The local clock keeps the ring moving even if one BLE progress
            // packet is delayed.  Stop at 98% until MaixCAM confirms completion.
            let localProgress = min(0.98, elapsed / duration * 0.98)
            let smoothProgress = min(1, max(bluetooth.enrollmentProgress, localProgress))
            let complete = bluetooth.enrollmentProgress >= 0.999
            let remaining = max(1, Int(ceil((1 - smoothProgress) * duration)))
            let activeColor: Color = bluetooth.isRefining ? .cyan : .red
            enrollmentRing(
                progress: smoothProgress,
                complete: complete,
                remaining: remaining,
                activeColor: activeColor
            )
        }
    }

    private func enrollmentRing(
        progress: Double,
        complete: Bool,
        remaining: Int,
        activeColor: Color
    ) -> some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.58))
                .frame(width: 176, height: 176)
                .shadow(color: .black.opacity(0.45), radius: 18)

            Circle()
                .stroke(.white.opacity(0.20), lineWidth: 8)
                .frame(width: 154, height: 154)

            Circle()
                .trim(from: 0, to: max(0.012, progress))
                .stroke(
                    complete ? Color.green : activeColor,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .frame(width: 154, height: 154)
                .rotationEffect(.degrees(-90))
                .shadow(color: (complete ? Color.green : activeColor).opacity(0.55), radius: 7)

            VStack(spacing: 7) {
                Image(systemName: complete ? "checkmark" : bluetooth.isRefining ? "viewfinder.circle" : bluetooth.selectedMode.icon)
                    .font(.system(size: 29, weight: .bold))
                    .foregroundStyle(complete ? .green : .white)
                Text(complete ? "XONG" : "\(remaining)")
                    .font(.custom("Arial", size: 30).monospacedDigit().weight(.bold))
                Text(bluetooth.enrollmentStatus)
                    .font(.custom("Arial", size: 12).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 132)
            }
        }
        .transition(.scale(scale: 0.88).combined(with: .opacity))
        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: complete)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bluetooth.enrollmentStatus)
    }

    private var calibrationOverlay: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(calibrationPhaseStartedAt))
            // Calibration normally takes about four seconds.  Animate locally
            // to 92%, then wait for verified stable samples before showing done.
            let localProgress = min(0.92, elapsed / 4.0 * 0.92)
            let smoothProgress = min(1, max(bluetooth.calibrationProgress, localProgress))
            calibrationRing(progress: smoothProgress)
        }
    }

    private func calibrationRing(progress: Double) -> some View {
        let complete = bluetooth.calibrationProgress >= 0.999
        return ZStack {
            Circle()
                .fill(.black.opacity(0.48))
                .frame(width: 188, height: 188)

            Circle()
                .stroke(.white.opacity(0.22), lineWidth: 7)
                .frame(width: 164, height: 164)

            Circle()
                .trim(from: 0, to: max(0.012, progress))
                .stroke(
                    complete ? Color.green : Color.cyan,
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .frame(width: 164, height: 164)
                .rotationEffect(.degrees(-90))

            Image(systemName: complete ? "checkmark" : "scope")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(complete ? .green : .white)

            VStack {
                Spacer()
                Text(bluetooth.calibrationStatus)
                    .font(.custom("Arial", size: 12).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(width: 174)
            }
            .frame(height: 236)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bluetooth.calibrationStatus)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            topStatus
                .padding(.horizontal, 14)
                .padding(.top, 8)
            modeTabs
                .padding(.horizontal, 14)
                .padding(.top, 8)
            Spacer()
            bottomControls
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
    }

    private var topStatus: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(bluetooth.isConnected ? Color.green.opacity(0.22) : Color.orange.opacity(0.22))
                        .frame(width: 38, height: 38)
                    Image(systemName: "airplane.departure")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(bluetooth.isConnected ? .green : .orange)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("SE • \(bluetooth.selectedMode.title)")
                        .font(.custom("Arial", size: 15).weight(.bold))
                    Text(bluetooth.connectionText)
                        .font(.custom("Arial", size: 12))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
                Spacer()
                if camera.isRecording {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text(recordingTime)
                            .font(.custom("Arial", size: 14).monospacedDigit().weight(.bold))
                    }
                } else {
                    Text("0,5× cố định • 1080p60 mát máy")
                        .font(.custom("Arial", size: 13).weight(.bold))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }

            HStack(spacing: 9) {
                Image(systemName: stateIcon)
                    .foregroundStyle(stateColor)
                Text(bluetooth.trackingTitle)
                    .font(.custom("Arial", size: 13).weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if bluetooth.trackingState == .lock || bluetooth.trackingState == .search {
                    Text("\(bluetooth.confidence)%")
                        .font(.custom("Arial", size: 14).monospacedDigit().weight(.bold))
                        .foregroundStyle(stateColor)
                }
                Text("P \(Int(bluetooth.panAngle))°  T \(Int(bluetooth.tiltAngle))°")
                    .font(.custom("Arial", size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var modeTabs: some View {
        HStack(spacing: 8) {
            ForEach(TrackingMode.allCases) { mode in
                let selected = bluetooth.selectedMode == mode
                Button {
                    if camera.isRecording {
                        bluetooth.stop()
                        camera.stopRecording()
                    }
                    bluetooth.selectMode(mode)
                } label: {
                    Group {
                        if mode.rawValue == TrackingMode.waterRocket.rawValue {
                            Image("WaterRocketTabIcon")
                                .resizable()
                                .renderingMode(.template)
                                .scaledToFit()
                                .frame(width: 24, height: 24)
                        } else {
                            Image(systemName: mode.icon)
                                .font(.system(size: 17, weight: .bold))
                        }
                    }
                        .foregroundStyle(selected ? .black : .white.opacity(0.76))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(
                            selected ? stateColor : Color.white.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(.white.opacity(selected ? 0.42 : 0.10), lineWidth: 1)
                        }
                        .accessibilityLabel(mode.title)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
    }

    private var bottomControls: some View {
        VStack(spacing: 13) {
            Text(camera.statusText)
                .font(.custom("Arial", size: 13).weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.44), in: Capsule())

            HStack(alignment: .center) {
                Button {
                    if camera.isRecording {
                        camera.stopRecording()
                    }
                    bluetooth.home()
                    camera.announceHome()
                } label: {
                    controlButton(icon: "house.fill", title: "Home", color: .blue)
                }

                Spacer()

                Button {
                    if camera.isRecording {
                        bluetooth.stop()
                        camera.stopRecording()
                    } else {
                        bluetooth.arm()
                        camera.startRecording()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.92), lineWidth: 5)
                            .frame(width: 82, height: 82)
                        RoundedRectangle(cornerRadius: camera.isRecording ? 8 : 32, style: .continuous)
                            .fill(camera.isRecording ? Color.red : Color.white)
                            .frame(width: camera.isRecording ? 34 : 64, height: camera.isRecording ? 34 : 64)
                            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: camera.isRecording)
                    }
                }
                .disabled(!camera.isReady || (!camera.isRecording && !bluetooth.isConnected))
                .opacity(camera.isReady && (camera.isRecording || bluetooth.isConnected) ? 1 : 0.42)

                Spacer()

                Button {
                    bluetooth.calibrateCenter()
                } label: {
                    controlButton(icon: "scope", title: "Căn tâm", color: .cyan)
                }
                .buttonStyle(.plain)
                .disabled(!bluetooth.canCalibrateCenter)
                .opacity(bluetooth.canCalibrateCenter ? 1 : 0.38)
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func trackingOverlay(in size: CGSize) -> some View {
        let point = CGPoint(
            x: size.width * bluetooth.targetX,
            y: size.height * bluetooth.targetY
        )
        let locked = bluetooth.trackingState == .lock
        let searching = bluetooth.trackingState == .search
        // iPhone 15 renders roughly 6 logical points per millimetre.  A fixed
        // 30 pt reticle is therefore about 5 mm and shows the actual aim point;
        // the larger detector box remains internal to MaixCAM.
        let aimBoxSide: CGFloat = 30

        ZStack {
            Path { path in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                path.move(to: CGPoint(x: center.x - 14, y: center.y))
                path.addLine(to: CGPoint(x: center.x + 14, y: center.y))
                path.move(to: CGPoint(x: center.x, y: center.y - 14))
                path.addLine(to: CGPoint(x: center.x, y: center.y + 14))
            }
            .stroke(.white.opacity(0.48), lineWidth: 1)

            if locked || searching {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(stateColor, style: StrokeStyle(lineWidth: 2.5, dash: searching ? [7, 5] : []))
                    .frame(width: aimBoxSide, height: aimBoxSide)
                    .position(point)
                    .shadow(color: stateColor.opacity(0.48), radius: 6)
                    // ESP32 publishes at 20 Hz.  A 65 ms linear bridge removes
                    // visible stepping without adding the sluggish 100+ ms lag
                    // that makes a fast rocket appear behind the reticle.
                    .animation(.linear(duration: 0.065), value: point)

                Text("MaixCAM • \(bluetooth.lockedTargetName)")
                    .font(.custom("Arial", size: 12).weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(stateColor.opacity(0.86), in: Capsule())
                    .position(
                        x: min(size.width - 78, max(78, point.x)),
                        y: max(32, point.y - aimBoxSide / 2 - 18)
                    )
            }
        }
        .allowsHitTesting(false)
    }

    private func candidateSelectionOverlay(in size: CGSize) -> some View {
        ZStack {
            Color.black.opacity(0.10)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        bluetooth.selectCandidate(
                            atX: Double(min(1, max(0, value.location.x / max(1, size.width)))),
                            y: Double(min(1, max(0, value.location.y / max(1, size.height))))
                        )
                    }
                )

            ForEach(bluetooth.candidates) { candidate in
                let point = CGPoint(
                    x: min(size.width - 30, max(30, size.width * candidate.x)),
                    y: min(size.height - 40, max(40, size.height * candidate.y))
                )
                let visibleWidth = min(180, max(38, size.width * candidate.width))
                let visibleHeight = min(220, max(38, size.height * candidate.height))
                let tapWidth = max(58, visibleWidth)
                let tapHeight = max(58, visibleHeight)

                Button {
                    bluetooth.selectCandidate(candidate)
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                Color.cyan,
                                style: StrokeStyle(lineWidth: 3, dash: [8, 4])
                            )
                            .frame(width: visibleWidth, height: visibleHeight)
                            .shadow(color: .cyan.opacity(0.72), radius: 7)

                        Text("\(candidate.label) • \(candidate.confidence)%")
                            .font(.custom("Arial", size: 11).weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.cyan, in: Capsule())
                            .offset(y: -visibleHeight / 2 - 17)
                    }
                    .frame(width: tapWidth, height: tapHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(point)
                .accessibilityLabel("Chọn \(candidate.label), độ tin cậy \(candidate.confidence) phần trăm")
            }

            VStack {
                Spacer()
                VStack(spacing: 9) {
                    Label(
                        bluetooth.candidates.isEmpty
                            ? "Đã quét xong • đang nhận danh sách từ MaixCAM"
                            : "Chạm trực tiếp vào vật cần theo dõi",
                        systemImage: bluetooth.candidates.isEmpty ? "ellipsis" : "hand.tap.fill"
                    )
                        .font(.custom("Arial", size: 13).weight(.bold))
                        .foregroundStyle(.white)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 9) {
                            ForEach(bluetooth.candidates) { candidate in
                                Button {
                                    bluetooth.selectCandidate(candidate)
                                } label: {
                                    HStack(spacing: 7) {
                                        Text("\(candidate.id)")
                                            .font(.custom("Arial", size: 13).weight(.black))
                                            .frame(width: 25, height: 25)
                                            .background(.cyan, in: RoundedRectangle(cornerRadius: 7))
                                            .foregroundStyle(.black)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(candidate.label)
                                                .font(.custom("Arial", size: 12).weight(.bold))
                                            Text("Độ tin cậy \(candidate.confidence)%")
                                                .font(.custom("Arial", size: 10))
                                                .foregroundStyle(.white.opacity(0.68))
                                        }
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 13))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 13)
                                            .stroke(.cyan.opacity(0.72), lineWidth: 1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.vertical, 10)
                .background(.black.opacity(0.70), in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 12)
                .padding(.bottom, 150)
            }
        }
        .transition(.opacity)
    }

    private func controlButton(icon: String, title: String, color: Color) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().fill(color.opacity(0.20)).frame(width: 46, height: 46)
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(title)
                .font(.custom("Arial", size: 11).weight(.bold))
                .foregroundStyle(.white.opacity(0.76))
        }
        .frame(width: 62)
    }

    private var stateColor: Color {
        switch bluetooth.trackingState {
        case .lock: return .green
        case .search, .acquire: return .yellow
        case .choose: return .cyan
        case .refine: return .mint
        case .home: return .blue
        case .calibrate: return .cyan
        case .disconnected: return .orange
        case .idle: return .white
        }
    }

    private var stateIcon: String {
        switch bluetooth.trackingState {
        case .lock: return "scope"
        case .search: return "location.magnifyingglass"
        case .acquire: return "dot.scope"
        case .choose: return "hand.tap.fill"
        case .refine: return "viewfinder.circle"
        case .home: return "house.fill"
        case .calibrate: return "scope"
        case .disconnected: return "antenna.radiowaves.left.and.right.slash"
        case .idle: return "checkmark.circle.fill"
        }
    }

    private var recordingTime: String {
        String(format: "%02d:%02d", camera.elapsedSeconds / 60, camera.elapsedSeconds % 60)
    }
}
