import ExperienceDomain
import Foundation

/// Provider-scoped IDs prevent an arbitrary or foreign experience identifier
/// from being interpreted as a saved PlayStation console.
public enum PlayStationRemotePlayExperienceID {
    public static let prefix = "playstation.remote-play.console/"

    public static func make(consoleID: UUID) -> ExperienceID {
        ExperienceID(rawValue: prefix + consoleID.uuidString.lowercased())
    }

    public static func consoleID(from experienceID: ExperienceID) -> UUID? {
        let rawValue = experienceID.rawValue
        guard rawValue.hasPrefix(prefix) else { return nil }

        let uuidText = String(rawValue.dropFirst(prefix.count))
        guard let consoleID = UUID(uuidString: uuidText),
              rawValue == make(consoleID: consoleID).rawValue else {
            return nil
        }
        return consoleID
    }
}

public enum PlayStationRemotePlayExperience {
    /// Capabilities backed by the current native provider. Cross-device
    /// continuity and touch input remain separate future gates.
    public static let transportOnlyCapabilities: Set<ExperienceCapability> = [
        .wake,
        .pair,
        .rest,
        .physicalController,
        .healthTelemetry,
    ]
}

public extension SavedPlayStationConsole {
    var remotePlayExperience: ExperienceDescriptor {
        ExperienceDescriptor(
            id: PlayStationRemotePlayExperienceID.make(consoleID: id),
            kind: .remoteStream,
            displayName: displayName,
            capabilities: PlayStationRemotePlayExperience.transportOnlyCapabilities
        )
    }
}
