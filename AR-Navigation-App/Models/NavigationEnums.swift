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
// MARK: - 导航阶段 & 目的地模式

enum NavStage { case scanStart, pickRoute, navigating }
enum DestinationMode { case room, professor }
enum AccessPriority { case stair, elevator }

// ✅ Demo 展示方式（AR页可切换）
enum DemoMode: String, CaseIterable, Identifiable {
    case overview
    case segmented
    var id: String { rawValue }
    var title: String { self == .overview ? "Full" : "Segment" }
}

// ✅ Arrow 模式（AR页可切换）
enum ArrowMode: String, CaseIterable, Identifiable {
    case ar
    case simple
    var id: String { rawValue }
    var title: String { self == .ar ? "AR" : "Simple" }
}
