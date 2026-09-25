import SwiftUI

struct PrinterRemoteControlView: View {
    @ObservedObject var bluetooth: H2DBLEManager
    @ObservedObject var printerCamera: BambuPrinterCameraManager
    @Binding var cameraEnabled: Bool
    let printerName: String

    @Environment(\.dismiss) private var dismiss
    @State private var objectIDsText = ""
    @State private var filamentSource = 0
    @State private var filamentTemperature = 220
    @State private var printSpeed = 2
    @State private var confirmation: RemoteConfirmation?

    private let cyan = Color(red: 0.18, green: 0.88, blue: 0.96)
    private let amber = Color(red: 0.96, green: 0.61, blue: 0.20)
    private let green = Color(red: 0.20, green: 0.94, blue: 0.57)

    private var controlsReady: Bool {
        bluetooth.isConnected && bluetooth.isH2DBridge && bluetooth.isH2DReady &&
            !bluetooth.isSwitchingPrinter && !bluetooth.isPrinterControlPending
    }

    private var parsedObjectIDs: [Int]? {
        let tokens = objectIDsText.split { character in
            character == "," || character == ";" || character.isWhitespace
        }
        guard !tokens.isEmpty, tokens.count <= 24 else { return nil }
        let values = tokens.compactMap { Int($0) }
        guard values.count == tokens.count,
              values.allSatisfy({ (0...9999).contains($0) }) else { return nil }
        return Array(Set(values)).sorted()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [.black, Color(red: 0.025, green: 0.075, blue: 0.09)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        statusCard
                        printerCameraCard
                        printJobCard
                        skipObjectsCard
                        filamentCard
                        utilityCard
                        safetyNote
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)
            }
            .preferredColorScheme(.dark)
            .navigationTitle("Điều khiển máy in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
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
                Button("Dừng bản in", role: .destructive) {
                    bluetooth.stopSelectedPrint()
                }
            case let .skip(ids):
                Button("Bỏ qua \(ids.count) vật thể", role: .destructive) {
                    bluetooth.skipSelectedPrintObjects(ids)
                }
            case let .load(source, temperature):
                Button("Nạp nhựa") {
                    let location = filamentLocation(source)
                    bluetooth.loadFilament(
                        amsID: location.amsID,
                        slotID: location.slotID,
                        target: location.target,
                        temperature: temperature
                    )
                }
            case let .unload(source):
                Button("Rút nhựa", role: .destructive) {
                    bluetooth.unloadFilament(amsID: filamentLocation(source).amsID)
                }
            }
            Button("Hủy", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 11) {
                Image(systemName: "printer.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text(printerName.uppercased())
                        .font(.system(size: 15, weight: .black, design: .rounded))
                    Text("MQTT LAN QUA ESP32")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.42))
                }
                Spacer()
                Circle()
                    .fill(controlsReady ? green : amber)
                    .frame(width: 8, height: 8)
                    .shadow(color: controlsReady ? green : amber, radius: 5)
            }

            HStack(alignment: .top, spacing: 9) {
                if bluetooth.isPrinterControlPending {
                    ProgressView().tint(amber)
                } else {
                    Image(systemName: bluetooth.printerControlLastSucceeded == false
                        ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(bluetooth.printerControlLastSucceeded == false ? .red : green)
                }
                Text(bluetooth.printerControlStatusText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
        .remoteControlCard()
    }

    private var printerCameraCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                controlTitle("CAMERA MÁY IN", icon: "video.fill")
                Spacer()
                Text(printerCamera.isStreaming ? "LIVE" : printerCamera.transportText)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(printerCamera.isStreaming ? green : amber)
                Button {
                    cameraEnabled.toggle()
                } label: {
                    Image(systemName: cameraEnabled ? "video.slash.fill" : "video.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .tint(cameraEnabled ? .white.opacity(0.70) : cyan)
            }

            ZStack {
                LinearGradient(
                    colors: [.black, Color(red: 0.018, green: 0.055, blue: 0.07)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if cameraEnabled, let frame = printerCamera.frame {
                    Image(decorative: frame, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFit()
                } else {
                    VStack(spacing: 9) {
                        if cameraEnabled && printerCamera.isConnecting {
                            ProgressView().tint(amber)
                        } else {
                            Image(systemName: cameraEnabled ? "video.fill" : "video.slash")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(cameraEnabled ? amber : .white.opacity(0.30))
                        }
                        Text(cameraEnabled
                            ? printerCamera.statusText
                            : "Bật camera để theo dõi thao tác điều khiển")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.60))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 18)
                        if cameraEnabled && !printerCamera.isConnecting && !printerCamera.isStreaming {
                            Button("Thử lại") { printerCamera.retryNow() }
                                .buttonStyle(.bordered)
                                .tint(cyan)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke((printerCamera.isStreaming ? green : cyan).opacity(0.28), lineWidth: 1)
            }
        }
        .remoteControlCard()
    }

    private var printJobCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            controlTitle("BẢN IN HIỆN TẠI", icon: "playpause.fill")
            HStack(spacing: 10) {
                Button {
                    if bluetooth.isPausedPrint {
                        bluetooth.resumeSelectedPrint()
                    } else {
                        bluetooth.pauseSelectedPrint()
                    }
                } label: {
                    Label(
                        bluetooth.isPausedPrint ? "Tiếp tục" : "Tạm dừng",
                        systemImage: bluetooth.isPausedPrint ? "play.fill" : "pause.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(RemoteActionButtonStyle(tint: cyan))
                .disabled(!controlsReady || !bluetooth.isPrintSessionActive)

                Button {
                    confirmation = .stop
                } label: {
                    Label("Dừng in", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RemoteActionButtonStyle(tint: .red))
                .disabled(!controlsReady || !bluetooth.isPrintSessionActive)
            }
            Text("Trạng thái: \(bluetooth.h2dPrintState) • \(bluetooth.h2dPrintPercent)%")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.48))
        }
        .remoteControlCard()
    }

    private var skipObjectsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            controlTitle("BỎ QUA VẬT THỂ", icon: "square.stack.3d.up.slash.fill")
            TextField("ID, ví dụ: 1, 3, 5", text: $objectIDsText)
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(.black.opacity(0.36), in: RoundedRectangle(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(cyan.opacity(0.24), lineWidth: 1)
                }

            Button {
                if let ids = parsedObjectIDs { confirmation = .skip(ids) }
            } label: {
                Label("Bỏ qua các ID đã nhập", systemImage: "forward.end.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RemoteActionButtonStyle(tint: amber))
            .disabled(!controlsReady || !bluetooth.isPrintSessionActive || parsedObjectIDs == nil)

            Text("Nhập ID vật thể trong file đã slice. Đây không phải số thứ tự lớp in.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
        }
        .remoteControlCard()
    }

    private var filamentCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            controlTitle("NẠP / RÚT NHỰA", icon: "arrow.triangle.2.circlepath")

            Picker("Nguồn nhựa", selection: $filamentSource) {
                ForEach(0..<17, id: \.self) { source in
                    Text(filamentSourceName(source)).tag(source)
                }
            }
            .pickerStyle(.menu)
            .tint(cyan)

            Stepper(value: $filamentTemperature, in: 170...320, step: 5) {
                HStack {
                    Text("Nhiệt độ đầu phun")
                    Spacer()
                    Text("\(filamentTemperature)°C")
                        .monospacedDigit()
                        .foregroundStyle(amber)
                }
            }

            HStack(spacing: 10) {
                Button {
                    confirmation = .load(source: filamentSource, temperature: filamentTemperature)
                } label: {
                    Label("Nạp nhựa", systemImage: "arrow.down.to.line.compact")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RemoteActionButtonStyle(tint: green))
                .disabled(!controlsReady)

                Button {
                    confirmation = .unload(source: filamentSource)
                } label: {
                    Label("Rút nhựa", systemImage: "arrow.up.from.line.compact")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RemoteActionButtonStyle(tint: amber))
                .disabled(!controlsReady)
            }

            HStack(spacing: 10) {
                Button("AMS tiếp tục") { bluetooth.continueFilamentOperation() }
                    .buttonStyle(.bordered)
                    .tint(cyan)
                    .disabled(!controlsReady)
                Button("Đã hoàn tất") { bluetooth.finishFilamentOperation() }
                    .buttonStyle(.bordered)
                    .tint(green)
                    .disabled(!controlsReady)
            }
        }
        .remoteControlCard()
    }

    private var utilityCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            controlTitle("TIỆN ÍCH", icon: "slider.horizontal.3")
            Picker("Tốc độ", selection: $printSpeed) {
                Text("Im lặng").tag(1)
                Text("Chuẩn").tag(2)
                Text("Nhanh").tag(3)
                Text("Siêu tốc").tag(4)
            }
            .pickerStyle(.segmented)

            Button {
                bluetooth.setSelectedPrintSpeed(printSpeed)
            } label: {
                Label("Áp dụng tốc độ", systemImage: "speedometer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RemoteActionButtonStyle(tint: cyan))
            .disabled(!controlsReady || !bluetooth.isPrintSessionActive)

            HStack(spacing: 10) {
                Button("Bật đèn") { bluetooth.setChamberLightEnabled(true) }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
                    .tint(amber)
                    .disabled(!controlsReady)
                Button("Tắt đèn") { bluetooth.setChamberLightEnabled(false) }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.72))
                    .disabled(!controlsReady)
            }
        }
        .remoteControlCard()
    }

    private var safetyNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Firmware Bambu mới cần bật LAN Mode > Developer Mode để nhận lệnh từ SE.",
                systemImage: "network.badge.shield.half.filled"
            )
            Label(
                "Giữ máy trong tầm quan sát. Xác nhận nhận lệnh không có nghĩa thao tác cơ khí đã hoàn tất.",
                systemImage: "exclamationmark.shield.fill"
            )
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(amber.opacity(0.86))
        .padding(.horizontal, 4)
    }

    private func controlTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .black, design: .monospaced))
            .foregroundStyle(cyan.opacity(0.88))
    }

    private func filamentSourceName(_ source: Int) -> String {
        guard source < 16 else { return "Cuộn ngoài" }
        return "AMS \(source / 4 + 1) • khe \(source % 4 + 1)"
    }

    private func filamentLocation(_ source: Int) -> (amsID: Int, slotID: Int, target: Int) {
        guard source < 16 else { return (255, 0, 254) }
        return (source / 4, source % 4, source)
    }
}

private enum RemoteConfirmation: Identifiable {
    case stop
    case skip([Int])
    case load(source: Int, temperature: Int)
    case unload(source: Int)

    var id: String {
        switch self {
        case .stop: return "stop"
        case let .skip(ids): return "skip-\(ids.map(String.init).joined(separator: "-"))"
        case let .load(source, temperature): return "load-\(source)-\(temperature)"
        case let .unload(source): return "unload-\(source)"
        }
    }

    var title: String {
        switch self {
        case .stop: return "Dừng hẳn bản in?"
        case .skip: return "Bỏ qua vật thể đã chọn?"
        case .load: return "Bắt đầu nạp nhựa?"
        case .unload: return "Bắt đầu rút nhựa?"
        }
    }

    var message: String {
        switch self {
        case .stop:
            return "Máy in sẽ hủy công việc hiện tại. Thao tác này không thể tiếp tục lại."
        case let .skip(ids):
            return "Máy sẽ ngừng in các vật thể ID \(ids.map(String.init).joined(separator: ", "))."
        case let .load(_, temperature):
            return "Đầu phun có thể nóng tới \(temperature)°C và AMS sẽ chuyển động. Hãy bảo đảm đường nhựa an toàn."
        case .unload:
            return "AMS và đầu phun sẽ chuyển động để rút nhựa. Hãy giữ tay khỏi cơ cấu máy."
        }
    }
}

private extension View {
    func remoteControlCard() -> some View {
        padding(15)
            .background(.black.opacity(0.46), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
    }
}

private struct RemoteActionButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .padding(.horizontal, 10)
            .frame(minHeight: 43)
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
