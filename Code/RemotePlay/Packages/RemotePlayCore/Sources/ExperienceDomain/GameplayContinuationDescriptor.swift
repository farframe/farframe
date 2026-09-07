import Foundation

public enum GameplayContinuationDescriptorError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(UInt8)
    case invalidTimeRange
    case expired
}

/// Secret-free state that a platform Handoff adapter may publish after the
/// source session has disconnected without Resting the console. Credentials,
/// host sockets, media state, and controller ownership are deliberately absent.
public struct GameplayContinuationDescriptor: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt8 = 1

    public let schemaVersion: UInt8
    public let providerID: String
    public let experienceID: ExperienceID
    public let resourceID: UUID
    public let qualityProfileID: String
    public let issuedAt: Date
    public let expiresAt: Date
    public let nonce: UUID

    public init(
        providerID: String,
        experienceID: ExperienceID,
        resourceID: UUID,
        qualityProfileID: String,
        issuedAt: Date,
        expiresAt: Date,
        nonce: UUID = UUID()
    ) throws {
        guard expiresAt > issuedAt else {
            throw GameplayContinuationDescriptorError.invalidTimeRange
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.providerID = providerID
        self.experienceID = experienceID
        self.resourceID = resourceID
        self.qualityProfileID = qualityProfileID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.nonce = nonce
    }

    public func validate(at date: Date = Date()) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw GameplayContinuationDescriptorError
                .unsupportedSchemaVersion(schemaVersion)
        }
        guard expiresAt > issuedAt else {
            throw GameplayContinuationDescriptorError.invalidTimeRange
        }
        guard date < expiresAt else {
            throw GameplayContinuationDescriptorError.expired
        }
    }
}
