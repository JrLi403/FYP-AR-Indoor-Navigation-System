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
// MARK: - AR 内部状态机 / PathData / ARNavSession

enum NavState: Equatable {
    case idle
    case scanning
    case initializing
    case navigating
    case arrived
    case lostTracking
    case error(String)
}

struct PathStep {
    let distanceFromStart: Double
    let instruction: String
    let eventType: Event.EventType?
    let angleDeg: Double?

    init(
        distanceFromStart: Double,
        instruction: String,
        eventType: Event.EventType? = nil,
        angleDeg: Double? = nil
    ) {
        self.distanceFromStart = distanceFromStart
        self.instruction = instruction
        self.eventType = eventType
        self.angleDeg = angleDeg
    }
}

struct PathData {
    var points: [SIMD2<Float>]
    var steps: [PathStep]

    var totalLength: Double = 0
    var segmentLengths: [Double] = []
    var cumulativeLengths: [Double] = []

    init(points: [SIMD2<Float>], steps: [PathStep]) {
        self.points = points
        self.steps = steps
        precompute()
    }

    mutating func precompute() {
        guard points.count >= 2 else { return }
        segmentLengths = []
        cumulativeLengths = [0]
        var acc: Double = 0
        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            let d = simd_distance(a, b)
            segmentLengths.append(Double(d))
            acc += Double(d)
            cumulativeLengths.append(acc)
        }
        totalLength = acc
    }

    func distanceAlongPath(for pos: SIMD2<Float>) -> Double {
        guard points.count >= 2 else { return 0 }

        var bestDist2 = Float.greatestFiniteMagnitude
        var bestAlong: Double = 0

        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            let ab = b - a
            let ap = pos - a
            let abLen2 = simd_length_squared(ab)
            if abLen2 == 0 { continue }

            var t = simd_dot(ap, ab) / abLen2
            t = simd_clamp(t, 0, 1)
            let proj = a + t * ab
            let diff = pos - proj
            let dist2 = simd_length_squared(diff)
            if dist2 < bestDist2 {
                bestDist2 = dist2
                let base = cumulativeLengths[i]
                let segLen = segmentLengths[i]
                bestAlong = base + Double(t) * segLen
            }
        }
        return bestAlong
    }

    func positionAndDirection(at distance: Double) -> (pos: SIMD2<Float>, dir: SIMD2<Float>) {
        guard points.count >= 2 else {
            return (SIMD2<Float>(0, 0), SIMD2<Float>(0, -1))
        }

        let d = max(0, min(distance, totalLength))

        var idx = 0
        while idx < segmentLengths.count && cumulativeLengths[idx + 1] < d {
            idx += 1
        }

        let a = points[idx]
        let b = points[idx + 1]
        let segLen = segmentLengths[idx]
        let base = cumulativeLengths[idx]

        let remain = d - base
        let t = segLen > 0 ? Float(remain / segLen) : 0

        let pos = simd_mix(a, b, SIMD2<Float>(repeating: t))
        let dirRaw = simd_normalize(b - a)
        return (pos, dirRaw)
    }

    func stepIndex(forDistance d: Double) -> Int {
        guard !steps.isEmpty else { return 0 }
        var idx = 0
        while idx + 1 < steps.count && d >= steps[idx + 1].distanceFromStart {
            idx += 1
        }
        return idx
    }
}

final class ARNavSession: NSObject, ObservableObject {
    @Published var navState: NavState = .idle
    @Published var currentStep: Int = 0
    @Published var hintText: String = ""
    @Published var debugText: String = ""

    @Published var remainingDistance: Double = 0
    @Published var remainingSteps: Int = 0
    @Published var remainingTimeSec: Int = 0

    // ✅ Simple mode overlay: arrow rotation (radians), plus a short text
    @Published var simpleArrowAngleRad: Double = 0
    @Published var simpleArrowLabel: String = "Forward"

    // ✅ Arrow mode set by UI
    @Published var arrowMode: ArrowMode = .ar

    weak var sceneView: ARSCNView?
    var pathData: PathData?

    let pathRootNode = SCNNode()
    let destinationNode = SCNNode()

    private var chevronNodes: [SCNNode] = []
    private let chevronCount: Int = 3
    private let chevronSpacing: Double = 1.4
    private let chevronBaseOffset: Double = 1.8

    // ✅ Keep a handle of the path mesh node so we can hide it in Simple mode
    private var pathMeshNode: SCNNode?

    var worldToPathTransform = matrix_identity_float4x4
    private var originIsSet: Bool = false
    private var filteredDistance: Double = 0
    private var maxDistanceReached: Double = 0
    private var lastUpdateTime: TimeInterval = 0
    private let minUpdateInterval: TimeInterval = 0.1

    func resetOrigin() {
        originIsSet = false
        worldToPathTransform = matrix_identity_float4x4
        filteredDistance = 0
        maxDistanceReached = 0
        currentStep = 0
    }

    func setArrowMode(_ mode: ArrowMode) {
        arrowMode = mode
        applyArrowVisibility()
    }

    private func applyArrowVisibility() {
        let show3D = (arrowMode == .ar)
        pathMeshNode?.isHidden = !show3D
        for n in chevronNodes { n.isHidden = !show3D }
    }

    func setOriginUsingCurrentCamera() {
        guard let sceneView = sceneView,
              let frame = sceneView.session.currentFrame else {
            navState = .error("Unable to get camera position")
            return
        }

        if pathRootNode.parent == nil {
            sceneView.scene.rootNode.addChildNode(pathRootNode)
        }

        let cam = frame.camera.transform
        var t = horizontalizedTransform(from: cam)
        t.columns.3.y -= 1.2
        pathRootNode.simdTransform = t
        worldToPathTransform = pathRootNode.simdTransform.inverse
        originIsSet = true

        navState = .idle
        hintText = "Start point and heading calibrated, route navigation can be loaded"
    }

    func startNavigation(with pathData: PathData) {
        guard originIsSet else {
            navState = .error("Please align the start point first")
            return
        }

        self.pathData = pathData
        filteredDistance = 0
        maxDistanceReached = 0
        currentStep = 0

        remainingDistance = pathData.totalLength
        remainingSteps = 0
        remainingTimeSec = 0

        navState = .initializing
        hintText = "Initializing path…"

        setupSceneIfNeeded(alignOrigin: false)
        buildPathNodes()
        setupChevronNodesIfNeeded()
        applyArrowVisibility()

        navState = .navigating
        hintText = "Follow the arrow direction"
    }

    func restartNavigationKeepingOrigin(with pathData: PathData) {
        guard originIsSet else {
            navState = .error("Please align the start point first (Scan)")
            return
        }

        self.pathData = pathData
        filteredDistance = 0
        maxDistanceReached = 0
        currentStep = 0

        remainingDistance = pathData.totalLength
        remainingSteps = 0
        remainingTimeSec = 0

        setupSceneIfNeeded(alignOrigin: false)
        buildPathNodes()
        setupChevronNodesIfNeeded()
        applyArrowVisibility()

        navState = .navigating
        hintText = "Follow the arrow direction"
    }

    private func setupSceneIfNeeded(alignOrigin: Bool) {
        guard let sceneView = sceneView else { return }

        if pathRootNode.parent == nil {
            sceneView.scene.rootNode.addChildNode(pathRootNode)
        }

        if alignOrigin, !originIsSet, let frame = sceneView.session.currentFrame {
            let cam = frame.camera.transform
            var t = horizontalizedTransform(from: cam)
            t.columns.3.y -= 1.2
            pathRootNode.simdTransform = t
            worldToPathTransform = pathRootNode.simdTransform.inverse
            originIsSet = true
        }

        if destinationNode.parent == nil {
            let geo = SCNSphere(radius: 0.18)
            geo.firstMaterial?.diffuse.contents = UIColor.systemRed
            geo.firstMaterial?.emission.contents = UIColor.systemRed
            destinationNode.geometry = geo
            pathRootNode.addChildNode(destinationNode)
        }
    }

    private func buildPathNodes() {
        guard let path = pathData else { return }

        pathRootNode.childNodes
            .filter { !chevronNodes.contains($0) && $0 !== destinationNode }
            .forEach { $0.removeFromParentNode() }

        pathMeshNode = nil
        guard path.points.count >= 2 else { return }

        let width: Float = 0.30
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []

        for i in 0..<path.points.count {
            let p = path.points[i]

            let prev = i == 0 ? path.points[i] : path.points[i - 1]
            let next = i == path.points.count - 1 ? path.points[i] : path.points[i + 1]

            var dir = next - prev
            if simd_length_squared(dir) < 1e-6 {
                dir = SIMD2<Float>(0, -1)
            } else {
                dir = simd_normalize(dir)
            }

            let perp = SIMD2<Float>(-dir.y, dir.x)
            let left = p + perp * (width / 2)
            let right = p - perp * (width / 2)

            vertices.append(SCNVector3(left.x, 0, left.y))
            vertices.append(SCNVector3(right.x, 0, right.y))

            let n = SCNVector3(0, 1, 0)
            normals.append(n); normals.append(n)
        }

        let indices: [Int32] = (0..<vertices.count).map { Int32($0) }
        let vertexSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)

        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangleStrip,
            primitiveCount: vertices.count - 2,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let geom = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.6)
        mat.isDoubleSided = true
        mat.lightingModel = .physicallyBased
        geom.materials = [mat]

        let node = SCNNode(geometry: geom)
        node.position.y = 0.0
        pathRootNode.addChildNode(node)
        pathMeshNode = node

        if let last = path.points.last {
            destinationNode.position = SCNVector3(last.x, 0, last.y)
        }
    }

    private func setupChevronNodesIfNeeded() {
        guard chevronNodes.isEmpty else { return }
        for i in 0..<chevronCount {
            let node = makeChevronNode(index: i)
            chevronNodes.append(node)
            pathRootNode.addChildNode(node)
        }
    }

    private func makeChevronNode(index: Int) -> SCNNode {
        let img = UIImage(named: "chevron_arrow")
        let plane = SCNPlane(width: 0.8, height: 0.35)
        plane.firstMaterial?.diffuse.contents = img ?? UIColor.systemBlue
        plane.firstMaterial?.isDoubleSided = true
        plane.firstMaterial?.lightingModel = .constant
        plane.firstMaterial?.writesToDepthBuffer = true
        plane.firstMaterial?.readsFromDepthBuffer = true
        plane.firstMaterial?.transparency = 0.95

        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -Float.pi / 2
        node.position.y = 0.01

        let t = 1.0 - Float(index) / Float(max(1, chevronCount - 1))
        let baseScale: Float = 0.9
        let extraScale: Float = 0.4
        let scale = baseScale + extraScale * t
        node.scale = SCNVector3(scale, scale, scale)
        return node
    }

    private func horizontalizedTransform(from cam: simd_float4x4) -> simd_float4x4 {
        var t = cam
        t.columns.3.y = 0
        let forward = SIMD3<Float>(-cam.columns.2.x, 0, -cam.columns.2.z)
        let f = simd_normalize(forward)
        let right = SIMD3<Float>(f.z, 0, -f.x)
        let up = SIMD3<Float>(0, 1, 0)

        t.columns.0 = SIMD4<Float>(right, 0)
        t.columns.1 = SIMD4<Float>(up, 0)
        t.columns.2 = SIMD4<Float>(-f, 0)
        return t
    }

    
    /// 在“只关注转弯”的导向里，把箭头最多指到「下一个 TURN 事件」的位置；
    /// 没有 TURN 则指向终点。
    private func capDistanceToNextTurn(from currentAlong: Double) -> Double {
        guard let path = pathData else { return currentAlong }
        if path.steps.isEmpty { return path.totalLength }
        let curIdx = max(0, min(currentStep, path.steps.count - 1))
        if curIdx + 1 < path.steps.count {
            for i in (curIdx + 1)..<path.steps.count {
                if path.steps[i].eventType == .TURN {
                    return max(currentAlong, path.steps[i].distanceFromStart)
                }
            }
        }
        return path.totalLength
    }

private func updateChevronNodes() {
        guard let path = pathData, !chevronNodes.isEmpty else { return }
        let capD = capDistanceToNextTurn(from: filteredDistance)
        for (i, node) in chevronNodes.enumerated() {
            var d = filteredDistance + chevronBaseOffset + chevronSpacing * Double(i)
            d = min(d, capD)

            let (pos, dir) = path.positionAndDirection(at: d)
            node.position = SCNVector3(pos.x, 0.01, pos.y)

            let heading = atan2f(dir.x, -dir.y)
            let yaw = Float.pi / 2 - heading
            node.eulerAngles.y = yaw

            let distFactor = 1.0 - Float(i) / Float(max(1, chevronCount - 1))
            node.opacity = CGFloat(0.7 + 0.3 * distFactor)
        }
    }

    private func updateSimpleArrow() {
        guard arrowMode == .simple,
              let sceneView = sceneView,
              let frame = sceneView.session.currentFrame,
              let path = pathData else { return }

        let cameraInPath = worldToPathTransform * frame.camera.transform

        let fwd3 = SIMD3<Float>(-cameraInPath.columns.2.x, 0, -cameraInPath.columns.2.z)
        var camFwd2 = SIMD2<Float>(fwd3.x, fwd3.z)
        if simd_length_squared(camFwd2) < 1e-6 { camFwd2 = SIMD2<Float>(0, -1) }
        else { camFwd2 = simd_normalize(camFwd2) }

        let capD = capDistanceToNextTurn(from: filteredDistance)
        let lookAhead = min(capD, filteredDistance + 2.0)
        let (_, pathDir) = path.positionAndDirection(at: lookAhead)

        let dotv = simd_dot(camFwd2, pathDir)
        let cross = camFwd2.x * pathDir.y - camFwd2.y * pathDir.x
        let ang = atan2(Double(cross), Double(dotv))

        simpleArrowAngleRad = ang

        let deg = ang * 180.0 / .pi
        if abs(deg) < 12 { simpleArrowLabel = "Forward" }
        else if deg > 0 { simpleArrowLabel = (deg > 65 ? "Turn Left" : "Left") }
        else { simpleArrowLabel = (deg < -65 ? "Turn Right" : "Right") }
    }
}

// MARK: - Manual alignment controls

extension ARNavSession {

    func nudgeLeft(cm: Float = 5) {
        let meters = cm / 100.0
        pathRootNode.position.x -= meters
        worldToPathTransform = pathRootNode.simdTransform.inverse
    }

    func nudgeRight(cm: Float = 5) {
        let meters = cm / 100.0
        pathRootNode.position.x += meters
        worldToPathTransform = pathRootNode.simdTransform.inverse
    }

    func nudgeForward(cm: Float = 5) {
        let meters = cm / 100.0
        pathRootNode.position.z -= meters
        worldToPathTransform = pathRootNode.simdTransform.inverse
    }

    func nudgeBackward(cm: Float = 5) {
        let meters = cm / 100.0
        pathRootNode.position.z += meters
        worldToPathTransform = pathRootNode.simdTransform.inverse
    }

    func rotateLeft(deg: Float = 1) {
        let rad = deg * .pi / 180.0
        pathRootNode.eulerAngles.y += rad
        worldToPathTransform = pathRootNode.simdTransform.inverse
    }

    func rotateRight(deg: Float = 1) {
        let rad = deg * .pi / 180.0
        pathRootNode.eulerAngles.y -= rad
        worldToPathTransform = pathRootNode.simdTransform.inverse
    }

    func alignHereUsingCurrentCamera() {
        guard let sceneView = sceneView,
              let frame = sceneView.session.currentFrame else { return }

        let cam = frame.camera.transform
        var t = horizontalizedTransform(from: cam)
        t.columns.3.y -= 1.2

        pathRootNode.simdTransform = t
        worldToPathTransform = pathRootNode.simdTransform.inverse
    }
}


extension ARNavSession: ARSCNViewDelegate {
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard time - lastUpdateTime > minUpdateInterval else { return }
        lastUpdateTime = time
        DispatchQueue.main.async { [weak self] in self?.tick() }
    }

    private func tick() {
        switch navState {
        case .navigating:
            updateUserProgressUsingAR()
            if arrowMode == .ar { updateChevronNodes() }
            else { updateSimpleArrow() }
            checkArrival()
        default:
            break
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .notAvailable:
            navState = .lostTracking
            hintText = "Tracking unavailable, please try again later"
        case .limited:
            navState = .lostTracking
            hintText = "Tracking unstable, please move the phone slowly"
        case .normal:
            if navState == .lostTracking {
                navState = .navigating
                hintText = "Continue following the arrow"
            }
        }
    }
}

// MARK: - 进度更新 / 指令 / 到达检测

extension ARNavSession {

    func updateUserProgressUsingAR() {
        guard let sceneView = sceneView,
              let frame = sceneView.session.currentFrame,
              let path = pathData else { return }

        let cameraInPath = worldToPathTransform * frame.camera.transform
        let pos = SIMD2<Float>(cameraInPath.columns.3.x, cameraInPath.columns.3.z)
        let rawD = path.distanceAlongPath(for: pos)

        let backTolerance: Double = 0.7
        let alpha: Double = 0.2

        if rawD + backTolerance < maxDistanceReached {
            debugText = String(format: "ignore back: raw=%.2f max=%.2f", rawD, maxDistanceReached)
            return
        }

        filteredDistance = alpha * rawD + (1 - alpha) * filteredDistance
        if filteredDistance > maxDistanceReached { maxDistanceReached = filteredDistance }

        let clamped = max(0, min(filteredDistance, path.totalLength))
        let stepIdx = path.stepIndex(forDistance: clamped)

        if stepIdx != currentStep {
            currentStep = stepIdx
            updateHintForStep(stepIdx)
        }

        debugText = String(format: "raw=%.2f filtered=%.2f step=%d", rawD, filteredDistance, currentStep)
    }

    private func updateHintForStep(_ step: Int) {
        guard let path = pathData, step < path.steps.count else {
            hintText = "Follow the arrow direction"
            return
        }
        hintText = path.steps[step].instruction

        if #available(iOS 16.1, *) {
            let totalSteps = path.steps.count
            let remainingSteps = max(totalSteps - step, 0)

            let remainingMeters = Int(Double(remainingSteps) * 0.75)
            let etaSeconds = Int(Double(remainingMeters) / 1.2)

            LiveActivityManager.shared.updateInstruction(
                hintText,
                distanceText: "Approx. \(remainingMeters)m",
                etaText: "Approx. \(etaSeconds)s",
                stepText: "\(remainingSteps) steps"
            )
        }
    }

    private func checkArrival() {
        guard let path = pathData else { return }
        let remain = path.totalLength - filteredDistance
        if remain < 0.8 {
            navState = .arrived
            hintText = "Destination reached 🎉"
            if #available(iOS 16.1, *) {
                LiveActivityManager.shared.updateInstruction(hintText, distanceText: "", etaText: "", stepText: "")
                LiveActivityManager.shared.end()
            }
        }
    }
}
