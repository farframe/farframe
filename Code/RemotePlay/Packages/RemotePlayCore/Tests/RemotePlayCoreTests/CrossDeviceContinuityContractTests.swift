import ExperienceDomain
import Foundation
import PlayStationRemotePlay
import Testing

@Test
func crossDevicePlayStationRegistrationRoundTripsWithGenerationIdentity() throws {
    let console = SavedPlayStationConsole(
        displayName: "Living Room PS5",
        hostAddress: "192.0.2.10",
        macAddress: testHardwareAddress([0x00, 0x11, 0x22, 0x33, 0x44, 0x55])
    )
    let registration = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x11, count: 16),
        remotePlayKey: Data(repeating: 0x22, count: 16)
    )
    let generation = UUID()
    let transfer = PlayStationCrossDeviceRegistration(
        console: console,
        credentialGenerationID: generation,
        registration: registration
    )

    let encoded = try JSONEncoder().encode(transfer)
    let decoded = try JSONDecoder().decode(
        PlayStationCrossDeviceRegistration.self,
        from: encoded
    )

    #expect(decoded.console == console)
    #expect(decoded.credentialGenerationID == generation)
    #expect(try decoded.registration() == registration)
}

private func testHardwareAddress(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
}

@Test
func crossDevicePlayStationRegistrationRejectsCorruptedSecretEnvelope() throws {
    let console = SavedPlayStationConsole(
        displayName: "PS5",
        hostAddress: "192.0.2.10"
    )
    let registration = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x11, count: 16),
        remotePlayKey: Data(repeating: 0x22, count: 16)
    )
    let transfer = PlayStationCrossDeviceRegistration(
        console: console,
        registration: registration
    )
    var object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(transfer))
            as? [String: Any]
    )
    object["registrationEnvelope"] = Data([0x01]).base64EncodedString()
    let corrupted = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(
            PlayStationCrossDeviceRegistration.self,
            from: corrupted
        )
    }
}

@Test
func gameplayContinuationDescriptorIsShortLivedAndSecretFreeByConstruction() throws {
    let issuedAt = Date(timeIntervalSince1970: 1_000)
    let descriptor = try GameplayContinuationDescriptor(
        providerID: "playstation.remote-play",
        experienceID: "playstation.remote-play.console-id",
        resourceID: UUID(),
        qualityProfileID: "balanced",
        issuedAt: issuedAt,
        expiresAt: issuedAt.addingTimeInterval(120)
    )

    try descriptor.validate(at: issuedAt.addingTimeInterval(30))
    #expect(throws: GameplayContinuationDescriptorError.expired) {
        try descriptor.validate(at: issuedAt.addingTimeInterval(120))
    }

    let encoded = try JSONEncoder().encode(descriptor)
    #expect(encoded.count < 3_000)
    let keys = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    ).keys
    #expect(Set(keys) == [
        "schemaVersion",
        "providerID",
        "experienceID",
        "resourceID",
        "qualityProfileID",
        "issuedAt",
        "expiresAt",
        "nonce",
    ])
}
