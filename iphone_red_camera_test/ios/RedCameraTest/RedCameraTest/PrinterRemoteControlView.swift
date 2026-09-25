import Foundation
import SwiftUI

struct PrinterRemoteControlView: View {
    @ObservedObject var bluetooth: H2DBLEManager
    @ObservedObject var printerCamera: BambuPrinterCameraManager
    @Binding var cameraEnabled: Bool
    let printerName: String
    let profile: BambuPrinterProfile
    let accessCode: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var directControl = BambuPrinterControlManager()
    @State private var selectedObjectIDs = Set<Int>()
    @State private var filamentTemperature = 220
    @State private var printSpeed = 2
    @State private var confirmation: RemoteConfirmation?

    private let cyan = Color(red: 0.18, green: 0.88, blue: 0.96)
    private let amber = Color(red: 0.96, green: 0.61, blue: 0.20)
    private let green = Color(red: 0.20, green: 0.94, blue: 0.57)

    private var controlsReady: Bool {
        directControl.isReady && !directControl.isPending
    }

    private var selectedObjects: [BambuPrintableObject] {
        directControl.printableObjects.filter { selectedObjectIDs.contains($0.id) }
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
        .onAppear(perform: startDirectControl)
        .onDisappear { directControl.stop() }
        .onChange(of: profile.id) { _, _ in startDirectControl() }
        .onChange(of: accessCode) { _, _ in startDirectControl() }
        .onChange(of: directControl.printableObjects) { _, objects in
            let selectable = Set(objects.filter { !$0.isSkipped }.map(\.id))
            selectedObjectIDs.formIntersection(selectable)
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
                    directControl.stopPrint()
                }
            case let .skip(ids, _):
                Button("Bỏ qua vật thể đã chọn", role: .destructive) {
                    directControl.skipObjects(ids)
                    selectedObjectIDs.removeAll()
                }
            case let .load(temperature):
                Button("Nạp cuộn ngoài") {
                    directControl.loadExternalFilament(temperature: temperature)
                }
            case .unload:
                Button("Rút cuộn ngoài", role: .destructive) {
                    directControl.unloadExternalFilament()
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
                    Text("MQTT LAN TRỰC TIẾP TỪ IPHONE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.42))
                }
                Spacer()
                Circle()
                    .fill(directControl.isReady ? green : amber)
                    .frame(width: 8, height: 8)
                    .shadow(color: directControl.isReady ? green : amber, radius: 5)
            }

            HStack(alignment: .top, spacing: 9) {
                if directControl.isPending {
                    ProgressView().tint(amber)
                } else {
                    Image(systemName: directControl.lastSucceeded == false
                        ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(directControl.lastSucceeded == false ? .red : green)
                }
                Text(directControl.statusText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                Spacer(minLength: 5)
                if !directControl.isReady && !directControl.isPending {
                    Button("Kết nối lại") { directControl.retry() }
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .buttonStyle(.bordered)
                        .tint(cyan)
                }
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
                        directControl.resumePrint()
                    } else {
                        directControl.pausePrint()
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
            HStack {
                controlTitle("CHẠM VẬT THỂ CẦN BỎ QUA", icon: "square.stack.3d.up.slash.fill")
                Spacer()
                Button {
                    directControl.refreshObjects()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .tint(cyan)
                .disabled(directControl.isLoadingObjects)
            }

            objectSelectionBed

            HStack(spacing: 8) {
                if directControl.isLoadingObjects {
                    ProgressView().tint(amber)
                }
                Text(directControl.objectStatusText)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
            }

            Button {
                let objects = selectedObjects
                confirmation = .skip(objects.map(\.id), objects.map(\.name))
            } label: {
                Label(
                    selectedObjectIDs.isEmpty
                        ? "Chạm chọn vật thể trên bàn in"
                        : "Bỏ qua \(selectedObjectIDs.count) vật thể đã chọn",
                    systemImage: "forward.end.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RemoteActionButtonStyle(tint: amber))
            .disabled(!controlsReady || !bluetooth.isPrintSessionActive || selectedObjectIDs.isEmpty)
        }
        .remoteControlCard()
    }

    private var objectSelectionBed: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0.035, green: 0.085, blue: 0.095))
                BedGrid()
                    .stroke(cyan.opacity(0.12), lineWidth: 0.7)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if directControl.printableObjects.isEmpty && !directControl.isLoadingObjects {
                    VStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 25, weight: .semibold))
                        Text("Bấm làm mới để đọc vật thể\ntrong bản in hiện tại")
                            .multilineTextAlignment(.center)
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.34))
                }

                ForEach(Array(directControl.printableObjects.enumerated()), id: \.element.id) { index, object in
                    let selected = selectedObjectIDs.contains(object.id)
                    Button {
                        toggleObject(object)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: object.isSkipped
                                ? "checkmark.seal.fill"
                                : (selected ? "checkmark.circle.fill" : "cube.fill"))
                                .font(.system(size: 22, weight: .bold))
                            Text(shortObjectName(object.name))
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(object.isSkipped ? .white.opacity(0.28) : (selected ? .black : cyan))
                        .frame(width: 82, height: 64)
                        .background(
                            object.isSkipped ? Color.white.opacity(0.05) : (selected ? amber : Color.black.opacity(0.54)),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(selected ? amber : cyan.opacity(0.28), lineWidth: selected ? 2 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(object.isSkipped)
                    .position(objectPosition(object, index: index, in: geometry.size))
                }
            }
        }
        .aspectRatio(1.18, contentMode: .fit)
        .accessibilityLabel("Sơ đồ vật thể trên bàn in")
    }

    private var filamentCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                controlTitle("NẠP / RÚT NHỰA CUỘN NGOÀI", icon: "arrow.triangle.2.circlepath")
                Spacer()
                Text("KHÔNG AMS")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(green)
            }

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
                    confirmation = .load(temperature: filamentTemperature)
                } label: {
                    Label("Nạp cuộn ngoài", systemImage: "arrow.down.to.line.compact")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RemoteActionButtonStyle(tint: green))
                .disabled(!controlsReady)

                Button {
                    confirmation = .unload
                } label: {
                    Label("Rút cuộn ngoài", systemImage: "arrow.up.from.line.compact")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RemoteActionButtonStyle(tint: amber))
                .disabled(!controlsReady)
            }

            Text("Hai nút này chỉ điều khiển đường nhựa cuộn ngoài; không chọn và không chạy motor AMS.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.46))
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
                directControl.setPrintSpeed(printSpeed)
            } label: {
                Label("Áp dụng tốc độ", systemImage: "speedometer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RemoteActionButtonStyle(tint: cyan))
            .disabled(!controlsReady || !bluetooth.isPrintSessionActive)

            HStack(spacing: 10) {
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
        .remoteControlCard()
    }

    private var safetyNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Máy in phải bật LAN Mode > Developer Mode để nhận lệnh điều khiển từ SE.",
                systemImage: "network.badge.shield.half.filled"
            )
            Label(
                "iPhone và máy in phải cùng Wi-Fi. Điểm truy cập cá nhân cần được tắt.",
                systemImage: "wifi"
            )
            Label(
                "Giữ máy trong tầm quan sát khi dừng in hoặc nạp/rút nhựa.",
                systemImage: "exclamationmark.shield.fill"
            )
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(amber.opacity(0.86))
        .padding(.horizontal, 4)
    }

    private func startDirectControl() {
        directControl.start(profile: profile, accessCode: accessCode)
    }

    private func toggleObject(_ object: BambuPrintableObject) {
        guard !object.isSkipped else { return }
        if selectedObjectIDs.contains(object.id) {
            selectedObjectIDs.remove(object.id)
        } else {
            selectedObjectIDs.insert(object.id)
        }
    }

    private func shortObjectName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutExtension = (trimmed as NSString).deletingPathExtension
        let value = withoutExtension.isEmpty ? trimmed : withoutExtension
        return value.count > 20 ? String(value.prefix(18)) + "…" : value
    }

    private func objectPosition(
        _ object: BambuPrintableObject,
        index: Int,
        in size: CGSize
    ) -> CGPoint {
        let padding: CGFloat = 48
        let objectsWithPosition = directControl.printableObjects.compactMap { item -> (Double, Double)? in
            guard let x = item.centerX, let y = item.centerY else { return nil }
            return (x, y)
        }

        if let x = object.centerX, let y = object.centerY, !objectsWithPosition.isEmpty {
            let xs = objectsWithPosition.map(\.0)
            let ys = objectsWithPosition.map(\.1)
            let minX = xs.min() ?? x
            let maxX = xs.max() ?? x
            let minY = ys.min() ?? y
            let maxY = ys.max() ?? y
            let spanX = max(maxX - minX, 1)
            let spanY = max(maxY - minY, 1)
            let availableWidth = max(size.width - padding * 2, 1)
            let availableHeight = max(size.height - padding * 2, 1)
            return CGPoint(
                x: padding + CGFloat((x - minX) / spanX) * availableWidth,
                y: size.height - padding - CGFloat((y - minY) / spanY) * availableHeight
            )
        }

        let count = max(directControl.printableObjects.count, 1)
        let columns = max(Int(ceil(sqrt(Double(count)))), 1)
        let rows = max(Int(ceil(Double(count) / Double(columns))), 1)
        let column = index % columns
        let row = index / columns
        return CGPoint(
            x: size.width * CGFloat(column + 1) / CGFloat(columns + 1),
            y: size.height * CGFloat(row + 1) / CGFloat(rows + 1)
        )
    }

    private func controlTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .black, design: .monospaced))
            .foregroundStyle(cyan.opacity(0.88))
    }
}

private struct BedGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let divisions = 8
        for index in 1..<divisions {
            let fraction = CGFloat(index) / CGFloat(divisions)
            let x = rect.minX + rect.width * fraction
            let y = rect.minY + rect.height * fraction
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

private enum RemoteConfirmation: Identifiable {
    case stop
    case skip([Int], [String])
    case load(temperature: Int)
    case unload

    var id: String {
        switch self {
        case .stop: return "stop"
        case let .skip(ids, _): return "skip-\(ids.map(String.init).joined(separator: "-"))"
        case let .load(temperature): return "load-external-\(temperature)"
        case .unload: return "unload-external"
        }
    }

    var title: String {
        switch self {
        case .stop: return "Dừng hẳn bản in?"
        case .skip: return "Bỏ qua vật thể đã chọn?"
        case .load: return "Nạp nhựa từ cuộn ngoài?"
        case .unload: return "Rút nhựa cuộn ngoài?"
        }
    }

    var message: String {
        switch self {
        case .stop:
            return "Máy in sẽ hủy công việc hiện tại. Thao tác này không thể tiếp tục lại."
        case let .skip(_, names):
            return "Máy sẽ ngừng in: \(names.joined(separator: ", "))."
        case let .load(temperature):
            return "Chỉ dùng cuộn ngoài. Đầu phun có thể nóng tới \(temperature)°C; AMS sẽ không được chọn."
        case .unload:
            return "Chỉ rút đường nhựa cuộn ngoài. Hãy giữ tay khỏi đầu phun và bộ đùn."
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
