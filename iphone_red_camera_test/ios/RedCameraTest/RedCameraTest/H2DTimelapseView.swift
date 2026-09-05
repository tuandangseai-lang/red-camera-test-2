import SwiftUI

struct H2DTimelapseView: View {
    @ObservedObject var bluetooth: H2DBLEManager
    @ObservedObject var timelapse: H2DTimelapseManager
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("SE.H2D.wifiSSID") private var wifiSSID = ""
    @AppStorage("SE.H2D.printerIP") private var printerIP = ""
    @AppStorage("SE.H2D.printerSerial") private var printerSerial = ""
    @AppStorage("SE.H2D.configurationSaved") private var configurationSaved = false
    @State private var wifiPassword = ""
    @State private var accessCode = ""
    @State private var showConfiguration = true
    @State private var idlePulse = false
    @State private var showStopOptions = false
    @State private var showPrinterCamera = false
    @State private var automaticConfigurationAttempted = false

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
        .overlay {
            screenEdgeLEDStrip
                .ignoresSafeArea()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            printerStatusIsland
                .padding(.bottom, 6)
        }
        .onAppear {
            if accessCode.isEmpty {
                accessCode = H2DAccessCodeStore.load()
            }
            if wifiPassword.isEmpty {
                wifiPassword = H2DWiFiPasswordStore.load()
            }
            // Migrate configurations saved by v9.6: the old build already
            // persisted the non-secret fields, while this flag is new.
            if !configurationSaved && !wifiSSID.isEmpty && !printerIP.isEmpty &&
                !printerSerial.isEmpty && !accessCode.isEmpty {
                configurationSaved = true
            }
            if configurationSaved && !wifiSSID.isEmpty && !printerIP.isEmpty &&
                !printerSerial.isEmpty && !accessCode.isEmpty {
                showConfiguration = false
            }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                attemptAutomaticConfigurationIfNeeded()
            }
        }
        .onDisappear {
            if !timelapse.isArmed { timelapse.stopPreview() }
        }
        .onChange(of: scenePhase) { _, phase in
            timelapse.handleScenePhase(phase)
        }
        .onChange(of: timelapse.isArmed) { _, armed in
            bluetooth.setH2DTimelapseArmed(armed)
            if !armed {
                // Let the capture screen disappear before starting the fairly
                // expensive AVCapture session again. This removes the visible
                // hitch when leaving capture mode.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard !timelapse.isArmed, !showPrinterCamera else { return }
                    timelapse.preparePreview()
                }
            }
        }
        .onChange(of: bluetooth.isConfiguring) { wasConfiguring, configuring in
            guard wasConfiguring && !configuring else { return }
            if bluetooth.configurationProgress >= 6 && !bluetooth.hasBridgeError {
                configurationSaved = true
                showConfiguration = false
            } else if bluetooth.hasBridgeError {
                configurationSaved = false
                showConfiguration = true
            }
        }
        .onChange(of: bluetooth.h2dStatusCode) { _, status in
            if status == "READY" || status == "ARMED" || status == "DISARMED" {
                configurationSaved = true
                showConfiguration = false
                automaticConfigurationAttempted = false
            } else {
                attemptAutomaticConfigurationIfNeeded()
            }
        }
        .onChange(of: bluetooth.isH2DBridge) { _, recognized in
            if recognized { attemptAutomaticConfigurationIfNeeded() }
        }
        .onChange(of: bluetooth.hasBridgeError) { _, hasError in
            // A bridge/configuration failure means the saved values need to be
            // editable again. Printer HMS alerts use hasActivePrinterAlert and
            // do not reopen this form.
            if hasError && bluetooth.isH2DBridge && !configurationSaved {
                showConfiguration = true
            }
        }
        .fullScreenCover(isPresented: $showPrinterCamera) {
            H2DPrinterCameraView(printerIP: printerIP, accessCode: accessCode)
        }
        .onChange(of: showPrinterCamera) { _, showing in
            if !showing && !timelapse.isArmed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    timelapse.preparePreview()
                }
            }
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
        if bluetooth.hasActiveCriticalPrinterAlert || visibleBridgeError { return .error }
        if !bluetooth.isConnected { return .connecting }
        if timelapse.isCapturing { return .capturing }
        if !bluetooth.isH2DReady { return .connecting }
        switch bluetooth.h2dPrintState.uppercased() {
        // A stopped/failed job is no longer an active printer alert. Keep the
        // Island in its waiting state unless the bridge has a real
        // connection/configuration error (handled above).
        case "FAILED", "ERROR": return .idle
        case "RUNNING": return bluetooth.isActuallyPrinting ? .printing : .preparing
        case "PREPARE", "PREPARING", "SLICING", "INIT", "HEATING", "PAUSE", "PAUSED": return .preparing
        default: return .idle
        }
    }

    private var visibleBridgeError: Bool {
        bluetooth.hasBridgeError && bluetooth.isConnected && bluetooth.isH2DBridge
    }

    private var printerIslandTitle: String {
        switch printerIslandState {
        case .idle: return "H2D • CHƯA BẮT ĐẦU"
        case .preparing: return "H2D • \(bluetooth.h2dStageText.uppercased())"
        case .printing: return "H2D • ĐANG IN \(bluetooth.h2dPrintPercent)%"
        case .capturing: return "ĐANG CHỤP LỚP \(max(1, bluetooth.h2dCurrentLayer))"
        case .connecting: return "ESP32 • ĐANG KẾT NỐI H2D"
        case .error:
            if bluetooth.hasActiveCriticalPrinterAlert { return "H2D • CÓ LỖI" }
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
        // Keep the Dynamic Island compact: its width follows the status
        // content instead of stretching across the entire screen.
        .fixedSize(horizontal: true, vertical: false)
        .shadow(color: printerIslandState.color.opacity(0.16), radius: 10, y: 3)
        .accessibilityLabel(printerIslandTitle)
    }

    /// A low-cost status light that hugs the physical screen edge.  The
    /// printing segment starts at 12 o'clock and advances clockwise with the
    /// printer's reported progress; all other states use a steady/breathing
    /// colour and do not continuously redraw the camera preview.
    private var screenEdgeLEDStrip: some View {
        let isPrinting = printerIslandState == .printing
        let isBlinking = printerIslandState == .idle ||
            printerIslandState == .preparing ||
            printerIslandState == .connecting
        let progress: Double? = isPrinting ? min(1, max(0, printerProgress)) : nil

        return ScreenEdgeLEDStrip(
            color: printerIslandState.color,
            progress: progress,
            blinks: isBlinking
        )
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    private var printerProgress: Double {
        // mc_percent is H2D's actual job progress. Layer ratio is only a
        // fallback for older firmware that did not report a percentage.
        if bluetooth.h2dPrintPercent > 0 {
            return Double(bluetooth.h2dPrintPercent) / 100.0
        }
        if bluetooth.h2dTotalLayers > 0 {
            return Double(bluetooth.h2dCurrentLayer) / Double(max(1, bluetooth.h2dTotalLayers))
        }
        return 0
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
            HStack {
                Spacer(minLength: 0)
                H2DCameraPreview(
                    session: timelapse.previewSession,
                    rotationAngle: timelapse.cameraRotationAngle
                )
                     // Give the portrait viewport an explicit 9.0 / 16.0 size.  Leaving
                    // only an aspect-ratio constraint inside an HStack with
                    // Spacers can collapse the width to a thin strip.
                    .frame(width: 180, height: 320)
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
                Spacer(minLength: 0)
            }
            Text("Đặt iPhone dọc 16:9, lấy trọn vùng in. Khi bắt đầu chờ, hình xem trước sẽ tắt hoàn toàn.")
                .font(.custom("Arial", size: 12))
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var remoteCameraCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Camera có sẵn của H2D", systemImage: "video.fill")
                .font(.custom("Arial", size: 15).weight(.bold))
            Text("Xem trực tiếp ngay trong SE bằng camera Live View của H2D. iPhone phải ở cùng mạng Wi-Fi và LAN Only Liveview trên H2D phải bật.")
                .font(.custom("Arial", size: 12))
                .foregroundStyle(.secondary)

            SecureField("Access Code trong LAN Only (không phải Serial)", text: $accessCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.custom("Arial", size: 13))
                .padding(11)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

            Button {
                H2DAccessCodeStore.save(accessCode)
                timelapse.stopPreview()
                showPrinterCamera = true
            } label: {
                Label("Xem camera H2D trong SE", systemImage: "play.rectangle.fill")
                    .font(.custom("Arial", size: 13).weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(
                printerIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                accessCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .cardStyle()
    }

    private var bridgeStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(
                        visibleBridgeError
                            ? Color.red
                            : bluetooth.hasActiveCriticalPrinterAlert
                                ? .red
                                : bluetooth.hasActivePrinterAlert
                                    ? .orange
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
                ProgressView(value: printerProgress)
                .tint(.orange)
                Text(
                    bluetooth.isActuallyPrinting
                        ? "ĐANG IN • lớp \(bluetooth.h2dCurrentLayer)/\(bluetooth.h2dTotalLayers) • \(bluetooth.h2dPrintPercent)%"
                        : "\(bluetooth.h2dStageText) • \(bluetooth.h2dPrintPercent)%"
                )
                    .font(.custom("Arial", size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if bluetooth.hasActivePrinterAlert &&
                !bluetooth.hasActiveCriticalPrinterAlert &&
                !bluetooth.printerAlertText.isEmpty {
                Label(bluetooth.printerAlertText, systemImage: "exclamationmark.triangle.fill")
                    .font(.custom("Arial", size: 11).weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .cardStyle()
    }

    private func attemptAutomaticConfigurationIfNeeded() {
        let status = bluetooth.h2dStatusCode
        guard status == "CONFIG_REQUIRED" || status == "MQTT_AUTH_FAILED" else { return }
        guard configurationSaved,
              bluetooth.isH2DBridge,
              !bluetooth.isConfiguring,
              !automaticConfigurationAttempted,
              !wifiSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !wifiPassword.isEmpty,
              !printerIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !printerSerial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !accessCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if configurationSaved && !bluetooth.isConfiguring {
                configurationSaved = false
                showConfiguration = true
            }
            return
        }
        automaticConfigurationAttempted = true
        showConfiguration = false
        bluetooth.configureH2DBridge(
            wifiSSID: wifiSSID,
            wifiPassword: wifiPassword,
            printerIP: printerIP,
            printerSerial: printerSerial,
            accessCode: accessCode
        )
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
                    H2DAccessCodeStore.save(accessCode)
                    H2DWiFiPasswordStore.save(wifiPassword)
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
            } else if configurationSaved {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Cấu hình H2D đã lưu", systemImage: "checkmark.shield.fill")
                        .font(.custom("Arial", size: 14).weight(.bold))
                        .foregroundStyle(.green)
                    Text("Wi‑Fi: \(wifiSSID)  •  IP: \(printerIP)  •  Serial: \(printerSerial)")
                        .font(.custom("Arial", size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("Thay đổi cấu hình") {
                        configurationSaved = false
                        showConfiguration = true
                    }
                    .buttonStyle(.bordered)
                    .font(.custom("Arial", size: 12).weight(.bold))
                }
            }
        }
        .cardStyle()
    }

    private var activeCaptureView: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 8)
            if timelapse.isLiveMonitorVisible && !timelapse.isRendering {
                HStack {
                    Spacer(minLength: 0)
                    H2DCameraPreview(
                        session: timelapse.previewSession,
                        rotationAngle: timelapse.cameraRotationAngle
                    )
                    .frame(width: 180, height: 320)
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
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
            } else {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.08), lineWidth: 7)
                        .frame(width: 150, height: 150)
                    Circle()
                        .trim(from: 0, to: min(1, max(0.015,
                            printerProgress)))
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
                if !printerIP.isEmpty && !accessCode.isEmpty {
                    Button {
                        timelapse.setLiveMonitorVisible(false)
                        showPrinterCamera = true
                    } label: {
                        Label("Xem camera H2D", systemImage: "video.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, 22)
                }

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

            Text("Smooth Timelapse: mỗi lớp chỉ tạo 1 ảnh khi H2D báo đã chuyển lớp; ảnh đầu phiên cũng được giữ lại. SE chờ 0,7 giây để đầu in về vị trí cố định, không dùng hẹn giờ lặp.")
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

private struct ScreenEdgeLEDStrip: View {
    let color: Color
    let progress: Double?
    let blinks: Bool

    @State private var pulse = true

    var body: some View {
        ZStack {
            // Dim rail keeps the state readable even when progress is near 0%.
            ClockwiseScreenBorderShape()
                .stroke(
                    color.opacity(0.20),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )

            if let progress {
                ClockwiseScreenBorderShape()
                    .trim(from: 0, to: max(0.008, progress))
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                color.opacity(0.35),
                                color,
                                .white.opacity(0.92)
                            ]),
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(270)
                        ),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .shadow(color: color.opacity(0.8), radius: 5)

                // A small bright head gives the progress a clock-hand feel
                // without adding a continuously animated timer.
                ClockwiseScreenBorderShape()
                    .trim(from: max(0, progress - 0.028), to: progress)
                    .stroke(
                        .white.opacity(0.78),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .animation(.linear(duration: 0.35), value: progress)
            } else {
                ClockwiseScreenBorderShape()
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .shadow(color: color.opacity(0.65), radius: 5)
            }
        }
        .opacity(blinks && !pulse ? 0.22 : 1)
        .onAppear {
            guard blinks else { return }
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                pulse = false
            }
        }
        .onChange(of: blinks) { _, shouldBlink in
            if shouldBlink {
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                    pulse = false
                }
            } else {
                withAnimation(.linear(duration: 0.15)) {
                    pulse = true
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A rounded-rectangle path whose first point is at 12 o'clock.  Trimming it
/// therefore fills the edge in the same clockwise direction as a clock hand.
private struct ClockwiseScreenBorderShape: Shape {
    var inset: CGFloat = 7
    var cornerRadius: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + inset
        let right = rect.maxX - inset
        let top = rect.minY + inset
        let bottom = rect.maxY - inset
        let radius = min(cornerRadius, min((right - left) / 2, (bottom - top) / 2))
        let midX = (left + right) / 2

        var path = Path()
        path.move(to: CGPoint(x: midX, y: top))
        path.addLine(to: CGPoint(x: right - radius, y: top))
        path.addQuadCurve(
            to: CGPoint(x: right, y: top + radius),
            control: CGPoint(x: right, y: top)
        )
        path.addLine(to: CGPoint(x: right, y: bottom - radius))
        path.addQuadCurve(
            to: CGPoint(x: right - radius, y: bottom),
            control: CGPoint(x: right, y: bottom)
        )
        path.addLine(to: CGPoint(x: left + radius, y: bottom))
        path.addQuadCurve(
            to: CGPoint(x: left, y: bottom - radius),
            control: CGPoint(x: left, y: bottom)
        )
        path.addLine(to: CGPoint(x: left, y: top + radius))
        path.addQuadCurve(
            to: CGPoint(x: left + radius, y: top),
            control: CGPoint(x: left, y: top)
        )
        path.addLine(to: CGPoint(x: midX, y: top))
        return path
    }
}
