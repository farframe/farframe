import AccountsAndSecurity
import CryptoKit
import Foundation
import PlayStationRemotePlay
import Testing

@Test
func playStationRegistrationEnvelopeIsAtomicAndVersioned() throws {
    let registrationKey = Data(0..<16)
    let remotePlayKey = Data(16..<32)
    let registration = try PlayStationConsoleRegistration(
        registrationKey: registrationKey,
        remotePlayKey: remotePlayKey
    )

    #expect(registration.envelope.count == 33)
    #expect(registration.envelope.first == 1)
    #expect(try PlayStationConsoleRegistration(envelope: registration.envelope) == registration)
}

@Test
func playStationRegistrationRejectsMalformedSecretsAndEnvelopes() {
    #expect(throws: PlayStationConsoleRegistrationError.invalidRegistrationKeyLength(15)) {
        _ = try PlayStationConsoleRegistration(
            registrationKey: Data(repeating: 0, count: 15),
            remotePlayKey: Data(repeating: 0, count: 16)
        )
    }
    #expect(throws: PlayStationConsoleRegistrationError.invalidRemotePlayKeyLength(17)) {
        _ = try PlayStationConsoleRegistration(
            registrationKey: Data(repeating: 0, count: 16),
            remotePlayKey: Data(repeating: 0, count: 17)
        )
    }
    #expect(throws: PlayStationConsoleRegistrationError.invalidEnvelopeLength(32)) {
        _ = try PlayStationConsoleRegistration(envelope: Data(repeating: 0, count: 32))
    }

    var futureEnvelope = Data(repeating: 0, count: 33)
    futureEnvelope[0] = 2
    #expect(throws: PlayStationConsoleRegistrationError.unsupportedEnvelopeVersion(2)) {
        _ = try PlayStationConsoleRegistration(envelope: futureEnvelope)
    }
}

@Test
func savedConsoleMetadataContainsNoRegistrationSecretFields() throws {
    let console = SavedPlayStationConsole(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Living Room PS5",
        hostAddress: "192.0.2.20",
        macAddress: testHardwareAddress([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
    )
    let json = String(decoding: try JSONEncoder().encode(console), as: UTF8.self)

    #expect(json.contains("registrationKey") == false)
    #expect(json.contains("rpKey") == false)
    #expect(json.contains("isRegistered") == false)
}

@Test
func consoleRepositoryVerifiesCredentialBeforeSavingMetadata() async throws {
    let metadata = InMemoryPlayStationConsoleMetadataStore()
    let credentials = InMemoryCredentialStore()
    let repository = PlayStationConsoleRepository(metadataStore: metadata, credentialStore: credentials)
    let console = SavedPlayStationConsole(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Living Room PS5",
        hostAddress: "192.0.2.20",
        macAddress: testHardwareAddress([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
    )
    let registration = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x11, count: 16),
        remotePlayKey: Data(repeating: 0x22, count: 16)
    )

    try await repository.save(console, registration: registration)

    #expect(try await repository.consoles() == [console])
    #expect(await metadata.loadPendingRegistration() == nil)
    #expect(try await repository.registration(for: console.id) == registration)
    #expect(try await repository.isRegistered(console.id))

    var renamed = console
    renamed.displayName = "Office PS5"
    try await repository.save(renamed, registration: registration)
    #expect(try await repository.consoles() == [renamed])

    try await repository.remove(console.id)
    #expect(try await repository.consoles().isEmpty)
    #expect(try await repository.isRegistered(console.id) == false)
}

@Test
func consoleRepositoryDoesNotExposeMetadataWhenCredentialVerificationFails() async throws {
    let metadata = InMemoryPlayStationConsoleMetadataStore()
    let credentials = ControlledCredentialStore(corruptReads: true)
    let repository = PlayStationConsoleRepository(metadataStore: metadata, credentialStore: credentials)
    let console = SavedPlayStationConsole(displayName: "PS5", hostAddress: "192.0.2.20")
    let registration = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x11, count: 16),
        remotePlayKey: Data(repeating: 0x22, count: 16)
    )

    await #expect(throws: PlayStationConsoleRepositoryError.credentialVerificationFailed(console.id)) {
        try await repository.save(console, registration: registration)
    }
    #expect(try await repository.consoles().isEmpty)
}

@Test
func consoleRepositoryDoesNotReportRemovalWhenCredentialDeletionFails() async throws {
    let console = SavedPlayStationConsole(displayName: "PS5", hostAddress: "192.0.2.20")
    let metadata = InMemoryPlayStationConsoleMetadataStore(consoles: [console])
    let credentials = ControlledCredentialStore(failRemovals: true)
    let repository = PlayStationConsoleRepository(metadataStore: metadata, credentialStore: credentials)

    do {
        try await repository.remove(console.id)
        Issue.record("Expected credential deletion failure")
    } catch {
        #expect(try await repository.consoles() == [console])
    }
}

@Test
func consoleRepositoryVerifiesCredentialIsAbsentBeforeRemovingMetadata() async throws {
    let console = SavedPlayStationConsole(displayName: "PS5", hostAddress: "192.0.2.20")
    let metadata = InMemoryPlayStationConsoleMetadataStore()
    let credentials = ControlledCredentialStore(retainValuesOnRemove: true)
    let repository = PlayStationConsoleRepository(metadataStore: metadata, credentialStore: credentials)
    let registration = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x11, count: 16),
        remotePlayKey: Data(repeating: 0x22, count: 16)
    )
    try await repository.save(console, registration: registration)

    await #expect(throws: PlayStationConsoleRepositoryError.credentialDeletionVerificationFailed(console.id)) {
        try await repository.remove(console.id)
    }
    #expect(try await repository.consoles() == [console])
}

@Test
func consoleRepositoryRecoversJournaledRegistrationAfterInterruption() async throws {
    let console = SavedPlayStationConsole(displayName: "PS5", hostAddress: "192.0.2.20")
    let metadata = InMemoryPlayStationConsoleMetadataStore(pendingRegistration: console)
    let credentials = InMemoryCredentialStore()
    let registration = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x11, count: 16),
        remotePlayKey: Data(repeating: 0x22, count: 16)
    )
    let credentialKey = CredentialKey(
        providerID: PlayStationConsoleRepository.providerID,
        accountID: console.id.uuidString.lowercased(),
        purpose: PlayStationConsoleRepository.registrationPurpose
    )
    await credentials.set(registration.envelope, for: credentialKey)
    let repository = PlayStationConsoleRepository(metadataStore: metadata, credentialStore: credentials)

    #expect(
        try await repository.recoverPendingRegistration(expectedRegistration: registration)
            == .completed(console)
    )
    #expect(try await repository.consoles() == [console])
    #expect(await metadata.loadPendingRegistration() == nil)
}

@Test
func consoleRepositoryRetainsJournalWhenRegistrationMustBeRetried() async throws {
    let console = SavedPlayStationConsole(displayName: "PS5", hostAddress: "192.0.2.20")
    let metadata = InMemoryPlayStationConsoleMetadataStore(pendingRegistration: console)
    let repository = PlayStationConsoleRepository(
        metadataStore: metadata,
        credentialStore: InMemoryCredentialStore()
    )

    #expect(try await repository.recoverPendingRegistration() == .needsRegistration(console))
    #expect(try await repository.consoles().isEmpty)
    #expect(await metadata.loadPendingRegistration() == console)
}

@Test
func consoleRepositoryDoesNotMistakeOlderCredentialForPendingReregistration() async throws {
    let console = SavedPlayStationConsole(displayName: "Renamed PS5", hostAddress: "192.0.2.30")
    let metadata = InMemoryPlayStationConsoleMetadataStore(pendingRegistration: console)
    let credentials = InMemoryCredentialStore()
    let olderRegistration = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x11, count: 16),
        remotePlayKey: Data(repeating: 0x22, count: 16)
    )
    let intendedRegistration = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x33, count: 16),
        remotePlayKey: Data(repeating: 0x44, count: 16)
    )
    let credentialKey = CredentialKey(
        providerID: PlayStationConsoleRepository.providerID,
        accountID: console.id.uuidString.lowercased(),
        purpose: PlayStationConsoleRepository.registrationPurpose
    )
    await credentials.set(olderRegistration.envelope, for: credentialKey)
    let repository = PlayStationConsoleRepository(metadataStore: metadata, credentialStore: credentials)

    #expect(
        try await repository.recoverPendingRegistration(expectedRegistration: intendedRegistration)
            == .needsRegistration(console)
    )
    #expect(try await repository.consoles().isEmpty)
    #expect(await metadata.loadPendingRegistration() == console)
    #expect(try await repository.registration(for: console.id) == olderRegistration)
}

@Test
func consoleRepositoryDoesNotOverwriteAnotherPendingRegistration() async throws {
    let pending = SavedPlayStationConsole(displayName: "First PS5", hostAddress: "192.0.2.20")
    let requested = SavedPlayStationConsole(displayName: "Second PS5", hostAddress: "192.0.2.30")
    let metadata = InMemoryPlayStationConsoleMetadataStore(pendingRegistration: pending)
    let repository = PlayStationConsoleRepository(
        metadataStore: metadata,
        credentialStore: InMemoryCredentialStore()
    )
    let registration = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x11, count: 16),
        remotePlayKey: Data(repeating: 0x22, count: 16)
    )

    await #expect(
        throws: PlayStationConsoleRepositoryError.pendingRegistrationConflict(
            existing: pending.id,
            requested: requested.id
        )
    ) {
        try await repository.save(requested, registration: registration)
    }
    #expect(await metadata.loadPendingRegistration() == pending)
}

@Test
func consoleRepositoryRecoversAfterMetadataWriteFailsFollowingCredentialWrite() async throws {
    let console = SavedPlayStationConsole(displayName: "PS5", hostAddress: "192.0.2.20")
    let metadata = FailOnceConsoleMetadataStore()
    let credentials = InMemoryCredentialStore()
    let repository = PlayStationConsoleRepository(metadataStore: metadata, credentialStore: credentials)
    let registration = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x11, count: 16),
        remotePlayKey: Data(repeating: 0x22, count: 16)
    )

    await #expect(throws: TestConsoleMetadataStoreError.saveFailed) {
        try await repository.save(console, registration: registration)
    }
    #expect(try await repository.registration(for: console.id) == registration)
    #expect(await metadata.loadPendingRegistration() == console)
    #expect(try await repository.consoles().isEmpty)

    #expect(
        try await repository.recoverPendingRegistration(expectedRegistration: registration)
            == .completed(console)
    )
    #expect(try await repository.consoles() == [console])
    #expect(await metadata.loadPendingRegistration() == nil)
}

@Test
func consoleRepositoryRecoveryDoesNotDuplicateMetadataBeforeJournalCleanup() async throws {
    let console = SavedPlayStationConsole(displayName: "PS5", hostAddress: "192.0.2.20")
    let metadata = InMemoryPlayStationConsoleMetadataStore(
        consoles: [console],
        pendingRegistration: console
    )
    let credentials = InMemoryCredentialStore()
    let registration = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x11, count: 16),
        remotePlayKey: Data(repeating: 0x22, count: 16)
    )
    let credentialKey = CredentialKey(
        providerID: PlayStationConsoleRepository.providerID,
        accountID: console.id.uuidString.lowercased(),
        purpose: PlayStationConsoleRepository.registrationPurpose
    )
    await credentials.set(registration.envelope, for: credentialKey)
    let repository = PlayStationConsoleRepository(metadataStore: metadata, credentialStore: credentials)

    #expect(
        try await repository.recoverPendingRegistration(expectedRegistration: registration)
            == .completed(console)
    )
    #expect(try await repository.consoles() == [console])
    #expect(await metadata.loadPendingRegistration() == nil)
}

@Test
func consoleRepositorySerializesConcurrentRegistrationMutations() async throws {
    let first = SavedPlayStationConsole(displayName: "First PS5", hostAddress: "192.0.2.20")
    let second = SavedPlayStationConsole(displayName: "Second PS5", hostAddress: "192.0.2.30")
    let metadata = InMemoryPlayStationConsoleMetadataStore()
    let credentials = PausingCredentialStore()
    let repository = PlayStationConsoleRepository(metadataStore: metadata, credentialStore: credentials)
    let registration = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x11, count: 16),
        remotePlayKey: Data(repeating: 0x22, count: 16)
    )

    let firstSave = Task { try await repository.save(first, registration: registration) }
    await credentials.waitUntilFirstSetStarts()
    let secondSave = Task { try await repository.save(second, registration: registration) }
    await Task.yield()
    await credentials.resumeFirstSet()

    try await firstSave.value
    try await secondSave.value
    #expect(try await repository.consoles() == [first, second])
    #expect(await metadata.loadPendingRegistration() == nil)
}

@Test
func consoleRepositoryRejectsDuplicateCanonicalMetadata() async throws {
    let console = SavedPlayStationConsole(displayName: "PS5", hostAddress: "192.0.2.20")
    let repository = PlayStationConsoleRepository(
        metadataStore: InMemoryPlayStationConsoleMetadataStore(consoles: [console, console]),
        credentialStore: InMemoryCredentialStore()
    )

    await #expect(throws: PlayStationConsoleRepositoryError.duplicateMetadata(console.id)) {
        _ = try await repository.consoles()
    }
}

@Test
func userDefaultsConsoleMetadataStoreRoundTripsAndClearsJournal() async throws {
    let suiteName = "RemotePlayCoreTests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsPlayStationConsoleMetadataStore(suiteName: suiteName)
    let console = SavedPlayStationConsole(displayName: "PS5", hostAddress: "192.0.2.20")

    try await store.save([console])
    #expect(try await store.load() == [console])
    try await store.savePendingRegistration(console)
    #expect(try await store.loadPendingRegistration() == console)
    try await store.clearPendingRegistration(ifMatching: console.id)
    #expect(try await store.loadPendingRegistration() == nil)
}

@Test
func userDefaultsConsoleMetadataStoreRoundTripsNonSecretRecoveryTransaction() async throws {
    let suiteName = "RemotePlayCoreTests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsPlayStationConsoleMetadataStore(suiteName: suiteName)
    let console = SavedPlayStationConsole(
        displayName: "PS5",
        hostAddress: "192.0.2.20"
    )
    let registration = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x11, count: 16),
        remotePlayKey: Data(repeating: 0x22, count: 16)
    )
    let transaction = PendingPlayStationConsoleRegistration(
        console: console,
        registrationFingerprint: Data(SHA256.hash(data: registration.envelope))
    )

    try await store.savePendingRegistrationTransaction(transaction)
    #expect(try await store.loadPendingRegistrationTransaction() == transaction)

    let data = try #require(
        UserDefaults(suiteName: suiteName)?.data(
            forKey: UserDefaultsPlayStationConsoleMetadataStore
                .defaultPendingRegistrationKey
        )
    )
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("registrationKey") == false)
    #expect(json.contains("remotePlayKey") == false)
    #expect(json.contains("accountID") == false)
    #expect(json.contains("linkDevicePIN") == false)
}

@Test
func consoleRepositoryRejectsUnknownPendingJournalVersionWithoutMutation() async throws {
    let console = SavedPlayStationConsole(
        displayName: "PS5",
        hostAddress: "192.0.2.20"
    )
    let valid = PendingPlayStationConsoleRegistration(
        console: console,
        registrationFingerprint: Data(repeating: 0x77, count: 32)
    )
    var object = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
            as? [String: Any]
    )
    object["schemaVersion"] = 99
    let unknownVersion = try JSONDecoder().decode(
        PendingPlayStationConsoleRegistration.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
    let metadata = InMemoryPlayStationConsoleMetadataStore()
    try await metadata.savePendingRegistrationTransaction(unknownVersion)
    let repository = PlayStationConsoleRepository(
        metadataStore: metadata,
        credentialStore: InMemoryCredentialStore()
    )

    await #expect(
        throws: PlayStationConsoleRepositoryError.invalidPendingRegistrationJournal(
            console.id
        )
    ) {
        _ = try await repository.recoverPendingRegistration()
    }
    #expect(try await metadata.loadPendingRegistrationTransaction() == unknownVersion)
    #expect(try await repository.consoles().isEmpty)
}

private func testHardwareAddress(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
}

private enum ControlledCredentialStoreError: Error {
    case removalFailed
}

private actor ControlledCredentialStore: CredentialStore {
    private var values: [CredentialKey: Data] = [:]
    private let corruptReads: Bool
    private let failRemovals: Bool
    private let retainValuesOnRemove: Bool

    init(
        corruptReads: Bool = false,
        failRemovals: Bool = false,
        retainValuesOnRemove: Bool = false
    ) {
        self.corruptReads = corruptReads
        self.failRemovals = failRemovals
        self.retainValuesOnRemove = retainValuesOnRemove
    }

    func value(for key: CredentialKey) -> Data? {
        guard let value = values[key] else { return nil }
        return corruptReads ? Data([0xFF]) : value
    }

    func set(_ value: Data, for key: CredentialKey) {
        values[key] = value
    }

    func removeValue(for key: CredentialKey) throws {
        guard failRemovals == false else {
            throw ControlledCredentialStoreError.removalFailed
        }
        if retainValuesOnRemove == false {
            values[key] = nil
        }
    }
}

private enum TestConsoleMetadataStoreError: Error {
    case saveFailed
}

private actor FailOnceConsoleMetadataStore: PlayStationConsoleMetadataStore {
    private var consoles: [SavedPlayStationConsole] = []
    private var pending: PendingPlayStationConsoleRegistration?
    private var shouldFailConsoleSave = true

    func load() -> [SavedPlayStationConsole] {
        consoles
    }

    func save(_ consoles: [SavedPlayStationConsole]) throws {
        if shouldFailConsoleSave {
            shouldFailConsoleSave = false
            throw TestConsoleMetadataStoreError.saveFailed
        }
        self.consoles = consoles
    }

    func loadPendingRegistration() -> SavedPlayStationConsole? {
        pending?.console
    }

    func savePendingRegistration(_ console: SavedPlayStationConsole) {
        pending = PendingPlayStationConsoleRegistration(console: console)
    }

    func loadPendingRegistrationTransaction()
        -> PendingPlayStationConsoleRegistration? {
        pending
    }

    func savePendingRegistrationTransaction(
        _ transaction: PendingPlayStationConsoleRegistration
    ) {
        pending = transaction
    }

    func clearPendingRegistration(ifMatching consoleID: UUID) {
        if pending?.console.id == consoleID {
            pending = nil
        }
    }
}

private actor PausingCredentialStore: CredentialStore {
    private var values: [CredentialKey: Data] = [:]
    private var didStartFirstSet = false
    private var firstSetContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func value(for key: CredentialKey) -> Data? {
        values[key]
    }

    func set(_ value: Data, for key: CredentialKey) async {
        if didStartFirstSet == false {
            didStartFirstSet = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstSetContinuation = continuation
            }
        }
        values[key] = value
    }

    func removeValue(for key: CredentialKey) {
        values[key] = nil
    }

    func waitUntilFirstSetStarts() async {
        if didStartFirstSet { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeFirstSet() {
        firstSetContinuation?.resume()
        firstSetContinuation = nil
    }
}
