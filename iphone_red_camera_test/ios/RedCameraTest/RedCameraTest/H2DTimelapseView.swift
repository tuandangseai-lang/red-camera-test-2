import Foundation
import SwiftUI

struct H2DTimelapseView: View {
    @ObservedObject var bluetooth: H2DBLEManager
    @ObservedObject var timelapse: H2DTimelapseManager
    @StateObject private var printerAlarm = PrinterAlarmPlayer()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("SE.H2D.wifiSSID") private var wifiSSID = ""
    @AppStorage("SE.H2D.printerIP") private var printerIP = ""
    @AppStorage("SE.H2D.printerSerial") private var printerSerial = ""
    @AppStorage("SE.H2D.configurationSaved") private var configurationSaved = false
    @AppStorage("SE.H2D.setupCameraEnabled") private var setupCameraEnabled = false
    @State private var wifiPassword = ""
    @State private var accessCode = ""
    @State private var showConfiguration = true
    @State private var idlePulse = false
    @State private var showStopOptions = false
    @State private var automaticConfigurationAttempted = false
    @State private var selectedPrinterKind: BambuPrinterKind = .h2d
    @State private var savedProfiles: [BambuPrinterProfile] = []
    @State private var pendingProfileSwitch = false
    @State private var showCriticalPrinterAlarm = false
    @State private var acknowledgedAlarmID = ""
    @State private var hardwareArmRequested = false
    @State private var hardwareStartedCapture = false
    @State private var hardwareModeOneLatched = false
    @State private var hardwareControlGeneration = 0
    @State private var completionBlueActive = false
    @State private var completionDismissWorkItem: DispatchWorkItem?

    private var detectedPrinterKind: BambuPrinterKind {
        let fromSerial = BambuPrinterKind.detect(serial: printerSerial)
        if fromSerial != .unknown { return fromSerial }
        if !configurationSaved { return selectedPrinterKind }
        let fromBridge = bluetooth.printerKind
        return fromBridge == .unknown ? selectedPrinterKind : fromBridge
    }

    private var printerName: String { detectedPrinterKind.rawValue }

    private let cinemaCyan = Color(red: 0.18, green: 0.88, blue: 0.96)
    private let cinemaAmber = Color(red: 0.96, green: 0.61, blue: 0.20)
    private let cinemaGreen = Color(red: 0.20, green: 0.94, blue: 0.57)

    var body: some View {
        observedContent
            .onChange(of: bluetooth.hardwareControlRevision) { _, _ in
                scheduleHardwareControls()
            }
            .onChange(of: bluetooth.hardwareLevelPercent) { _, level in
                // Apply volume directly as well as through the aggregate
                // control revision so rapid knob updates cannot be coalesced
                // with a simultaneous MODE or HOLD notification.
                printerAlarm.setLevel(Double(level) / 100.0)
                timelapse.setEffectSoundLevel(Double(level) / 100.0)
            }
            .onChange(of: timelapse.isRendering) { _, rendering in
                if !rendering { applyHardwareControls(force: true) }
            }
            .alert("\(bluetooth.activeCriticalPrinterDisplayName) đang có lỗi", isPresented: $showCriticalPrinterAlarm) {
                Button("OK") {
                    acknowledgedAlarmID = currentAlarmID
                    printerAlarm.stop()
                }
            } message: {
                Text(bluetooth.activeCriticalPrinterAlertText.isEmpty
                    ? "Hãy kiểm tra màn hình máy in. Âm báo sẽ tự tắt khi lỗi được xử lý."
                    : bluetooth.activeCriticalPrinterAlertText)
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
                Text("Dừng chụp không dừng máy in \(printerName).")
            }
    }

    private var observedContent: some View {
        ZStack {
            CinemaTechnologyBackdrop()
                .ignoresSafeArea()
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
            timelapse.setViewActive(true)
            savedProfiles = BambuPrinterProfileStore.load()
            let storedKind = BambuPrinterKind.detect(serial: printerSerial)
            if storedKind != .unknown { selectedPrinterKind = storedKind }
            if accessCode.isEmpty {
                accessCode = H2DAccessCodeStore.load(for: selectedPrinterKind)
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
            withAnimation(.linear(duration: 0.18).repeatForever(autoreverses: true)) {
                idlePulse = true
            }
            updateCompletionPresentation(for: bluetooth.h2dPrintState)
            timelapse.didStoreFrame = { layer, success in
                bluetooth.acknowledgeH2DFrame(layer: layer, success: success)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if setupCameraEnabled {
                    timelapse.preparePreview()
                } else {
                    timelapse.stopPreview()
                }
            }
            bluetooth.requestH2DStatus()
            applyHardwareControls(force: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                reconcileBridgeWithSelectedProfile()
                attemptAutomaticConfigurationIfNeeded()
                syncFleetWhenPossible()
                synchronizePrinterAlarm()
            }
        }
        .onDisappear {
            timelapse.restoreDisplayWhenLeaving()
            timelapse.setHardwareTorch(steady: false, blinking: false, keepCameraWarm: false)
            if !timelapse.isArmed { timelapse.stopPreview() }
        }
        .onChange(of: scenePhase) { _, phase in
            timelapse.handleScenePhase(phase, allowSetupPreview: setupCameraEnabled)
        }
        .onChange(of: timelapse.isArmed) { _, armed in
            bluetooth.setH2DTimelapseArmed(armed)
            if armed { hardwareArmRequested = false }
            if !armed {
                // Let the capture screen disappear before starting the fairly
                // expensive AVCapture session again. This removes the visible
                // hitch when leaving capture mode.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard !timelapse.isArmed else { return }
                    if setupCameraEnabled {
                        timelapse.preparePreview()
                    } else {
                        timelapse.stopPreview()
                    }
                    applyHardwareControls(force: true)
                }
            }
        }
        .onChange(of: setupCameraEnabled) { _, enabled in
            guard !timelapse.isArmed else { return }
            if enabled {
                timelapse.preparePreview()
            } else {
                timelapse.stopPreview()
            }
        }
        .onChange(of: bluetooth.isConfiguring) { wasConfiguring, configuring in
            guard wasConfiguring && !configuring else { return }
            if bluetooth.configurationProgress >= bluetooth.configurationTotal &&
                bluetooth.configurationTotal > 0 && !bluetooth.hasBridgeError {
                configurationSaved = true
                showConfiguration = false
                persistActiveProfile()
                // If the user tapped another saved profile while the initial
                // configuration was still running, perform that pending
                // switch now instead of leaving the app on the old printer.
                switchToSelectedProfileIfPossible()
            } else if bluetooth.hasBridgeError {
                configurationSaved = false
                showConfiguration = true
            }
        }
        .onChange(of: bluetooth.h2dStatusCode) { _, status in
            if !bluetooth.isSwitchingPrinter &&
                (status == "READY" || status == "ARMED" || status == "DISARMED") {
                configurationSaved = true
                showConfiguration = false
                automaticConfigurationAttempted = false
            } else {
                attemptAutomaticConfigurationIfNeeded()
            }
            if bluetooth.isH2DReady { applyHardwareControls(force: true) }
            if status == "READY" || status == "ARMED" || status == "DISARMED" {
                syncFleetWhenPossible()
            }
        }
        .onChange(of: bluetooth.h2dPrintState) { _, state in
            updateCompletionPresentation(for: state)
        }
        .onChange(of: bluetooth.isH2DBridge) { _, recognized in
            if recognized {
                reconcileBridgeWithSelectedProfile()
                switchToSelectedProfileIfPossible()
                attemptAutomaticConfigurationIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    syncFleetWhenPossible()
                }
            }
        }
        .onChange(of: bluetooth.printerSerial) { _, _ in
            reconcileBridgeWithSelectedProfile()
        }
        .onChange(of: printerSerial) { _, serial in
            let detected = BambuPrinterKind.detect(serial: serial)
            guard detected != .unknown, detected != selectedPrinterKind else { return }
            selectedPrinterKind = detected
            accessCode = H2DAccessCodeStore.load(for: detected)
        }
        .onChange(of: bluetooth.hasBridgeError) { _, hasError in
            // A bridge/configuration failure means the saved values need to be
            // editable again. Printer HMS alerts use hasActivePrinterAlert and
            // do not reopen this form.
            if hasError && bluetooth.isH2DBridge && !configurationSaved {
                showConfiguration = true
            }
        }
        .onChange(of: bluetooth.hasActiveCriticalPrinterAlert) { _, _ in
            synchronizePrinterAlarm()
        }
        .onChange(of: bluetooth.activeCriticalPrinterKind) { _, _ in
            synchronizePrinterAlarm()
        }
        .onChange(of: bluetooth.activeCriticalPrinterAlertText) { _, _ in
            synchronizePrinterAlarm()
        }
    }

    private enum PrinterIslandState: Equatable {
        case idle
        case preparing
        case printing
        case capturing
        case connecting
        case stopping
        case paused
        case completed
        case error

        var color: Color {
            switch self {
            case .idle, .connecting: return .yellow
            case .preparing, .printing: return .green
            case .capturing: return .blue
            case .stopping, .paused: return .red
            case .completed: return .blue
            case .error: return .red
            }
        }

    }

    private var printerIslandState: PrinterIslandState {
        if bluetooth.hasActiveCriticalPrinterAlert || visibleBridgeError { return .error }
        if timelapse.isStopping || bluetooth.isStoppingPrint { return .stopping }
        if bluetooth.isPausedPrint { return .paused }
        if !bluetooth.isConnected { return .connecting }
        if timelapse.isCapturing { return .capturing }
        if !bluetooth.isH2DReady { return .connecting }
        if completionBlueActive { return .completed }
        switch bluetooth.h2dPrintState.uppercased() {
        // A failed/cancelled job without a real printer alarm is a deliberate
        // stop: show the red breathing state without starting the siren.
        case "FAILED": return .stopping
        case "ERROR": return .idle
        case "RUNNING": return isLayerPrintingOrChangingFilament ? .printing : .preparing
        case "PAUSE", "PAUSED": return .paused
        case "PREPARE", "PREPARING", "SLICING", "INIT", "HEATING": return .preparing
        default: return .idle
        }
    }

    private var visibleBridgeError: Bool {
        bluetooth.hasBridgeError && bluetooth.isConnected && bluetooth.isH2DBridge
    }

    private var printerIslandTitle: String {
        switch printerIslandState {
        case .idle: return "\(printerName) • CHƯA BẮT ĐẦU"
        case .preparing: return "\(printerName) • \(bluetooth.h2dStageText.uppercased())"
        case .printing: return "\(printerName) • ĐANG IN \(bluetooth.h2dPrintPercent)%"
        case .capturing: return "\(printerName) • CHỤP LỚP \(max(1, bluetooth.h2dCurrentLayer))"
        case .connecting: return "ESP32 • ĐANG KẾT NỐI \(printerName)"
        case .stopping: return "\(printerName) • ĐANG DỪNG"
        case .paused: return "\(printerName) • ĐANG TẠM DỪNG"
        case .completed: return "\(printerName) • ĐÃ IN XONG"
        case .error:
            if bluetooth.hasActiveCriticalPrinterAlert {
                return "\(bluetooth.activeCriticalPrinterDisplayName) • CÓ LỖI"
            }
            return bluetooth.isConnected ? "\(printerName) • CÓ LỖI" : "ESP32 • MẤT KẾT NỐI"
        }
    }

    private var printerStatusIsland: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(printerIslandState.color)

            Text(printerIslandTitle)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)

            Circle()
                .fill(printerIslandState.color)
                .frame(width: 9, height: 9)
                .shadow(color: printerIslandState.color.opacity(0.8), radius: 5)
                .opacity(
                    printerIslandState == .error
                        ? (idlePulse ? 1 : 0.18)
                        : 1
                )
        }
        .padding(.horizontal, 13)
        .frame(height: 43)
        .background(.ultraThinMaterial, in: Capsule())
        .background(.black.opacity(0.76), in: Capsule())
        .overlay {
            Capsule()
                .stroke(
                    LinearGradient(
                        colors: [printerIslandState.color.opacity(0.75), .white.opacity(0.10)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )
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
        let isBlinking = printerIslandState == .error
        let isCompleted = printerIslandState == .completed
        let shouldShowEdge = printerIslandState != .idle && printerIslandState != .connecting
        let progress: Double? = isPrinting ? min(1, max(0, printerProgress)) : nil
        // Capturing temporarily paints the whole edge blue. Keep the green
        // printing animation's anchor alive underneath so it resumes from the
        // same live position instead of restarting at 12 o'clock.
        let preservesPrintingProgress =
            printerIslandState == .capturing && isLayerPrintingOrChangingFilament

        return ScreenEdgeLEDStrip(
            color: printerIslandState.color,
            progress: progress,
            remainingSeconds: bluetooth.h2dRemainingMinutes > 0
                ? Double(bluetooth.h2dRemainingMinutes) * 60.0
                : nil,
            blinks: isBlinking,
            breathingPeriod: isCompleted ? 4.0 : nil,
            minimumOpacity: isCompleted ? 0.02 : 1.0,
            maximumOpacity: 1.0,
            preservesProgressWhenHidden: preservesPrintingProgress
        )
        .opacity(shouldShowEdge ? 1 : 0)
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

    private var isLayerPrintingOrChangingFilament: Bool {
        bluetooth.h2dPrintState.uppercased() == "RUNNING" &&
            (bluetooth.isActuallyPrinting || bluetooth.h2dCurrentLayer > 0)
    }

    private func updateCompletionPresentation(for state: String) {
        let normalized = state.uppercased()
        if ["FINISH", "COMPLETE", "COMPLETED"].contains(normalized) {
            guard !completionBlueActive else { return }
            completionDismissWorkItem?.cancel()
            completionBlueActive = true
            let workItem = DispatchWorkItem {
                completionBlueActive = false
                bluetooth.acknowledgePrintCompletion()
            }
            completionDismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                // Show one complete slow blue breath, then return to the
                // borderless standby state without requiring a tap.
                deadline: .now() + 4.0,
                execute: workItem
            )
        } else if ["RUNNING", "PREPARE", "PREPARING", "SLICING", "INIT", "HEATING"].contains(normalized) {
            dismissCompletionPresentation(notifyBridge: false)
        }
    }

    private func dismissCompletionPresentation(notifyBridge: Bool) {
        completionDismissWorkItem?.cancel()
        completionDismissWorkItem = nil
        completionBlueActive = false
        if notifyBridge { bluetooth.acknowledgePrintCompletion() }
    }

    private var setupView: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    cinemaSystemHeader
                    cameraCard
                    bridgeStatusCard
                    configurationCard

                    Button {
                        // Position 0 is neutral. A session started from this
                        // on-screen button must not be stopped when ESP32 later
                        // repeats MODE,0 as part of a status response.
                        hardwareStartedCapture = false
                        if bluetooth.hardwareMode == 1 {
                            hardwareModeOneLatched = true
                        }
                        timelapse.arm(startingAtLayer: bluetooth.h2dCurrentLayer)
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(.black.opacity(0.72))
                                    .frame(width: 38, height: 38)
                                Image(systemName: "record.circle.fill")
                                    .font(.system(size: 23, weight: .black))
                                    .foregroundStyle(.red)
                                    .shadow(color: .red.opacity(0.75), radius: 6)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("KHỞI ĐỘNG TIMELAPSE")
                                    .font(.system(size: 14, weight: .black, design: .rounded))
                                Text("Theo dõi \(printerName) • tự chụp từng lớp")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .opacity(0.72)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .black))
                        }
                        .padding(.horizontal, 15)
                        .frame(maxWidth: .infinity, minHeight: 58)
                    }
                    .buttonStyle(CinemaLaunchButtonStyle())
                    .disabled(!bluetooth.isH2DReady)
                    .opacity(bluetooth.isH2DReady ? 1 : 0.42)

                    Label(
                        "Giữ SE ở màn hình trước. Màn hình sẽ hạ sáng; camera chỉ chụp khi ESP32 báo lớp vừa hoàn tất.",
                        systemImage: "lock.shield.fill"
                    )
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))
                }
                .padding(16)
            }
            .background(Color.clear)
            .scrollIndicators(.hidden)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var cinemaSystemHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [cinemaAmber.opacity(0.30), cinemaCyan.opacity(0.11)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(cinemaAmber)
                    .shadow(color: cinemaAmber.opacity(0.65), radius: 8)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("SE CINEMA CONTROL")
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .tracking(0.8)
                Text("SMART LAYER CAPTURE • \(printerName)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(cinemaCyan.opacity(0.72))
                    .tracking(0.7)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(bluetooth.isConnected ? cinemaGreen : .red)
                        .frame(width: 6, height: 6)
                        .shadow(color: bluetooth.isConnected ? cinemaGreen : .red, radius: 4)
                    Text(bluetooth.isConnected ? "LINK" : "OFFLINE")
                }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.74))

                Text("V9.49")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.34))
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 5)
    }

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("OPTICAL VIEWFINDER")
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .tracking(0.8)
                    Text("CAMERA IPHONE • 1.5×")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.36))
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(cameraStatusColor)
                        .frame(width: 6, height: 6)
                        .shadow(color: cameraStatusColor, radius: 4)
                    Text(setupCameraEnabled ? (timelapse.isPreviewRunning ? "LIVE" : "WARMING") : "STANDBY")
                }
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(cameraStatusColor)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(cameraStatusColor.opacity(0.10), in: Capsule())
                .overlay { Capsule().stroke(cameraStatusColor.opacity(0.30), lineWidth: 1) }

                if setupCameraEnabled {
                    Button {
                        timelapse.rotateCamera180()
                    } label: {
                        Image(systemName: "rotate.right")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(CinemaIconButtonStyle(tint: cinemaCyan))
                }
                Button {
                    setupCameraEnabled.toggle()
                } label: {
                    Image(systemName: setupCameraEnabled ? "video.slash.fill" : "video.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(CinemaIconButtonStyle(tint: setupCameraEnabled ? .white.opacity(0.65) : cinemaCyan))
            }
            HStack {
                Spacer(minLength: 0)
                Group {
                    if setupCameraEnabled {
                        H2DCameraPreview(
                            session: timelapse.previewSession,
                            rotationAngle: timelapse.cameraRotationAngle
                        )
                        .overlay {
                            ZStack {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(cinemaCyan.opacity(0.36), lineWidth: 1)
                                CinemaViewfinderOverlay(tint: cinemaCyan)
                                if !timelapse.isPreviewRunning {
                                    VStack(spacing: 9) {
                                        ProgressView()
                                            .tint(cinemaAmber)
                                        Text("INITIALIZING OPTICS")
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.55))
                                    }
                                }
                            }
                        }
                    } else {
                        cinemaProjectorStandby
                    }
                }
                // Give the portrait viewport an explicit 9.0 / 16.0 size.
                .frame(width: 180, height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Spacer(minLength: 0)
            }
            HStack(spacing: 7) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(cinemaCyan.opacity(0.72))
                Text("Ẩn viewfinder không tắt chức năng chụp tự động theo lớp.")
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
        }
        .cardStyle()
    }

    private var cameraStatusColor: Color {
        guard setupCameraEnabled else { return .white.opacity(0.42) }
        return timelapse.isPreviewRunning ? cinemaGreen : cinemaAmber
    }

    private var cinemaProjectorStandby: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.95), Color(red: 0.025, green: 0.075, blue: 0.09)],
                startPoint: .top,
                endPoint: .bottom
            )

            ZStack {
                Image("CinemaProjectorOutline")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white.opacity(0.76))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 21)
                    .shadow(color: cinemaCyan.opacity(0.42), radius: 8)
                    .opacity(isFlashArtworkActive ? 0 : 1)
                    .scaleEffect(isFlashArtworkActive ? 0.97 : 1)

                CinemaLightningArtwork(
                    tint: cinemaAmber
                )
                .padding(.horizontal, 30)
                .padding(.vertical, 54)
                .opacity(isFlashArtworkActive ? 1 : 0)
                .scaleEffect(isFlashArtworkActive ? 1 : 0.97)
            }
            .animation(.easeInOut(duration: 0.24), value: isFlashArtworkActive)

            LinearGradient(
                colors: [.clear, cinemaCyan.opacity(0.09), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 34)
            .offset(y: -62)

            VStack {
                HStack {
                    Text("SE // OPTICAL UNIT")
                    Spacer()
                    Text(isFlashArtworkActive ? "FLASH ON" : "CAM OFF")
                        .foregroundStyle(cinemaAmber)
                }
                Spacer()
                HStack {
                    Image(systemName: isFlashArtworkActive ? "bolt.fill" : "viewfinder")
                    Text(isFlashArtworkActive ? "ILLUMINATION ACTIVE" : "READY FOR LAYER SIGNAL")
                    Spacer()
                    Text("9:16")
                }
            }
            .font(.system(size: 7, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.45))
            .padding(12)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(cinemaCyan.opacity(0.24), lineWidth: 1)
        }
    }

    private var isFlashArtworkActive: Bool {
        timelapse.isFlashModeActive
    }

    private var bridgeStatusCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(bridgeAccentColor.opacity(0.13))
                        .frame(width: 38, height: 38)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(bridgeAccentColor)
                        .shadow(color: bridgeAccentColor.opacity(0.65), radius: 5)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("PRINTER TELEMETRY")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.38))
                    Text(bluetooth.h2dBridgeStatus)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    bluetooth.requestH2DStatus()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(CinemaIconButtonStyle(tint: cinemaCyan))
            }

            if bluetooth.h2dTotalLayers > 0 {
                VStack(spacing: 7) {
                    HStack(alignment: .lastTextBaseline) {
                        Text(
                            isLayerPrintingOrChangingFilament
                                ? "LAYER \(bluetooth.h2dCurrentLayer) / \(bluetooth.h2dTotalLayers)"
                                : bluetooth.h2dStageText.uppercased()
                        )
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.58))
                        Spacer()
                        Text("\(bluetooth.h2dPrintPercent)%")
                            .font(.system(size: 24, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(cinemaGreen)
                    }
                    CinemaProgressRail(progress: printerProgress, tint: cinemaGreen)
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(bluetooth.filamentType.isEmpty ? .gray : .orange)
                if bluetooth.filamentType.isEmpty {
                    Text("\(printerName) • đang đồng bộ loại nhựa")
                        .font(.custom("Arial", size: 12).weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(printerName) • \(bluetooth.materialDescription)")
                        .font(.custom("Arial", size: 12).weight(.bold))
                }
            }
            if bluetooth.hasTemperatureTelemetry || bluetooth.hasFanTelemetry {
                VStack(alignment: .leading, spacing: 6) {
                    if bluetooth.hasTemperatureTelemetry { temperatureTelemetryRows }
                    if bluetooth.hasFanTelemetry {
                        Label(fanTelemetryText, systemImage: "fan.fill")
                            .font(.custom("Arial", size: 11).monospacedDigit().weight(.semibold))
                            .foregroundStyle(.cyan.opacity(0.85))
                    }
                }
                .padding(.top, 2)
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

    private var bridgeAccentColor: Color {
        if visibleBridgeError || bluetooth.hasActiveCriticalPrinterAlert { return .red }
        if bluetooth.hasActivePrinterAlert { return cinemaAmber }
        return bluetooth.isH2DReady ? cinemaGreen : cinemaAmber
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
                    Label("Cấu hình máy in Bambu", systemImage: "network")
                        .font(.custom("Arial", size: 15).weight(.bold))
                    Spacer()
                    Image(systemName: showConfiguration ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(.plain)

            printerProfileSelector

            if showConfiguration {
                Label("Chọn hồ sơ; SE còn tự kiểm tra đầu serial để nhận đúng A1 / H2D / P2S.", systemImage: "sparkles")
                    .font(.custom("Arial", size: 12).weight(.bold))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 12) {
                    configurationLabel("Tên Wi-Fi", detail: "Mạng mà ESP32 sẽ kết nối")
                    TextField("Ví dụ: Khoá học cùng SE", text: $wifiSSID)

                    configurationLabel("Mật khẩu Wi-Fi")
                    SecureField("Nhập mật khẩu Wi-Fi", text: $wifiPassword)

                    configurationLabel("IP của \(printerName)")
                    TextField("Ví dụ: 192.168.100.210", text: $printerIP)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)

                    configurationLabel("Serial máy in")
                    TextField("Ví dụ: 039… / 094… / 22E…", text: $printerSerial)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()

                    Label(
                        BambuPrinterKind.detect(serial: printerSerial) == .unknown
                            ? "Chưa nhận được loại máy từ serial"
                            : "Đã tự nhận: \(BambuPrinterKind.detect(serial: printerSerial).rawValue)",
                        systemImage: BambuPrinterKind.detect(serial: printerSerial) == .unknown
                            ? "questionmark.circle" : "checkmark.seal.fill"
                    )
                    .font(.custom("Arial", size: 12).weight(.bold))
                    .foregroundStyle(BambuPrinterKind.detect(serial: printerSerial) == .unknown ? .yellow : .green)

                    configurationLabel("Access Code")
                    SecureField("Nhập mã trong mục LAN Only", text: $accessCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .font(.custom("Arial", size: 14))
                .textFieldStyle(CinemaTextFieldStyle())
                .padding(12)
                .background(.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(cinemaCyan.opacity(0.12), lineWidth: 1)
                }

                if bluetooth.isConfiguring {
                    ProgressView(
                        value: Double(bluetooth.configurationProgress),
                        total: Double(max(1, bluetooth.configurationTotal))
                    )
                        .tint(.blue)
                }

                Button {
                    persistActiveProfile()
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
                    Label("Hồ sơ \(printerName) đã lưu", systemImage: "checkmark.shield.fill")
                        .font(.custom("Arial", size: 14).weight(.bold))
                        .foregroundStyle(.green)
                    Text("Thông tin kết nối được ẩn để bảo vệ hồ sơ máy in.")
                        .font(.custom("Arial", size: 11))
                        .foregroundStyle(.secondary)
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

    private var printerProfileSelector: some View {
        HStack(spacing: 8) {
            ForEach([BambuPrinterKind.a1, .h2d, .p2s]) { kind in
                let fleet = bluetooth.fleetStatus(for: kind)
                Button {
                    activateProfile(kind)
                } label: {
                    HStack(spacing: 5) {
                        PrinterActivityDot(
                            isConfigured: savedProfiles.contains(where: { $0.kind == kind }),
                            status: fleet
                        )
                        Text(kind.rawValue)
                    }
                    .font(.custom("Arial", size: 12).weight(.bold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(selectedPrinterKind == kind ? .blue : .gray.opacity(0.34))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        // The blue selected fill is the only selection cue.
                        // Do not add a second green outline around the active
                        // profile; green is reserved for a printer that is
                        // actually printing.
                        .stroke(.clear, lineWidth: 0)
                }
                .accessibilityLabel(profileAccessibilityText(kind: kind, status: fleet))
            }
        }
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
                activeCinemaStandbyHUD
            }

            Text(timelapse.statusText)
                .font(.custom("Arial", size: 15).weight(.semibold))
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            if bluetooth.h2dTotalLayers > 0 {
                Text(
                    timelapse.isStopping
                        ? "\(printerName) • đang dừng chụp và ghép ảnh"
                        : bluetooth.isStoppingPrint
                            ? "\(printerName) • đang dừng bản in"
                            : bluetooth.isPausedPrint
                                ? "\(printerName) • đang tạm dừng"
                            : isLayerPrintingOrChangingFilament
                        ? "\(printerName) • đang in lớp \(bluetooth.h2dCurrentLayer)/\(bluetooth.h2dTotalLayers)"
                        : "\(printerName) • \(bluetooth.h2dStageText.lowercased())"
                )
                    .font(.custom("Arial", size: 13).monospacedDigit().weight(.bold))
                    .foregroundStyle(.orange.opacity(0.65))
            }

            HStack(spacing: 7) {
                Image(systemName: "cube.fill")
                    .foregroundStyle(bluetooth.filamentType.isEmpty ? .gray : .orange)
                Text(
                    bluetooth.filamentType.isEmpty
                        ? "\(printerName) • đang đồng bộ nhựa"
                        : "\(printerName) • \(bluetooth.materialDescription)"
                )
                    .font(.custom("Arial", size: 11).weight(.bold))
                    .foregroundStyle(bluetooth.filamentType.isEmpty ? .secondary : .primary)
            }

            if bluetooth.hasTemperatureTelemetry || bluetooth.hasFanTelemetry {
                VStack(spacing: 4) {
                    if bluetooth.hasTemperatureTelemetry { temperatureTelemetryRows }
                    if bluetooth.hasFanTelemetry {
                        Label(fanTelemetryText, systemImage: "fan.fill")
                            .font(.custom("Arial", size: 10).monospacedDigit().weight(.semibold))
                            .foregroundStyle(.cyan.opacity(0.78))
                    }
                }
            }

            capturedFramesCard
            Spacer(minLength: 4)

            if !timelapse.isRendering {
                HStack(spacing: 12) {
                    Button {
                        timelapse.setLiveMonitorVisible(!timelapse.isLiveMonitorVisible)
                    } label: {
                        Label(
                            timelapse.isLiveMonitorVisible
                                ? "Ẩn hình xem trước"
                                : "Hiện hình xem trước",
                            systemImage: timelapse.isLiveMonitorVisible
                                ? "video.slash.fill"
                                : "video.fill"
                        )
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(timelapse.isLiveMonitorVisible ? .gray : .blue)
                    .accessibilityLabel(
                        timelapse.isLiveMonitorVisible
                            ? "Ẩn hình xem trước"
                            : "Hiện hình xem trước"
                    )

                    Button {
                        timelapse.setTorchEnabled(!timelapse.isFlashModeActive)
                    } label: {
                        Label(
                            timelapse.isFlashModeActive ? "Tắt đèn flash" : "Bật đèn flash",
                            systemImage: timelapse.isFlashModeActive
                                ? "bolt.fill"
                                : "bolt.slash.fill"
                        )
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(timelapse.isFlashModeActive ? .yellow : .gray)
                    .disabled(!timelapse.canUseTorch)
                    .opacity(timelapse.canUseTorch ? 1 : 0.42)
                    .accessibilityLabel(
                        timelapse.isFlashModeActive ? "Tắt đèn flash" : "Bật đèn flash"
                    )

                    Button(role: .destructive) {
                        requestStopCapture()
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

            Text("Smooth Timelapse: camera được giữ sẵn sàng và chụp ngay trong khoảng tháp Smooth, trước khi máy chuyển sang lớp kế tiếp. Khi vào lại giữa bản in, SE bắt đầu từ lớp hiện tại và không chụp bù lớp cũ.")
                .font(.custom("Arial", size: 10))
                .foregroundStyle(.white.opacity(0.38))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .background(Color.clear)
    }

    private var activeCinemaStandbyHUD: some View {
        ZStack {
            ZStack {
                Image("CinemaProjectorOutline")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white.opacity(0.17))
                    .frame(width: 206, height: 366)
                    .shadow(color: cinemaCyan.opacity(0.28), radius: 12)
                    .opacity(isFlashArtworkActive ? 0 : 1)
                    .scaleEffect(isFlashArtworkActive ? 0.97 : 1)

                CinemaLightningArtwork(
                    tint: cinemaAmber
                )
                .frame(width: 170, height: 270)
                .opacity(isFlashArtworkActive ? 1 : 0)
                .scaleEffect(isFlashArtworkActive ? 1 : 0.97)
            }
            .animation(.easeInOut(duration: 0.24), value: isFlashArtworkActive)

            Circle()
                .stroke(.white.opacity(0.07), lineWidth: 7)
                .frame(width: 150, height: 150)
            Circle()
                .trim(from: 0, to: min(1, max(0.015, printerProgress)))
                .stroke(
                    AngularGradient(
                        colors: [cinemaAmber, cinemaCyan, cinemaGreen],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .frame(width: 150, height: 150)
                .rotationEffect(.degrees(-90))
                .shadow(color: cinemaCyan.opacity(0.35), radius: 6)
                .animation(.linear(duration: 0.3), value: bluetooth.h2dCurrentLayer)

            VStack(spacing: 6) {
                Image(systemName: timelapse.isRendering ? "film.stack.fill" : "camera.aperture")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(timelapse.isRendering ? cinemaCyan : cinemaAmber)
                Text("\(timelapse.capturedFrameCount)")
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .monospacedDigit()
                Text("FRAMES CAPTURED")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                    .tracking(0.7)
            }
        }
        .frame(height: 330)
        .overlay(alignment: .bottom) {
            HStack(spacing: 6) {
                Circle()
                    .fill(timelapse.isRendering ? cinemaCyan : cinemaGreen)
                    .frame(width: 5, height: 5)
                Text(timelapse.isRendering ? "RENDER ENGINE ACTIVE" : "LAYER SENSOR ARMED")
            }
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.46))
        }
    }

    private var capturedFramesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: timelapse.isCapturing ? "camera.fill" : "camera.badge.clock")
                    .foregroundStyle(timelapse.isCapturing ? Color.blue : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(timelapse.isCapturing ? "iPhone đang chụp ảnh lớp" : "Chế độ chụp đang hoạt động")
                        .font(.custom("Arial", size: 13).weight(.bold))
                    Text(
                        bluetooth.h2dStatusCode == "ARMED"
                            ? "ESP32 đã nhận chụp • đã lưu \(timelapse.capturedFrameCount) ảnh"
                            : "Đang đồng bộ ESP32 • đã lưu \(timelapse.capturedFrameCount) ảnh"
                    )
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(.black.opacity(0.46), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [cinemaCyan.opacity(0.26), .white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
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

    private func activateProfile(_ kind: BambuPrinterKind) {
        selectedPrinterKind = kind
        if let profile = BambuPrinterProfileStore.profile(for: kind) {
            printerIP = profile.ip
            printerSerial = profile.serial
        } else {
            printerIP = ""
            printerSerial = ""
        }
        bluetooth.prepareForPrinterProfile(kind, serial: printerSerial)
        accessCode = H2DAccessCodeStore.load(for: kind)
        automaticConfigurationAttempted = false
        let complete = hasCompleteSelectedProfile
        configurationSaved = complete
        showConfiguration = !complete
        pendingProfileSwitch = complete
        switchToSelectedProfileIfPossible()
    }

    private func requestStopCapture() {
        guard timelapse.capturedFrameCount > 0 else {
            bluetooth.setH2DTimelapseArmed(false)
            timelapse.disarm()
            return
        }
        showStopOptions = true
    }

    private func syncFleetWhenPossible() {
        guard configurationSaved, bluetooth.isH2DBridge,
              !bluetooth.isConfiguring, !bluetooth.isSwitchingPrinter else { return }
        bluetooth.syncFleetProfiles(selectedKind: selectedPrinterKind)
    }

    private func profileAccessibilityText(
        kind: BambuPrinterKind,
        status: BambuFleetStatus
    ) -> String {
        let selection = selectedPrinterKind == kind ? "đang được chọn để chụp" : "không được chọn để chụp"
        if status.hasCriticalError { return "\(kind.rawValue), có lỗi, \(selection)" }
        if status.hasActivePrintJob { return "\(kind.rawValue), đang in \(status.printPercent) phần trăm, \(selection)" }
        if status.isOnline { return "\(kind.rawValue), đang trực tuyến, \(selection)" }
        return "\(kind.rawValue), chưa trực tuyến, \(selection)"
    }

    private var hasCompleteSelectedProfile: Bool {
        !wifiSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !wifiPassword.isEmpty &&
            !printerIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !printerSerial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !accessCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func switchToSelectedProfileIfPossible() {
        guard pendingProfileSwitch, hasCompleteSelectedProfile,
              bluetooth.isH2DBridge, !bluetooth.isConfiguring else { return }
        pendingProfileSwitch = false
        automaticConfigurationAttempted = true
        configurationSaved = true
        showConfiguration = false
        bluetooth.selectStoredPrinterProfile(
            selectedPrinterKind,
            printerIP: printerIP,
            printerSerial: printerSerial,
            accessCode: accessCode
        )
    }

    private func reconcileBridgeWithSelectedProfile() {
        guard configurationSaved, hasCompleteSelectedProfile,
              bluetooth.isH2DBridge, !bluetooth.isConfiguring,
              !bluetooth.isSwitchingPrinter else { return }
        let desired = printerSerial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let reported = bluetooth.printerSerial
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !desired.isEmpty, !reported.isEmpty, desired != reported else { return }
        bluetooth.prepareForPrinterProfile(selectedPrinterKind, serial: desired)
        pendingProfileSwitch = true
        switchToSelectedProfileIfPossible()
    }

    private func telemetryValue(_ label: String, current: Int, target: Int) -> some View {
        let currentText = current >= 0 ? "\(current)" : "–"
        let targetText = target >= 0 ? "\(target)" : "–"
        return Label("\(label) \(currentText)/\(targetText)°C", systemImage: "thermometer.medium")
            .font(.custom("Arial", size: 11).monospacedDigit().weight(.semibold))
            .foregroundStyle(.orange.opacity(0.88))
    }

    @ViewBuilder
    private var temperatureTelemetryRows: some View {
        if detectedPrinterKind == .h2d {
            VStack(alignment: .leading, spacing: 5) {
                // Match the physical H2D layout: left is outside, right is inside.
                HStack(spacing: 12) {
                    telemetryValue(
                        "Đầu trái",
                        current: bluetooth.leftNozzleTemperature,
                        target: bluetooth.leftNozzleTargetTemperature
                    )
                    telemetryValue(
                        "Đầu phải",
                        current: bluetooth.nozzleTemperature,
                        target: bluetooth.nozzleTargetTemperature
                    )
                }
                telemetryValue(
                    "Bàn in",
                    current: bluetooth.bedTemperature,
                    target: bluetooth.bedTargetTemperature
                )
            }
        } else {
            HStack(spacing: 12) {
                telemetryValue(
                    "Đầu in",
                    current: bluetooth.nozzleTemperature,
                    target: bluetooth.nozzleTargetTemperature
                )
                telemetryValue(
                    "Bàn in",
                    current: bluetooth.bedTemperature,
                    target: bluetooth.bedTargetTemperature
                )
            }
        }
    }

    private var fanTelemetryText: String {
        var values: [String] = []
        if bluetooth.partFanPercent >= 0 { values.append("Part \(bluetooth.partFanPercent)%") }
        if bluetooth.auxiliaryFanPercent >= 0 { values.append("Aux \(bluetooth.auxiliaryFanPercent)%") }
        if bluetooth.exhaustFanPercent >= 0 { values.append("Exhaust \(bluetooth.exhaustFanPercent)%") }
        return "Quạt: " + values.joined(separator: " • ")
    }

    private var currentAlarmID: String {
        let detail = bluetooth.activeCriticalPrinterAlertText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(bluetooth.activeCriticalPrinterDisplayName)|\(detail.isEmpty ? "critical" : detail)"
    }

    private func applyHardwareControls(force: Bool = false) {
        printerAlarm.setLevel(Double(bluetooth.hardwareLevelPercent) / 100.0)
        timelapse.setEffectSoundLevel(Double(bluetooth.hardwareLevelPercent) / 100.0)

        // Potentiometer reports are frequent. They only control brightness and
        // alarm volume, so they must not disturb a torch the user enabled from
        // the app or restart another hardware action.
        if !force && bluetooth.hardwareLastControl == "LEVEL" { return }

        let mode = bluetooth.hardwareMode
        let buttonHeld = bluetooth.hardwareHoldActive
        let keepCameraWarm = setupCameraEnabled || timelapse.isArmed || mode == 1
        timelapse.setHardwareTorch(
            steady: mode == -1,
            blinking: buttonHeld,
            keepCameraWarm: keepCameraWarm
        )

        if mode == 1 {
            guard !hardwareModeOneLatched else { return }
            guard bluetooth.isH2DReady, !timelapse.isArmed,
                  !timelapse.isRendering, !hardwareArmRequested else { return }
            hardwareModeOneLatched = true
            hardwareArmRequested = true
            hardwareStartedCapture = true
            timelapse.arm(startingAtLayer: bluetooth.h2dCurrentLayer)
            // Permission denial or a camera startup failure must not leave the
            // hardware switch permanently unable to retry.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if !timelapse.isArmed { hardwareArmRequested = false }
            }
            return
        }

        hardwareModeOneLatched = false
        hardwareArmRequested = false
        // MODE 0 is neutral for a manually started capture. Only leaving
        // position +1 may stop a session that position +1 itself started.
        guard hardwareStartedCapture else { return }
        hardwareStartedCapture = false
        guard timelapse.isArmed, !timelapse.isStopping else { return }
        // Leaving the right position is an intentional end of capture, not a
        // printer fault. Preserve existing frames by rendering them when any
        // were already captured; an empty run can simply be disarmed.
        if timelapse.capturedFrameCount > 0 {
            timelapse.finishEarlyAndRender()
        } else {
            timelapse.disarm()
        }
    }

    private func scheduleHardwareControls() {
        // Industrial three-position switches briefly touch the centre contact
        // while moving between sides. Coalesce bounce and intermediate MODE
        // packets, then apply only the final physical position. LEVEL has its
        // own lightweight observer and never needs to restart the camera.
        guard bluetooth.hardwareLastControl != "LEVEL" else { return }
        hardwareControlGeneration &+= 1
        let generation = hardwareControlGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard generation == self.hardwareControlGeneration else { return }
            self.applyHardwareControls()
        }
    }

    private func synchronizePrinterAlarm() {
        guard bluetooth.hasActiveCriticalPrinterAlert else {
            printerAlarm.stop()
            showCriticalPrinterAlarm = false
            acknowledgedAlarmID = ""
            return
        }
        // A fault on another profile remains visible in red on the iPhone,
        // while ESP32's own buzzer handles it. Moving to that profile transfers
        // the audible/modal alarm to the phone without losing the fault.
        guard bluetooth.shouldPlayPhonePrinterAlarm else {
            printerAlarm.stop()
            showCriticalPrinterAlarm = false
            return
        }
        guard acknowledgedAlarmID != currentAlarmID else { return }
        showCriticalPrinterAlarm = true
        printerAlarm.startLooping()
    }

    private func persistActiveProfile() {
        let detected = BambuPrinterKind.detect(serial: printerSerial)
        let kind = detected == .unknown ? selectedPrinterKind : detected
        guard kind != .unknown else { return }
        selectedPrinterKind = kind
        BambuPrinterProfileStore.save(
            BambuPrinterProfile(kind: kind, ip: printerIP, serial: printerSerial)
        )
        H2DAccessCodeStore.save(accessCode, for: kind)
        savedProfiles = BambuPrinterProfileStore.load()
        syncFleetWhenPossible()
    }
}

private struct PrinterActivityDot: View {
    let isConfigured: Bool
    let status: BambuFleetStatus

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let brightHalf = Int(context.date.timeIntervalSinceReferenceDate) % 2 == 0
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
                .opacity(shouldBlink ? (brightHalf ? 1 : 0.18) : 1)
                .shadow(color: dotColor.opacity(shouldBlink && brightHalf ? 0.9 : 0), radius: 4)
        }
    }

    private var shouldBlink: Bool {
        status.hasCriticalError || status.hasActivePrintJob
    }

    private var dotColor: Color {
        if status.hasCriticalError { return .red }
        // Green means an active print only.  A powered, idle printer is
        // reachable but waiting, so it gets yellow.  A configured printer
        // that is powered off (or has a stale IP) is black, never yellow.
        if status.hasActivePrintJob { return .green }
        if status.isOnline { return .yellow }
        return .black
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .background(.black.opacity(0.50), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 0.18, green: 0.88, blue: 0.96).opacity(0.24),
                                .white.opacity(0.08),
                                Color(red: 0.96, green: 0.61, blue: 0.20).opacity(0.15)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
    }
}

private struct CinemaTechnologyBackdrop: View {
    var body: some View {
        ZStack {
            Color.black

            LinearGradient(
                colors: [
                    Color(red: 0.015, green: 0.055, blue: 0.065),
                    Color(red: 0.025, green: 0.028, blue: 0.045),
                    .black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Canvas { context, size in
                var path = Path()
                let spacing: CGFloat = 28
                for x in stride(from: CGFloat.zero, through: size.width, by: spacing) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: CGFloat.zero, through: size.height, by: spacing) {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(.white.opacity(0.018)), lineWidth: 0.5)
            }

            RadialGradient(
                colors: [Color.cyan.opacity(0.10), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 360
            )

            RadialGradient(
                colors: [Color.orange.opacity(0.055), .clear],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 300
            )
        }
    }
}

private struct CinemaViewfinderOverlay: View {
    let tint: Color

    var body: some View {
        ZStack {
            Image(systemName: "viewfinder")
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint.opacity(0.38))
                .padding(10)

            HStack(spacing: 5) {
                Rectangle()
                    .fill(tint.opacity(0.20))
                    .frame(width: 28, height: 0.5)
                Circle()
                    .stroke(tint.opacity(0.45), lineWidth: 0.7)
                    .frame(width: 9, height: 9)
                Rectangle()
                    .fill(tint.opacity(0.20))
                    .frame(width: 28, height: 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CinemaLightningArtwork: View {
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.08, to: 0.42)
                .stroke(tint.opacity(0.30), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .rotationEffect(.degrees(-28))
            Circle()
                .trim(from: 0.55, to: 0.90)
                .stroke(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 6]))
                .rotationEffect(.degrees(24))
                .padding(13)

            Image(systemName: "bolt.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint.opacity(0.18))
                .padding(24)

            Image(systemName: "bolt")
                .resizable()
                .scaledToFit()
                .fontWeight(.ultraLight)
                .foregroundStyle(.white.opacity(0.94))
                .padding(24)
                .shadow(color: tint.opacity(0.70), radius: 9)

            VStack {
                HStack(spacing: 5) {
                    Rectangle().frame(width: 20, height: 1)
                    Circle().frame(width: 3, height: 3)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().frame(width: 3, height: 3)
                    Rectangle().frame(width: 20, height: 1)
                }
            }
            .foregroundStyle(tint.opacity(0.36))
            .padding(.vertical, 26)
        }
        .accessibilityHidden(true)
    }
}

private struct CinemaProgressRail: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let fraction = min(1, max(0, progress))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.065))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.48), tint, .cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(5, proxy.size.width * fraction))
                    .shadow(color: tint.opacity(0.70), radius: 5)
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.45), value: progress)
    }
}

private struct CinemaLaunchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.black.opacity(0.88))
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.96, green: 0.61, blue: 0.20),
                        Color(red: 0.99, green: 0.77, blue: 0.35)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.38), lineWidth: 1)
            }
            .shadow(color: Color.orange.opacity(configuration.isPressed ? 0.18 : 0.42), radius: 13, y: 5)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct CinemaIconButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(tint)
            .background(tint.opacity(configuration.isPressed ? 0.18 : 0.09), in: Circle())
            .overlay { Circle().stroke(tint.opacity(0.24), lineWidth: 1) }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
    }
}

private struct CinemaTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<_Label>) -> some View {
        configuration
            .padding(.horizontal, 12)
            .frame(minHeight: 42)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(.white.opacity(0.09), lineWidth: 1)
            }
    }
}

private struct ScreenEdgeLEDStrip: View {
    let color: Color
    let progress: Double?
    let remainingSeconds: TimeInterval?
    let blinks: Bool
    let breathingPeriod: TimeInterval?
    let minimumOpacity: Double
    let maximumOpacity: Double
    let preservesProgressWhenHidden: Bool

    @State private var pulse = true
    @State private var reportedProgress = 0.0
    @State private var transitionStartProgress = 0.0
    @State private var progressAnchorDate = Date()
    @State private var remainingSecondsAtAnchor: TimeInterval?

    private let correctionDuration: TimeInterval = 1.2

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 30.0,
            paused: progress == nil && breathingPeriod == nil
        )) { context in
            let liveProgress = progress == nil ? nil : interpolatedProgress(at: context.date)
            let shimmer = (sin(context.date.timeIntervalSinceReferenceDate * 3.2) + 1.0) / 2.0
            let breathingOpacity = smoothBreathingOpacity(at: context.date)
            stripContent(progress: liveProgress, shimmer: shimmer)
                .opacity(breathingOpacity)
        }
        .opacity(blinks && !pulse ? 0.22 : 1)
        .onAppear {
            reanchorProgress(progress, remainingSeconds: remainingSeconds)
            guard blinks else { return }
            withAnimation(.linear(duration: 0.18).repeatForever(autoreverses: true)) {
                pulse = false
            }
        }
        .onChange(of: progress) { _, newProgress in
            reanchorProgress(newProgress, remainingSeconds: remainingSeconds)
        }
        .onChange(of: remainingSeconds) { _, newRemainingSeconds in
            reanchorProgress(progress, remainingSeconds: newRemainingSeconds)
        }
        .onChange(of: blinks) { _, shouldBlink in
            if shouldBlink {
                withAnimation(.linear(duration: 0.18).repeatForever(autoreverses: true)) {
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

    private func smoothBreathingOpacity(at date: Date) -> Double {
        guard let breathingPeriod, breathingPeriod > 0 else {
            return maximumOpacity
        }
        let radians = date.timeIntervalSinceReferenceDate * 2.0 * .pi / breathingPeriod
        let unit = (sin(radians) + 1.0) / 2.0
        let eased = unit * unit * (3.0 - 2.0 * unit)
        return minimumOpacity + (maximumOpacity - minimumOpacity) * eased
    }

    @ViewBuilder
    private func stripContent(progress: Double?, shimmer: Double) -> some View {
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
                                Color.mint.opacity(0.78 + shimmer * 0.16),
                                .white.opacity(0.78 + shimmer * 0.20)
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
                        .white.opacity(0.62 + shimmer * 0.30),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
            } else {
                ClockwiseScreenBorderShape()
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .shadow(color: color.opacity(0.65), radius: 5)
            }
        }
    }

    private func interpolatedProgress(at date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(progressAnchorDate))
        let correction = min(1, elapsed / correctionDuration)
        let easedCorrection = correction * correction * (3 - 2 * correction)
        let corrected = transitionStartProgress +
            (reportedProgress - transitionStartProgress) * easedCorrection
        guard elapsed > correctionDuration,
              let remainingSecondsAtAnchor,
              remainingSecondsAtAnchor > correctionDuration else {
            return min(1, max(0, corrected))
        }
        let predictionElapsed = elapsed - correctionDuration
        let predictionDuration = remainingSecondsAtAnchor - correctionDuration
        let predicted = reportedProgress +
            (1 - reportedProgress) * min(1, predictionElapsed / predictionDuration)
        return min(0.999, max(corrected, predicted))
    }

    private func reanchorProgress(
        _ newProgress: Double?,
        remainingSeconds: TimeInterval?
    ) {
        // A blue capture flash makes `progress` nil for a moment. Do not turn
        // that visual overlay into a real progress reset; the next green frame
        // continues from the clock position that was already moving.
        if newProgress == nil && preservesProgressWhenHidden { return }
        let now = Date()
        let previous = interpolatedProgress(at: now)
        let target = min(1, max(0, newProgress ?? 0))
        transitionStartProgress = newProgress == nil ? target : previous
        reportedProgress = max(transitionStartProgress, target)
        progressAnchorDate = now
        remainingSecondsAtAnchor = remainingSeconds
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
