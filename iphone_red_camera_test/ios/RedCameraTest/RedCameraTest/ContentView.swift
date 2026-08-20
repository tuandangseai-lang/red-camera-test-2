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

    private var controls: some View {
        VStack(spacing: 0) {
            topStatus
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
                    Text("SE • MAIX AI")
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
