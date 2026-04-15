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
// MARK: - SimpleExport / NavRoute

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

struct EventRef: Codable {
    let type: Event.EventType
    let atStep: Int
    let angleDeg: Double?
}

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

struct NavRoute {
    let export: SimpleExport
    var totalSteps: Int { export.totalSteps }
    var keyEvents: [EventRef] { export.keyEvents }
    var steps: [StepRecord] { export.steps }
}
