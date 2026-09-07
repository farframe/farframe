import Foundation

public enum PlayStationCrossDeviceRegistrationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(UInt8)
    case invalidRegistration(PlayStationConsoleRegistrationError)
}

/// A versioned, provider-specific bootstrap payload intended only for an
/// opt-in synchronized Keychain item. It contains no PSN password, token,
/// Account ID, Link Device PIN, live session, or controller state.
///
/// The registration bytes are bearer credentials. Treat the encoded value as
/// secret and copy it into the destination's device-local operational Keychain
/// before attempting a connection.
public struct PlayStationCrossDeviceRegistration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt8 = 1

    public let schemaVersion: UInt8
    public let console: SavedPlayStationConsole
    public let credentialGenerationID: UUID
    public let registrationEnvelope: Data

    public init(
        console: SavedPlayStationConsole,
        credentialGenerationID: UUID = UUID(),
        registration: PlayStationConsoleRegistration
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.console = console
        self.credentialGenerationID = credentialGenerationID
        self.registrationEnvelope = registration.envelope
    }

    public func registration() throws -> PlayStationConsoleRegistration {
        do {
            return try PlayStationConsoleRegistration(envelope: registrationEnvelope)
        } catch let error as PlayStationConsoleRegistrationError {
            throw PlayStationCrossDeviceRegistrationError.invalidRegistration(error)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case console
        case credentialGenerationID
        case registrationEnvelope
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(UInt8.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw PlayStationCrossDeviceRegistrationError
                .unsupportedSchemaVersion(schemaVersion)
        }

        let console = try container.decode(SavedPlayStationConsole.self, forKey: .console)
        let credentialGenerationID = try container.decode(
            UUID.self,
            forKey: .credentialGenerationID
        )
        let registrationEnvelope = try container.decode(
            Data.self,
            forKey: .registrationEnvelope
        )
        do {
            _ = try PlayStationConsoleRegistration(envelope: registrationEnvelope)
        } catch let error as PlayStationConsoleRegistrationError {
            throw PlayStationCrossDeviceRegistrationError.invalidRegistration(error)
        }

        self.schemaVersion = schemaVersion
        self.console = console
        self.credentialGenerationID = credentialGenerationID
        self.registrationEnvelope = registrationEnvelope
    }
}
