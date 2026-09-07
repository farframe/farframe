import AccountsAndSecurity
import Foundation
import PlayStationRemotePlay
@testable import PlayStationRemotePlayUI
import Testing

// Home/Away routing and the shared web sign-in identity derivation.
// Addresses use RFC 5737 documentation ranges and documentation host names only.

@Test
func savedConsoleDecodesPreRouteMetadataAsHome() throws {
    let legacyJSON = """
    {"id":"11111111-2222-3333-4444-555555555555","displayName":"Living Room PS5","hostAddress":"192.0.2.20"}
    """
    let console = try JSONDecoder().decode(
        SavedPlayStationConsole.self,
        from: Data(legacyJSON.utf8)
    )

    #expect(console.connectionRoute == .home)
    #expect(console.awayHostAddress == nil)
    #expect(console.activeHostAddress == "192.0.2.20")
    #expect(console.hasAwayAddress == false)
}

@Test
func savedConsoleRoundTripsAwayAddressAndRoute() throws {
    let console = SavedPlayStationConsole(
        displayName: "PS5",
        hostAddress: "192.0.2.20",
        awayHostAddress: "ps5.example.net",
        connectionRoute: .away
    )
    let data = try JSONEncoder().encode(console)
    let decoded = try JSONDecoder().decode(SavedPlayStationConsole.self, from: data)

    #expect(decoded == console)
    #expect(decoded.activeHostAddress == "ps5.example.net")
    #expect(decoded.connectionRoute == .away)
}

@Test
func savedConsoleWithoutAwayAddressNeverResolvesAwayRoute() {
    let blankAway = SavedPlayStationConsole(
        displayName: "PS5",
        hostAddress: "192.0.2.20",
        awayHostAddress: "   ",
        connectionRoute: .away
    )

    #expect(blankAway.awayHostAddress == nil)
    #expect(blankAway.connectionRoute == .home)
    #expect(blankAway.activeHostAddress == "192.0.2.20")
}

@Test
func repositoryUpdatesAddressesWithoutTouchingRegistration() async throws {
    let metadata = InMemoryPlayStationConsoleMetadataStore()
    let credentials = InMemoryCredentialStore()
    let repository = PlayStationConsoleRepository(metadataStore: metadata, credentialStore: credentials)
    let console = SavedPlayStationConsole(displayName: "PS5", hostAddress: "192.0.2.20")
    let registration = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x11, count: 16),
        remotePlayKey: Data(repeating: 0x22, count: 16)
    )
    try await repository.save(console, registration: registration)

    let updated = try await repository.updateConnectionAddresses(
        consoleID: console.id,
        hostAddress: "192.0.2.21",
        awayHostAddress: "ps5.example.net",
        connectionRoute: .away
    )

    #expect(updated.id == console.id)
    #expect(updated.hostAddress == "192.0.2.21")
    #expect(updated.awayHostAddress == "ps5.example.net")
    #expect(updated.connectionRoute == .away)
    #expect(try await repository.consoles() == [updated])
    #expect(try await repository.registration(for: console.id) == registration)
    #expect(try await repository.isRegistered(console.id))

    let cleared = try await repository.updateConnectionAddresses(
        consoleID: console.id,
        hostAddress: "192.0.2.21",
        awayHostAddress: nil,
        connectionRoute: .away
    )
    #expect(cleared.connectionRoute == .home)
    #expect(cleared.awayHostAddress == nil)
}

@Test
func repositoryRejectsEmptyHomeAddressAndUnknownConsole() async throws {
    let console = SavedPlayStationConsole(displayName: "PS5", hostAddress: "192.0.2.20")
    let metadata = InMemoryPlayStationConsoleMetadataStore(consoles: [console])
    let repository = PlayStationConsoleRepository(
        metadataStore: metadata,
        credentialStore: InMemoryCredentialStore()
    )

    await #expect(throws: PlayStationConsoleRepositoryError.invalidHostAddress(console.id)) {
        _ = try await repository.updateConnectionAddresses(
            consoleID: console.id,
            hostAddress: " ",
            awayHostAddress: nil,
            connectionRoute: .home
        )
    }
    let missing = UUID()
    await #expect(throws: PlayStationConsoleRepositoryError.consoleNotFound(missing)) {
        _ = try await repository.updateConnectionAddresses(
            consoleID: missing,
            hostAddress: "192.0.2.20",
            awayHostAddress: nil,
            connectionRoute: .home
        )
    }
    #expect(try await repository.consoles() == [console])
}

@Test
func reRegistrationPreservesAwayAddressAndRoute() async throws {
    let metadata = InMemoryPlayStationConsoleMetadataStore()
    let credentials = InMemoryCredentialStore()
    let repository = PlayStationConsoleRepository(metadataStore: metadata, credentialStore: credentials)
    let console = SavedPlayStationConsole(
        displayName: "PS5",
        hostAddress: "192.0.2.20",
        awayHostAddress: "ps5.example.net",
        connectionRoute: .away
    )
    let first = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x11, count: 16),
        remotePlayKey: Data(repeating: 0x22, count: 16)
    )
    try await repository.save(console, registration: first)

    let second = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x33, count: 16),
        remotePlayKey: Data(repeating: 0x44, count: 16)
    )
    let canonical = try await repository.reconcileAndSavePairing(
        existingConsoleID: console.id,
        hostAddress: "192.0.2.22",
        fallbackDisplayName: "PS5",
        serverNickname: "PS5",
        macAddress: nil,
        registration: second
    )

    #expect(canonical.id == console.id)
    #expect(canonical.hostAddress == "192.0.2.22")
    #expect(canonical.awayHostAddress == "ps5.example.net")
    #expect(canonical.connectionRoute == .away)
    #expect(try await repository.registration(for: console.id) == second)
}

@Test
func webSignInDerivesLittleEndianAccountIDAndSanitizedName() throws {
    let identity = try PlayStationWebSignInService.identity(
        userID: 0x0102_0304_0506_0708,
        onlineID: "  player   one  "
    )

    #expect(identity.accountID.bytes == Data([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]))
    #expect(identity.displayName == "player one")
}

@Test
func webSignInRedirectValidatesStateAndCode() throws {
    let expectedState = "abc123"
    // Build the redirect from the service's own constants so no service
    // configuration literal lives outside the single reviewed source file.
    let redirectBase = "https://" + PlayStationWebSignInService.redirectHost
        + PlayStationWebSignInService.redirectPath
    let success = URL(string: redirectBase + "?code=XYZ&state=abc123")!
    let result = try PlayStationWebSignInService.redirectResult(
        from: success,
        expectedState: expectedState
    )
    guard case let .code(code)? = result else {
        Issue.record("Expected a code result")
        return
    }
    #expect(code == "XYZ")

    let unrelated = URL(string: "https://example.com/other?code=XYZ&state=abc123")!
    #expect(try PlayStationWebSignInService.redirectResult(
        from: unrelated,
        expectedState: expectedState
    ) == nil)

    let mismatched = URL(string: redirectBase + "?code=XYZ&state=other")!
    #expect(throws: PlayStationWebSignInError.mismatchedRequest) {
        _ = try PlayStationWebSignInService.redirectResult(
            from: mismatched,
            expectedState: expectedState
        )
    }
}
