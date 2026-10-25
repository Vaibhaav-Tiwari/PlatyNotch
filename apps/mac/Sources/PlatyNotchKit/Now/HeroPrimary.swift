import Foundation

/// The one primary control a live hero may offer (spec 6.4: Approve, Pause, Stop, Join).
/// Agents use `AgentRowAction`; downloads, file actions, the mirror and Chase have none.
public enum HeroPrimary {
    public static func title(rank: LiveRank, playing: Bool, hasLink: Bool) -> String? {
        switch rank {
        case .ringing: "Stop"
        case .timerRunning: "Pause"
        case .music: playing ? "Pause" : "Play"
        case .meetingImminent, .meetingSoon: hasLink ? "Join" : nil
        default: nil
        }
    }
}
