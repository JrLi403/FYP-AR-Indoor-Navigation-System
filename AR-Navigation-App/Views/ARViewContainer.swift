import ActivityKit
import SwiftUI
import ARKit
import SceneKit
import simd
import Combine
import AVFoundation
import UniformTypeIdentifiers
import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore
// MARK: - AR SwiftUI 包装视图

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var session: ARNavSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.delegate = session
        view.session.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true
        view.scene = SCNScene()

        session.sceneView = view

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        view.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, ARSessionDelegate {}
}
