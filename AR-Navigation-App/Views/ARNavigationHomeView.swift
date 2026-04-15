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
// MARK: - 主界面

struct ARNavigationHomeView: View {
    @EnvironmentObject var authVM: AuthViewModel

    @State private var stage: NavStage = .scanStart
    @State private var showScanner = false

    @State private var startInfo: StartInfo?
    @State private var navRoute: NavRoute?
    @State private var alertMsg: String?

    @State private var destMode: DestinationMode = .room
    @State private var selectedRoom: String?
    @State private var selectedProf: String?
    @State private var selectedFloor: Int?
    @State private var accessPriority: AccessPriority = .stair

    @State private var currentRoomInfo: RoomInfo?

    @State private var demoMode: DemoMode = .overview
    @State private var arrowMode: ArrowMode = .ar

    @State private var segmentRouteChain: [FirestoreRoute] = []
    @State private var segmentNodeChain: [String] = []
    @State private var segmentIndex: Int = 0
    @State private var destKeyCandidates: [String] = []

    @State private var showNextSegmentAlert: Bool = false
    @State private var nextSegmentAlertText: String = ""
    @State private var isScanningNextSegmentQR: Bool = false
    @State private var isScanningRecalibrateQR: Bool = false

    @State private var modeToast: String? = nil

    @StateObject private var navSession = ARNavSession()
    @StateObject private var routeVM = RoutePickerViewModel()
    @StateObject private var roomsVM = RoomsViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                switch stage {
                case .scanStart: scanStartView
                case .pickRoute: pickRouteView
                case .navigating: navigatingView
                }
            }
            .navigationTitle("AR Navigation")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Log out") { authVM.signOut() }
                }
            }
            .alert(alertMsg ?? "",
                   isPresented: Binding(get: { alertMsg != nil }, set: { _ in alertMsg = nil })) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func startFloorInt() -> Int? {
        guard let f = startInfo?.floor?.trimmingCharacters(in: .whitespacesAndNewlines),
              !f.isEmpty else { return nil }
        return Int(f)
    }

    private func graphKey(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return trimmed }
        let parts = trimmed.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return trimmed }
        if let first = parts.first, first.first == "F", Int(first.dropFirst()) != nil {
            return parts.dropFirst().joined(separator: "-")
        }
        return trimmed
    }

    private func endpoints(fromRouteId id: String) -> (src: String, dst: String)? {
        let parts = id.split(separator: "-").map(String.init)
        guard let toIndex = parts.firstIndex(of: "to"), toIndex >= 2 else { return nil }

        let leftRaw = parts[1..<toIndex].joined(separator: "-")

        var rightStart = toIndex + 1
        if rightStart < parts.count,
           parts[rightStart].first == "F",
           Int(parts[rightStart].dropFirst()) != nil {
            rightStart += 1
        }
        guard rightStart < parts.count else { return nil }
        let rightRaw = parts[rightStart...].joined(separator: "-")

        let src = graphKey(from: leftRaw)
        let dst = graphKey(from: rightRaw)
        if src.isEmpty || dst.isEmpty { return nil }
        return (src, dst)
    }

    private func mergedExport(for chain: [FirestoreRoute]) -> SimpleExport {
        var allSteps: [StepRecord] = []
        var allEvents: [EventRef] = []
        var offset = 0

        for route in chain {
            let steps = route.export.steps
            for step in steps {
                allSteps.append(StepRecord(i: step.i + offset, deltaYawDeg: step.deltaYawDeg, strideEstM: step.strideEstM, events: step.events))
            }
            for ev in route.export.keyEvents {
                allEvents.append(EventRef(type: ev.type, atStep: ev.atStep + offset, angleDeg: ev.angleDeg))
            }
            offset += steps.count
        }

        return SimpleExport(keyEvents: allEvents, steps: allSteps, totalSteps: offset)
    }

    private func shortestPathRoutes(from startKeyRaw: String, toAnyOf destKeyRaws: [String])
    -> (destKey: String, totalSteps: Int, nodeChain: [String], routeChain: [FirestoreRoute])? {

        let startKey = graphKey(from: startKeyRaw)
        let destKeys = destKeyRaws.map { graphKey(from: $0) }.filter { !$0.isEmpty }
        let destSet = Set(destKeys)

        var adj: [String: [(String, FirestoreRoute)]] = [:]
        for r in routeVM.routes {
            guard let ep = endpoints(fromRouteId: r.id) else { continue }
            adj[ep.src, default: []].append((ep.dst, r))
            adj[ep.dst, default: []].append((ep.src, r))
        }

        var dist: [String: Int] = [startKey: 0]
        var prev: [String: (String, FirestoreRoute)] = [:]
        var visited = Set<String>()
        var heap: [(node: String, dist: Int)] = [(startKey, 0)]

        while !heap.isEmpty {
            heap.sort { $0.dist > $1.dist }
            let (u, d) = heap.removeLast()
            if visited.contains(u) { continue }
            visited.insert(u)
            if destSet.contains(u) { break }

            guard let edges = adj[u] else { continue }
            for (v, route) in edges {
                let nd = d + route.export.totalSteps
                if nd < (dist[v] ?? Int.max) {
                    dist[v] = nd
                    prev[v] = (u, route)
                    heap.append((v, nd))
                }
            }
        }

        var bestDest: String?
        var bestDist = Int.max
        for k in destKeys {
            if let d = dist[k], d < bestDist {
                bestDest = k
                bestDist = d
            }
        }
        guard let finalDest = bestDest, bestDist < Int.max else { return nil }

        var routeChain: [FirestoreRoute] = []
        var nodeChain: [String] = [finalDest]

        var cur = finalDest
        while cur != startKey {
            guard let (p, r) = prev[cur] else { break }
            routeChain.append(r)
            nodeChain.append(p)
            cur = p
        }
        nodeChain.reverse()
        routeChain.reverse()

        return (finalDest, bestDist, nodeChain, routeChain)
    }

    private func applyDemoModeToCurrentNavigation(immediateARRestart: Bool) {
        guard !segmentRouteChain.isEmpty else {
            modeToast = "MODE → \(demoMode.title) (no chain)"
            return
        }

        if demoMode == .overview {
            navRoute = NavRoute(export: mergedExport(for: segmentRouteChain))
            modeToast = "MODE → FULL (merged \(segmentRouteChain.count) segments)"
        } else {
            segmentIndex = min(max(0, segmentIndex), max(0, segmentRouteChain.count - 1))
            navRoute = NavRoute(export: segmentRouteChain[segmentIndex].export)
            modeToast = "MODE → SEGMENT \(segmentIndex + 1)/\(segmentRouteChain.count)"
        }

        guard immediateARRestart, let route = navRoute else { return }
        navSession.restartNavigationKeepingOrigin(with: route.toPathData())
    }

    // Stage 1
    private var scanStartView: some View {
        VStack {
            Spacer()
            VStack(spacing: 18) {
                Text("AR Navigation").font(.title).bold()
                Image(systemName: "qrcode.viewfinder").font(.system(size: 80))

                Text("1. Scan the start QR code（JSON or building/location/floor documentation）")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)

                Button("Start scanning the QR code") { showScanner = true }
                    .buttonStyle(.borderedProminent)

                Button("Test entrance（Skip scanning the QR code）") {
                    startInfo = StartInfo(building: "Electrical Engineering And Electronics", location: "NodeA", floor: "3")
                    stage = .pickRoute
                }
                .foregroundColor(.secondary)
                .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showScanner) {
            QRScannerView(isPresented: $showScanner) { code in
                if let info = parseStartInfo(from: code) {
                    startInfo = info
                    stage = .pickRoute
                } else {
                    alertMsg = "Unable to parse QR code content:\n\(code)"
                }
            }
            .ignoresSafeArea()
        }
    }

    // Stage 2
    private var pickRouteView: some View {
        let floors = Array(Set(roomsVM.rooms.compactMap { $0.floor })).sorted()
        let filteredRooms: [RoomInfo] = (selectedFloor != nil) ? roomsVM.rooms.filter { $0.floor == selectedFloor } : roomsVM.rooms
        let roomNames = Array(Set(filteredRooms.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        let profNames = Array(Set(filteredRooms.compactMap { $0.professor?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()

        return VStack(spacing: 12) {
            if let s = startInfo {
                VStack(spacing: 4) {
                    Text("Start point confirm").font(.title2).bold()
                    if let b = s.building, !b.isEmpty { Text("Building： \(b)") }
                    if let f = s.floor, !f.isEmpty { Text("Floor： \(f)") }
                    Text("Position / Node： \(s.location)")
                }
                .padding(.bottom, 8)
            }

            Text("2. Select your destination").foregroundColor(.secondary)

            if roomsVM.isLoading {
                ProgressView("Loading room…").padding(.top, 8)
            } else if floors.isEmpty {
                Text("No floor information under the current building").font(.footnote).foregroundColor(.secondary)
            } else {
                HStack {
                    Text("Floor：")
                    Spacer()
                    Picker("Floor", selection: $selectedFloor) {
                        Text("All").tag(Int?.none)
                        ForEach(floors, id: \.self) { f in Text("F\(f)").tag(Int?.some(f)) }
                    }
                    .pickerStyle(.menu)
                }
                .padding(.horizontal)
            }

            Picker("Vertical transport priority", selection: $accessPriority) {
                Text("Stairs").tag(AccessPriority.stair)
                Text("Elevator").tag(AccessPriority.elevator)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Picker("Mode", selection: $destMode) {
                Text("Rooms").tag(DestinationMode.room)
                Text("Prof").tag(DestinationMode.professor)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if destMode == .room {
                Picker("Select room", selection: $selectedRoom) {
                    Text("Please select the room").tag(String?.none)
                    ForEach(roomNames, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .pickerStyle(.wheel)
                .frame(height: 160)
            } else {
                Picker("Select professor", selection: $selectedProf) {
                    Text("Please select the professor").tag(String?.none)
                    ForEach(profNames, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .pickerStyle(.wheel)
                .frame(height: 160)
            }

            if routeVM.isLoading {
                ProgressView("Loading route…").padding(.top, 8)
            } else if let err = routeVM.errorMessage {
                Text(err).foregroundColor(.red).font(.footnote).padding(.top, 4)
            }

            if let route = navRoute {
                Text("Matched route：\(route.totalSteps) steps，Key event: \(route.keyEvents.count)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)

                Button("Enter AR navigation") { stage = .navigating }
                    .padding(.top, 4)
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Please select a floor and match the route based on the room or professor.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }

            Spacer()

            Button("Rescan the starting point QR code.") { endNavigationAndReset() }
                .tint(.secondary)
        }
        .onAppear {
            if let s = startInfo {
                routeVM.loadRoutes(for: s)
                roomsVM.loadRooms(for: s)
            }
        }
        .onChange(of: selectedFloor) { _ in
            selectedRoom = nil; selectedProf = nil; navRoute = nil
            segmentRouteChain = []; segmentNodeChain = []; segmentIndex = 0; destKeyCandidates = []
        }
        .onChange(of: destMode) { _ in
            selectedRoom = nil; selectedProf = nil; navRoute = nil
            segmentRouteChain = []; segmentNodeChain = []; segmentIndex = 0; destKeyCandidates = []
        }
        .onChange(of: selectedRoom) { newValue in
            guard let roomName = newValue, let s = startInfo else { return }

            guard let room = roomsVM.rooms.first(where: { $0.name == roomName }) else {
                navRoute = nil; currentRoomInfo = nil
                return
            }
            currentRoomInfo = room

            destKeyCandidates = [
                room.id.trimmingCharacters(in: .whitespacesAndNewlines),
                room.name.trimmingCharacters(in: .whitespacesAndNewlines)
            ]

            let startFloor = startFloorInt()
            let targetFloor = room.floor

            if let sf = startFloor, let tf = targetFloor, sf == tf {
                let startNodeKey = graphKey(from: s.location)
                if let result = shortestPathRoutes(from: startNodeKey, toAnyOf: destKeyCandidates) {
                    segmentRouteChain = result.routeChain
                    segmentNodeChain = result.nodeChain
                    segmentIndex = 0
                    navRoute = NavRoute(export: mergedExport(for: result.routeChain)) // default FULL
                } else {
                    navRoute = nil
                    alertMsg = "No route found from the current QR code to \(roomName). Please check the routes documents."
                }
            } else {
                navRoute = nil
                alertMsg = "Cross-floor flow remains unchanged: please navigate to the stairs/elevator first, then rescan the QR code."
            }
        }
        .onChange(of: selectedProf) { newValue in
            guard destMode == .professor, let profName = newValue else { return }
            let candidateRooms: [RoomInfo] = (selectedFloor != nil)
            ? roomsVM.rooms.filter { $0.floor == selectedFloor }
            : roomsVM.rooms

            if let room = candidateRooms.first(where: { $0.professor == profName }) {
                selectedRoom = room.name
            } else {
                navRoute = nil
                alertMsg = "Could not find the room for professor \(profName) on the current floor."
            }
        }
    }

    // Stage 3
    private var navigatingView: some View {
        ZStack(alignment: .top) {
            ARViewContainer(session: navSession).edgesIgnoringSafeArea(.all)

            VStack(spacing: 10) {
                roomInfoCard
                modeBanner

                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Picker("", selection: $demoMode) {
                            ForEach(DemoMode.allCases) { m in Text(m.title).tag(m) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240)

                        Button { isScanningRecalibrateQR = true } label: {
                            Label("Scan", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 10) {
                        Picker("", selection: $arrowMode) {
                            ForEach(ArrowMode.allCases) { m in Text(m.title).tag(m) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240)

                        Text(arrowMode == .ar ? "3D arrows" : "2D arrow")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.85))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.35))
                .cornerRadius(12)

                Spacer()
                manualAdjustPanel
                bottomSummaryBar
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if arrowMode == .simple && navSession.navState == .navigating {
                simpleArrowOverlay
            }

            if let t = modeToast {
                VStack {
                    Spacer()
                    Text(t)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(12)
                        .padding(.bottom, 92)
                }
            }
        }
        .onAppear {
            navSession.setArrowMode(arrowMode)
            startCurrentNavRouteInAR()
            applyDemoModeToCurrentNavigation(immediateARRestart: false)
        }
        .onDisappear {
            if #available(iOS 16.1, *) { LiveActivityManager.shared.end() }
        }
        .onChange(of: demoMode) { _ in
            applyDemoModeToCurrentNavigation(immediateARRestart: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { self.modeToast = nil }
        }
        .onChange(of: arrowMode) { newValue in
            navSession.setArrowMode(newValue)
            modeToast = "ARROW → \(newValue.title)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.modeToast = nil }
        }
        .onChange(of: navSession.navState) { newState in
            guard demoMode == .segmented, newState == .arrived else { return }
            guard !segmentRouteChain.isEmpty else { return }

            if segmentIndex < segmentRouteChain.count - 1 {
                let nextIdx = segmentIndex + 1
                let nextNode = (nextIdx < segmentNodeChain.count) ? segmentNodeChain[nextIdx] : "Next"
                nextSegmentAlertText = "Segment \(segmentIndex + 1) completed.\nPlease scan the QR at \(nextNode) to continue."
                showNextSegmentAlert = true
            }
        }
        .alert(nextSegmentAlertText, isPresented: $showNextSegmentAlert) {
            Button("Scan next segment") { isScanningNextSegmentQR = true }
            Button("End", role: .destructive) { endNavigationAndReset() }
        }
        .sheet(isPresented: $isScanningNextSegmentQR) {
            QRScannerView(isPresented: $isScanningNextSegmentQR) { code in
                guard let info = parseStartInfo(from: code) else {
                    alertMsg = "Unable to parse QR code content:\n\(code)"
                    return
                }

                if let b0 = startInfo?.building, let b1 = info.building,
                   !b0.isEmpty, !b1.isEmpty, b0 != b1 {
                    alertMsg = "Next segment QR code building mismatch: \(b1)"
                    return
                }

                startInfo = info
                segmentIndex = min(segmentIndex + 1, max(0, segmentRouteChain.count - 1))
                navRoute = NavRoute(export: segmentRouteChain[segmentIndex].export)

                navSession.resetOrigin()
                startCurrentNavRouteInAR()

                modeToast = "SEGMENT \(segmentIndex + 1)/\(segmentRouteChain.count)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { self.modeToast = nil }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isScanningRecalibrateQR) {
            QRScannerView(isPresented: $isScanningRecalibrateQR) { code in
                guard let info = parseStartInfo(from: code) else {
                    alertMsg = "Unable to parse QR code content:\n\(code)"
                    return
                }
                recomputeFromScannedStart(info)
            }
            .ignoresSafeArea()
        }
    }

    private var simpleArrowOverlay: some View {
        VStack {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.black.opacity(0.35))
                    .frame(width: 190, height: 190)

                Image(systemName: "arrow.up")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 90, height: 90)
                    .foregroundColor(.white)
                    .rotationEffect(.radians(navSession.simpleArrowAngleRad))

                VStack {
                    Spacer()
                    Text(navSession.simpleArrowLabel)
                        .font(.headline.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.bottom, 18)
                }
                .frame(width: 190, height: 190)
            }
            .padding(.bottom, 170)
        }
        .allowsHitTesting(false)
    }

    private func startCurrentNavRouteInAR() {
        guard let route = navRoute else {
            alertMsg = "No route selected yet, please return to the previous page and choose again."
            stage = .scanStart
            return
        }

        navSession.navState = .scanning
        navSession.hintText = "Please point the phone roughly toward the direction of the QR code just scanned to align the start point…"

        let pathData = route.toPathData()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.navSession.setOriginUsingCurrentCamera()
            self.navSession.startNavigation(with: pathData)
            self.navSession.setArrowMode(self.arrowMode)

            if #available(iOS 16.1, *),
               let selected = self.selectedRoom,
               let room = self.roomsVM.rooms.first(where: { $0.name == selected })
            {
                let currentInstruction = self.navSession.hintText.isEmpty ? "Follow the arrow direction" : self.navSession.hintText
                let totalSteps = self.navRoute?.totalSteps ?? 0
                let remainingSteps = max(totalSteps - self.navSession.currentStep, 0)
                let remainingMeters = Int(Double(remainingSteps) * 0.75)
                let etaSeconds = remainingSteps * 2

                LiveActivityManager.shared.start(
                    profName: room.professor ?? "",
                    department: room.department ?? "",
                    officeHour: room.officeHour ?? "",
                    instruction: currentInstruction,
                    distanceText: "Approx. \(remainingMeters)m",
                    etaText: "Approx. \(etaSeconds)s",
                    stepText: "\(remainingSteps) steps"
                )
            }
        }
    }

    private func recomputeFromScannedStart(_ scanned: StartInfo) {
        if let b0 = startInfo?.building, let b1 = scanned.building,
           !b0.isEmpty, !b1.isEmpty, b0 != b1 {
            alertMsg = "QR code building mismatch: \(b1)"
            return
        }
        if destKeyCandidates.isEmpty {
            alertMsg = "No destination information (destKeyCandidates is empty), please return and select the room again."
            return
        }

        let startNodeKey = graphKey(from: scanned.location)
        guard let result = shortestPathRoutes(from: startNodeKey, toAnyOf: destKeyCandidates) else {
            alertMsg = "No route found from \(startNodeKey) to the destination. Please check the Routes data."
            return
        }

        segmentRouteChain = result.routeChain
        segmentNodeChain = result.nodeChain

        if demoMode == .overview {
            navRoute = NavRoute(export: mergedExport(for: result.routeChain))
            segmentIndex = 0
            modeToast = "SCAN ✓  FULL"
        } else {
            segmentIndex = 0
            if let first = result.routeChain.first {
                navRoute = NavRoute(export: first.export)
                modeToast = "SCAN ✓  SEGMENT 1/\(result.routeChain.count)"
            } else {
                navRoute = nil
                alertMsg = "Segmented: routeChain is empty."
                return
            }
        }

        startInfo = scanned
        navSession.resetOrigin()
        startCurrentNavRouteInAR()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { self.modeToast = nil }
    }

    private func endNavigationAndReset() {
        navSession.sceneView?.session.pause()
        navSession.navState = .idle
        stage = .scanStart
        navRoute = nil
        selectedRoom = nil
        selectedProf = nil
        selectedFloor = nil
        currentRoomInfo = nil

        segmentRouteChain = []
        segmentNodeChain = []
        segmentIndex = 0
        destKeyCandidates = []

        if #available(iOS 16.1, *) { LiveActivityManager.shared.end() }
    }

    @ViewBuilder
    private var roomInfoCard: some View {
        if let info = currentRoomInfo {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let name = info.professor, !name.isEmpty {
                        Text(name).font(.headline).foregroundColor(.white)
                    }
                    if let dept = info.department, !dept.isEmpty {
                        Text(dept).font(.subheadline).foregroundColor(.white.opacity(0.9))
                    }
                    if let time = info.officeHour, !time.isEmpty {
                        Text(time).font(.caption).foregroundColor(.white.opacity(0.8))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.85)))
            .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 6)
        }
    }

    private var modeBanner: some View {
        let line1: String = {
            if demoMode == .overview { return "MODE: FULL (overview)" }
            if segmentRouteChain.isEmpty { return "MODE: SEGMENT (no chain)" }
            return "MODE: SEGMENT \(segmentIndex + 1)/\(segmentRouteChain.count)"
        }()

        let line2: String = "ARROW: \(arrowMode == .ar ? "AR (3D)" : "Simple (2D)")"
        let bg: Color = (demoMode == .overview) ? Color.blue.opacity(0.75) : Color.orange.opacity(0.8)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: demoMode == .overview ? "map" : "point.topleft.down.curvedto.point.bottomright.up")
                    .foregroundColor(.white)
                Text(line1).font(.subheadline.weight(.bold)).foregroundColor(.white)
                Spacer()
            }
            HStack {
                Image(systemName: arrowMode == .ar ? "arkit" : "arrow.up.circle.fill")
                    .foregroundColor(.white.opacity(0.95))
                Text(line2).font(.caption.weight(.semibold)).foregroundColor(.white.opacity(0.95))
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(bg)
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 4)
    }


    private var manualAdjustPanel: some View {
        VStack(spacing: 8) {
            Text("Manual Adjustment")
                .font(.caption)
                .foregroundColor(.white.opacity(0.9))

            HStack(spacing: 8) {
                Button("⟲ 1°") { navSession.rotateLeft(deg: 1) }
                    .buttonStyle(.bordered)

                Button("Align") { navSession.alignHereUsingCurrentCamera() }
                    .buttonStyle(.borderedProminent)

                Button("⟳ 1°") { navSession.rotateRight(deg: 1) }
                    .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Button("← 5cm") { navSession.nudgeLeft(cm: 5) }
                    .buttonStyle(.bordered)

                Button("↑ 5cm") { navSession.nudgeForward(cm: 5) }
                    .buttonStyle(.bordered)

                Button("↓ 5cm") { navSession.nudgeBackward(cm: 5) }
                    .buttonStyle(.bordered)

                Button("5cm →") { navSession.nudgeRight(cm: 5) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.35))
        .cornerRadius(12)
    }

    private var bottomSummaryBar: some View {
        let remain = computeRemainInfo()

        return HStack(spacing: 12) {
            Button { endNavigationAndReset() } label: {
                Text("End")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 20).stroke(Color.gray.opacity(0.4), lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 2) {
                if let r = remain {
                    Text("Remaining \(r.meters)m · \(r.minutes) min \(r.seconds) sec")
                        .font(.headline)
                        .foregroundColor(.black)
                }
                if let r = remain {
                    Text("Estimated arrival at \(r.arrivalTime)")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            Button { } label: {
                Text("More")
                    .font(.body.weight(.medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color.white).shadow(color: .black.opacity(0.15), radius: 2))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.white).shadow(color: .black.opacity(0.2), radius: 12, y: -2))
    }

    private func computeRemainInfo()
        -> (meters: Int, minutes: Int, seconds: Int, arrivalTime: String)? {

        guard let route = navRoute, let path = navSession.pathData else { return nil }

        let totalSteps = max(1, route.export.totalSteps)
        let stepLen = path.totalLength / Double(totalSteps)

        let usedSteps = navSession.currentStep
        let remainSteps = max(0, totalSteps - usedSteps)
        let remainDist = Double(remainSteps) * stepLen

        let speed = 1.2
        let remainSec = Int(remainDist / speed)
        let min = remainSec / 60
        let sec = remainSec % 60

        let eta = Date().addingTimeInterval(TimeInterval(remainSec))
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let etaString = formatter.string(from: eta)

        return (meters: Int(round(remainDist)), minutes: min, seconds: sec, arrivalTime: etaString)
    }
}
