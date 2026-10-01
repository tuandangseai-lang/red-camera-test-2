import Foundation
import SwiftUI

/// Compact printer controls embedded directly in the waiting room. Camera,
/// progress and telemetry stay in H2DTimelapseView so none of that information
/// is repeated here.
struct PrinterRemoteControlView: View {
    @ObservedObject var bluetooth: H2DBLEManager
    let printerName: String
    let profile: BambuPrinterProfile
    let accessCode: String
    let languageCode: String
    let alarmActive: Bool
    let alarmAcknowledged: Bool
    let onSilenceAlarm: () -> Void
    var lowPowerDarkMode = false

    @ObservedObject var directControl: BambuPrinterControlManager
    var compactLayout = false
    @State private var filamentTemperature = 220
    @State private var automaticTemperatureSignature = ""
    @State private var printSpeed = 2
    @State private var chamberLightEnabled = false
    @State private var confirmation: RemoteConfirmation?
    @State private var alarmPulse = false
    @State private var showsFilamentHelp = false
    @State private var selectedExternalExtruderID = 1
    @State private var amsDryingHours = 8
    @State private var dryerPulse = false

    private let cyan = Color(red: 0.02, green: 0.43, blue: 0.40)
    private let amber = Color(red: 0.91, green: 0.48, blue: 0.14)
    private let green = Color(red: 0.03, green: 0.61, blue: 0.43)

    private var controlsReady: Bool {
        directControl.isReady && !directControl.isPending
    }

    private var printActionsAvailable: Bool {
        // Printer telemetry, not a stale BLE session, owns print actions.
        // Drying an AMS is not a print job and cannot use pause/print-stop.
        controlsReady && directControl.snapshot.isRecent &&
            directControl.snapshot.hasActivePrintJob
    }

    private var printIsPaused: Bool {
        ["PAUSE", "PAUSED"].contains(directControl.snapshot.printState)
    }

    private var alarmNeedsAttention: Bool {
        alarmActive && !alarmAcknowledged
    }

    private var usesLeftNozzlePath: Bool {
        directControl.snapshot.extruderCount > 1 && externalSpoolExtruderID == 1
    }

    private var externalSpoolExtruderID: Int {
        guard directControl.snapshot.extruderCount > 1 || profile.kind == .h2d else { return 0 }
        return selectedExternalExtruderID
    }

    private var selectedExternalFilamentPresent: Bool? {
        let snapshot = directControl.snapshot
        // A P2S cannot run a real print without filament at its only
        // toolhead. Its top-level switch can briefly arrive as unknown/zero
        // while the AMS route is changing, so the active job is the stronger
        // signal during that short window.
        if snapshot.hasActivePrintJob, profile.kind == .p2s {
            return true
        }
        if snapshot.hasActivePrintJob,
           snapshot.currentAMSTrayID == nil,
           (snapshot.externalSpoolExtruderID == externalSpoolExtruderID || profile.kind == .p2s) {
            return true
        }
        if let value = snapshot.filamentPresentByExtruder[externalSpoolExtruderID] {
            return value
        }
        if snapshot.externalSpoolExtruderID == externalSpoolExtruderID {
            return snapshot.externalFilamentPresent
        }
        return nil
    }

    private var externalLoadUnavailable: Bool {
        selectedExternalFilamentPresent == true
    }

    private var externalUnloadUnavailable: Bool {
        selectedExternalFilamentPresent == false
    }

    private var surfaceColor: Color {
        lowPowerDarkMode ? Color(white: 0.055) : .white
    }

    private var subduedSurfaceColor: Color {
        lowPowerDarkMode ? Color.white.opacity(0.045) : Color.black.opacity(0.025)
    }

    private var hairlineColor: Color {
        lowPowerDarkMode ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compactLayout ? 10 : 14) {
            controlHeader
            Divider().overlay(hairlineColor)
            if let prompt = directControl.activePrompt {
                printerPromptCard(prompt)
            }
            quickActions
            if directControl.isPending || directControl.lastSucceeded != nil {
                controlFeedback
            }
            filamentControls
            if directControl.snapshot.hasAMS {
                amsControls
            }
            utilityControls
        }
        .padding(compactLayout ? 12 : 16)
        .background(
            surfaceColor,
            in: RoundedRectangle(cornerRadius: compactLayout ? 18 : 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: compactLayout ? 18 : 20, style: .continuous)
                .stroke(hairlineColor, lineWidth: 1)
        }
        .controlSize(compactLayout ? .small : .regular)
        .onAppear {
            startDirectControl()
            updateAlarmPulse()
            updateDryerPulse()
        }
        .onChange(of: profile.id) { _, _ in
            selectedExternalExtruderID = profile.kind == .h2d ? 1 : 0
            startDirectControl()
        }
        .onChange(of: accessCode) { _, _ in startDirectControl() }
        .onChange(of: bluetooth.filamentType) { _, _ in applyAutomaticFilamentTemperature() }
        .onChange(of: bluetooth.nozzleTargetTemperature) { _, _ in applyAutomaticFilamentTemperature() }
        .onChange(of: bluetooth.leftNozzleTargetTemperature) { _, _ in applyAutomaticFilamentTemperature() }
        .onChange(of: directControl.snapshot.chamberLightOn) { _, value in
            if let value { chamberLightEnabled = value }
        }
        .onChange(of: directControl.snapshot.printSpeedLevel) { _, value in
            if let value, (1...4).contains(value) { printSpeed = value }
        }
        .onChange(of: directControl.activePrompt?.id) { _, _ in
            showsFilamentHelp = false
        }
        .onChange(of: alarmNeedsAttention) { _, _ in updateAlarmPulse() }
        .onChange(of: directControl.snapshot.amsDrying) { _, _ in updateDryerPulse() }
        .alert(
            localized(confirmation?.title(
                usesLeftNozzlePath: usesLeftNozzlePath,
                languageCode: languageCode
            ) ?? "Xác nhận"),
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            presenting: confirmation
        ) { action in
            switch action {
            case .stop:
                Button(localized("Dừng"), role: .destructive) {
                    if printActionsAvailable { directControl.stopPrint() }
                }
                .disabled(!printActionsAvailable)
            case let .load(temperature):
                Button(localized(usesLeftNozzlePath
                    ? "Nạp cuộn ngoài vào đầu trái"
                    : "Nạp nhựa cuộn ngoài")) {
                    directControl.loadExternalFilament(
                        temperature: temperature,
                        extruderID: externalSpoolExtruderID
                    )
                }
            case let .unload(temperature, _):
                Button(localized(usesLeftNozzlePath ? "Rút nhựa đầu trái" : "Rút nhựa"), role: .destructive) {
                    directControl.unloadExternalFilament(
                        temperature: temperature,
                        extruderID: externalSpoolExtruderID
                    )
                }
            }
            Button(localized("Hủy"), role: .cancel) {}
        } message: { action in
            Text(localized(action.message(
                usesLeftNozzlePath: usesLeftNozzlePath,
                languageCode: languageCode
            )))
        }
    }

    private var controlFeedback: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: directControl.isPending ? "clock" :
                (directControl.lastSucceeded == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                .foregroundStyle(directControl.lastSucceeded == true ? green : amber)
            Text(localized(directControl.statusText))
                .font(.system(size: compactLayout ? 11 : 12))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("se.control.feedback")
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(subduedSurfaceColor, in: RoundedRectangle(cornerRadius: 10))
    }

    private var controlHeader: some View {
        HStack(spacing: compactLayout ? 7 : 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: compactLayout ? 14 : 15, weight: .semibold))
                .foregroundStyle(cyan)
                .frame(width: compactLayout ? 28 : 32, height: compactLayout ? 28 : 32)
                .background(cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text("\(localized("Điều khiển")) \(printerName)")
                .font(.system(size: compactLayout ? 14 : 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .layoutPriority(1)

            PrinterLifetimeHoursBadge(
                directControl: directControl,
                profile: profile,
                languageCode: languageCode,
                darkMode: lowPowerDarkMode
            )

            Spacer(minLength: compactLayout ? 2 : 6)

            if directControl.isPending {
                ProgressView().tint(amber)
            } else {
                Circle()
                    .fill(directControl.isReady ? green : amber)
                    .frame(width: 8, height: 8)
            }

            if !directControl.isReady && !directControl.isPending {
                Button {
                    directControl.retry()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .tint(cyan)
                .accessibilityLabel(localized("Kết nối lại điều khiển máy in"))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(localized(directControl.statusText))
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 9) {
            controlTitle("Thao tác nhanh", icon: "hand.tap.fill")

            HStack(spacing: 8) {
                Button {
                    if printIsPaused {
                        directControl.resumePrint()
                    } else {
                        directControl.pausePrint()
                    }
                } label: {
                    iconOnlyActionLabel(
                        printIsPaused ? "Tiếp tục" : "Tạm dừng",
                        icon: printIsPaused ? "play.fill" : "pause.fill"
                    )
                }
                .buttonStyle(RemoteActionButtonStyle(
                    tint: printActionsAvailable ? cyan : Color.gray.opacity(0.72)
                ))
                .disabled(!printActionsAvailable)
                .accessibilityIdentifier("se.print.pause-resume")

                Button {
                    confirmation = .stop
                } label: {
                    iconOnlyActionLabel("Dừng", icon: "stop.fill")
                }
                .buttonStyle(RemoteActionButtonStyle(
                    tint: printActionsAvailable ? .red : Color.gray.opacity(0.72)
                ))
                .disabled(!printActionsAvailable)
                .accessibilityIdentifier("se.print.stop")

                Button {
                    onSilenceAlarm()
                } label: {
                    iconOnlyActionLabel(
                        alarmAcknowledged ? "Đã tắt" : "Tắt cảnh báo",
                        icon: alarmAcknowledged ? "speaker.slash.fill" : "bell.slash.fill"
                    )
                }
                .buttonStyle(RemoteActionButtonStyle(
                    tint: alarmNeedsAttention ? .red : Color.gray.opacity(0.72)
                ))
                .allowsHitTesting(alarmNeedsAttention)
                // Blink only the button opacity. Scaling/shadow animation made
                // the surrounding red screen edge appear to judder on iPhone.
                .opacity(alarmNeedsAttention ? (alarmPulse ? 1 : 0.60) : 1)
                .animation(
                    alarmNeedsAttention
                        ? .easeInOut(duration: 0.62).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.18),
                    value: alarmPulse
                )
                .accessibilityHint(localized(alarmNeedsAttention
                    ? "Tắt âm cảnh báo hiện tại"
                    : "Chỉ khả dụng khi máy in có cảnh báo"))
            }
        }
    }

    private var filamentControls: some View {
        VStack(spacing: compactLayout ? 10 : 12) {
            if compactLayout {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        filamentLiveTemperature
                        Spacer(minLength: 8)
                        externalNozzlePicker
                    }
                    HStack(spacing: 8) {
                        filamentTargetStepper
                        Spacer(minLength: 8)
                        filamentTemperatureSyncButton
                    }
                }
            } else {
                HStack(spacing: 10) {
                    filamentLiveTemperature
                    Spacer(minLength: 4)
                    externalNozzlePicker
                    filamentTargetStepper
                    filamentTemperatureSyncButton
                }
            }

            HStack(spacing: 10) {
                Button {
                    confirmation = .load(temperature: filamentTemperature)
                } label: {
                    Label(localized(usesLeftNozzlePath ? "Nạp đầu trái" : "Nạp nhựa"), systemImage: "arrow.down.to.line.compact")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RemoteActionButtonStyle(tint: green))
                .disabled(!controlsReady || selectedExternalFilamentPresent != false)
                .opacity(selectedExternalFilamentPresent == false ? 1 : 0.46)
                .accessibilityHint(localized(externalLoadUnavailable
                    ? "Cảm biến đã phát hiện nhựa trong đầu đùn"
                    : "Nạp nhựa từ cuộn ngoài"))

                Button {
                    confirmation = .unload(
                        temperature: filamentTemperature,
                        material: currentFilamentName
                    )
                } label: {
                    Label(localized(usesLeftNozzlePath ? "Rút đầu trái" : "Rút nhựa"), systemImage: "arrow.up.from.line.compact")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RemoteActionButtonStyle(tint: amber))
                .disabled(!controlsReady || selectedExternalFilamentPresent != true)
                .opacity(selectedExternalFilamentPresent == true ? 1 : 0.46)
                .accessibilityHint(localized(externalUnloadUnavailable
                    ? "Cảm biến chưa phát hiện nhựa trong đầu đùn"
                    : "Rút nhựa ra khỏi cuộn ngoài"))
            }

            if let present = selectedExternalFilamentPresent {
                Label(
                    localized(present ? "Cảm biến: đã có nhựa" : "Cảm biến: chưa có nhựa"),
                    systemImage: present ? "checkmark.circle.fill" : "circle.dashed"
                )
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(present ? green : .secondary)
            }
        }
        .padding(compactLayout ? 10 : 12)
        .background(
            lowPowerDarkMode
                ? Color(red: 0.055, green: 0.075, blue: 0.072)
                : Color(red: 0.965, green: 0.975, blue: 0.973),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(cyan.opacity(0.10), lineWidth: 1)
        }
    }

    private var filamentLiveTemperature: some View {
        HStack(spacing: 8) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: compactLayout ? 15 : 16, weight: .medium))
                .foregroundStyle(amber)
                .frame(width: compactLayout ? 30 : 34, height: compactLayout ? 30 : 34)
                .background(amber.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(liveNozzleTemperatureText)
                    .font(.system(size: compactLayout ? 14 : 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(liveNozzleIsHeating ? Color.red : Color.primary)

                if let material = selectedNozzleFilamentMaterial {
                    Text(material)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(selectedNozzleFilamentColor)
                        .lineLimit(1)
                        .shadow(color: Color.black.opacity(0.18), radius: 0.5)
                        .accessibilityLabel(localized("Nhựa \(material)"))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .layoutPriority(2)
    }

    @ViewBuilder
    private var externalNozzlePicker: some View {
        if directControl.snapshot.extruderCount > 1 || profile.kind == .h2d {
            HStack(spacing: 3) {
                externalNozzleButton(title: "L", extruderID: 1)
                externalNozzleButton(title: "R", extruderID: 0)
            }
            .padding(3)
            .background(
                lowPowerDarkMode ? Color.white.opacity(0.06) : Color.black.opacity(0.045),
                in: Capsule()
            )
            .accessibilityHint(localized("Chọn đầu in cho cuộn ngoài"))
        }
    }

    private var filamentTargetStepper: some View {
        HStack(spacing: 0) {
            temperatureButton(systemName: "minus") {
                filamentTemperature = max(170, filamentTemperature - 5)
            }
            Text("\(filamentTemperature)°C")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: compactLayout ? 58 : 64)
            temperatureButton(systemName: "plus") {
                filamentTemperature = min(320, filamentTemperature + 5)
            }
        }
        .padding(3)
        .background(
            lowPowerDarkMode ? Color.white.opacity(0.06) : Color.black.opacity(0.045),
            in: Capsule()
        )
    }

    private var filamentTemperatureSyncButton: some View {
        Button {
            applyAutomaticFilamentTemperature(force: true)
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 26)
        }
        .buttonStyle(.bordered)
        .tint(cyan)
        .accessibilityLabel(localized("Theo nhiệt độ máy in"))
    }

    private var amsControls: some View {
        let trays = directControl.snapshot.amsTrays
            .filter(\.isPresent)
        let humidity = directControl.snapshot.amsDryerUnitID
            .flatMap { directControl.snapshot.amsHumidityPercentByUnit[$0] }
            ?? trays.compactMap { directControl.snapshot.amsHumidityPercentByUnit[$0.amsID] }.first
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                controlTitle("AMS", icon: "square.grid.2x2.fill")
                Spacer(minLength: 4)
                if directControl.snapshot.amsDryerUnitID != nil {
                    HStack(spacing: 2) {
                        Button {
                            amsDryingHours = max(1, amsDryingHours - 1)
                        } label: {
                            Image(systemName: "minus")
                                .frame(width: 25, height: 25)
                        }
                        Text("\(amsDryingHours) h")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(minWidth: 31)
                        Button {
                            amsDryingHours = min(48, amsDryingHours + 1)
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 25, height: 25)
                        }
                    }
                    .buttonStyle(.plain)
                    .background(subduedSurfaceColor, in: Capsule())

                }
            }

            if trays.isEmpty {
                Text(localized("Đã phát hiện AMS • đang chờ dữ liệu khay nhựa"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(trays) { tray in
                            let selected = directControl.snapshot.currentAMSTrayID == tray.id
                            let extruderID = tray.extruderID
                                ?? directControl.snapshot.currentExtruderID
                                ?? 0
                            Button {
                                if selected {
                                    directControl.unloadAMSFilament(
                                        temperature: filamentTemperature,
                                        extruderID: extruderID
                                    )
                                } else {
                                    directControl.loadAMSFilament(
                                        tray,
                                        temperature: filamentTemperature,
                                        extruderID: extruderID
                                    )
                                }
                            } label: {
                                VStack(spacing: 4) {
                                    AMSSpoolGlyph(
                                        color: amsColor(tray.colorHex),
                                        isActive: selected
                                    )
                                    Text("\(tray.slotID + 1)")
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(.primary)
                                    Text(tray.material.isEmpty ? "—" : tray.material)
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(width: compactLayout ? 52 : 58, height: 70)
                                .saturation(selected ? 1 : 0.34)
                                .opacity(selected ? 1 : 0.52)
                                .background(
                                    selected
                                        ? (lowPowerDarkMode ? Color.white.opacity(0.14) : Color.white)
                                        : (lowPowerDarkMode ? Color.white.opacity(0.025) : Color.black.opacity(0.035)),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(
                                            selected ? amsColor(tray.colorHex).opacity(0.88) : hairlineColor,
                                            lineWidth: selected ? 1.6 : 0.8
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!controlsReady)
                            .accessibilityLabel(
                                localized(selected ? "Rút nhựa AMS" : "Nạp nhựa AMS")
                                    + " \(tray.slotID + 1)"
                            )
                            }
                        }
                    }

                    if humidity != nil || directControl.snapshot.amsDryerUnitID != nil {
                        amsHumidityDryingControl(humidity: humidity)
                    }
                }
            }
            if trays.isEmpty,
               humidity != nil || directControl.snapshot.amsDryerUnitID != nil {
                HStack {
                    Spacer(minLength: 0)
                    amsHumidityDryingControl(humidity: humidity)
                }
            }
        }
        .padding(12)
        .background(subduedSurfaceColor, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(hairlineColor, lineWidth: 1)
        }
    }

    private func amsHumidityDryingControl(humidity: Int?) -> some View {
        let drying = directControl.snapshot.amsDrying
        let tint = drying || (humidity ?? 0) > 55 ? amber : cyan
        let label = VStack(spacing: 5) {
            Image(systemName: drying ? "drop.fill" : "drop")
                .font(.system(size: 21, weight: .semibold))
                .scaleEffect(drying ? (dryerPulse ? 1.06 : 0.94) : 1)
            Text(humidity.map { "\($0)%" } ?? "—%")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(tint)
        .frame(width: 64, height: 70)
        .background(tint.opacity(drying ? 0.13 : 0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(tint.opacity(0.20), lineWidth: 1)
        }
        .overlay {
            if drying {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(amber.opacity(0.65), lineWidth: 1.5)
                    .scaleEffect(dryerPulse ? 1.18 : 0.96)
                    .opacity(dryerPulse ? 0 : 0.78)
                    .allowsHitTesting(false)
            }
        }
        .opacity(drying ? (dryerPulse ? 1 : 0.62) : 1)
        .animation(
            drying ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .easeOut(duration: 0.18),
            value: dryerPulse
        )

        return Group {
            if let dryerID = directControl.snapshot.amsDryerUnitID {
                Button {
                    directControl.setAMSDrying(
                        enabled: !drying,
                        amsID: dryerID,
                        durationHours: amsDryingHours,
                        temperature: recommendedAMSDryingTemperature,
                        filament: recommendedAMSDryingFilament
                    )
                } label: { label }
                .buttonStyle(.plain)
                .disabled(!controlsReady)
                .accessibilityHint(localized(drying ? "Tắt sấy AMS" : "Bật sấy AMS"))
                .accessibilityLabel(localized(humidity.map { "Độ ẩm AMS \($0) phần trăm" } ?? "Độ ẩm AMS"))
                .accessibilityValue(localized(drying ? "Tắt sấy AMS" : "Bật sấy AMS"))
                .accessibilityIdentifier("se.ams.humidity-drying")
            } else {
                // Old AMS units can report humidity but have no drying action.
                label
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(localized(humidity.map { "Độ ẩm AMS \($0) phần trăm" } ?? "Độ ẩm AMS"))
                    .accessibilityIdentifier("se.ams.humidity-drying")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var utilityControls: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(localized("Tốc độ in %"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)

                PrinterSpeedDial(
                    level: $printSpeed,
                    isEnabled: controlsReady,
                    tint: cyan,
                    caption: localized("Tốc độ in %"),
                    onCommit: { directControl.setPrintSpeed($0) }
                )
                .frame(
                    width: compactLayout ? 132 : 150,
                    height: compactLayout ? 92 : 104
                )
            }
            .padding(.leading, 8)
            .frame(maxWidth: .infinity)

            Divider().frame(height: compactLayout ? 72 : 82)

            VStack(alignment: .leading, spacing: 3) {
                Text(localized("Đèn máy in"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 12) {
                    Image(systemName: chamberLightEnabled ? "lightbulb.fill" : "lightbulb")
                        .font(.system(size: compactLayout ? 24 : 28, weight: .medium))
                        .foregroundStyle(chamberLightEnabled ? amber : Color.secondary)
                        .symbolEffect(.bounce, value: chamberLightEnabled)

                    Toggle("", isOn: Binding(
                        get: { chamberLightEnabled },
                        set: { value in
                            chamberLightEnabled = value
                            directControl.setChamberLight(enabled: value)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(amber)
                    .disabled(!controlsReady)
                    .accessibilityLabel(localized("Đèn buồng in"))
                    .accessibilityValue(
                        languageCode == SEAppLanguage.english.rawValue
                            ? (chamberLightEnabled ? "On" : "Off")
                            : (chamberLightEnabled ? "Bật" : "Tắt")
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.leading, 8)
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 10)
        .background(subduedSurfaceColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func printerPromptCard(_ prompt: BambuRemotePrompt) -> some View {
        let isError = prompt.kind == .printerError
        let tint: Color = isError ? .red : amber
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(localized(isError ? "Máy in cần xử lý" : "Máy in đang chờ xác nhận"))
                        .font(.system(size: 13, weight: .bold))
                    Text(localized(promptDescription(prompt)))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if isError {
                HStack(spacing: 8) {
                    Button(localized("Tiếp tục")) { directControl.continueActivePrompt() }
                        .buttonStyle(RemoteActionButtonStyle(tint: .red))
                        .disabled(!controlsReady)
                    Button(localized("Bỏ qua")) { directControl.ignoreActiveError() }
                        .buttonStyle(RemoteActionButtonStyle(tint: amber))
                        .disabled(!controlsReady)
                    Button(localized("Dừng")) { directControl.stopFromActivePrompt() }
                        .buttonStyle(RemoteActionButtonStyle(tint: .red))
                        .disabled(!controlsReady)
                }
            } else if prompt.kind == .filamentLoad {
                VStack(spacing: 8) {
                    Button(localized("Đã đùn nhựa • Tiếp tục")) {
                        directControl.finishFilamentOperation()
                    }
                        .buttonStyle(RemoteActionButtonStyle(tint: cyan))
                        .disabled(!controlsReady)
                        .frame(maxWidth: .infinity)
                    Button(localized("Chưa ra nhựa • Thử lại")) {
                        directControl.continueActivePrompt()
                    }
                        .buttonStyle(RemoteActionButtonStyle(tint: amber))
                        .disabled(!controlsReady)
                        .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 8) {
                    Button(localized("Đã rút xong • Tiếp tục")) {
                        directControl.continueActivePrompt()
                    }
                    .buttonStyle(RemoteActionButtonStyle(tint: cyan))
                    .disabled(!controlsReady)
                    .frame(maxWidth: .infinity)

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showsFilamentHelp.toggle()
                        }
                    } label: {
                        Label(localized("Trợ giúp xử lý"), systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(RemoteActionButtonStyle(tint: amber))
                    .frame(maxWidth: .infinity)

                    if showsFilamentHelp {
                        Text(localized(unloadHelpText))
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .padding(12)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        }
    }

    private func promptDescription(_ prompt: BambuRemotePrompt) -> String {
        switch prompt.kind {
        case .filamentLoad:
            if languageCode == SEAppLanguage.english.rawValue {
                return usesLeftNozzlePath
                    ? "Check whether filament is flowing from the left nozzle."
                    : "Check whether filament is flowing from the nozzle."
            }
            return usesLeftNozzlePath
                ? "Kiểm tra nhựa đã chảy ra từ đầu phun trái hay chưa."
                : "Kiểm tra nhựa đã chảy ra từ đầu phun hay chưa."
        case .filamentUnload:
            if languageCode == SEAppLanguage.english.rawValue {
                return usesLeftNozzlePath
                    ? "Pull the filament out from the left external spool path."
                    : "Pull the filament out from the external spool path."
            }
            return usesLeftNozzlePath
                ? "Rút sợi nhựa ra khỏi đường cuộn ngoài bên trái."
                : "Rút sợi nhựa ra khỏi đường cuộn ngoài."
        case .printerError:
            let code = prompt.errorCode.map { String(format: "%08X", $0) } ?? "—"
            if let detail = prompt.detail, !detail.isEmpty {
                return "\(detail) • \(code)"
            }
            return languageCode == SEAppLanguage.english.rawValue
                ? "Printer error \(code). Fix the cause, then continue, ignore, or stop."
                : "Lỗi máy in \(code). Khắc phục nguyên nhân rồi tiếp tục, bỏ qua hoặc dừng."
        }
    }

    private var unloadHelpText: String {
        if languageCode == SEAppLanguage.english.rawValue {
            return "If the prompt remains, check for broken filament in the extruder or PTFE tube, then remove or straighten it before continuing."
        }
        return "Nếu thông báo vẫn còn, kiểm tra nhựa gãy trong bộ đùn hoặc ống PTFE; lấy đoạn gãy ra hoặc nắn thẳng rồi mới tiếp tục."
    }

    private var liveNozzleTemperatureText: String {
        let snapshot = directControl.snapshot
        let directCurrent = usesLeftNozzlePath ? snapshot.leftNozzleTemperature : snapshot.nozzleTemperature
        let bridgeCurrent = usesLeftNozzlePath ? bluetooth.leftNozzleTemperature : bluetooth.nozzleTemperature
        let current = (snapshot.isRecent ? directCurrent : nil).flatMap { $0 >= 0 ? $0 : nil }
            ?? (bridgeCurrent >= 0 ? bridgeCurrent : nil)
        return "\(current.map { String($0) } ?? "—")°C"
    }

    private var selectedNozzleFilamentMaterial: String? {
        let snapshot = directControl.snapshot
        if let material = snapshot.filamentMaterialByExtruder[externalSpoolExtruderID]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
           !material.isEmpty {
            return material.uppercased()
        }

        if let currentTrayID = snapshot.currentAMSTrayID,
           let tray = snapshot.amsTrays.first(where: { $0.id == currentTrayID }),
           (tray.extruderID == externalSpoolExtruderID ||
               snapshot.currentExtruderID == externalSpoolExtruderID),
           !tray.material.isEmpty {
            return tray.material.uppercased()
        }

        let bridgeMaterial = bluetooth.filamentType
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bridgeMaterial.isEmpty,
              snapshot.extruderCount == 1 ||
                snapshot.currentExtruderID == externalSpoolExtruderID ||
                snapshot.externalSpoolExtruderID == externalSpoolExtruderID else {
            return nil
        }
        return bridgeMaterial.uppercased()
    }

    private var selectedNozzleFilamentColor: Color {
        let snapshot = directControl.snapshot
        if let raw = snapshot.filamentColorHexByExtruder[externalSpoolExtruderID],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return amsColor(raw)
        }
        if let currentTrayID = snapshot.currentAMSTrayID,
           let tray = snapshot.amsTrays.first(where: { $0.id == currentTrayID }),
           (tray.extruderID == externalSpoolExtruderID ||
               snapshot.currentExtruderID == externalSpoolExtruderID),
           !tray.colorHex.isEmpty {
            return amsColor(tray.colorHex)
        }
        return .secondary
    }

    private var liveNozzleIsHeating: Bool {
        let snapshot = directControl.snapshot
        let directCurrent = usesLeftNozzlePath ? snapshot.leftNozzleTemperature : snapshot.nozzleTemperature
        let directTarget = usesLeftNozzlePath ? snapshot.leftNozzleTargetTemperature : snapshot.nozzleTargetTemperature
        let bridgeCurrent = usesLeftNozzlePath ? bluetooth.leftNozzleTemperature : bluetooth.nozzleTemperature
        let bridgeTarget = usesLeftNozzlePath ? bluetooth.leftNozzleTargetTemperature : bluetooth.nozzleTargetTemperature
        let current = (snapshot.isRecent ? directCurrent : nil) ?? (bridgeCurrent >= 0 ? bridgeCurrent : nil)
        let target = (snapshot.isRecent ? directTarget : nil) ?? (bridgeTarget > 0 ? bridgeTarget : nil)
        guard let current, let target, target > 0 else { return false }
        return current + 2 < target
    }

    private func amsColor(_ raw: String) -> Color {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count >= 8 { value = String(value.prefix(6)) }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else {
            return Color.gray.opacity(0.45)
        }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    private func temperatureButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func externalNozzleButton(title: String, extruderID: Int) -> some View {
        Button {
            selectedExternalExtruderID = extruderID
            applyAutomaticFilamentTemperature(force: true)
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(width: 25, height: 25)
                .foregroundStyle(selectedExternalExtruderID == extruderID ? Color.white : Color.secondary)
                .background(
                    selectedExternalExtruderID == extruderID ? cyan : Color.clear,
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized(extruderID == 1 ? "Đầu trái" : "Đầu phải"))
        .accessibilityIdentifier("se.nozzle.\(extruderID)")
        .accessibilityAddTraits(selectedExternalExtruderID == extruderID ? .isSelected : [])
    }

    private func iconOnlyActionLabel(_ title: String, icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 17, weight: .bold))
            .frame(maxWidth: .infinity, minHeight: 32)
            .accessibilityLabel(localized(title))
    }

    private func startDirectControl() {
        directControl.start(profile: profile, accessCode: accessCode)
        if let knownLightState = directControl.snapshot.chamberLightOn {
            chamberLightEnabled = knownLightState
        }
        if let knownSpeed = directControl.snapshot.printSpeedLevel,
           (1...4).contains(knownSpeed) {
            printSpeed = knownSpeed
        }
        applyAutomaticFilamentTemperature(force: true)
    }

    private func updateAlarmPulse() {
        alarmPulse = false
        guard alarmNeedsAttention else { return }
        DispatchQueue.main.async { alarmPulse = true }
    }

    private func updateDryerPulse() {
        dryerPulse = false
        guard directControl.snapshot.amsDrying else { return }
        DispatchQueue.main.async { dryerPulse = true }
    }


    private var currentFilamentName: String {
        if let selectedNozzleFilamentMaterial { return selectedNozzleFilamentMaterial }
        let value = bluetooth.filamentType.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? localized("nhựa cuộn ngoài") : value.uppercased()
    }

    private func applyAutomaticFilamentTemperature(force: Bool = false) {
        let signature = [
            bluetooth.filamentType,
            String(bluetooth.nozzleTargetTemperature),
            String(bluetooth.leftNozzleTargetTemperature)
        ].joined(separator: "|")
        guard force || signature != automaticTemperatureSignature else { return }
        automaticTemperatureSignature = signature
        filamentTemperature = recommendedFilamentTemperature()
    }

    private func recommendedFilamentTemperature() -> Int {
        // H2D reports the right nozzle first and the left nozzle second. Follow
        // the nozzle explicitly selected by the user instead of letting a
        // stale AMS route silently move external-filament commands.
        let preferredTarget = usesLeftNozzlePath
            ? bluetooth.leftNozzleTargetTemperature
            : bluetooth.nozzleTargetTemperature
        if (170...320).contains(preferredTarget) {
            return min(320, max(170, Int((Double(preferredTarget) / 5.0).rounded()) * 5))
        }

        let material = bluetooth.filamentType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if material.contains("PPA") || material.contains("PPS") { return 300 }
        if material.contains("PETG") || material.contains("PCTG") || material == "PET" { return 250 }
        if material.contains("PA") || material.contains("NYLON") { return 280 }
        if material.contains("PC") { return 275 }
        if material.contains("ABS") || material.contains("ASA") { return 260 }
        if material.contains("HIPS") { return 245 }
        if material.contains("TPU") || material.contains("TPE") { return 230 }
        if material.contains("PVA") { return 215 }
        return 220
    }

    private var recommendedAMSDryingTemperature: Int {
        let snapshot = directControl.snapshot
        let selected = snapshot.amsTrays.first { $0.id == snapshot.currentAMSTrayID }
            ?? snapshot.amsTrays.first(where: \.isPresent)
        return min(90, max(45, selected?.dryingTemperature ?? 55))
    }

    private var recommendedAMSDryingFilament: String {
        let snapshot = directControl.snapshot
        let selected = snapshot.amsTrays.first { $0.id == snapshot.currentAMSTrayID }
            ?? snapshot.amsTrays.first(where: \.isPresent)
        return selected?.material ?? ""
    }

    private func controlTitle(_ title: String, icon: String) -> some View {
        Label(localized(title), systemImage: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }

    private func localized(_ source: String) -> String {
        SEStatusCopy.render(source, languageCode: languageCode)
    }

}

private struct PrinterSpeedDial: View {
    @Binding var level: Int
    let isEnabled: Bool
    let tint: Color
    let caption: String
    let onCommit: (Int) -> Void
    @State private var isDialUnlocked = false

    private let startAngle = 195.0
    private let endAngle = 345.0
    private let speedPercents = [50, 100, 124, 166]

    private var needleAngle: Double {
        startAngle + (Double(min(4, max(1, level))) - 1) * ((endAngle - startAngle) / 3)
    }

    private var speedPercent: Int {
        speedPercents[min(3, max(0, level - 1))]
    }

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height - 8)
            let radius = min(proxy.size.width * 0.46, proxy.size.height - 13)
            ZStack {
                PrinterSpeedDialFace(center: center, radius: radius)
                    .equatable()

                    Path { path in
                        path.move(to: center)
                        path.addLine(to: point(center: center, radius: radius * 0.73, angle: needleAngle))
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                    .shadow(color: tint.opacity(0.34), radius: 3)

                    Circle()
                        .fill(Color.primary.opacity(0.92))
                        .frame(width: 17, height: 17)
                        .overlay(Circle().fill(tint).frame(width: 7, height: 7))
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        .position(center)
            }
            .opacity(isEnabled ? 1 : 0.42)
            .contentShape(Rectangle())
            .gesture(
                    LongPressGesture(minimumDuration: 0.55, maximumDistance: 24)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { value in
                            guard isEnabled else { return }
                            switch value {
                            case .first(true):
                                isDialUnlocked = true
                            case .second(true, let drag):
                                isDialUnlocked = true
                                if let drag {
                                    level = dialLevel(at: drag.location, size: proxy.size)
                                }
                            default:
                                break
                            }
                        }
                        .onEnded { value in
                            defer { isDialUnlocked = false }
                            guard isEnabled, isDialUnlocked else { return }
                            if case .second(true, _) = value {
                                onCommit(level)
                            }
                        }
            )
            .animation(.easeOut(duration: 0.14), value: level)
        }
        .accessibilityElement()
        .accessibilityLabel(caption)
        .accessibilityValue("\(speedPercent)%")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: level = min(4, level + 1)
            case .decrement: level = max(1, level - 1)
            @unknown default: return
            }
            onCommit(level)
        }
    }

    private func dialLevel(at location: CGPoint, size: CGSize) -> Int {
        let center = CGPoint(x: size.width / 2, y: size.height - 9)
        let dx = location.x - center.x
        let dy = location.y - center.y
        var degrees = Double(atan2(dy, dx)) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let clamped = min(endAngle, max(startAngle, degrees))
        let fraction = (clamped - startAngle) / (endAngle - startAngle)
        return min(4, max(1, Int((fraction * 3).rounded()) + 1))
    }


    private func point(center: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
        let radians = angle * .pi / 180
        return CGPoint(
            x: center.x + radius * CGFloat(cos(radians)),
            y: center.y + radius * CGFloat(sin(radians))
        )
    }
}

private struct PrinterSpeedDialFace: View, Equatable {
    let center: CGPoint
    let radius: CGFloat
    private let startAngle = 195.0
    private let endAngle = 345.0
    private let speedPercents = [50, 100, 124, 166]

    var body: some View {
        ZStack {
            gaugeArc
                .stroke(Color.primary.opacity(0.13), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            // Batch 31 individual tick views into three native paths.
            ForEach(0..<3, id: \.self) { weight in
                Path { path in
                    for index in 0..<31 {
                        let category = index % 10 == 0 ? 2 : (index % 5 == 0 ? 1 : 0)
                        guard category == weight else { continue }
                        let angle = startAngle + (endAngle - startAngle) * Double(index) / 30
                        let length: CGFloat = weight == 2 ? 15 : (weight == 1 ? 11 : 7)
                        path.move(to: point(radius: radius - length, angle: angle))
                        path.addLine(to: point(radius: radius - 2, angle: angle))
                    }
                }
                .stroke(
                    Color.primary.opacity(weight == 2 ? 0.78 : (weight == 1 ? 0.48 : 0.25)),
                    style: StrokeStyle(lineWidth: weight == 2 ? 3.4 : (weight == 1 ? 2 : 1.15), lineCap: .round)
                )
            }
            ForEach(0..<4, id: \.self) { index in
                Text("\(speedPercents[index])")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .position(point(
                        radius: radius - 26,
                        angle: startAngle + (endAngle - startAngle) * Double(index) / 3
                    ))
            }
        }
    }

    private var gaugeArc: Path {
        var path = Path()
        for step in 0...60 {
            let angle = startAngle + (endAngle - startAngle) * Double(step) / 60
            let next = point(radius: radius, angle: angle)
            if step == 0 { path.move(to: next) } else { path.addLine(to: next) }
        }
        return path
    }

    private func point(radius: CGFloat, angle: Double) -> CGPoint {
        let radians = angle * .pi / 180
        return CGPoint(
            x: center.x + radius * CGFloat(cos(radians)),
            y: center.y + radius * CGFloat(sin(radians))
        )
    }
}

private struct AMSSpoolGlyph: View {
    let color: Color
    let isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(isActive ? 1 : 0.88))
            Circle()
                .stroke(Color.black.opacity(0.12), lineWidth: 0.7)
            Circle()
                .fill(Color.white.opacity(0.92))
                .frame(width: 12, height: 12)
            Circle()
                .stroke(color.opacity(0.72), lineWidth: 2)
                .frame(width: 7, height: 7)
        }
        .frame(width: 30, height: 30)
        .shadow(color: isActive ? color.opacity(0.52) : Color.clear, radius: 5)
    }
}

private enum RemoteConfirmation: Identifiable {
    case stop
    case load(temperature: Int)
    case unload(temperature: Int, material: String)

    var id: String {
        switch self {
        case .stop: return "stop"
        case let .load(temperature): return "load-external-\(temperature)"
        case let .unload(temperature, material): return "unload-external-\(temperature)-\(material)"
        }
    }

    func title(usesLeftNozzlePath: Bool, languageCode: String) -> String {
        if languageCode == SEAppLanguage.english.rawValue {
            switch self {
            case .stop: return "Stop the print?"
            case .load:
                return usesLeftNozzlePath
                    ? "Load external filament into the left nozzle?"
                    : "Load external filament?"
            case .unload:
                return usesLeftNozzlePath
                    ? "Unload filament from the left nozzle?"
                    : "Unload filament?"
            }
        }
        switch self {
        case .stop: return "Dừng hẳn bản in?"
        case .load:
            return usesLeftNozzlePath ? "Nạp cuộn ngoài vào đầu trái?" : "Nạp nhựa cuộn ngoài?"
        case .unload:
            return usesLeftNozzlePath ? "Rút nhựa khỏi đầu trái?" : "Rút nhựa?"
        }
    }

    func message(usesLeftNozzlePath: Bool, languageCode: String) -> String {
        if languageCode == SEAppLanguage.english.rawValue {
            switch self {
            case .stop:
                return "The printer will cancel the current job. It cannot be resumed."
            case let .load(temperature):
                return usesLeftNozzlePath
                    ? "Use only the left external spool. The nozzle may heat to \(temperature)°C; AMS will not be selected."
                    : "Use only the external spool. The nozzle may heat to \(temperature)°C; AMS will not be selected."
            case let .unload(temperature, material):
                return usesLeftNozzlePath
                    ? "Unload \(material) from the left nozzle at \(temperature)°C. AMS will not be selected; keep hands away from the nozzle and extruder."
                    : "Unload \(material) at \(temperature)°C. AMS will not be selected; keep hands away from the nozzle and extruder."
            }
        }
        switch self {
        case .stop:
            return "Máy in sẽ hủy công việc hiện tại. Thao tác này không thể tiếp tục lại."
        case let .load(temperature):
            return usesLeftNozzlePath
                ? "Chỉ dùng cuộn ngoài đầu trái. Đầu phun có thể nóng tới \(temperature)°C; AMS sẽ không được chọn."
                : "Chỉ dùng cuộn ngoài. Đầu phun có thể nóng tới \(temperature)°C; AMS sẽ không được chọn."
        case let .unload(temperature, material):
            return usesLeftNozzlePath
                ? "Rút \(material) khỏi đầu trái ở \(temperature)°C. AMS không được chọn; hãy giữ tay khỏi đầu phun và bộ đùn."
                : "Rút \(material) ở \(temperature)°C. AMS không được chọn; hãy giữ tay khỏi đầu phun và bộ đùn."
        }
    }
}

/// Lifetime bookkeeping is independent of the controls' layout and gestures.
private struct PrinterLifetimeHoursBadge: View {
    @ObservedObject var directControl: BambuPrinterControlManager
    let profile: BambuPrinterProfile
    let languageCode: String
    let darkMode: Bool
    @State private var lifetimePrintHours = 0.0
    @State private var lifetimeObservationAt: Date?
    @State private var lifetimeObservationWasPrinting = false
    @State private var lifetimePersistedAt: Date?

    private var subduedSurfaceColor: Color {
        darkMode ? Color.white.opacity(0.045) : Color.black.opacity(0.025)
    }

    private func localized(_ source: String) -> String {
        SEStatusCopy.render(source, languageCode: languageCode)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10, weight: .semibold))
            Text(String(format: "%.1f h", lifetimePrintHours))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(subduedSurfaceColor, in: Capsule())
        .accessibilityLabel(localized("Giờ in SE tự theo dõi"))
        .fixedSize(horizontal: true, vertical: false)
        .onAppear { loadLifetimePrintHours() }
        .onChange(of: profile.id) { _, _ in loadLifetimePrintHours() }
        .onChange(of: directControl.snapshot.receivedAt) { _, _ in updateLifetimePrintHours() }
        .onDisappear { persistLifetimePrintHours(at: Date()) }
    }

    private var lifetimeHoursStorageKey: String {
        let serial = profile.serial
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return "SE.Bambu.lifetimePrintHours.\(serial)"
    }

    private var lifetimeJobStorageKey: String {
        lifetimeHoursStorageKey + ".activeJob"
    }

    private var lifetimeObservationStorageKey: String {
        lifetimeHoursStorageKey + ".observedAt"
    }

    private func loadLifetimePrintHours() {
        let defaults = UserDefaults.standard
        lifetimePrintHours = max(0, defaults.double(forKey: lifetimeHoursStorageKey))
        if defaults.object(forKey: lifetimeHoursStorageKey) == nil {
            defaults.set(0.0, forKey: lifetimeHoursStorageKey)
        }
        // Start from printer telemetry. If a job is already running, the next
        // snapshot backfills from gcode_start_time instead of asking the user
        // to type a baseline.
        lifetimeObservationAt = nil
        lifetimeObservationWasPrinting = false
        lifetimePersistedAt = Date()
        updateLifetimePrintHours()
    }

    private func lifetimeJobIdentity(_ snapshot: BambuDirectSnapshot) -> String {
        let identifiers = [snapshot.jobID, snapshot.subtaskID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "0" }
        let start = snapshot.printStartedAt.map { String(Int($0.timeIntervalSince1970)) } ?? ""
        return (identifiers + [start]).filter { !$0.isEmpty }.joined(separator: "|")
    }

    private func updateLifetimePrintHours() {
        let snapshot = directControl.snapshot
        let now = snapshot.receivedAt ?? Date()
        let defaults = UserDefaults.standard

        if snapshot.hasActivePrintJob {
            var baseline = lifetimeObservationAt
            let identity = lifetimeJobIdentity(snapshot)

            if !lifetimeObservationWasPrinting {
                let storedIdentity = defaults.string(forKey: lifetimeJobStorageKey) ?? ""
                let storedTimestamp = defaults.double(forKey: lifetimeObservationStorageKey)
                if !identity.isEmpty, storedIdentity == identity, storedTimestamp > 0 {
                    baseline = Date(timeIntervalSince1970: storedTimestamp)
                } else if let printerStart = snapshot.printStartedAt {
                    baseline = printerStart
                } else {
                    baseline = now
                }
            }

            if let baseline {
                let seconds = now.timeIntervalSince(baseline)
                // Reject broken epochs, but allow an app suspension to be
                // recovered from the same printer-reported job.
                if seconds > 0, seconds <= 31 * 24 * 3_600 {
                    lifetimePrintHours += seconds / 3_600
                }
            }

            if now.timeIntervalSince(lifetimePersistedAt ?? .distantPast) >= 30 {
                persistLifetimePrintHours(at: now)
            }
        } else if lifetimeObservationWasPrinting,
                  let previous = lifetimeObservationAt {
            let seconds = now.timeIntervalSince(previous)
            if seconds > 0, seconds <= 35 {
                lifetimePrintHours += seconds / 3_600
            }
            persistLifetimePrintHours(at: now)
        }

        lifetimeObservationAt = now
        lifetimeObservationWasPrinting = snapshot.hasActivePrintJob
    }

    private func persistLifetimePrintHours(at date: Date) {
        let defaults = UserDefaults.standard
        defaults.set(max(0, lifetimePrintHours), forKey: lifetimeHoursStorageKey)
        let snapshot = directControl.snapshot
        let identity = snapshot.hasActivePrintJob ? lifetimeJobIdentity(snapshot) : ""
        defaults.set(identity, forKey: lifetimeJobStorageKey)
        defaults.set(date.timeIntervalSince1970, forKey: lifetimeObservationStorageKey)
        lifetimePersistedAt = date
    }
}

private struct RemoteActionButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(tint)
            .background(tint.opacity(configuration.isPressed ? 0.17 : 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
