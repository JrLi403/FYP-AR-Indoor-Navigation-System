import ARKit
import SceneKit
import SwiftUI
import Combine
import FirebaseAuth
import FirebaseFirestore
import CoreMotion
import AVFoundation
import UIKit
import UniformTypeIdentifiers
// MARK: - 一、记录路线 部分
// =======================================================

struct StartInfo: Codable, Equatable {
    let building: String?
    let location: String
    let floor: Int?
}

struct DestinationInfo: Equatable {
    var poiText: String = ""     // 终点房间名，如 Room601
    var floorText: String = ""   // 终点楼层（字符串），留空则用起点楼层

    var prof: String = ""
    var dept: String = ""

    var hasAny: Bool { !poiText.isEmpty }
    var displayName: String { poiText.isEmpty ? "destination" : poiText }
    var floorInt: Int? { Int(floorText.trimmingCharacters(in: .whitespaces)) }
}

struct StepInstant: Codable { let t: Double; let yawRad: Double }

struct StepRecord: Codable {
    let i: Int
    let deltaYawDeg: Double
    let strideEstM: Double
    let events: [Event]
}

struct Event: Codable {
    enum EventType: String, Codable { case TURN, STAIR_UP, STAIR_DOWN, ELEVATOR, ESCALATOR }
    let type: EventType
    let angleDeg: Double?
    let flights: Int?
}

struct EventRef: Codable { let type: Event.EventType; let atStep: Int; let angleDeg: Double? }

struct SimpleExport: Codable {
    let keyEvents: [EventRef]
    let steps: [StepRecord]
    let totalSteps: Int

    enum CodingKeys: String, CodingKey {
        case keyEvents
        case steps
        case totalSteps = "Total_steps"
    }
}

func cleanFileToken(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "_")
        .replacingOccurrences(of: "/", with: "_")
}

// 解析二维码：{"building": "...", "location": "...", "floor": 1}
func parseStartInfo(from raw: String) -> StartInfo? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    // JSON 形式
    if let d = s.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        let building = obj["building"] as? String
        let location = (obj["location"] as? String) ?? (obj["place"] as? String)
        let floor = (obj["floor"] as? Int) ??
                    (obj["floor"] as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if let location {
            return StartInfo(building: building, location: location, floor: floor)
        }
    }

    // 类 JSON：location: front desk; floor: 1; building: xxx
    let cleaned = s
        .replacingOccurrences(of: "{", with: "")
        .replacingOccurrences(of: "}", with: "")
        .replacingOccurrences(of: "\n", with: " ")

    var dict: [String: String] = [:]
    cleaned.split(separator: ";").forEach { pair in
        let kv = pair
            .split(separator: ":", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if kv.count == 2 {
            dict[kv[0].lowercased()] = kv[1]
        }
    }

    if let loc = dict["location"], !loc.isEmpty {
        let building = dict["building"]
        let floor = dict["floor"].flatMap { Int($0) }
        return StartInfo(building: building, location: loc, floor: floor)
    }
    return nil
}

@inline(__always)
func wrapDeg(_ a: Double) -> Double {
    var x = a
    while x > 180 { x -= 360 }
    while x < -180 { x += 360 }
    return x
}

@MainActor
final class MotionRecorder: NSObject, ObservableObject, ARSessionDelegate {

    // UI（保持字段名不变）
    @Published var isRecording = false
    @Published var stepCount = 0
    @Published var yawDegDisp: Double = 0
    @Published var usePedometer = false
    @Published var hiThreshG: Double = 0.18
    @Published var loThreshG: Double = 0.10

    // ✅ Turn detection (方案B：从 recording 阶段写入 Key_events)
    @Published var enableTurnDetection = true
    @Published var turnThresholdDeg: Double = 35.0   // 30~45 之间调
    @Published var turnNoiseFloorDeg: Double = 8.0   // 小于这个认为是直行噪声
    @Published var minStepsBetweenTurns: Int = 2      // 防止连续误触发

    // AR
    let session = ARSession()

    // ✅ 1.0 秒一个“伪 step”
    private let intervalSec: Double = 0.1

    // 时间基准
    private var startTime: TimeInterval? = nil

    // frame-to-frame
    private var lastFramePos: simd_float3? = nil
    private var lastFrameTs: TimeInterval? = nil

    // interval 累计
    private var intervalStartTs: TimeInterval? = nil
    private var intervalStartYawDeg: Double = 0
    private var accDist: Double = 0

    // 输出
    private var steps: [StepRecord] = []
    private var keyEvents: [EventRef] = []

    // ✅ turn accumulation
    private var turningAccumDeg: Double = 0
    private var turningSign: Double = 0
    private var lastTurnAtStep: Int = -999

    // Firestore
    private let db = Firestore.firestore()

    override init() {
        super.init()
        session.delegate = self
    }

    func start() {
        guard !isRecording else { return }
        resetState()
        isRecording = true
        UIApplication.shared.isIdleTimerDisabled = true

        let config = ARWorldTrackingConfiguration()
        config.isAutoFocusEnabled = true
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        session.pause()
        UIApplication.shared.isIdleTimerDisabled = false

        // ✅ flush any pending accumulated turn when stopping
        flushPendingTurnIfNeeded(atStep: steps.count - 1)
    }

    private func resetState() {
        startTime = nil
        lastFramePos = nil
        lastFrameTs = nil

        intervalStartTs = nil
        intervalStartYawDeg = 0
        accDist = 0

        steps.removeAll()
        keyEvents.removeAll()

        turningAccumDeg = 0
        turningSign = 0
        lastTurnAtStep = -999

        stepCount = 0
        yawDegDisp = 0
    }

    func zeroYawBaseline() {
        // 你现在是 AR 世界 yaw，不建议硬归零世界参考
        // 但你 UI 想显示 0 就显示 0
        yawDegDisp = 0
        intervalStartYawDeg = yawDegDisp
    }

    private func currentYawDeg(from frame: ARFrame) -> Double {
        Double(frame.camera.eulerAngles.y) * 180.0 / Double.pi
    }

    // ✅ Manual markers (optional): call during/after recording to insert events
    func markEvent(_ type: Event.EventType, angleDeg: Double? = nil, flights: Int? = nil) {
        // attach to the "next" step boundary: use max(0, steps.count-1)
        let at = max(0, steps.count - 1)
        keyEvents.append(EventRef(type: type, atStep: at, angleDeg: angleDeg))
    }

    private func flushPendingTurnIfNeeded(atStep: Int) {
        guard enableTurnDetection else {
            turningAccumDeg = 0
            turningSign = 0
            return
        }
        guard atStep >= 0 else { return }

        if abs(turningAccumDeg) >= turnThresholdDeg {
            if atStep - lastTurnAtStep >= minStepsBetweenTurns {
                keyEvents.append(EventRef(type: .TURN, atStep: atStep, angleDeg: turningAccumDeg))
                lastTurnAtStep = atStep
            }
        }
        turningAccumDeg = 0
        turningSign = 0
    }

    private func feedTurnAccumulator(dYaw: Double, atStep: Int) {
        guard enableTurnDetection else { return }

        let absDY = abs(dYaw)
        if absDY < turnNoiseFloorDeg {
            // leaving a turn segment -> flush if big enough
            flushPendingTurnIfNeeded(atStep: atStep)
            return
        }

        let sgn = (dYaw >= 0) ? 1.0 : -1.0
        if turningSign == 0 {
            turningSign = sgn
            turningAccumDeg = dYaw
            return
        }

        if sgn == turningSign {
            turningAccumDeg += dYaw
        } else {
            // direction flipped: finish previous segment, start new
            flushPendingTurnIfNeeded(atStep: atStep)
            turningSign = sgn
            turningAccumDeg = dYaw
        }

        // If already crossed threshold, you can choose to emit immediately.
        // Here we wait until segment ends (more stable), but for very sharp turns emit early:
        if abs(turningAccumDeg) >= (turnThresholdDeg + 25) {
            flushPendingTurnIfNeeded(atStep: atStep)
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRecording else { return }
        guard case .normal = frame.camera.trackingState else { return }

        let ts = frame.timestamp
        if startTime == nil { startTime = ts }
        let yawDeg = currentYawDeg(from: frame)
        yawDegDisp = yawDeg

        let t = frame.camera.transform
        let pos = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)

        // init interval
        if intervalStartTs == nil {
            intervalStartTs = ts
            intervalStartYawDeg = yawDeg
            lastFramePos = pos
            lastFrameTs = ts
            return
        }

        // 累计 interval 内位移
        if let lp = lastFramePos {
            let d = Double(simd_distance(pos, lp))
            if d.isFinite && d >= 0 { accDist += d }
        }
        lastFramePos = pos
        lastFrameTs = ts

        guard let t0 = intervalStartTs else { return }
        let dt = ts - t0

        if dt >= intervalSec {
            let dYaw = wrapDeg(yawDeg - intervalStartYawDeg)

            let rec = StepRecord(
                i: steps.count,
                deltaYawDeg: dYaw,
                strideEstM: accDist,
                events: []
            )
            steps.append(rec)
            stepCount = steps.count

            // ✅ TURN detection: feed accumulator using this interval yaw
            feedTurnAccumulator(dYaw: dYaw, atStep: steps.count - 1)

            // reset interval
            intervalStartTs = ts
            intervalStartYawDeg = yawDeg
            accDist = 0
        }
    }

    // 导出
    func makeTraceData(start: StartInfo, destination: DestinationInfo) throws -> (data: Data, filename: String) {
        // ✅ flush any pending turn before export
        flushPendingTurnIfNeeded(atStep: steps.count - 1)

        let export = SimpleExport(
            keyEvents: keyEvents,
            steps: steps,
            totalSteps: steps.count
        )

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(export)

        let floorNum = start.floor ?? destination.floorInt ?? 0
        let floorTag = "F\(floorNum)"
        let building = (start.building ?? "unknown-building")
        let fname = "\(cleanFileToken(building))_\(floorTag)_\(cleanFileToken(start.location))_\(floorTag)_\(cleanFileToken(destination.displayName)).json"

        return (data, fname)
    }

    func uploadRouteToFirestore(start: StartInfo,
                                destination: DestinationInfo,
                                completion: ((Error?) -> Void)? = nil) {

        guard let buildingName = start.building, !buildingName.isEmpty else {
            completion?(NSError(domain: "MotionRecorder",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "missing building name"]))
            return
        }

        let floorNum = start.floor ?? destination.floorInt ?? 0
        let floorTag = "F\(floorNum)"
        let startLoc = start.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let routeId = "\(floorTag)-\(startLoc)-to-\(floorTag)-\(destination.displayName)"

        do {
            // ✅ flush any pending turn before upload
            flushPendingTurnIfNeeded(atStep: steps.count - 1)

            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]

            let keyEventsData = try enc.encode(keyEvents)
            let stepsData = try enc.encode(steps)

            let keyEventsStr = String(data: keyEventsData, encoding: .utf8) ?? "[]"
            let stepsStr = String(data: stepsData, encoding: .utf8) ?? "[]"

            let docData: [String: Any] = [
                "Key_events": keyEventsStr,
                "Steps": stepsStr,
                "Total_steps": steps.count
            ]

            db.collection("building")
                .document(buildingName)
                .collection("Routes")
                .document(routeId)
                .setData(docData) { error in
                    completion?(error)
                }
        } catch {
            completion?(error)
        }
    }

    deinit { session.pause() }
}

struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = d
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// QR 扫描
struct QRScannerView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onFound: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onFound = { text in
            onFound(text)
            isPresented = false
        }
        return vc
    }
    func updateUIViewController(_ uiViewController: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onFound: ((String) -> Void)?

        private let session = AVCaptureSession()
        private let preview = AVCaptureVideoPreviewLayer()

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            preview.session = session
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)

            let box = CAShapeLayer()
            box.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
            box.lineWidth = 2
            box.fillColor = UIColor.clear.cgColor
            box.path = UIBezierPath(roundedRect: view.bounds.insetBy(dx: 40, dy: 140), cornerRadius: 12).cgPath
            view.layer.addSublayer(box)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview.frame = view.bounds
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if !session.isRunning { session.startRunning() }
        }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  obj.type == .qr,
                  let value = obj.stringValue else { return }
            session.stopRunning()
            onFound?(value)
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.session = session
        v.scene = SCNScene()
        v.automaticallyUpdatesLighting = true
        v.autoenablesDefaultLighting = true
        return v
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// AirDrop
struct AirDropShareView: UIViewControllerRepresentable {
    let fileURL: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        vc.excludedActivityTypes = [
            .postToFacebook, .postToTwitter, .postToWeibo, .message, .mail,
            .print, .copyToPasteboard, .assignToContact, .saveToCameraRoll,
            .addToReadingList, .postToFlickr, .postToVimeo, .postToTencentWeibo,
            .openInIBooks, .markupAsPDF
        ]
        vc.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: fileURL)
        }
        return vc
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// 记录路线 UI
struct RouteRecorderView: View {
    @StateObject var rec = MotionRecorder()

    enum Stage { case scan, dest, ready, recording }
    @State private var stage: Stage = .scan

    @State private var showScanner = false
    @State private var startInfo: StartInfo?
    @State private var dest = DestinationInfo()

    @State private var exportDoc: JSONDocument?
    @State private var exportFilename: String = "trace.json"
    @State private var showExporter = false

    @State private var airDropURL: URL?
    @State private var showAirDrop = false

    @State private var alertMsg: String?

    var body: some View {
        NavigationView {
            Group {
                switch stage {

                case .scan:
                    VStack(spacing: 18) {
                        Text("Scan the start QR code").font(.title2).bold()
                        Image(systemName: "qrcode.viewfinder").font(.system(size: 80))
                        Text("QR code should include building / location / floor").foregroundColor(.secondary)
                        Button("Start scanning") { showScanner = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .sheet(isPresented: $showScanner) {
                        QRScannerView(isPresented: $showScanner) { code in
                            if let info = parseStartInfo(from: code) {
                                startInfo = info
                                if let f = info.floor { dest.floorText = "\(f)" }
                                dest.poiText = ""
                                stage = .dest
                            } else {
                                alertMsg = "Unable to parse QR code content"
                            }
                        }.ignoresSafeArea()
                    }
                    .alert(alertMsg ?? "", isPresented: Binding(get: { alertMsg != nil }, set: { _ in alertMsg = nil })) {
                        Button("OK", role: .cancel) {}
                    }

                case .dest:
                    VStack(spacing: 16) {
                        Text("Start: \(startInfo?.location ?? "-") · Floor: \(startInfo?.floor ?? 0) · Building: \(startInfo?.building ?? "-")")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        TextField("Destination room name (e.g. Room601)", text: $dest.poiText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)

                        Spacer()

                        Button("Next") { stage = .ready }
                            .buttonStyle(.borderedProminent)
                            .disabled(dest.poiText.trimmingCharacters(in: .whitespaces).isEmpty)

                        Button("Scan again") {
                            stage = .scan
                            showScanner = true
                        }
                        .buttonStyle(.bordered)

                        Spacer()
                    }
                    .padding()
                    .navigationTitle("Enter destination")
                    .alert(alertMsg ?? "", isPresented: Binding(get: { alertMsg != nil }, set: { _ in alertMsg = nil })) {
                        Button("OK", role: .cancel) {}
                    }

                case .ready:
                    VStack(spacing: 16) {
                        Text("Face the QR code before starting").font(.title3).bold()
                        Text("Point the phone toward the QR code you just scanned and hold it naturally.").foregroundColor(.secondary)

                        DisclosureGroup("Advanced Settings (TURN detection / thresholds)") {
                            Toggle("Enable auto TURN detection", isOn: $rec.enableTurnDetection).tint(.blue)
                            VStack(alignment: .leading) {
                                HStack { Text("Turn threshold \(Int(rec.turnThresholdDeg))°"); Slider(value: $rec.turnThresholdDeg, in: 20...80, step: 1) }
                                HStack { Text("Noise floor \(Int(rec.turnNoiseFloorDeg))°"); Slider(value: $rec.turnNoiseFloorDeg, in: 2...20, step: 1) }
                                HStack { Text("Min steps gap \(rec.minStepsBetweenTurns)"); Stepper("", value: $rec.minStepsBetweenTurns, in: 0...8) }
                                Text("Note: lower thresholds are more sensitive; a higher noise floor is more stable; gap helps prevent repeated false detections.").font(.footnote).foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 8)

                        DisclosureGroup("Advanced Settings (local step thresholds / system pedometer)") {
                            Toggle("Use system pedometer (CMPedometer)", isOn: $rec.usePedometer).tint(.blue)
                            VStack(alignment: .leading) {
                                HStack { Text("High threshold \(String(format: "%.2f", rec.hiThreshG))"); Slider(value: $rec.hiThreshG, in: 0.12...0.30, step: 0.01) }
                                HStack { Text("Low threshold \(String(format: "%.2f", rec.loThreshG))"); Slider(value: $rec.loThreshG, in: 0.06...0.20, step: 0.01) }
                                Text("Note: applies when the system pedometer is disabled; if step count is too low, lower the thresholds; if false triggers are frequent, raise them.").font(.footnote).foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 8)

                        Button("Start recording") {
                            rec.zeroYawBaseline()
                            rec.start()
                            stage = .recording
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Back") { stage = .dest }.buttonStyle(.bordered)
                        Spacer()
                    }
                    .padding()
                    .navigationTitle("Ready")

                case .recording:
                    VStack(spacing: 12) {

                        ARViewContainer(session: rec.session)
                            .frame(height: 280)
                            .cornerRadius(12)

                        Text("Recording…").font(.headline)
                        HStack { Text("Step count:").bold(); Text("\(rec.stepCount)") }
                        HStack { Text("Relative heading (°):").bold(); Text(String(format: "%.1f", rec.yawDegDisp)) }

                        // ✅ Manual key event buttons (tiny, optional)
                        HStack(spacing: 10) {
                            Button("Mark Left") { rec.markEvent(.TURN, angleDeg: 90) }.buttonStyle(.bordered)
                            Button("Mark Right") { rec.markEvent(.TURN, angleDeg: -90) }.buttonStyle(.bordered)
                            Button("Stair Up") { rec.markEvent(.STAIR_UP) }.buttonStyle(.bordered)
                            Button("Stair Down") { rec.markEvent(.STAIR_DOWN) }.buttonStyle(.bordered)
                            Button("Elevator") { rec.markEvent(.ELEVATOR) }.buttonStyle(.bordered)
                        }
                        .font(.caption)

                        HStack(spacing: 10) {
                            Button("Stop") { rec.stop() }
                                .buttonStyle(.borderedProminent)

                            Button("Export JSON") {
                                guard let s = startInfo else { return }
                                do {
                                    let out = try rec.makeTraceData(start: s, destination: dest)
                                    exportDoc = JSONDocument(data: out.data)
                                    exportFilename = out.filename
                                    showExporter = true
                                } catch {
                                    alertMsg = "Export failed: \(error.localizedDescription)"
                                }
                            }
                            .disabled(rec.isRecording || rec.stepCount == 0)

                            Button("Upload to database") {
                                guard let s = startInfo, dest.hasAny else {
                                    alertMsg = "Missing start or destination information"
                                    return
                                }
                                rec.uploadRouteToFirestore(start: s, destination: dest) { error in
                                    if let error = error {
                                        alertMsg = "Upload failed: \(error.localizedDescription)"
                                    } else {
                                        alertMsg = "Upload successful"
                                    }
                                }
                            }
                            .disabled(rec.isRecording || rec.stepCount == 0)

                            Button("AirDrop") {
                                guard let s = startInfo else { return }
                                do {
                                    let out = try rec.makeTraceData(start: s, destination: dest)
                                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(out.filename)
                                    try out.data.write(to: url, options: .atomic)
                                    airDropURL = url
                                    showAirDrop = true
                                } catch {
                                    alertMsg = "Failed to generate AirDrop file: \(error.localizedDescription)"
                                }
                            }
                            .disabled(rec.isRecording || rec.stepCount == 0)
                        }

                        Button("Start over") {
                            rec.stop()
                            rec.zeroYawBaseline()
                            rec.start()
                        }
                        .buttonStyle(.bordered)

                        Spacer()
                    }
                    .padding()
                    .navigationTitle("Recording")
                    .fileExporter(isPresented: $showExporter,
                                  document: exportDoc,
                                  contentType: .json,
                                  defaultFilename: exportFilename) { result in
                        if case .failure(let err) = result {
                            alertMsg = "Save failed: \(err.localizedDescription)"
                        }
                        exportDoc = nil
                    }
                    .sheet(isPresented: $showAirDrop, onDismiss: {
                        if let url = airDropURL { try? FileManager.default.removeItem(at: url) }
                        airDropURL = nil
                    }) {
                        if let url = airDropURL {
                            AirDropShareView(fileURL: url).ignoresSafeArea()
                        }
                    }
                    .alert(alertMsg ?? "", isPresented: Binding(get: { alertMsg != nil }, set: { _ in alertMsg = nil })) {
                        Button("OK", role: .cancel) {}
                    }
                }
            }
        }
    }
}

// =======================================================
