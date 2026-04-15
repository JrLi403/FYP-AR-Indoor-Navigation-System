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
// MARK: - Firestore 模型

struct FirestoreRoute: Identifiable {
    let id: String
    let export: SimpleExport
    let destRoomId: String?
    let startNodeId: String?

    enum RouteKind { case stair, elevator, other }

    var routeKind: RouteKind {
        let lower = id.lowercased()
        if lower.contains("stair") { return .stair }
        if lower.contains("elev") || lower.contains("lift") { return .elevator }
        return .other
    }

    var destFloor: Int? {
        guard let destRoomId = destRoomId else { return nil }
        let segs = destRoomId.split(separator: "-")
        guard let first = segs.first else { return nil }
        let s = String(first)
        guard s.hasPrefix("F") else { return nil }
        return Int(s.dropFirst())
    }
}

extension FirestoreRoute {
    init?(doc: DocumentSnapshot) {
        guard let data = doc.data() else { return nil }
        let decoder = JSONDecoder()

        guard let stepsString = data["Steps"] as? String,
              let stepsData = stepsString.data(using: .utf8) else { return nil }

        var stepsArray: [StepRecord] = []
        if let arr = try? decoder.decode([StepRecord].self, from: stepsData) {
            stepsArray = arr
        } else if let single = try? decoder.decode(StepRecord.self, from: stepsData) {
            stepsArray = [single]
        } else { return nil }

        if stepsArray.isEmpty { return nil }

        var keyEventsArray: [EventRef] = []
        if let keyString = data["Key_events"] as? String,
           let keyData = keyString.data(using: .utf8) {
            if let arr = try? decoder.decode([EventRef].self, from: keyData) {
                keyEventsArray = arr
            } else if let single = try? decoder.decode(EventRef.self, from: keyData) {
                keyEventsArray = [single]
            }
        }

        var totalSteps = stepsArray.count
        if let t = data["Total_steps"] as? Int { totalSteps = t }
        else if let s = data["Total_steps"] as? String, let t = Int(s) { totalSteps = t }

        self.id = doc.documentID
        self.export = SimpleExport(keyEvents: keyEventsArray, steps: stepsArray, totalSteps: totalSteps)

        let segs = doc.documentID.split(separator: "-").map(String.init)
        var parsedStart: String? = nil
        var parsedDest: String? = nil

        if let toIndex = segs.firstIndex(of: "to"), toIndex > 0 {
            parsedStart = segs[toIndex - 1]
            let destParts = segs[(toIndex + 1)...]
            if destParts.count >= 2 { parsedDest = destParts.suffix(2).joined(separator: "-") }
            else if let last = destParts.last { parsedDest = last }
        } else {
            if segs.count >= 2 { parsedStart = segs[1] }
            if segs.count >= 2 { parsedDest = segs.suffix(2).joined(separator: "-") }
        }

        self.startNodeId = parsedStart
        self.destRoomId = parsedDest
    }
}

// Rooms
struct RoomInfo: Identifiable {
    let id: String
    let name: String
    let professor: String?
    let department: String?
    let officeHour: String?
    let floor: Int?
}
