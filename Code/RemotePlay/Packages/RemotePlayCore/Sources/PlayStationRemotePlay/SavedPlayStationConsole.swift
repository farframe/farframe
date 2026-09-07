import Foundation

/// Which saved address Wake and Connect use for a console.
///
/// `home` is the console's local-network address captured during pairing.
/// `away` is an optional user-supplied address reachable from outside the home
/// network (a router port forward, dynamic DNS name, or a VPN address). Farframe
/// does not perform automatic internet traversal; the route only selects which
/// saved endpoint the existing direct transport targets.
public enum PlayStationConnectionRoute: String, Codable, CaseIterable, Equatable, Hashable,
    Sendable {
    case home
    case away

    public var title: String {
        switch self {
        case .home: "Home"
        case .away: "Away"
        }
    }
}

/// Non-secret console metadata suitable for ordinary preferences and UI presentation.
public struct SavedPlayStationConsole: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var displayName: String
    public var hostAddress: String
    public var macAddress: String?
    /// Optional address used when `connectionRoute == .away`. Never a secret,
    /// but it may name the owner's public endpoint and is therefore excluded
    /// from every shareable diagnostic report.
    public var awayHostAddress: String?
    public var connectionRoute: PlayStationConnectionRoute

    public init(
        id: UUID = UUID(),
        displayName: String,
        hostAddress: String,
        macAddress: String? = nil,
        awayHostAddress: String? = nil,
        connectionRoute: PlayStationConnectionRoute = .home
    ) {
        self.id = id
        self.displayName = displayName
        self.hostAddress = hostAddress
        self.macAddress = macAddress
        self.awayHostAddress = Self.normalizedAwayAddress(awayHostAddress)
        // A console without an Away address always resolves to Home so a stale
        // preference can never point Wake/Connect at an empty endpoint.
        self.connectionRoute = self.awayHostAddress == nil ? .home : connectionRoute
    }

    /// The address the current route resolves to. Falls back to `hostAddress`
    /// whenever no usable Away address is saved.
    public var activeHostAddress: String {
        switch connectionRoute {
        case .home:
            hostAddress
        case .away:
            awayHostAddress ?? hostAddress
        }
    }

    public var hasAwayAddress: Bool {
        awayHostAddress != nil
    }

    public static func normalizedAwayAddress(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false,
              trimmed.utf8.contains(0) == false else {
            return nil
        }
        return trimmed
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case hostAddress
        case macAddress
        case awayHostAddress
        case connectionRoute
    }

    /// Consoles saved before the Away route existed decode with `.home` and no
    /// Away address, so an in-place upgrade never requires re-pairing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let displayName = try container.decode(String.self, forKey: .displayName)
        let hostAddress = try container.decode(String.self, forKey: .hostAddress)
        let macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress)
        let awayHostAddress = try container.decodeIfPresent(String.self, forKey: .awayHostAddress)
        let route = try container.decodeIfPresent(
            PlayStationConnectionRoute.self,
            forKey: .connectionRoute
        ) ?? .home
        self.init(
            id: id,
            displayName: displayName,
            hostAddress: hostAddress,
            macAddress: macAddress,
            awayHostAddress: awayHostAddress,
            connectionRoute: route
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(hostAddress, forKey: .hostAddress)
        try container.encodeIfPresent(macAddress, forKey: .macAddress)
        try container.encodeIfPresent(awayHostAddress, forKey: .awayHostAddress)
        try container.encode(connectionRoute, forKey: .connectionRoute)
    }
}
