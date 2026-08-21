import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var bluetooth = BLEManager()
    @Environment(\.scenePhase) private var scenePhase

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
                if bluetooth.isEnrolling {
                    enrollmentOverlay
                }
                controls
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
    }

    private var enrollmentOverlay: some View {
        let complete = bluetooth.enrollmentProgress >= 0.999
        let remaining = max(1, Int(ceil((1 - bluetooth.enrollmentProgress) * 3)))
        return ZStack {
            Circle()
                .fill(.black.opacity(0.58))
                .frame(width: 176, height: 176)
                .shadow(color: .black.opacity(0.45), radius: 18)

            Circle()
                .stroke(.white.opacity(0.20), lineWidth: 8)
                .frame(width: 154, height: 154)

            Circle()
                .trim(from: 0, to: max(0.012, bluetooth.enrollmentProgress))
                .stroke(
                    complete ? Color.green : Color.red,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .frame(width: 154, height: 154)
                .rotationEffect(.degrees(-90))
                .shadow(color: (complete ? Color.green : Color.red).opacity(0.55), radius: 7)
                .animation(.linear(duration: 0.10), value: bluetooth.enrollmentProgress)

            VStack(spacing: 7) {
                Image(systemName: complete ? "checkmark" : bluetooth.selectedMode.icon)
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
                    Text("0,5× • 4K")
                        .font(.custom("Arial", size: 13).weight(.bold))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }

            HStack(spacing: 9) {
                Image(systemName: stateIcon)
                    .foregroundStyle(stateColor)
                Text(bluetooth.trackingState.title)
                    .font(.custom("Arial", size: 13).weight(.semibold))
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
                .disabled(!camera.isReady)
                .opacity(camera.isReady ? 1 : 0.42)

                Spacer()

                VStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .fill(stateColor.opacity(0.20))
                            .frame(width: 46, height: 46)
                        Image(systemName: bluetooth.trackingState == .lock ? "scope" : "dot.scope")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(stateColor)
                    }
                    Text("AI")
                        .font(.custom("Arial", size: 11).weight(.bold))
                        .foregroundStyle(.white.opacity(0.76))
                }
                .frame(width: 62)
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
                    .frame(width: 58, height: 58)
                    .position(point)
                    .shadow(color: stateColor.opacity(0.48), radius: 6)
                    .animation(.linear(duration: 0.08), value: bluetooth.targetX)
                    .animation(.linear(duration: 0.08), value: bluetooth.targetY)
            }
        }
        .allowsHitTesting(false)
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
        case .home: return .blue
        case .disconnected: return .orange
        case .idle: return .white
        }
    }

    private var stateIcon: String {
        switch bluetooth.trackingState {
        case .lock: return "scope"
        case .search: return "location.magnifyingglass"
        case .acquire: return "dot.scope"
        case .home: return "house.fill"
        case .disconnected: return "antenna.radiowaves.left.and.right.slash"
        case .idle: return "checkmark.circle.fill"
        }
    }

    private var recordingTime: String {
        String(format: "%02d:%02d", camera.elapsedSeconds / 60, camera.elapsedSeconds % 60)
    }
}
