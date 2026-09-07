import Foundation
import PlayStationRemotePlay
import Testing

@Test
func playStationRemotePlayAccountIdentityRequiresValidatedAccountID() throws {
    #expect(throws: PlayStationPairingInputError.invalidAccountID) {
        _ = try PlayStationAccountID(bytes: Data(repeating: 0x01, count: 7))
    }

    let accountID = try PlayStationAccountID(
        bytes: Data([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
    )
    let identity = PlayStationRemotePlayAccountIdentity(
        accountID: accountID,
        displayName: "  Living\tRoom\u{0000}   PS5 \n"
    )

    #expect(identity.accountID == accountID)
    #expect(identity.displayName == "Living Room PS5")
}

@Test
func playStationRemotePlayAccountIdentityBoundsAndOmitsDisplayName() throws {
    let accountID = try PlayStationAccountID(bytes: Data(repeating: 0x02, count: 8))
    let bounded = PlayStationRemotePlayAccountIdentity(
        accountID: accountID,
        displayName: String(repeating: "A", count: 80)
    )
    let omitted = PlayStationRemotePlayAccountIdentity(
        accountID: accountID,
        displayName: " \n\t\u{0000}\r "
    )

    #expect(bounded.displayName == String(repeating: "A", count: 64))
    #expect(omitted.displayName == nil)
}

@Test
func playStationAccountIdentityCapabilityIsExplicit() {
    let available = PlayStationAccountIdentityAcquisitionCapability.available
    let unavailable = PlayStationAccountIdentityAcquisitionCapability.unavailable

    #expect(available.isAvailable)
    #expect(unavailable.isAvailable == false)
}

@MainActor
@Test
func unavailablePlayStationAccountIdentityAcquirerFailsHonestly() async {
    let acquirer = UnavailablePlayStationAccountIdentityAcquirer()

    #expect(acquirer.capability == .unavailable)
    await #expect(throws: PlayStationAccountIdentityAcquisitionError.unavailable) {
        _ = try await acquirer.acquireAccountIdentity()
    }
}

@Test
func playStationRemotePlayAccountIdentityIsIntentionallyNotCodable() throws {
    let identity = PlayStationRemotePlayAccountIdentity(
        accountID: try PlayStationAccountID(bytes: Data(repeating: 0x03, count: 8)),
        displayName: "Living Room"
    )

    #expect(isEncodable(identity) == false)
    #expect(isDecodable(identity) == false)
}

private func isEncodable(_ value: Any) -> Bool {
    value is any Encodable
}

private func isDecodable(_ value: Any) -> Bool {
    value is any Decodable
}
