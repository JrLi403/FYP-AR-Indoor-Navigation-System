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
// MARK: - NavRoute → PathData

extension NavRoute {
    func toPathData() -> PathData {
        let sortedSteps = steps.sorted { $0.i < $1.i }

        var points: [SIMD2<Float>] = []
        var pos = SIMD2<Float>(0, 0)

        var headingRad: Float = 0
        let noiseThresholdDeg: Double = 3.0

        points.append(pos)
        var cumulativeLengths: [Double] = [0]

        for step in sortedSteps {
            var deltaDeg = step.deltaYawDeg
            if abs(deltaDeg) < noiseThresholdDeg { deltaDeg = 0 }

            let deltaRad = Float(deltaDeg * .pi / 180.0)
            headingRad += deltaRad

            let stride = Float(step.strideEstM)
            let newPos = SIMD2<Float>(
                pos.x + stride * sin(headingRad),
                pos.y + -stride * cos(headingRad)
            )

            let segLen = simd_distance(pos, newPos)
            cumulativeLengths.append((cumulativeLengths.last ?? 0) + Double(segLen))

            pos = newPos
            points.append(pos)
        }

        let totalGeomLength = cumulativeLengths.last ?? 0
        if points.count < 2 { points = [SIMD2<Float>(0, 0), SIMD2<Float>(0, -1)] }

        func distanceForStepIndex(_ idx: Int) -> Double {
            let clamped = max(0, min(idx, cumulativeLengths.count - 1))
            return cumulativeLengths[clamped]
        }

        var stepsOut: [PathStep] = []
        stepsOut.append(PathStep(distanceFromStart: 0, instruction: "Follow the arrow direction", eventType: nil, angleDeg: nil))

        // ✅ Prefer stored Key_events; if empty, infer TURN events from accumulated yaw (Demo A).
        var effectiveEvents: [EventRef] = keyEvents

        if effectiveEvents.isEmpty {
            var accumulatedYaw: Double = 0
            let turnThresholdDeg: Double = 35.0   // tune: 30~40°

            // Use enumerated index as atStep so it always matches cumulativeLengths indexing
            for (idx, step) in sortedSteps.enumerated() {
                accumulatedYaw += step.deltaYawDeg

                if abs(accumulatedYaw) >= turnThresholdDeg {
                    effectiveEvents.append(
                        EventRef(
                            type: .TURN,
                            atStep: idx,
                            angleDeg: accumulatedYaw
                        )
                    )
                    accumulatedYaw = 0
                }
            }
        }

        let sortedEvents = effectiveEvents.sorted { $0.atStep < $1.atStep }
        for e in sortedEvents {
            let d = distanceForStepIndex(e.atStep)
            stepsOut.append(PathStep(distanceFromStart: d, instruction: instructionText(for: e)))
        }

        stepsOut.append(PathStep(distanceFromStart: totalGeomLength, instruction: "Near destination, please check the signs to confirm the location"))

        var pathData = PathData(points: points, steps: stepsOut)
        pathData.precompute()
        return pathData
    }

    fileprivate func instructionText(for event: EventRef) -> String {
        switch event.type {
        case .TURN:
            if let a = event.angleDeg {
                if a < -20 { return "Turn right ahead" }
                if a > 20 { return "Turn left ahead" }
                return "Adjust direction slightly ahead"
            }
            return "Turn ahead"
        case .STAIR_UP: return "Stairs up ahead, please watch your step"
        case .STAIR_DOWN: return "Stairs down ahead, please watch your step"
        case .ELEVATOR: return "Elevator ahead, please choose the floor according to the signs"
        case .ESCALATOR: return "Escalator ahead, please mind the handrail and nearby passengers"
        }
    }
}
