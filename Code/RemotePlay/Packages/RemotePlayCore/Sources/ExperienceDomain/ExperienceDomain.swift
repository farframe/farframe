import Foundation

public struct ExperienceID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

public enum ExperienceKind: String, Codable, CaseIterable, Sendable {
    case remoteStream
    case cloudStream
    case nativeGame
}

public enum ExperienceCapability: String, Codable, CaseIterable, Sendable {
    case wake
    case pair
    case rest
    case physicalController
    case touchController
    case gameplayContinuity
    case healthTelemetry
}

public struct ExperienceDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: ExperienceID
    public let kind: ExperienceKind
    public let displayName: String
    public let capabilities: Set<ExperienceCapability>

    public init(
        id: ExperienceID,
        kind: ExperienceKind,
        displayName: String,
        capabilities: Set<ExperienceCapability>
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.capabilities = capabilities
    }
}

public enum StreamingConnectionState: String, Codable, Sendable {
    case idle
    case preparing
    case connecting
    case streaming
    case disconnecting
    case disconnected
    case failed
}

public enum RemotePlayPlatform: String, CaseIterable, Codable, Sendable {
    case vision
    case mobile
    case mac

    public var displayName: String {
        switch self {
        case .vision: "Vision Pro"
        case .mobile: "iPhone and iPad"
        case .mac: "Mac"
        }
    }
}
