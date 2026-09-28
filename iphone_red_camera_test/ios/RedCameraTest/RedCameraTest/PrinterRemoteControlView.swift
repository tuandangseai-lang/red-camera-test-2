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

    @ObservedObject var directControl: BambuPrinterControlManager
    @State private var filamentTemperature = 220
    @State private var automaticTemperatureSignature = ""
    @State private var printSpeed = 2
    @State private var chamberLightEnabled = false
    @State private var confirmation: RemoteConfirmation?
    @State private var alarmPulse = false

    private let cyan = Color(red: 0.12, green: 0.48, blue: 0.46)
    private let amber = Color(red: 0.78, green: 0.48, blue: 0.10)
    private let green = Color(red: 0.16, green: 0.58, blue: 0.38)

    private var controlsReady: Bool {
        directControl.isReady && !directControl.isPending
    }

    private var alarmNeedsAttention: Bool {
        alarmActive && !alarmAcknowledged
    }

    private var usesLeftNozzlePath: Bool {
        profile.kind == .h2d
    }

    private var externalSpoolExtruderID: Int {
        usesLeftNozzlePath ? 1 : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controlHeader
            Divider().overlay(.black.opacity(0.08))
            if let prompt = directControl.activePrompt {
                printerPromptCard(prompt)
            }
            quickActions
            filamentControls
            utilityControls
        }
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        }
        .onAppear {
            startDirectControl()
            updateAlarmPulse()
        }
        .onChange(of: profile.id) { _, _ in startDirectControl() }
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
        .onChange(of: alarmNeedsAttention) { _, _ in updateAlarmPulse() }
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
                Button(localized("Dừng"), role: .destructive) { directControl.stopPrint() }
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

    private var controlHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(cyan)
                .frame(width: 32, height: 32)
                .background(cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text("\(localized("Điều khiển")) \(printerName)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 6)

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
                    if bluetooth.isPausedPrint {
                        directControl.resumePrint()
                    } else {
                        directControl.pausePrint()
                    }
                } label: {
                    compactActionLabel(
                        bluetooth.isPausedPrint ? "Tiếp tục" : "Tạm dừng",
                        icon: bluetooth.isPausedPrint ? "play.fill" : "pause.fill"
                    )
                }
                .buttonStyle(RemoteActionButtonStyle(tint: cyan))
                .disabled(!controlsReady)

                Button {
                    confirmation = .stop
                } label: {
                    compactActionLabel("Dừng", icon: "stop.fill")
                }
                .buttonStyle(RemoteActionButtonStyle(tint: .red))
                .disabled(!controlsReady)

                Button {
                    onSilenceAlarm()
                } label: {
                    compactActionLabel(
                        alarmAcknowledged ? "Đã tắt" : "Tắt cảnh báo",
                        icon: alarmAcknowledged ? "speaker.slash.fill" : "bell.slash.fill"
                    )
                }
                .buttonStyle(RemoteActionButtonStyle(
                    tint: alarmNeedsAttention ? .red : .white.opacity(0.58)
                ))
                .disabled(!alarmNeedsAttention)
                // Blink only the button opacity. Scaling/shadow animation made
                // the surrounding red screen edge appear to judder on iPhone.
                .opacity(alarmNeedsAttention ? (alarmPulse ? 1 : 0.60) : 0.58)
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
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(amber)
                    .frame(width: 38, height: 38)
                    .background(amber.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(localized(usesLeftNozzlePath ? "Đầu trái" : "Đầu in"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(liveNozzleTemperatureText)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                Spacer()

                HStack(spacing: 0) {
                    temperatureButton(systemName: "minus") {
                        filamentTemperature = max(170, filamentTemperature - 5)
                    }
                    Text("\(filamentTemperature)°C")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(minWidth: 64)
                    temperatureButton(systemName: "plus") {
                        filamentTemperature = min(320, filamentTemperature + 5)
                    }
                }
                .padding(3)
                .background(Color.black.opacity(0.045), in: Capsule())
            }

            HStack(spacing: 8) {
                Text(localized(filamentTemperatureDescription))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
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

            HStack(spacing: 10) {
                Button {
                    confirmation = .load(temperature: filamentTemperature)
                } label: {
                    Label(localized(usesLeftNozzlePath ? "Nạp đầu trái" : "Nạp nhựa"), systemImage: "arrow.down.to.line.compact")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RemoteActionButtonStyle(tint: green))
                .disabled(!controlsReady)

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
                .disabled(!controlsReady)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var utilityControls: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                PrinterSpeedDial(
                    level: $printSpeed,
                    isEnabled: controlsReady,
                    tint: cyan,
                    onCommit: { directControl.setPrintSpeed($0) }
                )
                .frame(width: 112, height: 112)
                Text(localized("Tốc độ"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Divider().frame(height: 92)

            VStack(spacing: 12) {
                Image(systemName: chamberLightEnabled ? "lightbulb.fill" : "lightbulb")
                    .font(.system(size: 28, weight: .medium))
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
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

            HStack(spacing: 8) {
                Button(localized("Tiếp tục")) { directControl.continueActivePrompt() }
                    .buttonStyle(RemoteActionButtonStyle(tint: isError ? .red : green))
                    .disabled(!controlsReady)

                if isError {
                    Button(localized("Bỏ qua")) { directControl.ignoreActiveError() }
                        .buttonStyle(RemoteActionButtonStyle(tint: amber))
                        .disabled(!controlsReady)
                    Button(localized("Dừng")) { directControl.stopFromActivePrompt() }
                        .buttonStyle(RemoteActionButtonStyle(tint: .red))
                        .disabled(!controlsReady)
                } else {
                    Button(localized("Hoàn tất")) { directControl.finishFilamentOperation() }
                        .buttonStyle(RemoteActionButtonStyle(tint: cyan))
                        .disabled(!controlsReady)
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
            return languageCode == SEAppLanguage.english.rawValue
                ? "Follow the printer instruction, then continue or finish here."
                : "Làm theo hướng dẫn nạp nhựa, rồi xác nhận ngay tại đây."
        case .filamentUnload:
            return languageCode == SEAppLanguage.english.rawValue
                ? "Remove the filament when prompted, then continue or finish here."
                : "Rút nhựa khi máy yêu cầu, rồi xác nhận ngay tại đây."
        case .printerError:
            let code = prompt.errorCode.map { String(format: "%08X", $0) } ?? "—"
            return languageCode == SEAppLanguage.english.rawValue
                ? "Printer error \(code). Fix the cause, then continue, ignore, or stop."
                : "Lỗi máy in \(code). Khắc phục nguyên nhân rồi tiếp tục, bỏ qua hoặc dừng."
        }
    }

    private var liveNozzleTemperatureText: String {
        let snapshot = directControl.snapshot
        let directCurrent = usesLeftNozzlePath ? snapshot.leftNozzleTemperature : snapshot.nozzleTemperature
        let directTarget = usesLeftNozzlePath ? snapshot.leftNozzleTargetTemperature : snapshot.nozzleTargetTemperature
        let bridgeCurrent = usesLeftNozzlePath ? bluetooth.leftNozzleTemperature : bluetooth.nozzleTemperature
        let bridgeTarget = usesLeftNozzlePath ? bluetooth.leftNozzleTargetTemperature : bluetooth.nozzleTargetTemperature
        let current = (snapshot.isRecent ? directCurrent : nil).flatMap { $0 >= 0 ? $0 : nil }
            ?? (bridgeCurrent >= 0 ? bridgeCurrent : nil)
        let target = (snapshot.isRecent ? directTarget : nil).flatMap { $0 > 0 ? $0 : nil }
            ?? (bridgeTarget > 0 ? bridgeTarget : nil)
            ?? filamentTemperature
        return "\(current.map { String($0) } ?? "—")/\(target)°C"
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

    private func compactActionLabel(_ title: String, icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
            Text(localized(title))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity)
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

    private var currentFilamentName: String {
        let value = bluetooth.filamentType.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? localized("nhựa cuộn ngoài") : value.uppercased()
    }

    private var filamentTemperatureDescription: String {
        if bluetooth.filamentType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return languageCode == SEAppLanguage.english.rawValue
                ? "Material not reported • default \(recommendedFilamentTemperature())°C"
                : "Máy chưa báo loại nhựa • mặc định \(recommendedFilamentTemperature())°C"
        }
        return languageCode == SEAppLanguage.english.rawValue
            ? "Using \(currentFilamentName) • recommended \(recommendedFilamentTemperature())°C"
            : "Theo \(currentFilamentName) • đề xuất \(recommendedFilamentTemperature())°C"
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
        // H2D reports the right nozzle first and the left nozzle second. This
        // workflow is explicitly tied to the external spool on the left.
        let preferredTarget = profile.kind == .h2d
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
    let onCommit: (Int) -> Void

    private var needleAngle: Double {
        -120 + (Double(min(4, max(1, level))) - 1) * 80
    }

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.07), radius: 8, y: 3)
                Circle()
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)

                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index + 1 == level ? tint : Color.black.opacity(0.18))
                        .frame(width: 3, height: index + 1 == level ? 11 : 7)
                        .offset(y: -(diameter / 2) + 14)
                        .rotationEffect(.degrees(-120 + Double(index) * 80))
                }

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.3), tint],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 4, height: diameter * 0.28)
                    .offset(y: -diameter * 0.14)
                    .rotationEffect(.degrees(needleAngle))
                    .shadow(color: tint.opacity(0.35), radius: 4)

                Circle()
                    .fill(tint)
                    .frame(width: 13, height: 13)
                Image(systemName: "speedometer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .offset(y: diameter * 0.25)
            }
            .opacity(isEnabled ? 1 : 0.42)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        level = dialLevel(at: gesture.location, size: proxy.size)
                    }
                    .onEnded { _ in
                        guard isEnabled else { return }
                        onCommit(level)
                    }
            )
            .animation(.easeOut(duration: 0.14), value: level)
        }
        .accessibilityElement()
        .accessibilityLabel("Print speed")
        .accessibilityValue("\(level) of 4")
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
        let dx = location.x - size.width / 2
        let dy = location.y - size.height / 2
        let degrees = atan2(dx, -dy) * 180 / .pi
        let clamped = min(120, max(-120, degrees))
        return min(4, max(1, Int(((clamped + 120) / 80).rounded()) + 1))
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

private struct RemoteActionButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 7)
            .frame(minHeight: 48)
            .foregroundStyle(tint)
            .background(tint.opacity(configuration.isPressed ? 0.16 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
