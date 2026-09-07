import Foundation

/// A transient account identity suitable for a PlayStation Remote Play pairing request.
///
/// This value intentionally does not conform to `Codable`. Platform sign-in flows may
/// produce it in memory, but persistence and synchronization require a separate,
/// explicitly reviewed contract.
public struct PlayStationRemotePlayAccountIdentity: Equatable, Sendable {
    public static let maximumDisplayNameLength = 64

    public let accountID: PlayStationAccountID
    public let displayName: String?

    public init(accountID: PlayStationAccountID, displayName: String? = nil) {
        self.accountID = accountID
        self.displayName = Self.sanitizeDisplayName(displayName)
    }

    private static func sanitizeDisplayName(_ value: String?) -> String? {
        guard let value else { return nil }

        var normalized = ""
        var separatorIsPending = false
        for scalar in value.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                separatorIsPending = normalized.isEmpty == false
                continue
            }
            if CharacterSet.controlCharacters.contains(scalar) {
                continue
            }
            if separatorIsPending {
                normalized.append(" ")
                separatorIsPending = false
            }
            normalized.append(contentsOf: String(scalar))
        }

        let bounded = String(normalized.prefix(maximumDisplayNameLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return bounded.isEmpty ? nil : bounded
    }
}

public enum PlayStationAccountIdentityAcquisitionCapability: Equatable, Sendable {
    case available
    case unavailable

    public var isAvailable: Bool {
        self == .available
    }
}

public enum PlayStationAccountIdentityAcquisitionError: Error, Equatable, Sendable,
    LocalizedError {
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "PlayStation account sign-in is not available in this build."
        }
    }
}

/// A platform-owned seam for acquiring the account ID needed by PS5 registration.
///
/// Implementations must return only the validated account ID and an optional display
/// name. Tokens, cookies, credentials, client configuration, and persistence are outside
/// this contract.
@MainActor
public protocol PlayStationAccountIdentityAcquiring: Sendable {
    var capability: PlayStationAccountIdentityAcquisitionCapability { get }

    func acquireAccountIdentity() async throws -> PlayStationRemotePlayAccountIdentity
}

/// The safe default when a platform shell has not supplied an authorized sign-in flow.
@MainActor
public struct UnavailablePlayStationAccountIdentityAcquirer:
    PlayStationAccountIdentityAcquiring {
    public let capability: PlayStationAccountIdentityAcquisitionCapability = .unavailable

    public init() {}

    public func acquireAccountIdentity() async throws
        -> PlayStationRemotePlayAccountIdentity {
        throw PlayStationAccountIdentityAcquisitionError.unavailable
    }
}
