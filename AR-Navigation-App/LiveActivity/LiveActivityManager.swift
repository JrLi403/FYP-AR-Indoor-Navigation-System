//
//  LiveActivityManager.swift
//  AR Navigation v3.0
//

import Foundation
import ActivityKit

@available(iOS 16.1, *)
final class LiveActivityManager {

    static let shared = LiveActivityManager()

    /// 当前正在运行的 Live Activity（如果有）
    private var activity: Activity<ARNavigationLiveActivityAttributes>?

    // MARK: - Start

    /// 开始一个新的 Live Activity
    func start(
        profName: String,
        department: String,
        officeHour: String,
        instruction: String,
        distanceText: String,
        etaText: String,
        stepText: String
    ) {
        let attributes = ARNavigationLiveActivityAttributes(
            profName: profName,
            department: department,
            officeHour: officeHour
        )

        let contentState = ARNavigationLiveActivityAttributes.ContentState(
            instruction: instruction,
            distanceText: distanceText,
            etaText: etaText,
            stepText: stepText
        )

        Task {
            // 先把以前残留的全关掉，防止有多个实例
            for a in Activity<ARNavigationLiveActivityAttributes>.activities {
                await a.end(nil, dismissalPolicy: .immediate)
            }

            do {
                let newActivity = try Activity.request(
                    attributes: attributes,
                    contentState: contentState,
                    pushType: nil
                )
                self.activity = newActivity
                print("✅ LiveActivity START, id = \(newActivity.id)")
            } catch {
                print("❌ LiveActivity start error: \(error)")
            }
        }
    }

    // MARK: - Update

    /// 更新提示语 + 距离 / 时间 / 步数
    func updateInstruction(
        _ instruction: String,
        distanceText: String,
        etaText: String,
        stepText: String
    ) {
        Task {
            guard let activity = activity ?? Activity<ARNavigationLiveActivityAttributes>.activities.first else {
                print("⚠️ LiveActivity update: no active activity")
                return
            }

            let state = ARNavigationLiveActivityAttributes.ContentState(
                instruction: instruction,
                distanceText: distanceText,
                etaText: etaText,
                stepText: stepText
            )

            await activity.update(using: state)
            print("🔄 LiveActivity UPDATE: \(instruction), \(distanceText), \(etaText), \(stepText)")
        }
    }

    // MARK: - End

    /// 结束 Live Activity，并让灵动岛立刻消失
    func end() {
        Task {
            var endedCount = 0

            if let activity = self.activity {
                await activity.end(nil, dismissalPolicy: .immediate)
                endedCount += 1
                print("🛑 LiveActivity END current id = \(activity.id)")
                self.activity = nil
            }

            // 再兜底把同类型所有实例全部关掉
            for a in Activity<ARNavigationLiveActivityAttributes>.activities {
                await a.end(nil, dismissalPolicy: .immediate)
                endedCount += 1
                print("🧹 LiveActivity FORCE END id = \(a.id)")
            }

            print("✅ LiveActivity end() finished, closed \(endedCount) activities")
        }
    }
}
