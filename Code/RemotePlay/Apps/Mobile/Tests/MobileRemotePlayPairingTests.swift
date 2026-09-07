import ExperienceDomain
import Foundation
import InputCore
import PlayStationRemotePlay
import Testing
@testable import RemotePlayMobile

@Suite("Mobile Remote Play pairing", .serialized)
@MainActor
struct MobileRemotePlayPairingTests {
    @Test("Local Network preflight runs exactly once per presentation")
    func localNetworkPreflightRunsExactlyOnce() async {
        let gate = PairingTestGate()
        let effects = PairingEffects(preflightGate: gate)
        let fixture = makeFixture(effects: effects)
        await fixture.coordinator.prepare()
        let model = MobilePlayStationPairingModel(
            coordinator: fixture.coordinator,
            target: MobilePairingTarget()
        )

        let first = Task { await model.prepareLocalNetwork() }
        await gate.waitUntilEntered()
        let duplicate = Task { await model.prepareLocalNetwork() }
        await Task.yield()

        #expect(await effects.preflightCount == 1)
        await gate.open()
        await first.value
        await duplicate.value
        await model.prepareLocalNetwork()

        #expect(await effects.preflightCount == 1)
        #expect(model.localNetworkPreflightCompleted)
        #expect(model.localNetworkPreflightSucceeded)
    }

    @Test("Already-cancelled preparation never dispatches a network trigger")
    func alreadyCancelledPreparationDoesNotDispatch() async {
        let effects = PairingEffects()
        let fixture = makeFixture(effects: effects)
        await fixture.coordinator.prepare()
        let model = makeReadyModel(coordinator: fixture.coordinator)

        // Both this test and the new task are MainActor-isolated, so cancel
        // synchronously before yielding the actor to the task.
        let preparation = Task { @MainActor in
            await model.prepareLocalNetwork()
        }
        preparation.cancel()
        await preparation.value

        #expect(await effects.preflightCount == 0)
        #expect(model.localNetworkPreflightCompleted == false)
        #expect(model.localNetworkPreflightSucceeded == false)

        // Cancellation must not consume the model's one completed attempt.
        await model.prepareLocalNetwork()
        #expect(await effects.preflightCount == 1)
        #expect(model.localNetworkPreflightCompleted)
    }

    @Test(
        "Interrupted preparation rejects late results and permits a returning view",
        arguments: [false, true]
    )
    func interruptedPreflightCanPrepareAgain(cancelViaButton: Bool) async {
        let gate = PairingTestGate()
        let effects = PairingEffects(preflightGate: gate)
        let fixture = makeFixture(effects: effects)
        await fixture.coordinator.prepare()
        let model = makeReadyModel(coordinator: fixture.coordinator)

        let preparation = Task { await model.prepareLocalNetwork() }
        await gate.waitUntilEntered()
        #expect(await effects.preflightCount == 1)

        if cancelViaButton {
            #expect(await model.cancelAndWait())
        } else {
            model.presentationDidDisappear()
        }
        #expect(model.localNetworkPreflightCompleted == false)

        // The injected dependency intentionally ignores task cancellation.
        // Releasing it models a syscall completion arriving after dismissal.
        await gate.open()
        await preparation.value
        #expect(model.localNetworkPreflightCompleted == false)
        #expect(model.localNetworkPreflightSucceeded == false)
        #expect(await effects.preflightCount == 1)

        await model.prepareLocalNetwork()
        await model.prepareLocalNetwork()
        #expect(await effects.preflightCount == 2)
        #expect(model.localNetworkPreflightCompleted)
        #expect(model.localNetworkPreflightSucceeded)

        let freshModel = makeReadyModel(coordinator: fixture.coordinator)
        await freshModel.prepareLocalNetwork()
        #expect(await effects.preflightCount == 3)
        #expect(freshModel.localNetworkPreflightCompleted)
    }

    @Test(
        "Completed preparation stays exact-once after disappearance",
        arguments: [false, true]
    )
    func completedPreflightIsNotRepeated(result: Bool) async {
        let effects = PairingEffects(preflightResult: result)
        let fixture = makeFixture(effects: effects)
        await fixture.coordinator.prepare()
        let model = makeReadyModel(coordinator: fixture.coordinator)

        await model.prepareLocalNetwork()
        model.presentationDidDisappear()
        await model.prepareLocalNetwork()

        #expect(await effects.preflightCount == 1)
        #expect(model.localNetworkPreflightCompleted)
        #expect(model.localNetworkPreflightSucceeded == result)
    }

    @Test("A failed early network probe does not block direct pairing")
    func failedPreflightStillAllowsPairing() async throws {
        let saved = testSavedConsole()
        let effects = PairingEffects(
            preflightResult: false,
            identityOutcome: .success(try testIdentity()),
            pairOutcome: .success(saved)
        )
        let fixture = makeFixture(
            startups: [
                MobileStartupSnapshot(consoles: []),
                MobileStartupSnapshot(consoles: [summary(saved)]),
            ],
            effects: effects
        )
        await fixture.coordinator.prepare()
        let model = makeReadyModel(coordinator: fixture.coordinator)
        #expect(model.canPair == false)

        await prepareForPairing(model)

        #expect(model.localNetworkPreflightCompleted)
        #expect(model.localNetworkPreflightSucceeded == false)
        #expect(model.canPair)
        await model.pair()
        #expect(await effects.pairCount == 1)
        #expect(model.status == .paired(name: saved.displayName, consoleID: saved.id))
    }

    @Test("Unavailable identity is honest and an available identity stays hidden")
    func accountIdentityCapabilityAndForwarding() async throws {
        let unavailableEffects = PairingEffects(
            identityCapability: .unavailable,
            identityOutcome: .failure(.ordinary)
        )
        let unavailableFixture = makeFixture(effects: unavailableEffects)
        await unavailableFixture.coordinator.prepare()
        let unavailableModel = MobilePlayStationPairingModel(
            coordinator: unavailableFixture.coordinator,
            target: MobilePairingTarget()
        )

        #expect(unavailableModel.accountIdentityCapability == .unavailable)
        await unavailableModel.acquireAccountIdentity()
        #expect(unavailableModel.hasAccountIdentity == false)
        #expect(unavailableModel.accountDisplayName == nil)
        #expect(
            unavailableModel.errorMessage ==
                PlayStationAccountIdentityAcquisitionError.unavailable.localizedDescription
        )
        #expect(await unavailableEffects.identityAcquisitionCount == 0)

        let identity = try testIdentity(displayName: "Living Room Player")
        let availableEffects = PairingEffects(
            identityCapability: .available,
            identityOutcome: .success(identity)
        )
        let availableFixture = makeFixture(effects: availableEffects)
        await availableFixture.coordinator.prepare()
        let availableModel = MobilePlayStationPairingModel(
            coordinator: availableFixture.coordinator,
            target: MobilePairingTarget()
        )

        await availableModel.acquireAccountIdentity()

        #expect(availableModel.hasAccountIdentity)
        #expect(availableModel.accountDisplayName == "Living Room Player")
        #expect(await availableEffects.identityAcquisitionCount == 1)
    }

    @Test("Manual Account ID supports source-safe customer pairing without sign-in")
    func manualAccountIDFallback() async throws {
        let effects = PairingEffects(identityCapability: .unavailable)
        let fixture = makeFixture(effects: effects)
        await fixture.coordinator.prepare()
        let model = MobilePlayStationPairingModel(
            coordinator: fixture.coordinator,
            target: MobilePairingTarget()
        )
        let accountBytes = Data([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])

        model.advancedAccountEntryIsExpanded = true
        model.manualAccountID = accountBytes.base64EncodedString()
        model.manualAccountDisplayName = "  Engineer  "
        model.applyManualAccountID()

        #expect(model.hasAccountIdentity)
        #expect(model.accountDisplayName == "Engineer")
        #expect(model.advancedAccountEntryIsExpanded == false)
        #expect(model.errorMessage == nil)
        #expect(await effects.identityAcquisitionCount == 0)

        model.manualAccountID = "not-an-account-id"
        model.applyManualAccountID()
        #expect(model.hasAccountIdentity == false)
        #expect(model.errorMessage != nil)
    }

    @Test("Host and PIN validation preserve an eight-digit leading-zero PIN")
    func hostAndPINValidation() async throws {
        let saved = testSavedConsole(name: "Paired PS5")
        let identity = try testIdentity()
        let effects = PairingEffects(
            identityOutcome: .success(identity),
            pairOutcome: .success(saved)
        )
        let pairedSummary = summary(saved)
        let fixture = makeFixture(
            startups: [
                MobileStartupSnapshot(consoles: []),
                MobileStartupSnapshot(consoles: [pairedSummary]),
            ],
            effects: effects
        )
        await fixture.coordinator.prepare()
        let model = MobilePlayStationPairingModel(
            coordinator: fixture.coordinator,
            target: MobilePairingTarget()
        )
        await model.prepareLocalNetwork()
        await model.acquireAccountIdentity()

        model.hostAddress = "   "
        model.linkDevicePIN = "0a1b23456789"
        #expect(model.linkDevicePIN == "01234567")
        #expect(model.canPair == false)

        model.hostAddress = " 192.0.2.50 "
        model.displayName = " Living Room PS5 "
        #expect(model.canPair)
        await model.pair()

        let request = await effects.pairRequests.first
        #expect(request?.hostAddress == "192.0.2.50")
        #expect(request?.fallbackDisplayName == "Living Room PS5")
        #expect(request?.pin.digits == "01234567")
        #expect(request?.accountID == identity.accountID)
    }

    @Test("Duplicate Pair actions reserve one registration operation")
    func duplicatePairIsSuppressed() async throws {
        let pairGate = PairingTestGate()
        let saved = testSavedConsole()
        let effects = PairingEffects(
            identityOutcome: .success(try testIdentity()),
            pairOutcome: .success(saved),
            pairGate: pairGate
        )
        let fixture = makeFixture(
            startups: [
                MobileStartupSnapshot(consoles: []),
                MobileStartupSnapshot(consoles: [summary(saved)]),
            ],
            effects: effects
        )
        await fixture.coordinator.prepare()
        let model = makeReadyModel(coordinator: fixture.coordinator)
        await prepareForPairing(model)

        let first = Task { await model.pair() }
        await pairGate.waitUntilEntered()
        let duplicate = Task { await model.pair() }
        await duplicate.value

        #expect(model.status == .pairing)
        #expect(fixture.coordinator.registrationOperationIsActive)
        #expect(await effects.pairCount == 1)

        await pairGate.open()
        await first.value
        #expect(model.status == .paired(name: saved.displayName, consoleID: saved.id))
        #expect(await effects.pairCount == 1)
    }

    @Test("Cancel owns one Pair task and ignores its stale success")
    func cancelOnceAndIgnoreStaleCompletion() async throws {
        let pairGate = PairingTestGate()
        let saved = testSavedConsole()
        let effects = PairingEffects(
            identityOutcome: .success(try testIdentity()),
            pairOutcome: .success(saved),
            pairGate: pairGate
        )
        let fixture = makeFixture(effects: effects)
        await fixture.coordinator.prepare()
        let model = makeReadyModel(coordinator: fixture.coordinator)
        await prepareForPairing(model)

        let pairing = Task { await model.pair() }
        await pairGate.waitUntilEntered()
        let cancellation = Task { await model.cancelAndWait() }
        let duplicateCancellation = Task { await model.cancelAndWait() }
        await Task.yield()
        #expect(model.status == .canceling)

        await pairGate.open()
        await pairing.value
        _ = await cancellation.value
        _ = await duplicateCancellation.value

        #expect(await effects.pairCount == 1)
        #expect(await effects.canceledPairCompletionCount == 1)
        #expect(model.status == .editing)
        #expect(model.hasAccountIdentity == false)
        #expect(model.linkDevicePIN.isEmpty)
        #expect(fixture.coordinator.consoles.isEmpty)
        #expect(fixture.coordinator.registrationOperationIsActive == false)
    }

    @Test("Ordinary pairing failure clears only the PIN and remains retryable")
    func ordinaryFailureClearsOnlyPIN() async throws {
        let identity = try testIdentity(displayName: "Player")
        let effects = PairingEffects(
            identityOutcome: .success(identity),
            pairOutcome: .failure(.ordinary)
        )
        let fixture = makeFixture(effects: effects)
        await fixture.coordinator.prepare()
        let model = makeReadyModel(coordinator: fixture.coordinator)
        await prepareForPairing(model)
        model.displayName = "Bedroom PS5"

        await model.pair()

        #expect(model.status == .editing)
        #expect(model.linkDevicePIN.isEmpty)
        #expect(model.hasAccountIdentity)
        #expect(model.accountDisplayName == "Player")
        #expect(model.hostAddress == "192.0.2.50")
        #expect(model.displayName == "Bedroom PS5")
        #expect(model.errorMessage == PairingTestFailure.ordinary.localizedDescription)
        #expect(fixture.coordinator.pairingSecureSaveIsPending == false)
    }

    @Test("Secure-save retry does not register the PS5 a second time")
    func secureSaveRetryDoesNotPairAgain() async throws {
        let saved = testSavedConsole(name: "Recovered PS5")
        let alpha = testSavedConsole(name: "Alpha")
        let effects = PairingEffects(
            identityOutcome: .success(try testIdentity()),
            pairOutcome: .secureSavePending,
            retryOutcome: .success(saved)
        )
        let fixture = makeFixture(
            startups: [
                MobileStartupSnapshot(consoles: []),
                MobileStartupSnapshot(consoles: [summary(saved), summary(alpha)]),
            ],
            effects: effects
        )
        await fixture.coordinator.prepare()
        let model = makeReadyModel(coordinator: fixture.coordinator)
        await prepareForPairing(model)

        await model.pair()
        #expect(model.secureSaveIsPending)
        #expect(model.hasAccountIdentity == false)
        #expect(model.linkDevicePIN.isEmpty)
        #expect(await effects.pairCount == 1)
        #expect(fixture.coordinator.pairingSecureSaveIsPending)

        await model.retryPendingSecureSave()

        #expect(model.status == .paired(name: saved.displayName, consoleID: saved.id))
        #expect(await effects.pairCount == 1)
        #expect(await effects.retryCount == 1)
        #expect(fixture.coordinator.consoles.map(\.name) == ["Alpha", "Recovered PS5"])
        #expect(fixture.coordinator.pairingSecureSaveIsPending == false)
    }

    @Test("Fatal secure-save retry failure returns to dismissible pairing")
    func fatalSecureSaveRetryFailureIsDismissible() async throws {
        let effects = PairingEffects(
            identityOutcome: .success(try testIdentity()),
            pairOutcome: .secureSavePending,
            retryOutcome: .failure(.ordinary)
        )
        let fixture = makeFixture(effects: effects)
        await fixture.coordinator.prepare()
        let model = makeReadyModel(coordinator: fixture.coordinator)
        await prepareForPairing(model)

        await model.pair()
        #expect(model.secureSaveIsPending)

        await model.retryPendingSecureSave()

        #expect(model.status == .editing)
        #expect(model.secureSaveIsPending == false)
        #expect(model.operationIsActive == false)
        #expect(model.errorMessage == PairingTestFailure.ordinary.localizedDescription)
        #expect(fixture.coordinator.pairingSecureSaveIsPending == false)
        #expect(await effects.pairCount == 1)
        #expect(await effects.retryCount == 1)
    }

    @Test("Cancel cannot orphan Pair secure-save recovery")
    func cancelKeepsPairSecureSaveRecoveryVisible() async throws {
        let pairGate = PairingTestGate()
        let effects = PairingEffects(
            identityOutcome: .success(try testIdentity()),
            pairOutcome: .secureSavePending,
            pairGate: pairGate
        )
        let fixture = makeFixture(effects: effects)
        await fixture.coordinator.prepare()
        let model = makeReadyModel(coordinator: fixture.coordinator)
        await prepareForPairing(model)

        let pairing = Task { await model.pair() }
        await pairGate.waitUntilEntered()
        let cancellation = Task { await model.cancelAndWait() }
        while model.status != .canceling { await Task.yield() }
        await pairGate.open()
        await pairing.value

        #expect(await cancellation.value == false)
        #expect(model.secureSaveIsPending)
        #expect(model.operationIsActive == false)
        #expect(fixture.coordinator.pairingSecureSaveIsPending)
        #expect(await effects.pairCount == 1)
    }

    @Test("Cancel cannot orphan retry secure-save recovery")
    func cancelKeepsRetrySecureSaveRecoveryVisible() async throws {
        let retryGate = PairingTestGate()
        let effects = PairingEffects(
            identityOutcome: .success(try testIdentity()),
            pairOutcome: .secureSavePending,
            retryOutcome: .secureSavePending,
            retryGate: retryGate
        )
        let fixture = makeFixture(effects: effects)
        await fixture.coordinator.prepare()
        let model = makeReadyModel(coordinator: fixture.coordinator)
        await prepareForPairing(model)
        await model.pair()
        #expect(model.secureSaveIsPending)

        let retry = Task { await model.retryPendingSecureSave() }
        await retryGate.waitUntilEntered()
        let cancellation = Task { await model.cancelAndWait() }
        while model.status != .canceling { await Task.yield() }
        await retryGate.open()
        await retry.value

        #expect(await cancellation.value == false)
        #expect(model.secureSaveIsPending)
        #expect(model.operationIsActive == false)
        #expect(fixture.coordinator.pairingSecureSaveIsPending)
        #expect(await effects.pairCount == 1)
        #expect(await effects.retryCount == 1)
    }

    @Test("Successful Pair clears transient identity and reloads sorted consoles")
    func successfulPairClearsTransientsAndReloadsConsoles() async throws {
        let saved = testSavedConsole(name: "Zulu")
        let alpha = testSavedConsole(name: "alpha")
        let effects = PairingEffects(
            identityOutcome: .success(try testIdentity(displayName: "Player")),
            pairOutcome: .success(saved)
        )
        let fixture = makeFixture(
            startups: [
                MobileStartupSnapshot(consoles: []),
                MobileStartupSnapshot(consoles: [summary(saved), summary(alpha)]),
            ],
            effects: effects
        )
        await fixture.coordinator.prepare()
        let model = makeReadyModel(coordinator: fixture.coordinator)
        await prepareForPairing(model)

        await model.pair()

        #expect(model.status == .paired(name: "Zulu", consoleID: saved.id))
        #expect(model.hasAccountIdentity == false)
        #expect(model.accountDisplayName == nil)
        #expect(model.linkDevicePIN.isEmpty)
        #expect(model.operationIsActive == false)
        #expect(fixture.coordinator.consoles.map(\.name) == ["alpha", "Zulu"])
        #expect(await fixture.startups.loadCount == 2)
    }

    @Test("Recovery uses a pending ID only when it is canonical")
    func recoveryTargetRequiresCanonicalConsoleID() {
        let pendingID = UUID()
        let otherID = UUID()

        #expect(
            MobilePairingTarget.canonicalRecoveryConsoleID(
                pendingConsoleID: pendingID,
                canonicalConsoleIDs: [pendingID, otherID]
            ) == pendingID
        )
        #expect(
            MobilePairingTarget.canonicalRecoveryConsoleID(
                pendingConsoleID: pendingID,
                canonicalConsoleIDs: [otherID]
            ) == nil
        )
    }

    @Test("Connect handoff is consumed only after pairing sheet dismissal")
    func connectWaitsForPairingSheetDismissal() {
        let consoleID = UUID()
        var handoff = MobilePairingConnectHandoff()

        #expect(handoff.pairingSheetDismissed() == nil)
        handoff.pairingCompleted(consoleID: consoleID)
        #expect(handoff.pendingConsoleID == consoleID)

        #expect(handoff.pairingSheetDismissed() == consoleID)
        #expect(handoff.pendingConsoleID == nil)
        #expect(handoff.pairingSheetDismissed() == nil)
    }

    @Test("Active Remote Play blocks Pair, re-register, retry, and removal")
    func activeSessionGuardsRegistrationMutations() async throws {
        let console = MobileConsoleSummary(
            id: UUID(),
            name: "Living Room PS5",
            hostAddress: "192.0.2.50"
        )
        let session = PairingTestSession()
        let effects = PairingEffects()
        let fixture = makeFixture(
            startups: [MobileStartupSnapshot(consoles: [console])],
            effects: effects,
            session: session
        )
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        #expect(fixture.coordinator.canPresentPairing == false)

        let identity = try testIdentity()
        let freshRequest = try pairingRequest(identity: identity)
        let reregisterRequest = try pairingRequest(
            existingConsoleID: console.id,
            identity: identity
        )

        #expect(await catchesSessionActive { try await fixture.coordinator.pairConsole(freshRequest) })
        #expect(
            await catchesSessionActive {
                try await fixture.coordinator.pairConsole(reregisterRequest)
            }
        )
        #expect(
            await catchesSessionActive {
                try await fixture.coordinator.retryPendingPairingSave()
            }
        )
        #expect(
            await catchesSessionActive {
                try await fixture.coordinator.removeConsole(console.id)
            }
        )
        #expect(await effects.pairCount == 0)
        #expect(await effects.retryCount == 0)
        #expect(await effects.removedConsoleIDs.isEmpty)

        await fixture.coordinator.disconnect()
    }

    @Test("Remove reloads the canonical console list")
    func removeReloadsConsoles() async throws {
        let removed = MobileConsoleSummary(
            id: UUID(),
            name: "Remove Me",
            hostAddress: "192.0.2.50"
        )
        let zulu = MobileConsoleSummary(
            id: UUID(),
            name: "Zulu",
            hostAddress: "192.0.2.51"
        )
        let alpha = MobileConsoleSummary(
            id: UUID(),
            name: "Alpha",
            hostAddress: "192.0.2.52"
        )
        let effects = PairingEffects()
        let fixture = makeFixture(
            startups: [
                MobileStartupSnapshot(consoles: [removed]),
                MobileStartupSnapshot(consoles: [zulu, alpha]),
            ],
            effects: effects
        )
        await fixture.coordinator.prepare()

        try await fixture.coordinator.removeConsole(removed.id)

        #expect(await effects.removedConsoleIDs == [removed.id])
        #expect(fixture.coordinator.consoles == [alpha, zulu])
        #expect(await fixture.startups.loadCount == 2)
        #expect(fixture.coordinator.registrationOperationIsActive == false)
    }
}

private extension MobileRemotePlayPairingTests {
    struct Fixture {
        let coordinator: MobileRemotePlayCoordinator
        let startups: PairingStartupSequence
    }

    func makeFixture(
        startups: [MobileStartupSnapshot] = [MobileStartupSnapshot(consoles: [])],
        effects: PairingEffects,
        session: PairingTestSession? = nil
    ) -> Fixture {
        let startupSequence = PairingStartupSequence(startups)
        let dependencies = MobileRemotePlayDependencies(
            loadStartup: { try await startupSequence.load() },
            wake: { _ in },
            makeSession: { _, _ in
                guard let session else { throw PairingTestFailure.noSession }
                return session
            },
            controllerSource: PairingTestControllerSource(),
            pairing: MobilePlayStationPairingDependencies(
                identityCapability: effects.identityCapability,
                requestLocalNetworkAccess: { await effects.requestLocalNetworkAccess() },
                acquireAccountIdentity: { try await effects.acquireAccountIdentity() },
                pair: { try await effects.pair($0) },
                retryPendingSecureSave: { try await effects.retryPendingSecureSave() },
                removeConsole: { await effects.removeConsole($0) }
            ),
            monitorInterval: .seconds(60),
            controllerDeliveryInterval: .seconds(60)
        )
        let suiteName = "RemotePlayMobilePairingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return Fixture(
            coordinator: MobileRemotePlayCoordinator(
                dependencies: dependencies,
                defaults: defaults
            ),
            startups: startupSequence
        )
    }

    func makeReadyModel(
        coordinator: MobileRemotePlayCoordinator,
        target: MobilePairingTarget = MobilePairingTarget()
    ) -> MobilePlayStationPairingModel {
        let model = MobilePlayStationPairingModel(coordinator: coordinator, target: target)
        model.hostAddress = "192.0.2.50"
        model.linkDevicePIN = "01234567"
        return model
    }

    func prepareForPairing(_ model: MobilePlayStationPairingModel) async {
        await model.prepareLocalNetwork()
        await model.acquireAccountIdentity()
        #expect(model.canPair)
    }

    func testIdentity(
        displayName: String? = "Player"
    ) throws -> PlayStationRemotePlayAccountIdentity {
        PlayStationRemotePlayAccountIdentity(
            accountID: try PlayStationAccountID(
                bytes: Data([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
            ),
            displayName: displayName
        )
    }

    func testSavedConsole(
        id: UUID = UUID(),
        name: String = "Living Room PS5",
        hostAddress: String = "192.0.2.50"
    ) -> SavedPlayStationConsole {
        SavedPlayStationConsole(
            id: id,
            displayName: name,
            hostAddress: hostAddress
        )
    }

    func summary(_ console: SavedPlayStationConsole) -> MobileConsoleSummary {
        MobileConsoleSummary(
            id: console.id,
            name: console.displayName,
            hostAddress: console.hostAddress
        )
    }

    func pairingRequest(
        existingConsoleID: UUID? = nil,
        identity: PlayStationRemotePlayAccountIdentity
    ) throws -> PlayStationPairingRequest {
        try PlayStationPairingRequest(
            existingConsoleID: existingConsoleID,
            hostAddress: "192.0.2.50",
            accountID: identity.accountID,
            pin: PlayStationLinkDevicePIN("01234567")
        )
    }

    func catchesSessionActive(
        _ operation: @MainActor () async throws -> Void
    ) async -> Bool {
        do {
            try await operation()
            return false
        } catch let error as MobileRemotePlayCoordinatorError {
            if case .sessionActive = error { return true }
            return false
        } catch {
            return false
        }
    }
}

private enum PairingTestFailure: Error, LocalizedError, Sendable {
    case ordinary
    case noSession

    var errorDescription: String? {
        switch self {
        case .ordinary:
            "The deterministic pairing operation failed."
        case .noSession:
            "No deterministic session was configured."
        }
    }
}

private enum PairingIdentityOutcome: Sendable {
    case success(PlayStationRemotePlayAccountIdentity)
    case failure(PairingTestFailure)
}

private enum PairingOutcome: Sendable {
    case success(SavedPlayStationConsole)
    case failure(PairingTestFailure)
    case secureSavePending
}

private enum PairingRetryOutcome: Sendable {
    case success(SavedPlayStationConsole)
    case failure(PairingTestFailure)
    case secureSavePending
}

private actor PairingEffects {
    nonisolated let identityCapability: PlayStationAccountIdentityAcquisitionCapability

    private let preflightResult: Bool
    private let preflightGate: PairingTestGate?
    private let identityOutcome: PairingIdentityOutcome
    private let pairOutcome: PairingOutcome
    private let retryOutcome: PairingRetryOutcome
    private let pairGate: PairingTestGate?
    private let retryGate: PairingTestGate?

    private(set) var preflightCount = 0
    private(set) var identityAcquisitionCount = 0
    private(set) var pairCount = 0
    private(set) var retryCount = 0
    private(set) var canceledPairCompletionCount = 0
    private(set) var pairRequests: [PlayStationPairingRequest] = []
    private(set) var removedConsoleIDs: [UUID] = []

    init(
        identityCapability: PlayStationAccountIdentityAcquisitionCapability = .available,
        preflightResult: Bool = true,
        preflightGate: PairingTestGate? = nil,
        identityOutcome: PairingIdentityOutcome? = nil,
        pairOutcome: PairingOutcome = .failure(.ordinary),
        retryOutcome: PairingRetryOutcome = .failure(.ordinary),
        pairGate: PairingTestGate? = nil,
        retryGate: PairingTestGate? = nil
    ) {
        self.identityCapability = identityCapability
        self.preflightResult = preflightResult
        self.preflightGate = preflightGate
        self.identityOutcome = identityOutcome ?? .failure(.ordinary)
        self.pairOutcome = pairOutcome
        self.retryOutcome = retryOutcome
        self.pairGate = pairGate
        self.retryGate = retryGate
    }

    func requestLocalNetworkAccess() async -> Bool {
        preflightCount += 1
        await preflightGate?.wait()
        return preflightResult
    }

    func acquireAccountIdentity() throws -> PlayStationRemotePlayAccountIdentity {
        identityAcquisitionCount += 1
        switch identityOutcome {
        case .success(let identity):
            return identity
        case .failure(let error):
            throw error
        }
    }

    func pair(_ request: PlayStationPairingRequest) async throws
        -> SavedPlayStationConsole {
        pairCount += 1
        pairRequests.append(request)
        await pairGate?.wait()
        if Task.isCancelled {
            canceledPairCompletionCount += 1
        }
        switch pairOutcome {
        case .success(let console):
            return console
        case .failure(let error):
            throw error
        case .secureSavePending:
            throw PlayStationPairingError.secureSavePending
        }
    }

    func retryPendingSecureSave() async throws -> SavedPlayStationConsole {
        retryCount += 1
        await retryGate?.wait()
        switch retryOutcome {
        case .success(let console):
            return console
        case .failure(let error):
            throw error
        case .secureSavePending:
            throw PlayStationPairingError.secureSavePending
        }
    }

    func removeConsole(_ consoleID: UUID) {
        removedConsoleIDs.append(consoleID)
    }
}

private actor PairingStartupSequence {
    private var snapshots: [MobileStartupSnapshot]
    private(set) var loadCount = 0

    init(_ snapshots: [MobileStartupSnapshot]) {
        self.snapshots = snapshots
    }

    func load() throws -> MobileStartupSnapshot {
        loadCount += 1
        guard snapshots.isEmpty == false else { throw PairingTestFailure.noSession }
        if snapshots.count == 1 { return snapshots[0] }
        return snapshots.removeFirst()
    }
}

private actor PairingTestGate {
    private var isOpen = false
    private var hasEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasEntered = true
        let observers = entryWaiters
        entryWaiters.removeAll()
        observers.forEach { $0.resume() }
        guard isOpen == false else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard hasEntered == false else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class PairingTestControllerSource:
    MobileRemotePlayControllerSource, @unchecked Sendable {
    func snapshot() -> ControllerSnapshot { .neutral }
    func connectionSnapshot() -> MobileControllerConnection { .disconnected }
}

private final class PairingTestSession: MobileRemotePlaySession, @unchecked Sendable {
    let id = UUID()
    let videoSurface: MobileRemotePlayVideoSurface? = .testHarness

    func start() async throws {}
    func stop() async {}
    func send(_: ControllerSnapshot) async {}
    func goHome() async throws {}
    func restAndDisconnect() async throws {}

    func snapshot() async -> MobileRemoteSessionSnapshot {
        MobileRemoteSessionSnapshot(state: .disconnected, displayIsBlocked: false)
    }

    func recoverVideoAfterInterruption() async {}
    func setVolume(_: Float) {}
    func setMuted(_: Bool) {}
}
