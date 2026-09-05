import Combine
import Security
import SwiftUI
import UIKit
import VLCKit

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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
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

final class H2DPrinterCameraPlayer: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    @Published private(set) var statusText = "Đang mở camera H2D..."
    @Published private(set) var isPlaying = false
    @Published private(set) var hasError = false

    let mediaPlayer = VLCMediaPlayer()
    private weak var drawableView: UIView?
    private var printerIP = ""
    private var accessCode = ""

    override init() {
        super.init()
        mediaPlayer.delegate = self
    }

    func attach(to view: UIView, printerIP: String, accessCode: String) {
        drawableView = view
        self.printerIP = printerIP.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessCode = accessCode.trimmingCharacters(in: .whitespacesAndNewlines)
        start()
    }

    func start() {
        guard let drawableView else { return }
        guard let streamURL = makeStreamURL() else {
            statusText = "Thiếu IP hoặc Access Code của H2D"
            hasError = true
            return
        }

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
        mediaPlayer.play()
    }

    func stop() {
        mediaPlayer.stop()
        mediaPlayer.drawable = nil
        isPlaying = false
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
                self.statusText = "Không mở được camera • kiểm tra LAN Only Liveview và Access Code"
                self.isPlaying = false
                self.hasError = true
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
