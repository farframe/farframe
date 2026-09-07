import AccountsAndSecurity
import Foundation
import PlayStationRemotePlay
import Testing

@Test
func legacyConsoleMigrationVerifiesSecureRecordsBeforeRemovingLegacyBlob() async throws {
    let records = [legacyRecord(id: "11111111-2222-3333-4444-555555555555")]
    let source = TestLegacyConsoleDataStore(data: try JSONEncoder().encode(records))
    let repository = PlayStationConsoleRepository(
        metadataStore: InMemoryPlayStationConsoleMetadataStore(),
        credentialStore: InMemoryCredentialStore()
    )
    let migrator = LegacyPlayStationConsoleMigrator(source: source, repository: repository)

    #expect(try await migrator.migrate() == .migrated(1))
    #expect(await source.load() == nil)

    let console = try #require(try await repository.consoles().first)
    #expect(console.id == records[0].id)
    #expect(console.displayName == records[0].name)
    #expect(console.hostAddress == records[0].hostAddress)
    #expect(try await repository.registration(for: console.id)?.registrationKey == records[0].registrationKey)
    #expect(try await repository.registration(for: console.id)?.remotePlayKey == records[0].rpKey)
}

@Test
func legacyConsoleMigrationPreflightsEveryRecordBeforeWritingAnything() async throws {
    let valid = legacyRecord(id: "11111111-2222-3333-4444-555555555555")
    let invalid = LegacyPlayStationConsoleRecord(
        id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
        name: "Broken PS5",
        hostAddress: "192.0.2.30",
        macAddress: nil,
        registrationKey: Data(repeating: 0x01, count: 15),
        rpKey: Data(repeating: 0x02, count: 16),
        isRegistered: true
    )
    let source = TestLegacyConsoleDataStore(data: try JSONEncoder().encode([valid, invalid]))
    let repository = PlayStationConsoleRepository(
        metadataStore: InMemoryPlayStationConsoleMetadataStore(),
        credentialStore: InMemoryCredentialStore()
    )
    let migrator = LegacyPlayStationConsoleMigrator(source: source, repository: repository)

    await #expect(throws: LegacyPlayStationConsoleMigrationError.invalidSecretMaterial(invalid.id)) {
        try await migrator.migrate()
    }
    #expect(try await repository.consoles().isEmpty)
    #expect(await source.load() != nil)
}

@Test
func legacyConsoleMigrationIsIdempotentAfterInterruptedCredentialWrite() async throws {
    let records = [
        legacyRecord(id: "11111111-2222-3333-4444-555555555555"),
        legacyRecord(id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
    ]
    let source = TestLegacyConsoleDataStore(data: try JSONEncoder().encode(records))
    let credentials = InterruptibleCredentialStore(failSetCall: 2)
    let repository = PlayStationConsoleRepository(
        metadataStore: InMemoryPlayStationConsoleMetadataStore(),
        credentialStore: credentials
    )
    let migrator = LegacyPlayStationConsoleMigrator(source: source, repository: repository)

    await #expect(throws: InterruptibleCredentialStoreError.setFailed) {
        try await migrator.migrate()
    }
    #expect(await source.load() != nil)
    #expect(try await repository.consoles().count == 1)

    await credentials.clearFailure()
    #expect(try await migrator.migrate() == .migrated(2))
    #expect(try await repository.consoles().count == 2)
    #expect(await source.load() == nil)
}

@Test
func legacyConsoleMigrationRetriesRemovalWithoutLosingMigratedState() async throws {
    let records = [legacyRecord(id: "11111111-2222-3333-4444-555555555555")]
    let source = TestLegacyConsoleDataStore(
        data: try JSONEncoder().encode(records),
        failRemovals: true
    )
    let repository = PlayStationConsoleRepository(
        metadataStore: InMemoryPlayStationConsoleMetadataStore(),
        credentialStore: InMemoryCredentialStore()
    )
    let migrator = LegacyPlayStationConsoleMigrator(source: source, repository: repository)

    await #expect(throws: TestLegacyConsoleDataStoreError.removeFailed) {
        try await migrator.migrate()
    }
    #expect(await source.load() != nil)
    #expect(try await repository.consoles().count == 1)

    await source.allowRemovals()
    #expect(try await migrator.migrate() == .migrated(1))
    #expect(await source.load() == nil)
}

@Test
func legacyConsoleMigrationRejectsDuplicateIdentifiersBeforeWriting() async throws {
    let first = legacyRecord(id: "11111111-2222-3333-4444-555555555555")
    var second = first
    second = LegacyPlayStationConsoleRecord(
        id: first.id,
        name: "Duplicate",
        hostAddress: "192.0.2.50",
        macAddress: nil,
        registrationKey: second.registrationKey,
        rpKey: second.rpKey,
        isRegistered: true
    )
    let source = TestLegacyConsoleDataStore(data: try JSONEncoder().encode([first, second]))
    let repository = PlayStationConsoleRepository(
        metadataStore: InMemoryPlayStationConsoleMetadataStore(),
        credentialStore: InMemoryCredentialStore()
    )
    let migrator = LegacyPlayStationConsoleMigrator(source: source, repository: repository)

    await #expect(throws: LegacyPlayStationConsoleMigrationError.duplicateConsoleID(first.id)) {
        try await migrator.migrate()
    }
    #expect(try await repository.consoles().isEmpty)
    #expect(await source.load() != nil)
}

@Test
func legacyConsoleMigrationRejectsConflictingCanonicalCredentialWithoutOverwrite() async throws {
    let record = legacyRecord(id: "11111111-2222-3333-4444-555555555555")
    let source = TestLegacyConsoleDataStore(data: try JSONEncoder().encode([record]))
    let repository = PlayStationConsoleRepository(
        metadataStore: InMemoryPlayStationConsoleMetadataStore(),
        credentialStore: InMemoryCredentialStore()
    )
    let conflicting = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x33, count: 16),
        remotePlayKey: Data(repeating: 0x44, count: 16)
    )
    let console = SavedPlayStationConsole(
        id: record.id,
        displayName: record.name,
        hostAddress: record.hostAddress,
        macAddress: record.macAddress
    )
    try await repository.save(console, registration: conflicting)
    let migrator = LegacyPlayStationConsoleMigrator(source: source, repository: repository)

    await #expect(
        throws: LegacyPlayStationConsoleMigrationError.conflictingMigratedCredential(record.id)
    ) {
        try await migrator.migrate()
    }
    #expect(try await repository.registration(for: record.id) == conflicting)
    #expect(await source.load() != nil)
}

@Test
func legacyConsoleMigrationDecodesKnownGoodLiteralJSONShape() async throws {
    let legacyJSON = #"[{"id":"11111111-2222-3333-4444-555555555555","name":"Living Room PS5","hostAddress":"192.0.2.20","macAddress":"\#(testHardwareAddress([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]))","registrationKey":"EREREREREREREREREREREQ==","rpKey":"IiIiIiIiIiIiIiIiIiIiIg==","isRegistered":true}]"#
    let source = TestLegacyConsoleDataStore(data: Data(legacyJSON.utf8))
    let repository = PlayStationConsoleRepository(
        metadataStore: InMemoryPlayStationConsoleMetadataStore(),
        credentialStore: InMemoryCredentialStore()
    )
    let migrator = LegacyPlayStationConsoleMigrator(source: source, repository: repository)

    #expect(try await migrator.migrate() == .migrated(1))
    let console = try #require(try await repository.consoles().first)
    #expect(console.id == UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
    #expect(try await repository.registration(for: console.id)?.registrationKey == Data(repeating: 0x11, count: 16))
    #expect(try await repository.registration(for: console.id)?.remotePlayKey == Data(repeating: 0x22, count: 16))
}

@Test
func legacyConsoleMigrationDoesNotRemoveSourceThatChangedMidMigration() async throws {
    let initial = try JSONEncoder().encode([
        legacyRecord(id: "11111111-2222-3333-4444-555555555555"),
    ])
    let changed = try JSONEncoder().encode([
        legacyRecord(id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
    ])
    let source = TestLegacyConsoleDataStore(data: initial)
    let credentials = PausingMigrationCredentialStore()
    let repository = PlayStationConsoleRepository(
        metadataStore: InMemoryPlayStationConsoleMetadataStore(),
        credentialStore: credentials
    )
    let migrator = LegacyPlayStationConsoleMigrator(source: source, repository: repository)

    let migration = Task { try await migrator.migrate() }
    await credentials.waitUntilSetStarts()
    await source.replace(with: changed)
    await credentials.resumeSet()

    await #expect(throws: LegacyPlayStationConsoleMigrationError.legacySourceChanged) {
        try await migration.value
    }
    #expect(await source.load() == changed)
}

private func legacyRecord(id: String) -> LegacyPlayStationConsoleRecord {
    LegacyPlayStationConsoleRecord(
        id: UUID(uuidString: id)!,
        name: "Living Room PS5",
        hostAddress: "192.0.2.20",
        macAddress: testHardwareAddress([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]),
        registrationKey: Data(repeating: 0x11, count: 16),
        rpKey: Data(repeating: 0x22, count: 16),
        isRegistered: true
    )
}

private func testHardwareAddress(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
}

private enum TestLegacyConsoleDataStoreError: Error {
    case removeFailed
}

private actor TestLegacyConsoleDataStore: LegacyPlayStationConsoleDataStore {
    private var data: Data?
    private var failRemovals: Bool

    init(data: Data?, failRemovals: Bool = false) {
        self.data = data
        self.failRemovals = failRemovals
    }

    func load() -> Data? {
        data
    }

    func remove(ifUnchanged expectedData: Data) throws {
        guard failRemovals == false else { throw TestLegacyConsoleDataStoreError.removeFailed }
        guard data == expectedData else {
            throw LegacyPlayStationConsoleMigrationError.legacySourceChanged
        }
        data = nil
    }

    func allowRemovals() {
        failRemovals = false
    }

    func replace(with data: Data?) {
        self.data = data
    }
}

private enum InterruptibleCredentialStoreError: Error {
    case setFailed
}

private actor InterruptibleCredentialStore: CredentialStore {
    private var values: [CredentialKey: Data] = [:]
    private var setCalls = 0
    private var failSetCall: Int?

    init(failSetCall: Int?) {
        self.failSetCall = failSetCall
    }

    func value(for key: CredentialKey) -> Data? {
        values[key]
    }

    func set(_ value: Data, for key: CredentialKey) throws {
        setCalls += 1
        guard setCalls != failSetCall else { throw InterruptibleCredentialStoreError.setFailed }
        values[key] = value
    }

    func removeValue(for key: CredentialKey) {
        values[key] = nil
    }

    func clearFailure() {
        failSetCall = nil
    }
}

private actor PausingMigrationCredentialStore: CredentialStore {
    private var values: [CredentialKey: Data] = [:]
    private var didStartSet = false
    private var setContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func value(for key: CredentialKey) -> Data? {
        values[key]
    }

    func set(_ value: Data, for key: CredentialKey) async {
        if didStartSet == false {
            didStartSet = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                setContinuation = continuation
            }
        }
        values[key] = value
    }

    func removeValue(for key: CredentialKey) {
        values[key] = nil
    }

    func waitUntilSetStarts() async {
        if didStartSet { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeSet() {
        setContinuation?.resume()
        setContinuation = nil
    }
}
