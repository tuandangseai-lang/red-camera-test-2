import Combine
import Network
import Security
import SwiftUI
import UIKit
import VLCKit

/// H2D's LAN RTSPS endpoint uses a printer-local certificate.  VLC asks the
/// host application to confirm that certificate before it starts decoding;
/// without a dialog provider the question is silently cancelled and the app
/// only reports a generic "camera could not be opened" error.  This renderer
/// accepts certificate questions automatically (the stream is already limited
/// to the user's private LAN and authenticated with the H2D access code),
/// while cancelling unrelated dialogs instead of blocking playback.
private final class H2DVLCCertificateDialogRenderer: NSObject, VLCCustomDialogRendererProtocol {
    weak var provider: VLCDialogProvider?
    var password = ""

    func showError(withTitle error: String, message: String) {
        // VLC's error is surfaced by VLCMediaPlayerStateError; no modal UI is
        // needed here because the camera view has its own status banner.
    }

    func showLogin(
        withTitle title: String,
        message: String,
        defaultUsername username: String?,
        askingForStorage: Bool,
        withReference reference: NSValue
    ) {
        // Credentials are supplied in the media URL/options.  Do not display
        // a second login prompt that would stall the live view.
        provider?.postUsername("bblp", andPassword: password, forDialogReference: reference, store: false)
    }

    func showQuestion(
        withTitle title: String,
        message: String,
        type questionType: VLCDialogQuestionType,
        cancel cancelString: String?,
        action1String: String?,
        action2String: String?,
        withReference reference: NSValue
    ) {
        let text = "\(title) \(message)".lowercased()
        let isCertificateQuestion = ["certificate", "certificat", "ssl", "tls", "insecure", "security", "bảo mật"]
            .contains { text.contains($0) }
        // Action 1 is VLC's normal "accept/continue" button.  Any other
        // question is cancelled so it cannot leave the player waiting.
        provider?.postAction(isCertificateQuestion ? 1 : 3, forDialogReference: reference)
    }

    func showProgress(
        withTitle title: String,
        message: String,
        isIndeterminate: Bool,
        position: Float,
        cancel cancelString: String?,
        withReference reference: NSValue
    ) {
        // No custom progress sheet; playback status is shown by SwiftUI.
    }

    func updateProgress(withReference reference: NSValue, message: String?, position: Float) {
        // Intentionally empty.
    }

    func cancelDialog(withReference reference: NSValue) {
        // Intentionally empty.
    }
}

enum H2DAccessCodeStore {
    private static let service = "vn.rockettracker.RedCameraTest.h2d"
    private static let account = "lan-access-code"

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    static func save(_ value: String) {
        let trimmed = value
            .filter { $0.isNumber || ($0.isASCII && $0.isLetter) }
            .lowercased()
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(identity as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

enum H2DWiFiPasswordStore {
    private static let service = "vn.rockettracker.RedCameraTest.h2d"
    private static let account = "wifi-password"

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    static func save(_ value: String) {
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(identity as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

final class H2DPrinterCameraPlayer: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    @Published private(set) var statusText = "Đang mở camera H2D..."
    @Published private(set) var isPlaying = false
    @Published private(set) var hasError = false

    let mediaPlayer = VLCMediaPlayer()
    private weak var drawableView: UIView?
    private var printerIP = ""
    private var accessCode = ""
    private var preflightConnection: NWConnection?
    private var preflightTimeoutWorkItem: DispatchWorkItem?
    private var retryWorkItem: DispatchWorkItem?
    private var retryCount = 0
    private var activeAttemptID = UUID()
    private var isStopping = false
    private let dialogRenderer = H2DVLCCertificateDialogRenderer()
    private var dialogProvider: VLCDialogProvider?

    override init() {
        super.init()
        mediaPlayer.delegate = self
        // Keep the provider on the same VLCLibrary instance as the player.
        // The provider's renderer property is weak, so both objects are held
        // strongly by this player for the entire camera session.
        let provider = VLCDialogProvider(library: mediaPlayer.libraryInstance, customUI: true)
        dialogProvider = provider
        dialogRenderer.provider = provider
        provider?.customRenderer = dialogRenderer
    }

    func attach(to view: UIView, printerIP: String, accessCode: String) {
        drawableView = view
        self.printerIP = printerIP.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessCode = accessCode
            .filter { $0.isNumber || ($0.isASCII && $0.isLetter) }
            .lowercased()
        dialogRenderer.password = self.accessCode
        start()
    }

    func start() {
        guard drawableView != nil else { return }
        guard let streamURL = makeStreamURL() else {
            statusText = "Thiếu IP hoặc Access Code của H2D"
            hasError = true
            return
        }
        _ = streamURL // Validate the URL before starting the LAN preflight.

        isStopping = false
        retryCount = 0
        retryWorkItem?.cancel()
        startAttempt()
    }

    private func startAttempt() {
        guard drawableView != nil else { return }
        guard makeStreamURL() != nil else {
            statusText = "Thiếu IP hoặc Access Code của H2D"
            hasError = true
            return
        }

        let attemptID = UUID()
        activeAttemptID = attemptID
        preflightConnection?.cancel()
        preflightTimeoutWorkItem?.cancel()

        statusText = "Đang kiểm tra camera H2D (cổng 322)…"
        hasError = false
        isPlaying = false

        guard let port = NWEndpoint.Port(rawValue: 322) else {
            handlePreflightFailure(attemptID: attemptID)
            return
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(printerIP),
            port: port,
            using: .tcp
        )
        preflightConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self,
                      self.activeAttemptID == attemptID,
                      self.preflightConnection === connection else { return }
                switch state {
                case .ready:
                    self.preflightTimeoutWorkItem?.cancel()
                    self.preflightConnection = nil
                    connection.cancel()
                    self.openVLC()
                case .waiting:
                    self.statusText = "Đang chờ mạng LAN của H2D…"
                case .failed:
                    self.preflightTimeoutWorkItem?.cancel()
                    self.preflightConnection = nil
                    self.handlePreflightFailure(attemptID: attemptID)
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)

        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.activeAttemptID == attemptID,
                  self.preflightConnection === connection else { return }
            connection.cancel()
            self.preflightConnection = nil
            self.handlePreflightFailure(attemptID: attemptID)
        }
        preflightTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
    }

    private func openVLC() {
        guard let drawableView,
              let streamURL = makeStreamURL() else { return }

        mediaPlayer.stop()
        mediaPlayer.drawable = drawableView
        guard let media = VLCMedia(url: streamURL) else {
            statusText = "Không tạo được đường dẫn camera H2D"
            hasError = true
            return
        }
        // H2D exposes an authenticated RTSPS feed on TCP 322. Keep the
        // credentials in VLC options as well as the URL: this avoids failures
        // when a LAN access code contains characters that URLComponents must
        // percent-escape.
        media.addOption(":rtsp-tcp")
        media.addOption(":rtsp-user=bblp")
        media.addOption(":rtsp-pwd=\(accessCode)")
        media.addOption(":network-caching=500")
        media.addOption(":live-caching=300")
        media.addOption(":avcodec-hw=none")
        media.addOption(":rtsp-frame-buffer-size=500000")
        media.addOption(":no-audio")
        media.addOption(":clock-jitter=0")
        mediaPlayer.media = media
        statusText = "Đang kết nối camera H2D trong mạng LAN..."
        hasError = false
        isPlaying = false
        isStopping = false
        mediaPlayer.play()
    }

    func stop() {
        isStopping = true
        activeAttemptID = UUID()
        retryWorkItem?.cancel()
        preflightTimeoutWorkItem?.cancel()
        preflightConnection?.cancel()
        retryWorkItem = nil
        preflightTimeoutWorkItem = nil
        preflightConnection = nil
        mediaPlayer.stop()
        mediaPlayer.drawable = nil
        isPlaying = false
    }

    private func handlePreflightFailure(attemptID: UUID) {
        guard activeAttemptID == attemptID, !isStopping else { return }
        scheduleRetry("Không thấy cổng 322 • kiểm tra cùng Wi-Fi và LAN Only Liveview")
    }

    private func scheduleRetry(_ message: String) {
        guard !isStopping else { return }
        guard retryCount < 2 else {
            statusText = message
            hasError = true
            isPlaying = false
            return
        }
        retryCount += 1
        statusText = "\(message) • tự thử lại \(retryCount)/2"
        hasError = false
        retryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.startAttempt()
        }
        retryWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Double(retryCount),
            execute: item
        )
    }

    func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch newState {
            case .opening:
                self.statusText = "Đang đăng nhập camera H2D..."
                self.hasError = false
            case .playing:
                self.statusText = "Camera H2D • trực tiếp trong mạng LAN"
                self.isPlaying = true
                self.hasError = false
            case .paused:
                self.statusText = "Camera H2D đang tạm dừng"
                self.isPlaying = false
            case .error:
                guard !self.isStopping else { return }
                self.isPlaying = false
                self.scheduleRetry("Không xác thực được camera • kiểm tra Access Code LAN (username bblp)")
            case .stopped, .stopping:
                self.isPlaying = false
            default:
                break
            }
        }
    }

    private func makeStreamURL() -> URL? {
        guard !printerIP.isEmpty, !accessCode.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "rtsps"
        components.user = "bblp"
        components.password = accessCode
        components.host = printerIP
        components.port = 322
        components.path = "/streaming/live/1"
        return components.url
    }
}

private struct H2DPrinterVideoSurface: UIViewRepresentable {
    @ObservedObject var player: H2DPrinterCameraPlayer
    let printerIP: String
    let accessCode: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        DispatchQueue.main.async {
            player.attach(to: view, printerIP: printerIP, accessCode: accessCode)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        player.mediaPlayer.drawable = uiView
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        uiView.backgroundColor = .black
    }
}

struct H2DPrinterCameraView: View {
    let printerIP: String
    let accessCode: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = H2DPrinterCameraPlayer()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            H2DPrinterVideoSurface(
                player: player,
                printerIP: printerIP,
                accessCode: accessCode
            )
            .ignoresSafeArea()

            VStack {
                HStack(spacing: 10) {
                    Circle()
                        .fill(player.hasError ? Color.red : player.isPlaying ? .green : .yellow)
                        .frame(width: 9, height: 9)
                    Text(player.statusText)
                        .font(.custom("Arial", size: 12).weight(.bold))
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(.black.opacity(0.78), in: Capsule())

                Spacer()

                HStack(spacing: 14) {
                    Button {
                        player.start()
                    } label: {
                        Label("Kết nối lại", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        dismiss()
                    } label: {
                        Label("Đóng camera", systemImage: "xmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.gray.opacity(0.75))
                }
            }
            .padding(16)
        }
        .preferredColorScheme(.dark)
        .onDisappear { player.stop() }
    }
}
