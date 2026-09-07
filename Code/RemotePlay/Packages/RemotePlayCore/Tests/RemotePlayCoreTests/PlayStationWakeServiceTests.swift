import AccountsAndSecurity
import Foundation
import PlayStationRemotePlay
import Testing

@Test
func wakeServiceUsesSavedHostAndExactRegistrationKey() async throws {
    let console = SavedPlayStationConsole(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Living Room PS5",
        hostAddress: "192.0.2.20"
    )
    let registration = try PlayStationConsoleRegistration(
        registrationKey: Data("2a3b4c5d".utf8) + Data(repeating: 0, count: 8),
        remotePlayKey: Data(repeating: 0x22, count: 16)
    )
    let repository = PlayStationConsoleRepository(
        metadataStore: InMemoryPlayStationConsoleMetadataStore(),
        credentialStore: InMemoryCredentialStore()
    )
    try await repository.save(console, registration: registration)
    let client = RecordingWakeClient()
    let service = PlayStationWakeService(repository: repository, client: client)

    try await service.wake(consoleID: console.id)

    #expect(
        await client.calls() == [
            WakeCall(host: console.hostAddress, registrationKey: registration.registrationKey),
        ]
    )
}

@Test
func wakeServiceFailsClosedWhenRegistrationIsMissing() async throws {
    let console = SavedPlayStationConsole(displayName: "PS5", hostAddress: "192.0.2.20")
    let repository = PlayStationConsoleRepository(
        metadataStore: InMemoryPlayStationConsoleMetadataStore(consoles: [console]),
        credentialStore: InMemoryCredentialStore()
    )
    let client = RecordingWakeClient()
    let service = PlayStationWakeService(repository: repository, client: client)

    await #expect(throws: PlayStationWakeError.registrationMissing(console.id)) {
        try await service.wake(consoleID: console.id)
    }
    #expect(await client.calls().isEmpty)
}

@Test
func wakeServiceFailsClosedWhenConsoleIsMissing() async throws {
    let missingID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    let repository = PlayStationConsoleRepository(
        metadataStore: InMemoryPlayStationConsoleMetadataStore(),
        credentialStore: InMemoryCredentialStore()
    )
    let client = RecordingWakeClient()
    let service = PlayStationWakeService(repository: repository, client: client)

    await #expect(throws: PlayStationWakeError.consoleNotFound(missingID)) {
        try await service.wake(consoleID: missingID)
    }
    #expect(await client.calls().isEmpty)
}

@Test
func nativeWakeClientRejectsInvalidInputsBeforeNetworkWork() async {
    let client = ChiakiPlayStationWakeClient()

    await #expect(throws: PlayStationWakeError.invalidHost) {
        try await client.wake(host: "", registrationKey: Data(repeating: 0x11, count: 16))
    }
    await #expect(throws: PlayStationWakeError.invalidRegistrationKeyLength(15)) {
        try await client.wake(host: "192.0.2.20", registrationKey: Data(repeating: 0x11, count: 15))
    }
}

private struct WakeCall: Equatable, Sendable {
    let host: String
    let registrationKey: Data
}

private actor RecordingWakeClient: PlayStationWakeClient {
    private var recordedCalls: [WakeCall] = []

    func wake(host: String, registrationKey: Data) {
        recordedCalls.append(WakeCall(host: host, registrationKey: registrationKey))
    }

    func calls() -> [WakeCall] {
        recordedCalls
    }
}
