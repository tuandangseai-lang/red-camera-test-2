import SwiftUI

@main
struct RedCameraTestApp: App {
    init() {
#if targetEnvironment(simulator)
        SEInterfaceCheck.prepareDefaults()
#endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
