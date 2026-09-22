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
    @AppStorage("SE.H2D.hardwareBuzzerEnabled") private var hardwareBuzzerEnabled = true
    @AppStorage("SE.H2D.hardwareBuzzerVolume") private var hardwareBuzzerVolume = 1.0
    @AppStorage("SE.H2D.hardwareLEDBrightness") private var hardwareLEDBrightness = 0.95
    @AppStorage("SE.H2D.captureScreenBrightness") private var captureScreenBrightness = 0.0
    @State private var wifiPassword = ""
    @State private var accessCode = ""
    @State private var showConfiguration = true
    @State private var idlePulse = false
    @State private var showStopOptions = false
    @State private var automaticConfigurationAttempted = false
    @State private var selectedPrinterKind: BambuPrinterKind = .h2d
    @State private var selectedProfileID = ""
    @State private var profileDisplayName = ""
    @State private var savedProfiles: [BambuPrinterProfile] = []
    @State private var pendingProfileSwitch = false
    @State private var showCriticalPrinterAlarm = false
    @State private var acknowledgedAlarmID = ""
    @State private var hardwareArmRequested = false
    @State private var hardwareStartedCapture = false
    @State private var hardwareModeOneLatched = false
    @State private var hardwareControlGeneration = 0
    @State private var lastAppliedHardwareMode: Int?
    @State private var lastAppliedHardwareHold: Bool?
    @State private var completionBlueActive = false
    @State private var completionDismissWorkItem: DispatchWorkItem?
    @State private var acknowledgedFleetCompletions: Set<String> = []
    @State private var pendingFleetCompletionAcknowledgements: Set<String> = []
    @State private var buzzerVolumeSendWorkItem: DispatchWorkItem?
    @State private var ledBrightnessSendWorkItem: DispatchWorkItem?
    @State private var showCaptureBrightnessSlider = false
    @State private var captureBrightnessCollapseWorkItem: DispatchWorkItem?

    private var detectedPrinterKind: BambuPrinterKind {
        let fromSerial = BambuPrinterKind.detect(serial: printerSerial)
        if fromSerial != .unknown { return fromSerial }
        if !configurationSaved { return selectedPrinterKind }
        let fromBridge = bluetooth.printerKind
        return fromBridge == .unknown ? selectedPrinterKind : fromBridge
    }

    private var printerName: String {
        let trimmed = profileDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? detectedPrinterKind.rawValue : trimmed
    }

    private var selectedProfile: BambuPrinterProfile? {
        savedProfiles.first { $0.id == selectedProfileID } ??
            savedProfiles.first {
                $0.serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ==
                    printerSerial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            }
    }

    private var selectedFleetStatus: BambuFleetStatus {
        if let selectedProfile { return bluetooth.fleetStatus(for: selectedProfile) }
        return bluetooth.fleetStatus(for: selectedPrinterKind)
    }

    private let cinemaCyan = Color(red: 0.18, green: 0.88, blue: 0.96)
    private let cinemaAmber = Color(red: 0.96, green: 0.61, blue: 0.20)
    private let cinemaGreen = Color(red: 0.20, green: 0.94, blue: 0.57)

    var body: some View {
        observedContent
            .onChange(of: bluetooth.hardwareControlRevision) { _, _ in
                scheduleHardwareControls()
            }
            .onChange(of: timelapse.isRendering) { _, rendering in
                if !rendering { applyHardwareControls(force: true) }
            }
            .alert("\(bluetooth.activeCriticalPrinterDisplayName) đang có lỗi", isPresented: $showCriticalPrinterAlarm) {
                Button("OK") {
                    acknowledgedAlarmID = currentAlarmID
                    printerAlarm.stop()
                    bluetooth.acknowledgeCriticalPrinterAlarm()
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
        alarmObservedContent
            .onChange(of: bluetooth.hasActiveCriticalPrinterAlert) { _, _ in
                synchronizePrinterAlarm()
            }
            .onChange(of: bluetooth.activeCriticalPrinterKind) { _, _ in
                synchronizePrinterAlarm()
            }
            .onChange(of: bluetooth.activeCriticalPrinterAlertText) { _, _ in
                synchronizePrinterAlarm()
            }
            .onChange(of: hardwareBuzzerEnabled) { _, enabled in
                bluetooth.setHardwareBuzzerEnabled(enabled)
            }
            .onChange(of: hardwareBuzzerVolume) { _, _ in
                scheduleHardwareBuzzerVolumeSync()
            }
            .onChange(of: hardwareLEDBrightness) { _, _ in
                scheduleHardwareLEDBrightnessSync()
            }
            .onChange(of: captureScreenBrightness) { _, brightness in
                timelapse.setCaptureScreenBrightness(brightness)
                if showCaptureBrightnessSlider {
                    scheduleCaptureBrightnessAutoCollapse()
                }
            }
    }

    // Keep the modifier tree in small stages. Besides making the individual
    // responsibilities clearer, this avoids SwiftUI's generic type checker
    // having to solve the entire screen as one enormous expression.
    private var alarmObservedContent: some View {
        bridgeObservedContent
            .onChange(of: bluetooth.isH2DBridge) { _, recognized in
                if recognized {
                    reconcileBridgeWithSelectedProfile()
                    switchToSelectedProfileIfPossible()
                    attemptAutomaticConfigurationIfNeeded()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        syncFleetWhenPossible()
                        bluetooth.setHardwareBuzzerEnabled(hardwareBuzzerEnabled)
                        bluetooth.requestFleetRefresh()
                    }
                }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 120_000_000_000)
                    guard !Task.isCancelled else { return }
                    bluetooth.requestFleetRefresh()
                }
            }
            .onChange(of: bluetooth.printerSerial) { _, _ in
                reconcileBridgeWithSelectedProfile()
            }
            .onChange(of: printerSerial) { _, serial in
                let detected = BambuPrinterKind.detect(serial: serial)
                guard detected != .unknown, detected != selectedPrinterKind else { return }
                selectedPrinterKind = detected
                if let profile = BambuPrinterProfileStore.profile(id: selectedProfileID) {
                    accessCode = H2DAccessCodeStore.load(for: profile)
                } else {
                    accessCode = H2DAccessCodeStore.load(for: detected)
                }
            }
            .onChange(of: bluetooth.hasBridgeError) { _, hasError in
                // A bridge/configuration failure means the saved values need to be
                // editable again. Printer HMS alerts use hasActivePrinterAlert and
                // do not reopen this form.
                if hasError && bluetooth.isH2DBridge && !configurationSaved {
                    showConfiguration = true
                }
            }
    }

    private var bridgeObservedContent: some View {
        printerObservedContent
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
                if bluetooth.isH2DReady { applyHardwareControls() }
                if status == "READY" || status == "ARMED" || status == "DISARMED" {
                    syncFleetWhenPossible()
                }
            }
            .onChange(of: bluetooth.h2dPrintState) { _, state in
                updateCompletionPresentation(for: state)
            }
            .onChange(of: bluetooth.fleetStatuses) { _, statuses in
                updateFleetCompletionPresentations(statuses)
            }
            .onChange(of: bluetooth.profileFleetStatuses) { _, _ in
                updateProfileFleetCompletionPresentations()
            }
    }

    private var printerObservedContent: some View {
        lifecycleObservedContent
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
    }

    private var lifecycleObservedContent: some View {
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
        .onAppear {
            timelapse.setViewActive(true)
            savedProfiles = BambuPrinterProfileStore.load()
            if let activeProfile = savedProfiles.first(where: {
                $0.serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ==
                    printerSerial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            }) {
                selectedProfileID = activeProfile.id
                selectedPrinterKind = activeProfile.kind
                profileDisplayName = activeProfile.displayName
                accessCode = H2DAccessCodeStore.load(for: activeProfile)
            } else {
                let storedKind = BambuPrinterKind.detect(serial: printerSerial)
                if storedKind != .unknown { selectedPrinterKind = storedKind }
            }
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
                bluetooth.setHardwareBuzzerEnabled(hardwareBuzzerEnabled)
                bluetooth.setHardwareBuzzerVolume(Int((hardwareBuzzerVolume * 100).rounded()))
                bluetooth.setHardwareLEDBrightness(Int((hardwareLEDBrightness * 100).rounded()))
                bluetooth.requestFleetRefresh()
                synchronizePrinterAlarm()
            }
        }
        .onDisappear {
            captureBrightnessCollapseWorkItem?.cancel()
            captureBrightnessCollapseWorkItem = nil
            timelapse.restoreDisplayWhenLeaving()
            timelapse.setHardwareTorch(steady: false, blinking: false, keepCameraWarm: false)
            if !timelapse.isArmed { timelapse.stopPreview() }
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
            case .idle: return .yellow
            case .connecting: return .blue
            case .preparing, .printing: return .green
            case .capturing: return .blue
            case .stopping, .paused: return .red
            case .completed: return .blue
            case .error: return .red
            }
        }

    }

    private var printerIslandState: PrinterIslandState {
        if bluetooth.hasSelectedCriticalPrinterAlert || visibleBridgeError { return .error }
        if timelapse.isStopping || bluetooth.isStoppingPrint { return .stopping }
        if bluetooth.isPausedPrint { return .paused }
        if !bluetooth.isConnected { return .connecting }
        if timelapse.isCapturing { return .capturing }
        if !bluetooth.isH2DReady { return .connecting }
        if completionBlueActive { return .completed }
        // The selected profile is also refreshed by the independent fleet
        // watcher. Use that fresh signal immediately when the primary detail
        // packet is late; this prevents an actively printing H2D from staying
        // yellow until the user taps another profile and comes back.
        if selectedFleetStatus.hasActivePrintJob {
            return selectedFleetStatus.printState.uppercased() == "RUNNING"
                ? .printing : .preparing
        }
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
        case .printing:
            if bluetooth.h2dRemainingMinutes >= 0 {
                return "\(printerName) • \(bluetooth.h2dPrintPercent)% • \(bluetooth.remainingPrintTimeText.uppercased())"
            }
            return "\(printerName) • ĐANG IN \(bluetooth.h2dPrintPercent)%"
        case .capturing: return "\(printerName) • ĐANG CHỤP ẢNH"
        case .connecting: return "ESP32 • ĐANG KẾT NỐI \(printerName)"
        case .stopping: return "\(printerName) • ĐANG DỪNG"
        case .paused: return "\(printerName) • ĐANG TẠM DỪNG"
        case .completed: return "\(printerName) • ĐÃ IN XONG"
        case .error:
            if bluetooth.hasSelectedCriticalPrinterAlert {
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

    /// Keep the screen edge quiet during normal use. It is reserved for the
    /// two states that require immediate attention: a printer fault or an
    /// active stop request. Capture and print progress use the horizontal rail.
    private var screenEdgeLEDStrip: some View {
        let isError = printerIslandState == .error
        let shouldShowEdge = isError || printerIslandState == .stopping

        return ScreenEdgeLEDStrip(
            color: .red,
            progress: nil,
            remainingSeconds: nil,
            blinks: isError,
            breathingPeriod: nil,
            minimumOpacity: 1.0,
            maximumOpacity: 1.0,
            preservesProgressWhenHidden: false
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
        if selectedFleetStatus.printPercent > 0 {
            return Double(selectedFleetStatus.printPercent) / 100.0
        }
        if bluetooth.h2dTotalLayers > 0 {
            return Double(bluetooth.h2dCurrentLayer) / Double(max(1, bluetooth.h2dTotalLayers))
        }
        return 0
    }

    private var isLayerPrintingOrChangingFilament: Bool {
        (bluetooth.h2dPrintState.uppercased() == "RUNNING" &&
            (bluetooth.isActuallyPrinting || bluetooth.h2dCurrentLayer > 0)) ||
            selectedFleetStatus.hasActivePrintJob
    }

    private func updateCompletionPresentation(for state: String) {
        let normalized = state.uppercased()
        if ["FINISH", "COMPLETE", "COMPLETED"].contains(normalized) {
            guard !completionBlueActive else { return }
            completionDismissWorkItem?.cancel()
            completionBlueActive = true
            let workItem = DispatchWorkItem {
                completionBlueActive = false
            }
            completionDismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                // Show one complete slow blue breath, then return to the
                // borderless standby state without requiring a tap.
                deadline: .now() + 4.0,
                execute: workItem
            )
        } else if ["RUNNING", "PREPARE", "PREPARING", "SLICING", "INIT", "HEATING"].contains(normalized) {
            dismissCompletionPresentation()
        }
    }

    private func dismissCompletionPresentation() {
        completionDismissWorkItem?.cancel()
        completionDismissWorkItem = nil
        completionBlueActive = false
    }

    private func updateFleetCompletionPresentations(
        _ statuses: [BambuPrinterKind: BambuFleetStatus]
    ) {
        for profile in savedProfiles {
            guard let status = bluetooth.profileFleetStatuses[profile.id] ?? statuses[profile.kind] else { continue }
            updateFleetCompletionPresentation(profile: profile, status: status)
        }
    }

    private func updateProfileFleetCompletionPresentations() {
        for profile in savedProfiles {
            updateFleetCompletionPresentation(
                profile: profile,
                status: bluetooth.fleetStatus(for: profile)
            )
        }
    }

    private func updateFleetCompletionPresentation(
        profile: BambuPrinterProfile,
        status: BambuFleetStatus
    ) {
            let profileID = profile.id
            let state = status.printState.uppercased()
            let completed = ["FINISH", "COMPLETE", "COMPLETED"].contains(state)
            if status.hasActivePrintJob {
                acknowledgedFleetCompletions.remove(profileID)
                pendingFleetCompletionAcknowledgements.remove(profileID)
                return
            }
            guard completed,
                  !acknowledgedFleetCompletions.contains(profileID),
                  !pendingFleetCompletionAcknowledgements.contains(profileID) else { return }
            pendingFleetCompletionAcknowledgements.insert(profileID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                guard pendingFleetCompletionAcknowledgements.contains(profileID) else { return }
                pendingFleetCompletionAcknowledgements.remove(profileID)
                let current = bluetooth.fleetStatus(for: profile).printState.uppercased()
                guard ["FINISH", "COMPLETE", "COMPLETED"].contains(current) else { return }
                acknowledgedFleetCompletions.insert(profileID)
            }
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

                    if bluetooth.isPrintSessionActive {
                        HStack(spacing: 7) {
                            Image(systemName: "timer")
                                .foregroundStyle(cinemaCyan)
                            Text(bluetooth.remainingPrintTimeText)
                                .fontWeight(.bold)
                            Spacer(minLength: 8)
                            if !bluetooth.estimatedPrintFinishText.isEmpty {
                                Text(bluetooth.estimatedPrintFinishText)
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                    }
                }
                .padding(.vertical, 2)
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
                !bluetooth.hasSelectedCriticalPrinterAlert &&
                !bluetooth.printerAlertText.isEmpty {
                Label(bluetooth.printerAlertText, systemImage: "exclamationmark.triangle.fill")
                    .font(.custom("Arial", size: 11).weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .cardStyle()
    }

    private var bridgeAccentColor: Color {
        if visibleBridgeError || bluetooth.hasSelectedCriticalPrinterAlert { return .red }
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

            Toggle(isOn: $hardwareBuzzerEnabled) {
                Label("Loa báo trên ESP32", systemImage: hardwareBuzzerEnabled
                    ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.custom("Arial", size: 12).weight(.bold))
            }
            .tint(cinemaGreen)

            VStack(alignment: .leading, spacing: 10) {
                hardwareLevelSlider(
                    title: "Âm lượng loa ESP32",
                    systemImage: "speaker.wave.2.fill",
                    value: $hardwareBuzzerVolume
                )
                hardwareLevelSlider(
                    title: "Độ sáng LED ESP32",
                    systemImage: "sun.max.fill",
                    value: $hardwareLEDBrightness
                )
            }
            .padding(11)
            .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 12))

            if bluetooth.isSwitchingPrinter {
                printerProfileSwitchProgress
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if showConfiguration {
                Label("Chọn hồ sơ; SE còn tự kiểm tra đầu serial để nhận đúng A1 / H2D / P2S.", systemImage: "sparkles")
                    .font(.custom("Arial", size: 12).weight(.bold))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 12) {
                    configurationLabel("Tên hiển thị")
                    TextField("Ví dụ: Máy 1", text: $profileDisplayName)
                        .textInputAutocapitalization(.words)

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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(savedProfiles) { profile in
                    let fleet = effectiveFleetStatus(for: profile)
                    Button {
                        activateProfile(profile)
                    } label: {
                        HStack(spacing: 5) {
                            PrinterActivityDot(
                                isConfigured: true,
                                status: fleet,
                                isSwitching: bluetooth.isSwitchingPrinter && selectedProfileID == profile.id,
                                showsCompletion: ["FINISH", "COMPLETE", "COMPLETED"]
                                    .contains(fleet.printState.uppercased()) &&
                                    !acknowledgedFleetCompletions.contains(profile.id)
                            )
                            Text(profile.displayName)
                                .lineLimit(1)
                        }
                        .font(.custom("Arial", size: 12).weight(.bold))
                        .padding(.horizontal, 10)
                        .frame(minWidth: 82, minHeight: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(selectedProfileID == profile.id ? .blue : .gray.opacity(0.34))
                    .accessibilityLabel(profileAccessibilityText(profile: profile, status: fleet))
                    .disabled(bluetooth.isSwitchingPrinter && selectedProfileID == profile.id)
                    .draggable(profile.id)
                    .dropDestination(for: String.self) { identifiers, _ in
                        guard let movingID = identifiers.first else { return false }
                        savedProfiles = BambuPrinterProfileStore.reorder(
                            movingID: movingID,
                            before: profile.id
                        )
                        syncFleetWhenPossible()
                        return true
                    }
                }

                if savedProfiles.count < BambuPrinterProfileStore.maximumProfiles {
                    Button {
                        beginNewProfile()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .black))
                            .frame(width: 38, height: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.gray.opacity(0.34))
                    .accessibilityLabel("Thêm cấu hình máy in")
                }
            }
            .padding(.vertical, 2)
        }
        .animation(.easeInOut(duration: 0.25), value: bluetooth.isSwitchingPrinter)
    }

    private var printerProfileSwitchProgress: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(cinemaCyan)

                Text(bluetooth.printerSwitchPhaseText.isEmpty
                    ? "Đang chuyển sang \(selectedPrinterKind.rawValue)"
                    : bluetooth.printerSwitchPhaseText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(Int((bluetooth.printerSwitchProgress * 100).rounded()))%")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(cinemaCyan)
                    .monospacedDigit()
            }

            ProgressView(value: bluetooth.printerSwitchProgress, total: 1)
                .tint(cinemaCyan)
                .scaleEffect(x: 1, y: 1.35, anchor: .center)
                .animation(
                    .smooth(duration: 0.42),
                    value: bluetooth.printerSwitchProgress
                )
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(cinemaCyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(cinemaCyan.opacity(0.24), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Đang chuyển máy in \(selectedPrinterKind.rawValue)")
        .accessibilityValue("\(Int((bluetooth.printerSwitchProgress * 100).rounded())) phần trăm")
    }

    private var activeCaptureView: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 8)
            ZStack {
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

            }
            .frame(maxWidth: .infinity)

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

            if bluetooth.isPrintSessionActive || selectedFleetStatus.hasActivePrintJob {
                capturePrintProgressRail
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

    private var capturePrintProgressRail: some View {
        VStack(spacing: 7) {
            HStack(alignment: .lastTextBaseline) {
                Text("TIẾN ĐỘ IN THỜI GIAN THỰC")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.46))
                Spacer(minLength: 8)
                Text("\(bluetooth.h2dPrintPercent)%")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(cinemaGreen)
            }

            CinemaProgressRail(progress: printerProgress, tint: cinemaGreen)

            HStack(spacing: 7) {
                Image(systemName: "timer")
                    .foregroundStyle(cinemaCyan)
                Text(bluetooth.remainingPrintTimeText)
                    .fontWeight(.bold)
                Spacer(minLength: 8)
                if !bluetooth.estimatedPrintFinishText.isEmpty {
                    Text(bluetooth.estimatedPrintFinishText)
                        .foregroundStyle(.white.opacity(0.56))
                }
            }
            .font(.system(size: 10, design: .rounded))
            .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 1)
        }
        .padding(.horizontal, 22)
        .accessibilityElement(children: .combine)
    }

    private var activeCinemaStandbyHUD: some View {
        ZStack {
            if isFlashArtworkActive {
                CinemaLightningArtwork(
                    tint: cinemaAmber
                )
                .frame(width: 170, height: 270)
            }

            Group {
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
            // Flash mode should show only the clean lightning artwork.
            .opacity(isFlashArtworkActive ? 0 : 1)
            .animation(.easeInOut(duration: 0.18), value: isFlashArtworkActive)
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

    private var captureScreenBrightnessControl: some View {
        VStack(spacing: showCaptureBrightnessSlider ? 8 : 0) {
            Button {
                let willExpand = !showCaptureBrightnessSlider
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    showCaptureBrightnessSlider = willExpand
                }
                if willExpand {
                    scheduleCaptureBrightnessAutoCollapse()
                } else {
                    captureBrightnessCollapseWorkItem?.cancel()
                    captureBrightnessCollapseWorkItem = nil
                }
            } label: {
                HStack(spacing: 7) {
                    ZStack(alignment: captureScreenBrightness > 0.01 ? .bottom : .top) {
                        Capsule()
                            .fill(
                                captureScreenBrightness > 0.01
                                    ? cinemaAmber.opacity(0.34)
                                    : Color.white.opacity(0.09)
                            )
                        Circle()
                            .fill(captureScreenBrightness > 0.01 ? cinemaAmber : Color.white.opacity(0.42))
                            .padding(3)
                            .overlay {
                                Image(
                                    systemName: captureScreenBrightness > 0.01
                                        ? "sun.max.fill"
                                        : "sun.min.fill"
                                )
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(.black.opacity(0.78))
                            }
                    }
                    .frame(width: 36, height: 64)
                    .overlay {
                        Capsule()
                            .stroke(cinemaAmber.opacity(captureScreenBrightness > 0.01 ? 0.54 : 0.20), lineWidth: 1.2)
                    }

                    if showCaptureBrightnessSlider {
                        Text("\(Int((captureScreenBrightness * 100).rounded()))%")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(cinemaAmber)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                showCaptureBrightnessSlider
                    ? "Thu gọn thanh độ sáng màn hình"
                    : "Mở thanh độ sáng màn hình"
            )

            if showCaptureBrightnessSlider {
                Slider(value: $captureScreenBrightness, in: 0...1, step: 0.01)
                    .tint(cinemaAmber)
                    .frame(width: 164)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 38, height: 164)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.86, anchor: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.86, anchor: .top))
                        )
                    )

                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.white.opacity(0.45))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, showCaptureBrightnessSlider ? 11 : 5)
        .padding(.vertical, showCaptureBrightnessSlider ? 12 : 5)
        .background(.black.opacity(0.74), in: Capsule())
        .overlay { Capsule().stroke(cinemaAmber.opacity(0.34), lineWidth: 1.2) }
        .shadow(color: cinemaAmber.opacity(0.25), radius: 7)
        .opacity(isFlashArtworkActive ? 0.34 : 1)
        .disabled(isFlashArtworkActive)
        .animation(.spring(response: 0.30, dampingFraction: 0.82), value: showCaptureBrightnessSlider)
        .accessibilityLabel("Độ sáng màn hình iPhone")
        .accessibilityValue("\(Int((captureScreenBrightness * 100).rounded())) phần trăm")
    }

    private var capturedFramesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: timelapse.isCapturing ? "camera.fill" : "camera.badge.clock")
                    .foregroundStyle(timelapse.isCapturing ? Color.blue : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(timelapse.isCapturing ? "iPhone đang chụp ảnh" : "Chế độ chụp đang hoạt động")
                        .font(.custom("Arial", size: 13).weight(.bold))
                    Text(
                        bluetooth.h2dStatusCode == "ARMED"
                            ? "ESP32 đã nhận chụp • đã lưu \(timelapse.capturedFrameCount) ảnh"
                            : "Đang đồng bộ ESP32 • đã lưu \(timelapse.capturedFrameCount) ảnh"
                    )
                        .font(.custom("Arial", size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if timelapse.isCapturing {
                    ProgressView()
                        .tint(.blue)
                        .padding(.top, 8)
                }
                captureScreenBrightnessControl
                    .layoutPriority(1)
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

    private func hardwareLevelSlider(
        title: String,
        systemImage: String,
        value: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            Slider(value: value, in: 0...1, step: 0.01)
                .tint(cinemaCyan)
        }
    }

    private func scheduleHardwareBuzzerVolumeSync() {
        buzzerVolumeSendWorkItem?.cancel()
        let percent = Int((hardwareBuzzerVolume * 100).rounded())
        let workItem = DispatchWorkItem {
            bluetooth.setHardwareBuzzerVolume(percent)
            // A second idempotent delivery protects the final slider value if a
            // printer-status packet occupied the BLE write channel at release.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
                guard Int((hardwareBuzzerVolume * 100).rounded()) == percent else { return }
                bluetooth.setHardwareBuzzerVolume(percent)
            }
        }
        buzzerVolumeSendWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: workItem)
    }

    private func scheduleHardwareLEDBrightnessSync() {
        ledBrightnessSendWorkItem?.cancel()
        let percent = Int((hardwareLEDBrightness * 100).rounded())
        let workItem = DispatchWorkItem {
            bluetooth.setHardwareLEDBrightness(percent)
        }
        ledBrightnessSendWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: workItem)
    }

    private func scheduleCaptureBrightnessAutoCollapse() {
        captureBrightnessCollapseWorkItem?.cancel()
        guard showCaptureBrightnessSlider else {
            captureBrightnessCollapseWorkItem = nil
            return
        }
        let workItem = DispatchWorkItem {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                showCaptureBrightnessSlider = false
            }
            captureBrightnessCollapseWorkItem = nil
        }
        captureBrightnessCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
    }

    private func activateProfile(_ profile: BambuPrinterProfile) {
        let changedProfile = selectedProfileID != profile.id
        selectedProfileID = profile.id
        selectedPrinterKind = profile.kind
        profileDisplayName = profile.displayName
        printerIP = profile.ip
        printerSerial = profile.serial
        bluetooth.prepareForPrinterProfile(
            profile.kind,
            serial: printerSerial,
            profileID: profile.id
        )
        accessCode = H2DAccessCodeStore.load(for: profile)
        automaticConfigurationAttempted = false
        let complete = hasCompleteSelectedProfile
        configurationSaved = complete
        showConfiguration = !complete
        pendingProfileSwitch = complete
        if changedProfile { bluetooth.requestHardwareBeep() }
        switchToSelectedProfileIfPossible()
    }

    private func beginNewProfile() {
        guard savedProfiles.count < BambuPrinterProfileStore.maximumProfiles else { return }
        selectedProfileID = UUID().uuidString
        selectedPrinterKind = .unknown
        profileDisplayName = "Máy \(savedProfiles.count + 1)"
        printerIP = ""
        printerSerial = ""
        accessCode = ""
        configurationSaved = false
        automaticConfigurationAttempted = false
        pendingProfileSwitch = false
        showConfiguration = true
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
        bluetooth.syncFleetProfiles(selectedProfileID: selectedProfileID)
    }

    private func profileAccessibilityText(
        profile: BambuPrinterProfile,
        status: BambuFleetStatus
    ) -> String {
        let selection = selectedProfileID == profile.id ? "đang được chọn để chụp" : "không được chọn để chụp"
        if status.hasCriticalError { return "\(profile.displayName), có lỗi, \(selection)" }
        if status.hasActivePrintJob { return "\(profile.displayName), đang in \(status.printPercent) phần trăm, \(selection)" }
        if status.isOnline { return "\(profile.displayName), đang trực tuyến, \(selection)" }
        return "\(profile.displayName), chưa trực tuyến, \(selection)"
    }

    private func effectiveFleetStatus(for profile: BambuPrinterProfile) -> BambuFleetStatus {
        var status = bluetooth.fleetStatus(for: profile)
        if profile.id == selectedProfileID && bluetooth.isPrintSessionActive {
            status.isConfigured = true
            status.isOnline = true
            status.hasActivePrintJob = true
            status.printState = bluetooth.h2dPrintState
            status.printPercent = bluetooth.h2dPrintPercent
        }
        return status
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
        guard let profile = BambuPrinterProfileStore.profile(id: selectedProfileID) else { return }
        bluetooth.selectStoredPrinterProfile(profile, accessCode: accessCode)
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
        bluetooth.prepareForPrinterProfile(
            selectedPrinterKind,
            serial: desired,
            profileID: selectedProfileID
        )
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
        // Include every active fleet incident. If a second printer develops a
        // fault while the first one is already acknowledged, this signature
        // changes and the alarm is presented again instead of staying silent.
        let fleetSignature = savedProfiles.compactMap { profile -> String? in
            let status = bluetooth.fleetStatus(for: profile)
            guard status.hasCriticalError else { return nil }
            return "\(profile.id):\(status.printErrorCode):\(status.printState)"
        }.sorted().joined(separator: "|")
        if !fleetSignature.isEmpty { return fleetSignature }
        let detail = bluetooth.activeCriticalPrinterAlertText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(bluetooth.activeCriticalPrinterDisplayName)|\(detail.isEmpty ? "critical" : detail)"
    }

    private func applyHardwareControls(force: Bool = false) {
        let mode = bluetooth.hardwareMode
        let buttonHeld = bluetooth.hardwareHoldActive
        let controlsChanged = lastAppliedHardwareMode != mode ||
            lastAppliedHardwareHold != buttonHeld
        guard force || controlsChanged else { return }
        lastAppliedHardwareMode = mode
        lastAppliedHardwareHold = buttonHeld
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
        // packets, then apply only the final stable physical position. A
        // slightly longer window avoids starting and stopping AVCapture for
        // the centre contact while the knob is moving between its two sides.
        hardwareControlGeneration &+= 1
        let generation = hardwareControlGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
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
        // Every saved printer owns the same fleet-level alarm path. The user
        // must not have to open the faulty profile before the siren can start.
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
        let profileID = selectedProfileID.isEmpty ? UUID().uuidString : selectedProfileID
        let profile = BambuPrinterProfile(
            profileID: profileID,
            kind: kind,
            ip: printerIP,
            serial: printerSerial,
            customName: profileDisplayName
        )
        selectedProfileID = profileID
        profileDisplayName = profile.displayName
        BambuPrinterProfileStore.save(profile)
        H2DAccessCodeStore.save(accessCode, for: kind)
        H2DAccessCodeStore.save(accessCode, forProfileID: profileID)
        savedProfiles = BambuPrinterProfileStore.load()
        syncFleetWhenPossible()
    }
}

private struct PrinterActivityDot: View {
    let isConfigured: Bool
    let status: BambuFleetStatus
    let isSwitching: Bool
    let showsCompletion: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let brightHalf = Int(context.date.timeIntervalSinceReferenceDate) % 2 == 0
            let completionPhase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 4.0) / 4.0
            let completionOpacity = 0.18 + 0.82 *
                (0.5 - 0.5 * cos(completionPhase * .pi * 2.0))
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
                .opacity(showsCompletion
                    ? completionOpacity
                    : shouldBlink ? (brightHalf ? 1 : 0.18) : 1)
                .shadow(color: dotColor.opacity(shouldBlink && brightHalf ? 0.9 : 0), radius: 4)
        }
    }

    private var shouldBlink: Bool {
        isSwitching || status.hasCriticalError || status.hasActivePrintJob || showsCompletion
    }

    private var dotColor: Color {
        if isSwitching { return .cyan }
        if status.hasCriticalError { return .red }
        if showsCompletion { return .blue }
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
