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
    @State private var showsFilamentHelp = false

    private let cyan = Color(red: 0.02, green: 0.43, blue: 0.40)
    private let amber = Color(red: 0.91, green: 0.48, blue: 0.14)
    private let green = Color(red: 0.03, green: 0.61, blue: 0.43)

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
        .onChange(of: directControl.activePrompt?.id) { _, _ in
            showsFilamentHelp = false
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
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(amber)
                    .frame(width: 34, height: 34)
                    .background(amber.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(localized(usesLeftNozzlePath ? "Đầu trái" : "Đầu in"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(liveNozzleTemperatureText)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
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
        .background(
            Color(red: 0.965, green: 0.975, blue: 0.973),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(cyan.opacity(0.10), lineWidth: 1)
        }
    }

    private var utilityControls: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                PrinterSpeedDial(
                    level: $printSpeed,
                    isEnabled: controlsReady,
                    tint: cyan,
                    caption: localized("Tăng tốc"),
                    onCommit: { directControl.setPrintSpeed($0) }
                )
                .frame(width: 176, height: 108)
            }
            .frame(maxWidth: .infinity)

            Divider().frame(height: 82)

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
    let caption: String
    let onCommit: (Int) -> Void

    private let startAngle = 200.0
    private let endAngle = 340.0
    private let speedPercents = [50, 100, 124, 166]

    private var needleAngle: Double {
        startAngle + (Double(min(4, max(1, level))) - 1) * ((endAngle - startAngle) / 3)
    }

    private var speedPercent: Int {
        speedPercents[min(3, max(0, level - 1))]
    }

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height - 9)
            let radius = min(proxy.size.width * 0.45, proxy.size.height - 14)
            ZStack {
                gaugeArc(center: center, radius: radius)
                    .stroke(Color.black.opacity(0.07), style: StrokeStyle(lineWidth: 11, lineCap: .round))

                gaugeArc(center: center, radius: radius)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 0.02, green: 0.62, blue: 0.46),
                                Color(red: 0.02, green: 0.49, blue: 0.65),
                                Color(red: 0.11, green: 0.35, blue: 0.83)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .shadow(color: tint.opacity(0.18), radius: 5)

                ForEach(0..<13, id: \.self) { index in
                    let fraction = Double(index) / 12
                    let angle = startAngle + (endAngle - startAngle) * fraction
                    let isMajor = index % 4 == 0
                    Path { path in
                        path.move(to: point(center: center, radius: radius - (isMajor ? 15 : 10), angle: angle))
                        path.addLine(to: point(center: center, radius: radius - 4, angle: angle))
                    }
                    .stroke(
                        isMajor ? Color.primary.opacity(0.60) : Color.primary.opacity(0.24),
                        style: StrokeStyle(lineWidth: isMajor ? 2 : 1, lineCap: .round)
                    )
                }

                ForEach(0..<4, id: \.self) { index in
                    let angle = startAngle + (endAngle - startAngle) * (Double(index) / 3)
                    Text("\(speedPercents[index])")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .position(point(center: center, radius: radius - 26, angle: angle))
                }

                Path { path in
                    path.move(to: center)
                    path.addLine(to: point(center: center, radius: radius * 0.68, angle: needleAngle))
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .shadow(color: tint.opacity(0.38), radius: 4)

                Circle()
                    .fill(tint)
                    .frame(width: 12, height: 12)
                    .position(center)

                VStack(spacing: 0) {
                    Text("\(speedPercent)%")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text(caption.uppercased())
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                }
                .position(x: center.x, y: center.y - radius * 0.36)
            }
            .opacity(isEnabled ? 1 : 0.42)
            .contentShape(Rectangle())
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

    private func gaugeArc(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for step in 0...60 {
            let fraction = Double(step) / 60
            let angle = startAngle + (endAngle - startAngle) * fraction
            let next = point(center: center, radius: radius, angle: angle)
            if step == 0 { path.move(to: next) } else { path.addLine(to: next) }
        }
        return path
    }

    private func point(center: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
        let radians = angle * .pi / 180
        return CGPoint(
            x: center.x + radius * CGFloat(cos(radians)),
            y: center.y + radius * CGFloat(sin(radians))
        )
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
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(tint)
            .background(tint.opacity(configuration.isPressed ? 0.16 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
