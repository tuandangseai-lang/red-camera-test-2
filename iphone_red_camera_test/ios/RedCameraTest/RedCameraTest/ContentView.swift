import SwiftUI

struct ContentView: View {
    @StateObject private var bluetooth = H2DBLEManager()
    @StateObject private var timelapse = H2DTimelapseManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        H2DTimelapseView(bluetooth: bluetooth, timelapse: timelapse)
            .onAppear {
                bluetooth.resumeFromForeground()
            }
            .onChange(of: bluetooth.h2dTimelapseEvent) { _, event in
                guard let event else { return }
                timelapse.handle(event)
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    bluetooth.resumeFromForeground()
                case .inactive, .background:
                    bluetooth.suspendForBackground()
                @unknown default:
                    break
                }
            }
    }
}
