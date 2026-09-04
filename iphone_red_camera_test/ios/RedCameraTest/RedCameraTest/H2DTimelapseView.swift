import SwiftUI

struct H2DTimelapseView: View {
    @ObservedObject var bluetooth: H2DBLEManager
    @ObservedObject var timelapse: H2DTimelapseManager
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("SE.H2D.wifiSSID") private var wifiSSID = ""
    @AppStorage("SE.H2D.printerIP") private var printerIP = ""
    @AppStorage("SE.H2D.printerSerial") private var printerSerial = ""
    @State private var wifiPassword = ""
    @State private var accessCode = ""
    @State private var showConfiguration = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if timelapse.isArmed || timelapse.isRendering {
                activeCaptureView
            } else {
                setupView
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            timelapse.didStoreFrame = { layer, success in
                bluetooth.acknowledgeH2DFrame(layer: layer, success: success)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                timelapse.preparePreview()
            }
            bluetooth.requestH2DStatus()
        }
        .onDisappear {
            if !timelapse.isArmed { timelapse.stopPreview() }
        }
        .onChange(of: scenePhase) { _, phase in
            timelapse.handleScenePhase(phase)
        }
        .onChange(of: timelapse.isArmed) { _, armed in
            bluetooth.setH2DTimelapseArmed(armed)
        }
    }

    private var setupView: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    cameraCard
                    bridgeStatusCard
                    configurationCard

                    Button {
                        timelapse.arm()
                    } label: {
                        Label("Bật chờ H2D và làm tối màn hình", systemImage: "camera.aperture")
                            .font(.custom("Arial", size: 16).weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(!timelapse.isCameraReady || !bluetooth.isConnected || !bluetooth.isH2DBridge)
                    .opacity(timelapse.isCameraReady && bluetooth.isConnected && bluetooth.isH2DBridge ? 1 : 0.42)

                    Text("Khi đã bật: giữ SE ở màn hình trước, có thể hạ sáng xuống mức thấp nhất nhưng không khóa iPhone. Camera chỉ thức dậy khi ESP32 báo một lớp vừa hoàn tất.")
                        .font(.custom("Arial", size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .padding(16)
            }
            .background(Color.black)
            .navigationTitle("Timelapse H2D")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Khung hình iPhone", systemImage: "iphone.gen3")
                    .font(.custom("Arial", size: 15).weight(.bold))
                Spacer()
                Text(timelapse.isCameraReady ? "Sẵn sàng" : "Đang mở")
                    .font(.custom("Arial", size: 12).weight(.bold))
                    .foregroundStyle(timelapse.isCameraReady ? .green : .yellow)
            }
            H2DCameraPreview(session: timelapse.previewSession)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                }
            Text("Đặt iPhone cố định, lấy trọn vùng in. Khi bắt đầu chờ, hình xem trước sẽ tắt hoàn toàn.")
                .font(.custom("Arial", size: 12))
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var bridgeStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(bluetooth.isH2DBridge ? Color.green : bluetooth.isConnected ? .yellow : .red)
                    .frame(width: 10, height: 10)
                Text(bluetooth.h2dBridgeStatus)
                    .font(.custom("Arial", size: 14).weight(.semibold))
                Spacer()
                Button {
                    bluetooth.requestH2DStatus()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            if bluetooth.h2dTotalLayers > 0 {
                ProgressView(
                    value: Double(bluetooth.h2dCurrentLayer),
                    total: Double(max(1, bluetooth.h2dTotalLayers))
                )
                .tint(.orange)
                Text("\(bluetooth.h2dPrintState) • lớp \(bluetooth.h2dCurrentLayer)/\(bluetooth.h2dTotalLayers) • \(bluetooth.h2dPrintPercent)%")
                    .font(.custom("Arial", size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showConfiguration.toggle() }
            } label: {
                HStack {
                    Label("Cấu hình mạng H2D", systemImage: "network")
                        .font(.custom("Arial", size: 15).weight(.bold))
                    Spacer()
                    Image(systemName: showConfiguration ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(.plain)

            if showConfiguration {
                Text("Trên H2D: Cài đặt › Mạng › LAN Only › bật Developer Mode. Ghi lại IP, Serial và Access Code.")
                    .font(.custom("Arial", size: 12))
                    .foregroundStyle(.orange)

                Group {
                    TextField("Tên Wi-Fi mà ESP32 sẽ dùng", text: $wifiSSID)
                    SecureField("Mật khẩu Wi-Fi", text: $wifiPassword)
                    TextField("IP H2D, ví dụ 192.168.1.50", text: $printerIP)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Serial H2D", text: $printerSerial)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    SecureField("Access Code của H2D", text: $accessCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .font(.custom("Arial", size: 14))
                .padding(12)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

                Button {
                    bluetooth.configureH2DBridge(
                        wifiSSID: wifiSSID,
                        wifiPassword: wifiPassword,
                        printerIP: printerIP,
                        printerSerial: printerSerial,
                        accessCode: accessCode
                    )
                } label: {
                    Label("Lưu cấu hình vào ESP32", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(!bluetooth.isConnected)
            }
        }
        .cardStyle()
    }

    private var activeCaptureView: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.08), lineWidth: 7)
                    .frame(width: 176, height: 176)
                Circle()
                    .trim(from: 0, to: min(1, max(0.015,
                        Double(bluetooth.h2dCurrentLayer) /
                            Double(max(1, bluetooth.h2dTotalLayers)))))
                    .stroke(
                        timelapse.isRendering ? Color.cyan : Color.orange,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .frame(width: 176, height: 176)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: bluetooth.h2dCurrentLayer)
                VStack(spacing: 7) {
                    Image(systemName: timelapse.isRendering ? "film.stack" : "camera.aperture")
                        .font(.system(size: 30, weight: .semibold))
                    Text("\(timelapse.capturedFrameCount)")
                        .font(.custom("Arial", size: 38).monospacedDigit().weight(.bold))
                    Text("ẢNH ĐÃ CHỤP")
                        .font(.custom("Arial", size: 11).weight(.bold))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            Text(timelapse.statusText)
                .font(.custom("Arial", size: 15).weight(.semibold))
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            if bluetooth.h2dTotalLayers > 0 {
                Text("H2D • lớp \(bluetooth.h2dCurrentLayer)/\(bluetooth.h2dTotalLayers)")
                    .font(.custom("Arial", size: 13).monospacedDigit().weight(.bold))
                    .foregroundStyle(.orange.opacity(0.65))
            }
            Spacer()

            if !timelapse.isRendering {
                HStack(spacing: 12) {
                    Button {
                        timelapse.captureTestFrame()
                    } label: {
                        Label("Chụp thử", systemImage: "camera")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        bluetooth.setH2DTimelapseArmed(false)
                        timelapse.disarm(deleteFrames: true)
                    } label: {
                        Label("Dừng", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .font(.custom("Arial", size: 14).weight(.bold))
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
            }
        }
        .background(Color.black)
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
    }
}
