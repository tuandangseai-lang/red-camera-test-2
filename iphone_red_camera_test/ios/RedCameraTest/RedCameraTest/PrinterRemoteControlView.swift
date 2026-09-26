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
    let alarmActive: Bool
    let alarmAcknowledged: Bool
    let onSilenceAlarm: () -> Void

    @StateObject private var directControl = BambuPrinterControlManager()
    @State private var filamentTemperature = 220
    @State private var automaticTemperatureSignature = ""
    @State private var printSpeed = 2
    @State private var confirmation: RemoteConfirmation?
    @State private var showsFilamentControls = false
    @State private var showsUtilityControls = false
    @State private var alarmPulse = false

    private let cyan = Color(red: 0.18, green: 0.88, blue: 0.96)
    private let amber = Color(red: 0.96, green: 0.61, blue: 0.20)
    private let green = Color(red: 0.20, green: 0.94, blue: 0.57)

    private var controlsReady: Bool {
        directControl.isReady && !directControl.isPending
    }

    private var alarmNeedsAttention: Bool {
        alarmActive && !alarmAcknowledged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            controlHeader
            Divider().overlay(.white.opacity(0.08))
            quickActions
            filamentControls
            utilityControls
        }
        .padding(15)
        .background(.black.opacity(0.46), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(cyan.opacity(0.20), lineWidth: 1)
        }
        .onAppear {
            startDirectControl()
            updateAlarmPulse()
        }
        .onDisappear { directControl.stop() }
        .onChange(of: profile.id) { _, _ in startDirectControl() }
        .onChange(of: accessCode) { _, _ in startDirectControl() }
        .onChange(of: bluetooth.filamentType) { _, _ in applyAutomaticFilamentTemperature() }
        .onChange(of: bluetooth.nozzleTargetTemperature) { _, _ in applyAutomaticFilamentTemperature() }
        .onChange(of: bluetooth.leftNozzleTargetTemperature) { _, _ in applyAutomaticFilamentTemperature() }
        .onChange(of: alarmNeedsAttention) { _, _ in updateAlarmPulse() }
        .alert(
            confirmation?.title ?? "Xác nhận",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            presenting: confirmation
        ) { action in
            switch action {
            case .stop:
                Button("Dừng", role: .destructive) { directControl.stopPrint() }
            case let .load(temperature):
                Button("Nạp cuộn ngoài vào đầu trái") {
                    directControl.loadExternalFilamentIntoLeftNozzle(temperature: temperature)
                }
            case let .unload(temperature, _):
                Button("Rút nhựa đầu trái", role: .destructive) {
                    directControl.unloadExternalFilamentFromLeftNozzle(temperature: temperature)
                }
            }
            Button("Hủy", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
    }

    private var controlHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(cyan)
                .frame(width: 34, height: 34)
                .background(cyan.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("ĐIỀU KHIỂN \(printerName.uppercased())")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                Text(directControl.statusText)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            if directControl.isPending {
                ProgressView().tint(amber)
            } else {
                Circle()
                    .fill(directControl.isReady ? green : amber)
                    .frame(width: 8, height: 8)
                    .shadow(color: directControl.isReady ? green : amber, radius: 5)
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
                .accessibilityLabel("Kết nối lại điều khiển máy in")
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 9) {
            controlTitle("THAO TÁC NHANH", icon: "hand.tap.fill")

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
                .opacity(alarmNeedsAttention ? (alarmPulse ? 1 : 0.48) : 0.58)
                .scaleEffect(alarmNeedsAttention && alarmPulse ? 1.025 : 1)
                .shadow(color: alarmNeedsAttention ? .red.opacity(alarmPulse ? 0.8 : 0.15) : .clear, radius: 8)
                .animation(
                    alarmNeedsAttention
                        ? .easeInOut(duration: 0.62).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.18),
                    value: alarmPulse
                )
                .accessibilityHint(alarmNeedsAttention
                    ? "Tắt âm cảnh báo hiện tại"
                    : "Chỉ khả dụng khi máy in có cảnh báo")
            }
        }
    }

    private var filamentControls: some View {
        DisclosureGroup(isExpanded: $showsFilamentControls) {
            VStack(spacing: 12) {
                Stepper(value: $filamentTemperature, in: 170...320, step: 5) {
                    HStack {
                        Text("Nhiệt đầu trái")
                        Spacer()
                        Text("\(filamentTemperature)°C")
                            .monospacedDigit()
                            .foregroundStyle(amber)
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(amber)
                    Text(filamentTemperatureDescription)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.54))
                    Spacer(minLength: 4)
                    Button("Theo máy") { applyAutomaticFilamentTemperature(force: true) }
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .buttonStyle(.bordered)
                        .tint(cyan)
                }

                HStack(spacing: 10) {
                    Button {
                        confirmation = .load(temperature: filamentTemperature)
                    } label: {
                        Label("Nạp đầu trái", systemImage: "arrow.down.to.line.compact")
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
                        Label("Rút đầu trái", systemImage: "arrow.up.from.line.compact")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RemoteActionButtonStyle(tint: amber))
                    .disabled(!controlsReady)
                }

                Text("Chỉ dùng cuộn ngoài bên trái của H2D; không chọn và không chạy motor AMS.")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 10)
        } label: {
            controlTitle("NHỰA CUỘN NGOÀI • ĐẦU TRÁI", icon: "arrow.triangle.2.circlepath")
        }
        .tint(cyan)
    }

    private var utilityControls: some View {
        DisclosureGroup(isExpanded: $showsUtilityControls) {
            VStack(spacing: 12) {
                Picker("Tốc độ", selection: $printSpeed) {
                    Text("Im lặng").tag(1)
                    Text("Chuẩn").tag(2)
                    Text("Nhanh").tag(3)
                    Text("Siêu tốc").tag(4)
                }
                .pickerStyle(.segmented)

                HStack(spacing: 10) {
                    Button {
                        directControl.setPrintSpeed(printSpeed)
                    } label: {
                        Label("Áp dụng tốc độ", systemImage: "speedometer")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RemoteActionButtonStyle(tint: cyan))
                    .disabled(!controlsReady)

                    Button("Bật đèn") { directControl.setChamberLight(enabled: true) }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.bordered)
                        .tint(amber)
                        .disabled(!controlsReady)

                    Button("Tắt đèn") { directControl.setChamberLight(enabled: false) }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.bordered)
                        .tint(.white.opacity(0.72))
                        .disabled(!controlsReady)
                }
            }
            .padding(.top, 10)
        } label: {
            controlTitle("TỐC ĐỘ & ĐÈN BUỒNG IN", icon: "slider.horizontal.3")
        }
        .tint(cyan)
    }

    private func compactActionLabel(_ title: String, icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
            Text(title)
                .font(.system(size: 9, weight: .black, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity)
    }

    private func startDirectControl() {
        directControl.start(profile: profile, accessCode: accessCode)
        applyAutomaticFilamentTemperature(force: true)
    }

    private func updateAlarmPulse() {
        alarmPulse = false
        guard alarmNeedsAttention else { return }
        DispatchQueue.main.async { alarmPulse = true }
    }

    private var currentFilamentName: String {
        let value = bluetooth.filamentType.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "nhựa cuộn ngoài" : value.uppercased()
    }

    private var filamentTemperatureDescription: String {
        if bluetooth.filamentType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Máy chưa báo loại nhựa • mặc định \(recommendedFilamentTemperature())°C"
        }
        return "Theo \(currentFilamentName) • đề xuất \(recommendedFilamentTemperature())°C"
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
        Label(title, systemImage: icon)
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .foregroundStyle(cyan.opacity(0.88))
    }
}

private enum RemoteConfirmation: Identifiable {
    case stop
    case load(temperature: Int)
    case unload(temperature: Int, material: String)

    var id: String {
        switch self {
        case .stop: return "stop"
        case let .load(temperature): return "load-left-external-\(temperature)"
        case let .unload(temperature, material): return "unload-left-external-\(temperature)-\(material)"
        }
    }

    var title: String {
        switch self {
        case .stop: return "Dừng hẳn bản in?"
        case .load: return "Nạp cuộn ngoài vào đầu trái?"
        case .unload: return "Rút nhựa khỏi đầu trái?"
        }
    }

    var message: String {
        switch self {
        case .stop:
            return "Máy in sẽ hủy công việc hiện tại. Thao tác này không thể tiếp tục lại."
        case let .load(temperature):
            return "Chỉ dùng cuộn ngoài đầu trái. Đầu phun có thể nóng tới \(temperature)°C; AMS sẽ không được chọn."
        case let .unload(temperature, material):
            return "Rút \(material) khỏi đầu trái ở \(temperature)°C. AMS không được chọn; hãy giữ tay khỏi đầu phun và bộ đùn."
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
            .background(tint.opacity(configuration.isPressed ? 0.24 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(tint.opacity(0.34), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
