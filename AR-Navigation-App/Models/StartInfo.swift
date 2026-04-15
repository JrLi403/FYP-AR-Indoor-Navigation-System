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
// MARK: - 起点信息 & 解析二维码

struct StartInfo: Codable, Equatable {
    let building: String?
    let location: String
    let floor: String?
}

func parseStartInfo(from qr: String) -> StartInfo? {
    if let data = qr.data(using: .utf8),
       let info = try? JSONDecoder().decode(StartInfo.self, from: data) {
        return info
    }

    let parts = qr.split(separator: ";").map { $0.split(separator: "=") }
    var dict: [String: String] = [:]
    for p in parts where p.count == 2 { dict[String(p[0])] = String(p[1]) }

    guard let loc = dict["location"] else { return nil }
    return StartInfo(building: dict["building"], location: loc, floor: dict["floor"])
}
