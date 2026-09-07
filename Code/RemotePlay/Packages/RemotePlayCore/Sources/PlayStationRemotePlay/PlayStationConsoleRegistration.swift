import Foundation

public enum PlayStationConsoleRegistrationError: Error, Equatable, Sendable {
    case invalidRegistrationKeyLength(Int)
    case invalidRemotePlayKeyLength(Int)
    case invalidEnvelopeLength(Int)
    case unsupportedEnvelopeVersion(UInt8)
}

/// The two Chiaki registration secrets stored as one atomic, versioned Keychain value.
public struct PlayStationConsoleRegistration: Equatable, Sendable {
    public static let envelopeVersion: UInt8 = 1
    public static let secretLength = 16
    public static let envelopeLength = 1 + (secretLength * 2)

    public let registrationKey: Data
    public let remotePlayKey: Data

    public init(registrationKey: Data, remotePlayKey: Data) throws {
        guard registrationKey.count == Self.secretLength else {
            throw PlayStationConsoleRegistrationError.invalidRegistrationKeyLength(registrationKey.count)
        }
        guard remotePlayKey.count == Self.secretLength else {
            throw PlayStationConsoleRegistrationError.invalidRemotePlayKeyLength(remotePlayKey.count)
        }
        self.registrationKey = registrationKey
        self.remotePlayKey = remotePlayKey
    }

    public init(envelope: Data) throws {
        guard envelope.count == Self.envelopeLength else {
            throw PlayStationConsoleRegistrationError.invalidEnvelopeLength(envelope.count)
        }
        guard envelope[envelope.startIndex] == Self.envelopeVersion else {
            throw PlayStationConsoleRegistrationError.unsupportedEnvelopeVersion(envelope[envelope.startIndex])
        }

        let registrationStart = envelope.index(after: envelope.startIndex)
        let registrationEnd = envelope.index(registrationStart, offsetBy: Self.secretLength)
        let remotePlayEnd = envelope.index(registrationEnd, offsetBy: Self.secretLength)
        try self.init(
            registrationKey: Data(envelope[registrationStart..<registrationEnd]),
            remotePlayKey: Data(envelope[registrationEnd..<remotePlayEnd])
        )
    }

    public var envelope: Data {
        var data = Data([Self.envelopeVersion])
        data.append(registrationKey)
        data.append(remotePlayKey)
        return data
    }
}
