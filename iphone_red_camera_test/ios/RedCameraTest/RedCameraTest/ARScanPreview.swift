import ARKit
import SceneKit
import SwiftUI

struct ARScanPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.backgroundColor = .black
        view.session = session
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = true
        view.rendersCameraGrain = false
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        if uiView.session !== session {
            uiView.session = session
        }
    }
}
