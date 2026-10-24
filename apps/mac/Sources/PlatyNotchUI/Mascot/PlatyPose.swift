import PlatyNotchKit
import SwiftUI

/// Platy's pose for drawing: the Kit's plain numbers (`PlatyPoseValues`, C34) plus the
/// SwiftUI tint. `pose.eyesOpen`, `pose.bounce`… read straight through to the values.
@dynamicMemberLookup
struct PlatyPose: Equatable {
    var values: PlatyPoseValues

    init(_ values: PlatyPoseValues = PlatyPoseValues()) {
        self.values = values
    }

    subscript<T>(dynamicMember key: KeyPath<PlatyPoseValues, T>) -> T {
        values[keyPath: key]
    }

    /// The color laid over the body (waiting: amber), nil for none.
    var tint: Color? {
        switch values.tint {
        case .none: nil
        case .amber: PlatyPalette.amber
        }
    }

    static func at(_ mood: PlatyMood, time: TimeInterval) -> PlatyPose {
        PlatyPose(PlatyPoseValues.at(mood, time: time))
    }

    /// The still frame (Reduce Motion, a paused panel, renders).
    static func rest(_ mood: PlatyMood) -> PlatyPose {
        PlatyPose(PlatyPoseValues.rest(mood))
    }
}
