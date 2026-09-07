import AccountsAndSecurity
import CryptoKit
import Foundation
import PlayStationRemotePlay
import Testing

@Test
func secureSavePendingClassificationSurvivesErrorImageBoundary() {
    #expect(
        PlayStationPairingError.isSecureSavePending(
            PlayStationPairingError.secureSavePending
        )
    )

    let bridgedBoundaryError = NSError(
        domain: PlayStationPairingError.errorDomain,
        code: PlayStationPairingError.secureSavePending.errorCode,
        userInfo: nil
    )
    #expect(PlayStationPairingError.isSecureSavePending(bridgedBoundaryError))

    let otherPairingError = NSError(
        domain: PlayStationPairingError.errorDomain,
        code: PlayStationPairingError.noPendingSecureSave.errorCode,
        userInfo: nil
    )
    #expect(PlayStationPairingError.isSecureSavePending(otherPairingError) == false)
}

@Test
func secureSaveDiagnosticPreservesClassificationAndOnlySafeErrorFields() {
    for operation in [KeychainOperation.add, .update, .read, .remove] {
        let diagnostic = PlayStationSecureSaveDiagnostic.keychain(
            operation: operation,
            status: -34018
        )
        let error = PlayStationSecureSavePendingError(diagnostic: diagnostic)
        #expect(error.diagnostic == diagnostic)
        #expect(PlayStationPairingError.isSecureSavePending(error))
        #expect(error.errorCode == PlayStationPairingError.secureSavePending.errorCode)
        #expect(Set(error.errorUserInfo.keys) == Set([NSLocalizedDescriptionKey]))
        #expect(error.localizedDescription.contains(operation.rawValue))
        #expect(error.localizedDescription.contains("-34018"))

        let bridged = NSError(
            domain: PlayStationSecureSavePendingError.errorDomain,
            code: error.errorCode,
            userInfo: error.errorUserInfo
        )
        #expect(PlayStationPairingError.isSecureSavePending(bridged))
        #expect(bridged.localizedDescription == error.localizedDescription)
        #expect(bridged.userInfo[NSUnderlyingErrorKey] == nil)
    }
}

@Test(arguments: [KeychainOperation.add, .read])
func pairingServiceReportsKeychainFailureAndRetriesWithoutRegisteringAgain(
    operation: KeychainOperation
) async throws {
    let error = KeychainCredentialStoreError(operation: operation, status: -34018)
    let credentials = DiagnosticFailureCredentialStore(
        setFailure: operation == .add ? error : nil,
        readFailure: operation == .read ? error : nil
    )
    let fixture = try diagnosticPairingFixture(credentials: credentials)

    do {
        _ = try await fixture.service.pair(try pairingRequest())
        Issue.record("Expected the injected secure-save failure")
    } catch let error as PlayStationSecureSavePendingError {
        #expect(error.diagnostic == .keychain(operation: operation, status: -34018))
        #expect(PlayStationPairingError.isSecureSavePending(error))
    }

    #expect(try await fixture.repository.consoles().isEmpty)
    let saved = try await fixture.service.retryPendingSecureSave()
    #expect(await fixture.counter.value == 1)
    #expect(try await fixture.repository.consoles() == [saved])
    #expect(try await fixture.repository.registration(for: saved.id) == pairingRegistration())
    await #expect(throws: PlayStationPairingError.noPendingSecureSave) {
        _ = try await fixture.service.retryPendingSecureSave()
    }
}

@Test(arguments: [
    PlayStationSecureSaveRepositoryFailure.pendingRegistrationVerification,
    .credentialVerification,
    .credentialDeletionVerification,
    .metadataVerification,
    .pendingRegistrationCleanup,
])
func pairingServiceWhitelistsRepositoryDiagnosticsWithoutConsoleIdentifiers(
    failure: PlayStationSecureSaveRepositoryFailure
) async throws {
    let privateConsoleID = UUID()
    let error: PlayStationConsoleRepositoryError
    switch failure {
    case .pendingRegistrationVerification:
        error = .pendingRegistrationVerificationFailed(privateConsoleID)
    case .credentialVerification:
        error = .credentialVerificationFailed(privateConsoleID)
    case .credentialDeletionVerification:
        error = .credentialDeletionVerificationFailed(privateConsoleID)
    case .metadataVerification:
        error = .metadataVerificationFailed(privateConsoleID)
    case .pendingRegistrationCleanup:
        error = .pendingRegistrationCleanupFailed(privateConsoleID)
    }
    let fixture = try diagnosticPairingFixture(
        credentials: DiagnosticFailureCredentialStore(setFailure: error)
    )

    do {
        _ = try await fixture.service.pair(try pairingRequest())
        Issue.record("Expected the injected repository failure")
    } catch let error as PlayStationSecureSavePendingError {
        #expect(error.diagnostic == .repository(failure))
        #expect(PlayStationPairingError.isSecureSavePending(error))
        #expect(error.localizedDescription.contains(failure.rawValue))
        #expect(error.localizedDescription.contains(privateConsoleID.uuidString) == false)
        #expect(String(reflecting: error).contains(privateConsoleID.uuidString) == false)
        #expect(Set(error.errorUserInfo.keys) == Set([NSLocalizedDescriptionKey]))
    }

    _ = try await fixture.service.retryPendingSecureSave()
    #expect(await fixture.counter.value == 1)
}

@Test
func pairingServiceRedactsUnknownPersistenceErrorsAndKeepsRetryAvailable() async throws {
    let privateMarker = "synthetic-private-detail"
    let unknownError = NSError(
        domain: privateMarker,
        code: -99,
        userInfo: [
            NSLocalizedDescriptionKey: privateMarker,
            NSUnderlyingErrorKey: NSError(domain: privateMarker, code: -98),
            "query": privateMarker,
        ]
    )
    let fixture = try diagnosticPairingFixture(
        credentials: DiagnosticFailureCredentialStore(setFailure: unknownError)
    )

    do {
        _ = try await fixture.service.pair(try pairingRequest())
        Issue.record("Expected the injected unknown persistence failure")
    } catch {
        #expect(error as? PlayStationPairingError == .secureSavePending)
        #expect(PlayStationPairingError.isSecureSavePending(error))
        let bridged = error as NSError
        #expect(bridged.domain == PlayStationPairingError.errorDomain)
        #expect(Set(bridged.userInfo.keys) == Set([NSLocalizedDescriptionKey]))
        #expect(bridged.localizedDescription.contains(privateMarker) == false)
        #expect(String(reflecting: error).contains(privateMarker) == false)
    }

    _ = try await fixture.service.retryPendingSecureSave()
    #expect(await fixture.counter.value == 1)
}

@Test
func playStationAccountIDAcceptsCanonicalRepresentationsAndUsesLittleEndianDecimal() throws {
    let expected = Data([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
    #expect(try PlayStationAccountID(manualValue: expected.base64EncodedString()).bytes == expected)
    #expect(try PlayStationAccountID(manualValue: "72623859790382856").bytes == expected)
    #expect(
        try PlayStationAccountID(manualValue: "08070605040302a1").bytes
            == Data([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0xa1])
    )
    #expect(
        try PlayStationAccountID(manualValue: "0x0807060504030201").bytes
            == Data([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
    )
    var decimalLittleEndian = UInt64(1_000_000_000_000_000).littleEndian
    let expectedDecimal = withUnsafeBytes(of: &decimalLittleEndian) { Data($0) }
    #expect(
        try PlayStationAccountID(manualValue: "1000000000000000").bytes
            == expectedDecimal
    )
    #expect(throws: PlayStationPairingInputError.invalidAccountID) {
        _ = try PlayStationAccountID(manualValue: "online-name-is-not-an-account-id")
    }
}

@Test
func linkDevicePINRequiresEightASCIIDigitsAndPreservesLeadingZero() throws {
    #expect(try PlayStationLinkDevicePIN("01234567").digits == "01234567")
    #expect(throws: PlayStationPairingInputError.invalidLinkDevicePIN) {
        _ = try PlayStationLinkDevicePIN("1234567")
    }
    #expect(throws: PlayStationPairingInputError.invalidLinkDevicePIN) {
        _ = try PlayStationLinkDevicePIN("1234567x")
    }
}

@Test
func pairingRepositoryReusesHostIdentityAndAddsCanonicalMAC() async throws {
    let existing = SavedPlayStationConsole(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Old Name",
        hostAddress: " PS5.LOCAL. "
    )
    let metadata = InMemoryPlayStationConsoleMetadataStore(consoles: [existing])
    let credentials = InMemoryCredentialStore()
    let repository = PlayStationConsoleRepository(
        metadataStore: metadata,
        credentialStore: credentials
    )
    let registration = try pairingRegistration()

    let saved = try await repository.reconcileAndSavePairing(
        existingConsoleID: nil,
        hostAddress: "ps5.local",
        fallbackDisplayName: "PlayStation 5",
        serverNickname: "Living Room PS5",
        macAddress: testHardwareAddress(
            [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff],
            separator: "-",
            uppercase: true
        ),
        registration: registration
    )

    #expect(saved.id == existing.id)
    #expect(saved.displayName == "Living Room PS5")
    #expect(saved.macAddress == testHardwareAddress([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]))
    #expect(try await repository.consoles() == [saved])
    #expect(try await repository.registration(for: existing.id) == registration)
}

@Test
func pairingRepositoryUsesMACAcrossAddressChangesAndRemovesSafeDuplicate() async throws {
    let canonical = SavedPlayStationConsole(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "PS5",
        hostAddress: "192.0.2.20",
        macAddress: testHardwareAddress([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
    )
    let duplicate = SavedPlayStationConsole(
        id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
        displayName: "Duplicate",
        hostAddress: "192.0.2.30"
    )
    let metadata = InMemoryPlayStationConsoleMetadataStore(consoles: [canonical, duplicate])
    let credentials = InMemoryCredentialStore()
    let repository = PlayStationConsoleRepository(
        metadataStore: metadata,
        credentialStore: credentials
    )
    let registration = try pairingRegistration()
    try await repository.save(
        duplicate,
        registration: try PlayStationConsoleRegistration(
            registrationKey: Data(repeating: 0x55, count: 16),
            remotePlayKey: Data(repeating: 0x66, count: 16)
        )
    )

    let saved = try await repository.reconcileAndSavePairing(
        existingConsoleID: nil,
        hostAddress: "192.0.2.30",
        fallbackDisplayName: "PS5",
        serverNickname: "PS5-444",
        macAddress: testHardwareAddress([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]),
        registration: registration
    )

    #expect(saved.id == canonical.id)
    #expect(saved.hostAddress == "192.0.2.30")
    #expect(try await repository.consoles() == [saved])
    #expect(try await repository.registration(for: duplicate.id) == nil)
}

@Test
func pairingRepositoryKeepsDuplicateCredentialWhenCanonicalMetadataSaveFails() async throws {
    let canonical = SavedPlayStationConsole(
        displayName: "PS5",
        hostAddress: "192.0.2.20",
        macAddress: testHardwareAddress([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
    )
    let duplicate = SavedPlayStationConsole(
        displayName: "Duplicate",
        hostAddress: "192.0.2.30"
    )
    let metadata = PairingMetadataStoreThatFailsConsoleSave(
        consoles: [canonical, duplicate]
    )
    let credentials = InMemoryCredentialStore()
    let duplicateRegistration = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x55, count: 16),
        remotePlayKey: Data(repeating: 0x66, count: 16)
    )
    let duplicateCredentialKey = CredentialKey(
        providerID: PlayStationConsoleRepository.providerID,
        accountID: duplicate.id.uuidString.lowercased(),
        purpose: PlayStationConsoleRepository.registrationPurpose
    )
    await credentials.set(duplicateRegistration.envelope, for: duplicateCredentialKey)
    let repository = PlayStationConsoleRepository(
        metadataStore: metadata,
        credentialStore: credentials
    )

    await #expect(throws: PairingMetadataFailure.saveFailed) {
        _ = try await repository.reconcileAndSavePairing(
            existingConsoleID: nil,
            hostAddress: duplicate.hostAddress,
            fallbackDisplayName: "PS5",
            serverNickname: "PS5-444",
            macAddress: canonical.macAddress,
            registration: try pairingRegistration()
        )
    }

    #expect(await credentials.value(for: duplicateCredentialKey) == duplicateRegistration.envelope)
    #expect(await metadata.load() == [canonical, duplicate])
}

@Test
func pairingRepositoryRejectsHostCollisionWithDifferentKnownMAC() async throws {
    let existing = SavedPlayStationConsole(
        displayName: "Other PS5",
        hostAddress: "192.0.2.20",
        macAddress: testHardwareAddress([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
    )
    let repository = PlayStationConsoleRepository(
        metadataStore: InMemoryPlayStationConsoleMetadataStore(consoles: [existing]),
        credentialStore: InMemoryCredentialStore()
    )

    await #expect(
        throws: PlayStationConsoleRepositoryError.physicalConsoleIdentityConflict(existing.id)
    ) {
        _ = try await repository.reconcileAndSavePairing(
            existingConsoleID: nil,
            hostAddress: "192.0.2.20",
            fallbackDisplayName: "PS5",
            serverNickname: "PS5",
            macAddress: testHardwareAddress([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]),
            registration: try pairingRegistration()
        )
    }
}

@Test
func pairingRepositoryRejectsExplicitReregistrationThatMatchesAnotherConsoleMAC() async throws {
    let selected = SavedPlayStationConsole(
        displayName: "Selected PS5",
        hostAddress: "192.0.2.20"
    )
    let other = SavedPlayStationConsole(
        displayName: "Other PS5",
        hostAddress: "192.0.2.30",
        macAddress: testHardwareAddress([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
    )
    let repository = PlayStationConsoleRepository(
        metadataStore: InMemoryPlayStationConsoleMetadataStore(consoles: [selected, other]),
        credentialStore: InMemoryCredentialStore()
    )

    await #expect(
        throws: PlayStationConsoleRepositoryError.physicalConsoleIdentityConflict(other.id)
    ) {
        _ = try await repository.reconcileAndSavePairing(
            existingConsoleID: selected.id,
            hostAddress: other.hostAddress,
            fallbackDisplayName: selected.displayName,
            serverNickname: other.displayName,
            macAddress: other.macAddress,
            registration: try pairingRegistration()
        )
    }
}

@Test
func pairingServicePersistsOnlyAfterNativeSuccess() async throws {
    let repository = PlayStationConsoleRepository(
        metadataStore: InMemoryPlayStationConsoleMetadataStore(),
        credentialStore: InMemoryCredentialStore()
    )
    let nativeResult = PlayStationNativeRegistrationResult(
        registration: try pairingRegistration(),
        serverNickname: "PS5-444",
        serverMAC: Data([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
    )
    let service = PlayStationPairingService(
        repository: repository,
        nativeClientFactory: StaticRegistrationFactory(
            client: ImmediateRegistrationClient(result: nativeResult)
        )
    )

    let saved = try await service.pair(try pairingRequest())
    #expect(saved.displayName == "PS5-444")
    #expect(saved.macAddress == testHardwareAddress([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]))
    #expect(try await repository.consoles() == [saved])
    #expect(try await repository.registration(for: saved.id) == nativeResult.registration)
}

@Test
func pairingServiceRetriesSecureSaveWithoutRegisteringThePS5Again() async throws {
    let metadata = PairingMetadataStoreThatFailsOnce()
    let repository = PlayStationConsoleRepository(
        metadataStore: metadata,
        credentialStore: InMemoryCredentialStore()
    )
    let callCounter = RegistrationCallCounter()
    let nativeResult = PlayStationNativeRegistrationResult(
        registration: try pairingRegistration(),
        serverNickname: "PS5-444",
        serverMAC: Data([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
    )
    let service = PlayStationPairingService(
        repository: repository,
        nativeClientFactory: StaticRegistrationFactory(
            client: CountingRegistrationClient(result: nativeResult, counter: callCounter)
        )
    )

    await #expect(throws: PlayStationPairingError.secureSavePending) {
        _ = try await service.pair(try pairingRequest())
    }
    let saved = try await service.retryPendingSecureSave()

    #expect(await callCounter.value == 1)
    #expect(saved.displayName == "PS5-444")
    #expect(try await repository.consoles() == [saved])
    #expect(try await repository.registration(for: saved.id) == nativeResult.registration)
}

@Test
func pairingRepositoryRecoversCurrentJournalAfterProcessStateIsLost() async throws {
    let metadata = PairingMetadataStoreThatFailsOnce()
    let credentials = InMemoryCredentialStore()
    let repository = PlayStationConsoleRepository(
        metadataStore: metadata,
        credentialStore: credentials
    )
    let nativeResult = PlayStationNativeRegistrationResult(
        registration: try pairingRegistration(),
        serverNickname: "PS5-444",
        serverMAC: Data([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
    )
    let service = PlayStationPairingService(
        repository: repository,
        nativeClientFactory: StaticRegistrationFactory(
            client: ImmediateRegistrationClient(result: nativeResult)
        )
    )

    await #expect(throws: PlayStationPairingError.secureSavePending) {
        _ = try await service.pair(try pairingRequest())
    }

    let restartedRepository = PlayStationConsoleRepository(
        metadataStore: metadata,
        credentialStore: credentials
    )
    let recovery = try await restartedRepository.recoverPendingRegistration()
    guard case let .completed(console) = recovery else {
        Issue.record("Expected fingerprint-backed startup recovery")
        return
    }
    #expect(try await restartedRepository.consoles() == [console])
    #expect(try await restartedRepository.registration(for: console.id) == nativeResult.registration)
    #expect(await metadata.loadPendingRegistration() == nil)
}

@Test
func pairingRecoveryClearsMismatchedCurrentJournalWithoutReplacingOlderCredential() async throws {
    let console = SavedPlayStationConsole(
        displayName: "PS5",
        hostAddress: "192.0.2.44"
    )
    let pendingConsole = SavedPlayStationConsole(
        id: console.id,
        displayName: "Renamed PS5",
        hostAddress: "192.0.2.45"
    )
    let oldRegistration = try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x33, count: 16),
        remotePlayKey: Data(repeating: 0x44, count: 16)
    )
    let intendedRegistration = try pairingRegistration()
    let metadata = InMemoryPlayStationConsoleMetadataStore(consoles: [console])
    try await metadata.savePendingRegistrationTransaction(
        PendingPlayStationConsoleRegistration(
            console: pendingConsole,
            previousConsole: console,
            registrationFingerprint: Data(
                SHA256.hash(data: intendedRegistration.envelope)
            )
        )
    )
    let credentials = InMemoryCredentialStore()
    let key = CredentialKey(
        providerID: PlayStationConsoleRepository.providerID,
        accountID: console.id.uuidString.lowercased(),
        purpose: PlayStationConsoleRepository.registrationPurpose
    )
    await credentials.set(oldRegistration.envelope, for: key)
    let repository = PlayStationConsoleRepository(
        metadataStore: metadata,
        credentialStore: credentials
    )

    let recovery = try await repository.recoverPendingRegistration()
    let pendingAfterRecovery = try await metadata.loadPendingRegistrationTransaction()
    #expect(recovery == .needsRegistration(pendingConsole))
    #expect(try await repository.consoles() == [console])
    #expect(try await repository.registration(for: console.id) == oldRegistration)
    #expect(pendingAfterRecovery == nil)
}

@Test
func pairingRetryFinishesSupersededCredentialCleanupWithoutRegisteringAgain() async throws {
    let canonical = SavedPlayStationConsole(
        displayName: "PS5",
        hostAddress: "192.0.2.20",
        macAddress: testHardwareAddress([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
    )
    let duplicate = SavedPlayStationConsole(
        displayName: "Duplicate",
        hostAddress: "192.0.2.44"
    )
    let metadata = InMemoryPlayStationConsoleMetadataStore(
        consoles: [canonical, duplicate]
    )
    let duplicateKey = CredentialKey(
        providerID: PlayStationConsoleRepository.providerID,
        accountID: duplicate.id.uuidString.lowercased(),
        purpose: PlayStationConsoleRepository.registrationPurpose
    )
    let credentials = FailCredentialRemovalStore(
        failingKey: duplicateKey,
        remainingFailures: 2
    )
    await credentials.set(
        try PlayStationConsoleRegistration(
            registrationKey: Data(repeating: 0x55, count: 16),
            remotePlayKey: Data(repeating: 0x66, count: 16)
        ).envelope,
        for: duplicateKey
    )
    let repository = PlayStationConsoleRepository(
        metadataStore: metadata,
        credentialStore: credentials
    )
    let counter = RegistrationCallCounter()
    let nativeResult = PlayStationNativeRegistrationResult(
        registration: try pairingRegistration(),
        serverNickname: "PS5-444",
        serverMAC: Data([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
    )
    let service = PlayStationPairingService(
        repository: repository,
        nativeClientFactory: StaticRegistrationFactory(
            client: CountingRegistrationClient(result: nativeResult, counter: counter)
        )
    )

    await #expect(throws: PlayStationPairingError.secureSavePending) {
        _ = try await service.pair(try pairingRequest())
    }
    await #expect(throws: PlayStationPairingError.secureSavePending) {
        _ = try await service.retryPendingSecureSave()
    }
    let saved = try await service.retryPendingSecureSave()

    #expect(await counter.value == 1)
    #expect(saved.id == canonical.id)
    #expect(try await repository.consoles() == [saved])
    #expect(await credentials.value(for: duplicateKey) == nil)
    #expect(await metadata.loadPendingRegistration() == nil)
}

@Test
func pairingServiceRejectsConcurrentPairAndCancelsCleanly() async throws {
    let repository = PlayStationConsoleRepository(
        metadataStore: InMemoryPlayStationConsoleMetadataStore(),
        credentialStore: InMemoryCredentialStore()
    )
    let service = PlayStationPairingService(
        repository: repository,
        nativeClientFactory: StaticRegistrationFactory(client: SlowRegistrationClient()),
        timeout: .seconds(5)
    )
    let request = try pairingRequest()
    let first = Task { try await service.pair(request) }
    try await Task.sleep(for: .milliseconds(30))

    await #expect(throws: PlayStationPairingError.alreadyInProgress) {
        _ = try await service.pair(request)
    }
    first.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await first.value
    }
    #expect(try await repository.consoles().isEmpty)
}

private func pairingRegistration() throws -> PlayStationConsoleRegistration {
    try PlayStationConsoleRegistration(
        registrationKey: Data(repeating: 0x11, count: 16),
        remotePlayKey: Data(repeating: 0x22, count: 16)
    )
}

private func testHardwareAddress(
    _ bytes: [UInt8],
    separator: String = ":",
    uppercase: Bool = false
) -> String {
    let format = uppercase ? "%02X" : "%02x"
    return bytes.map { String(format: format, $0) }.joined(separator: separator)
}

private func pairingRequest() throws -> PlayStationPairingRequest {
    try PlayStationPairingRequest(
        hostAddress: "192.0.2.44",
        accountID: PlayStationAccountID(bytes: Data(0..<8)),
        pin: PlayStationLinkDevicePIN("01234567")
    )
}

private func diagnosticPairingFixture(credentials: any CredentialStore) throws -> (
    service: PlayStationPairingService,
    repository: PlayStationConsoleRepository,
    counter: RegistrationCallCounter
) {
    let repository = PlayStationConsoleRepository(
        metadataStore: InMemoryPlayStationConsoleMetadataStore(),
        credentialStore: credentials
    )
    let counter = RegistrationCallCounter()
    let nativeResult = PlayStationNativeRegistrationResult(
        registration: try pairingRegistration(),
        serverNickname: "PS5",
        serverMAC: Data(repeating: 0, count: 6)
    )
    let service = PlayStationPairingService(
        repository: repository,
        nativeClientFactory: StaticRegistrationFactory(
            client: CountingRegistrationClient(result: nativeResult, counter: counter)
        )
    )
    return (service, repository, counter)
}

/// Injects one failure without calling Security.framework or accessing Keychain.
private actor DiagnosticFailureCredentialStore: CredentialStore {
    private var values: [CredentialKey: Data] = [:]
    private var setFailure: (any Error)?
    private var readFailure: (any Error)?

    init(setFailure: (any Error)? = nil, readFailure: (any Error)? = nil) {
        self.setFailure = setFailure
        self.readFailure = readFailure
    }

    func value(for key: CredentialKey) throws -> Data? {
        if let readFailure {
            self.readFailure = nil
            throw readFailure
        }
        return values[key]
    }

    func set(_ value: Data, for key: CredentialKey) throws {
        if let setFailure {
            self.setFailure = nil
            throw setFailure
        }
        values[key] = value
    }

    func removeValue(for key: CredentialKey) {
        values[key] = nil
    }
}

private struct StaticRegistrationFactory: PlayStationNativeRegistrationClientFactory {
    let client: any PlayStationNativeRegistrationClient

    func makeClient() -> any PlayStationNativeRegistrationClient { client }
}

private struct ImmediateRegistrationClient: PlayStationNativeRegistrationClient {
    let result: PlayStationNativeRegistrationResult

    func register(_ request: PlayStationPairingRequest) async throws
        -> PlayStationNativeRegistrationResult {
        _ = request
        return result
    }
}

private actor RegistrationCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private struct CountingRegistrationClient: PlayStationNativeRegistrationClient {
    let result: PlayStationNativeRegistrationResult
    let counter: RegistrationCallCounter

    func register(_ request: PlayStationPairingRequest) async throws
        -> PlayStationNativeRegistrationResult {
        _ = request
        await counter.increment()
        return result
    }
}

private struct SlowRegistrationClient: PlayStationNativeRegistrationClient {
    func register(_ request: PlayStationPairingRequest) async throws
        -> PlayStationNativeRegistrationResult {
        _ = request
        try await Task.sleep(for: .seconds(10))
        return PlayStationNativeRegistrationResult(
            registration: try pairingRegistration(),
            serverNickname: "PS5",
            serverMAC: Data(repeating: 0, count: 6)
        )
    }
}

private enum PairingMetadataFailure: Error {
    case saveFailed
}

private actor PairingMetadataStoreThatFailsConsoleSave: PlayStationConsoleMetadataStore {
    private let consoles: [SavedPlayStationConsole]
    private var pending: PendingPlayStationConsoleRegistration?

    init(consoles: [SavedPlayStationConsole]) {
        self.consoles = consoles
    }

    func load() -> [SavedPlayStationConsole] { consoles }

    func save(_ consoles: [SavedPlayStationConsole]) throws {
        _ = consoles
        throw PairingMetadataFailure.saveFailed
    }

    func loadPendingRegistration() -> SavedPlayStationConsole? { pending?.console }

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

private actor PairingMetadataStoreThatFailsOnce: PlayStationConsoleMetadataStore {
    private var consoles: [SavedPlayStationConsole] = []
    private var pending: PendingPlayStationConsoleRegistration?
    private var shouldFail = true

    func load() -> [SavedPlayStationConsole] { consoles }

    func save(_ consoles: [SavedPlayStationConsole]) throws {
        if shouldFail {
            shouldFail = false
            throw PairingMetadataFailure.saveFailed
        }
        self.consoles = consoles
    }

    func loadPendingRegistration() -> SavedPlayStationConsole? { pending?.console }

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

private enum FailCredentialRemovalStoreError: Error {
    case injectedFailure
}

private actor FailCredentialRemovalStore: CredentialStore {
    private var values: [CredentialKey: Data] = [:]
    private let failingKey: CredentialKey
    private var remainingFailures: Int

    init(failingKey: CredentialKey, remainingFailures: Int) {
        self.failingKey = failingKey
        self.remainingFailures = remainingFailures
    }

    func value(for key: CredentialKey) -> Data? {
        values[key]
    }

    func set(_ value: Data, for key: CredentialKey) {
        values[key] = value
    }

    func removeValue(for key: CredentialKey) throws {
        if key == failingKey, remainingFailures > 0 {
            remainingFailures -= 1
            throw FailCredentialRemovalStoreError.injectedFailure
        }
        values[key] = nil
    }
}
