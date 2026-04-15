import Foundation
import ActivityKit

public struct ARNavigationLiveActivityAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        public var instruction: String
        public var distanceText: String
        public var etaText: String
        public var stepText: String
        
        public init(instruction: String, distanceText: String, etaText: String, stepText: String) {
            self.instruction = instruction
            self.distanceText = distanceText
            self.etaText = etaText
            self.stepText = stepText
        }
    }

    public var profName: String
    public var department: String
    public var officeHour: String

    public init(profName: String, department: String, officeHour: String) {
        self.profName = profName
        self.department = department
        self.officeHour = officeHour
    }
}
