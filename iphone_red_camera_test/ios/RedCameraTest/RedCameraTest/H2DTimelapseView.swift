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
    @State private var idlePulse = false
    @State private var showStopOptions = false

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
        .safeAreaInset(edge: .top, spacing: 0) {
            printerStatusIsland
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                idlePulse = true
            }
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
            if !armed { timelapse.preparePreview() }
        }
        .confirmationDialog(
            "Bạn muốn xử lý các ảnh đã chụp thế nào?",
            isPresented: $showStopOptions,
            titleVisibility: .visible
        ) {
            Button("Ghép \(timelapse.capturedFrameCount) ảnh thành video") {
                bluetooth.setH2DTimelapseArmed(false)
                timelapse.finishEarlyAndRender()
            }
            Button("Bỏ toàn bộ ảnh", role: .destructive) {
                bluetooth.setH2DTimelapseArmed(false)
                timelapse.disarm(deleteFrames: true)
            }
            Button("Tiếp tục chụp", role: .cancel) {}
        } message: {
            Text("Dừng chụp không dừng máy in H2D.")
        }
    }

    private enum PrinterIslandState: Equatable {
        case idle
        case preparing
        case printing
        case capturing
        case connecting
        case error

        var color: Color {
            switch self {
            case .idle, .preparing, .connecting: return .yellow
            case .printing: return .green
            case .capturing: return .blue
            case .error: return .red
            }
        }

        var icon: String {
            switch self {
            case .idle: return "clock"
            case .preparing: return "hourglass"
            case .printing: return "printer.fill"
            case .capturing: return "camera.fill"
            case .connecting: return "wifi.exclamationmark"
            case .error: return "exclamationmark.triangle.fill"
            }
        }
    }

    private var printerIslandState: PrinterIslandState {
        if bluetooth.hasBridgeError || bluetooth.hasPrinterAlert || !bluetooth.isConnected { return .error }
        if timelapse.isCapturing { return .capturing }
        if !bluetooth.isH2DReady { return .connecting }
        switch bluetooth.h2dPrintState.uppercased() {
        case "FAILED", "ERROR": return .error
        case "RUNNING": return bluetooth.isActuallyPrinting ? .printing : .preparing
        case "PREPARE", "PREPARING", "SLICING", "INIT", "HEATING", "PAUSE", "PAUSED": return .preparing
        default: return .idle
        }
    }

    private var printerIslandTitle: String {
        switch printerIslandState {
        case .idle: return "H2D • CHƯA BẮT ĐẦU"
        case .preparing: return "H2D • \(bluetooth.h2dStageText.uppercased())"
        case .printing: return "H2D • ĐANG IN \(bluetooth.h2dPrintPercent)%"
        case .capturing: return "ĐANG CHỤP LỚP \(max(1, bluetooth.h2dCurrentLayer))"
        case .connecting: return "ESP32 • ĐANG KẾT NỐI H2D"
        case .error:
            if bluetooth.hasPrinterAlert { return "H2D • CÓ CẢNH BÁO" }
            return bluetooth.isConnected ? "H2D • CÓ LỖI" : "ESP32 • MẤT KẾT NỐI"
        }
    }

    private var printerStatusIsland: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(printerIslandState.color.opacity(0.20))
                    .frame(width: 29, height: 29)
                Image(systemName: printerIslandState.icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(printerIslandState.color)
            }

            Text(printerIslandTitle)
                .font(.custom("Arial", size: 12).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)

            Spacer(minLength: 4)

            Circle()
                .fill(printerIslandState.color)
                .frame(width: 9, height: 9)
                .shadow(color: printerIslandState.color.opacity(0.8), radius: 5)
                .opacity(
                    printerIslandState == .idle || printerIslandState == .connecting
                        ? (idlePulse ? 1 : 0.18)
                        : 1
                )
        }
        .padding(.horizontal, 13)
        .frame(height: 43)
        .background(.black.opacity(0.94), in: Capsule())
        .overlay {
            Capsule()
                .stroke(printerIslandState.color.opacity(0.42), lineWidth: 1)
        }
        .shadow(color: printerIslandState.color.opacity(0.16), radius: 10, y: 3)
        .accessibilityLabel(printerIslandTitle)
    }

    private var setupView: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    cameraCard
                    bridgeStatusCard
                    remoteCameraCard
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
                    .disabled(!timelapse.isPreviewRunning || !bluetooth.isH2DReady)
                    .opacity(timelapse.isPreviewRunning && bluetooth.isH2DReady ? 1 : 0.42)

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
                Text(timelapse.isPreviewRunning ? "Đang hiển thị" : "Đang mở")
                    .font(.custom("Arial", size: 12).weight(.bold))
                    .foregroundStyle(timelapse.isPreviewRunning ? .green : .yellow)
                Button {
                    timelapse.rotateCamera180()
                } label: {
                    Label("Xoay 180°", systemImage: "rotate.right")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
            }
            H2DCameraPreview(
                session: timelapse.previewSession,
                rotationAngle: timelapse.cameraRotationAngle
            )
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.14), lineWidth: 1)
                        if !timelapse.isPreviewRunning {
                            VStack(spacing: 9) {
                                ProgressView()
                                    .tint(.orange)
                                Text("Đang khởi động lại camera iPhone...")
                                    .font(.custom("Arial", size: 12).weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            Text("Đặt iPhone cố định, lấy trọn vùng in. Khi bắt đầu chờ, hình xem trước sẽ tắt hoàn toàn.")
                .font(.custom("Arial", size: 12))
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var remoteCameraCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Camera có sẵn của H2D", systemImage: "video.fill")
                .font(.custom("Arial", size: 15).weight(.bold))
            Text("Khi không chụp timelapse bằng SE, bạn có thể xem và điều khiển H2D từ xa bằng Bambu Handy qua tài khoản Bambu Cloud.")
                .font(.custom("Arial", size: 12))
                .foregroundStyle(.secondary)
            Link(destination: URL(string: "https://apps.apple.com/app/bambu-handy/id1625671285")!) {
                Label("Mở Bambu Handy để xem từ xa", systemImage: "arrow.up.forward.app")
                    .font(.custom("Arial", size: 13).weight(.bold))
            }
        }
        .cardStyle()
    }

    private var bridgeStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(
                        bluetooth.hasBridgeError || !bluetooth.isConnected
                            ? Color.red
                            : bluetooth.isH2DReady ? .green : .yellow
                    )
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
                Text(
                    bluetooth.isActuallyPrinting
                        ? "ĐANG IN • lớp \(bluetooth.h2dCurrentLayer)/\(bluetooth.h2dTotalLayers) • \(bluetooth.h2dPrintPercent)%"
                        : "\(bluetooth.h2dStageText) • \(bluetooth.h2dPrintPercent)%"
                )
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
                Label("Bắt buộc: LAN Only và Developer Mode trên H2D đều phải bật màu xanh.", systemImage: "exclamationmark.shield.fill")
                    .font(.custom("Arial", size: 12).weight(.bold))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 12) {
                    configurationLabel("Tên Wi-Fi", detail: "Mạng mà ESP32 sẽ kết nối")
                    TextField("Ví dụ: Khoá học cùng SE", text: $wifiSSID)

                    configurationLabel("Mật khẩu Wi-Fi")
                    SecureField("Nhập mật khẩu Wi-Fi", text: $wifiPassword)

                    configurationLabel("IP của H2D")
                    TextField("Ví dụ: 192.168.100.210", text: $printerIP)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)

                    configurationLabel("Serial H2D")
                    TextField("Nhập số serial trên màn hình H2D", text: $printerSerial)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()

                    configurationLabel("Access Code")
                    SecureField("Nhập mã trong mục LAN Only", text: $accessCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .font(.custom("Arial", size: 14))
                .padding(12)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

                if bluetooth.isConfiguring {
                    ProgressView(value: Double(bluetooth.configurationProgress), total: 6)
                        .tint(.blue)
                }

                Button {
                    bluetooth.configureH2DBridge(
                        wifiSSID: wifiSSID,
                        wifiPassword: wifiPassword,
                        printerIP: printerIP,
                        printerSerial: printerSerial,
                        accessCode: accessCode
                    )
                } label: {
                    Label(
                        bluetooth.isConfiguring ? "Đang gửi từng bước..." : "Lưu cấu hình vào ESP32",
                        systemImage: bluetooth.isConfiguring ? "arrow.triangle.2.circlepath" : "square.and.arrow.down"
                    )
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(!bluetooth.isH2DBridge || bluetooth.isConfiguring)
            }
        }
        .cardStyle()
    }

    private var activeCaptureView: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 8)
            if timelapse.isLiveMonitorVisible && !timelapse.isRendering {
                H2DCameraPreview(
                    session: timelapse.previewSession,
                    rotationAngle: timelapse.cameraRotationAngle
                )
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 8) {
                        Button {
                            timelapse.rotateCamera180()
                        } label: {
                            Image(systemName: "rotate.right")
                        }
                        Button {
                            timelapse.setLiveMonitorVisible(false)
                        } label: {
                            Image(systemName: "xmark")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.black.opacity(0.72))
                    .padding(10)
                }
                .padding(.horizontal, 18)
            } else {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.08), lineWidth: 7)
                        .frame(width: 150, height: 150)
                    Circle()
                        .trim(from: 0, to: min(1, max(0.015,
                            Double(bluetooth.h2dCurrentLayer) /
                                Double(max(1, bluetooth.h2dTotalLayers)))))
                        .stroke(
                            timelapse.isRendering ? Color.cyan : Color.orange,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                        .frame(width: 150, height: 150)
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
            }

            Text(timelapse.statusText)
                .font(.custom("Arial", size: 15).weight(.semibold))
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            if bluetooth.h2dTotalLayers > 0 {
                Text(
                    bluetooth.isActuallyPrinting
                        ? "H2D • đang in lớp \(bluetooth.h2dCurrentLayer)/\(bluetooth.h2dTotalLayers)"
                        : "H2D • \(bluetooth.h2dStageText.lowercased())"
                )
                    .font(.custom("Arial", size: 13).monospacedDigit().weight(.bold))
                    .foregroundStyle(.orange.opacity(0.65))
            }

            capturedFramesCard
            Spacer(minLength: 4)

            if !timelapse.isRendering {
                HStack(spacing: 12) {
                    Button {
                        timelapse.setLiveMonitorVisible(!timelapse.isLiveMonitorVisible)
                    } label: {
                        Label(
                            timelapse.isLiveMonitorVisible ? "Tắt hình" : "Xem hình",
                            systemImage: timelapse.isLiveMonitorVisible ? "eye.slash" : "eye"
                        )
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        showStopOptions = true
                    } label: {
                        Label("Dừng quay", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .font(.custom("Arial", size: 14).weight(.bold))
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
            }

            Text("SE chờ 0,7 giây sau khi đổi lớp. Hãy bật Timelapse Smooth trong Bambu Studio để đầu in về một vị trí cố định trước mỗi ảnh.")
                .font(.custom("Arial", size: 10))
                .foregroundStyle(.white.opacity(0.38))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .background(Color.black)
    }

    private var capturedFramesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: timelapse.isCapturing ? "camera.fill" : "camera.badge.clock")
                    .foregroundStyle(timelapse.isCapturing ? Color.blue : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(timelapse.isCapturing ? "iPhone đang chụp ảnh lớp" : "Chế độ chụp đang hoạt động")
                        .font(.custom("Arial", size: 13).weight(.bold))
                    Text("Đã lưu \(timelapse.capturedFrameCount) ảnh trong phiên này")
                        .font(.custom("Arial", size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if timelapse.isCapturing {
                    ProgressView()
                        .tint(.blue)
                }
            }

            if timelapse.recentFramePreviews.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text("Ảnh vừa chụp sẽ hiện tại đây")
                }
                .font(.custom("Arial", size: 12).weight(.semibold))
                .foregroundStyle(.white.opacity(0.38))
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(timelapse.recentFramePreviews) { frame in
                            Image(uiImage: frame.image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 82, height: 58)
                                .clipped()
                                .overlay(alignment: .bottomLeading) {
                                    Text("Lớp \(frame.layer)")
                                        .font(.custom("Arial", size: 9).weight(.bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 3)
                                        .background(.black.opacity(0.72), in: Capsule())
                                        .padding(5)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.09), lineWidth: 1)
        }
        .padding(.horizontal, 18)
    }

    private func configurationLabel(_ title: String, detail: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.custom("Arial", size: 12).weight(.bold))
                .foregroundStyle(.white.opacity(0.78))
            if let detail {
                Text("• \(detail)")
                    .font(.custom("Arial", size: 11))
                    .foregroundStyle(.secondary)
            }
        }
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
