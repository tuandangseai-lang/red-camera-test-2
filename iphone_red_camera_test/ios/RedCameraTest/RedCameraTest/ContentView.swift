import Foundation
import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var ble = BLEManager()

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                statusPanel
                Spacer()
                controls
            }
            .padding()
        }
        .background(Color.black)
        .onAppear {
            ble.onArm = { [weak camera] in
                camera?.arm()
            }
            camera.onEvent = { [weak ble] message in
                ble?.sendStatus(message)
            }
            camera.start()
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(ble.connectionText, systemImage: ble.isConnected ? "antenna.radiowaves.left.and.right" : "bolt.horizontal.circle")
            Text(camera.statusText)
                .font(.headline)
            HStack {
                Text(String(format: "Đỏ: %.1f%%", camera.redPercent))
                Spacer()
                Text("Zoom: \(camera.zoomText)")
                    .monospacedDigit()
            }
            .font(.subheadline)
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if camera.isRecording {
                Button(role: .destructive) {
                    camera.stopRecording()
                } label: {
                    Label("Dừng và lưu video", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else if camera.canRetry {
                Button {
                    camera.retryTest()
                } label: {
                    Label("Thử lại", systemImage: "arrow.clockwise.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else if !camera.isArmed {
                Button {
                    camera.arm()
                } label: {
                    Label("Bật nhận diện thủ công", systemImage: "eye.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!camera.isReady)
            }

            Text("Giữ app mở và màn hình không khóa trong lúc thử")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
        }
    }
}
