import CommerceCore
import Foundation
import Testing
@testable import FarframeStorefront

private let farframeReferenceDate = Date(timeIntervalSince1970: 2_000_000_000)

@Test
func farframeProductionProductIDsPreserveExactImmutableCasing() {
    #expect(FarframeProductID.trial == "Farframe.vision.trial.3day")
    #expect(FarframeProductID.lifetime == "Farframe.Vision.Lifetime")
    #expect(FarframeProductID.all == [
        "Farframe.vision.trial.3day",
        "Farframe.Vision.Lifetime",
    ])
}

@Test
func farframeSharedStoreKitFixtureMatchesUniversalFamilyContract() throws {
    let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let fixtureURL = testDirectory
        .appending(path: "../../../..")
        .standardizedFileURL
        .appending(path: "Apps/Shared/StoreKit/Farframe.storekit")
    let fixture = try JSONDecoder().decode(
        FarframeStoreKitFixture.self,
        from: Data(contentsOf: fixtureURL)
    )
    let products = Dictionary(
        uniqueKeysWithValues: fixture.products.map { ($0.productID, $0) }
    )

    #expect(Set(products.keys) == FarframeProductID.all)
    #expect(products[FarframeProductID.trial]?.type == "NonConsumable")
    #expect(products[FarframeProductID.trial]?.familyShareable == false)
    #expect(products[FarframeProductID.lifetime]?.type == "NonConsumable")
    #expect(products[FarframeProductID.lifetime]?.familyShareable == true)
}

@Test
func farframeNewAppleAccountIsTrialEligible() {
    #expect(evaluate(current: [], history: []) == .trialEligible)
}

@Test
func farframeTrialUsesVerifiedHistoryDuringCurrentEntitlementLag() {
    let trial = record(FarframeProductID.trial, at: farframeReferenceDate)
    let oneSecondBeforeExpiry = farframeReferenceDate.addingTimeInterval(
        FarframeAccessPolicy.trialDuration - 1
    )

    #expect(
        evaluate(current: [], history: [trial], now: oneSecondBeforeExpiry)
            == .trialActive(
                startedAt: farframeReferenceDate,
                expiresAt: farframeReferenceDate.addingTimeInterval(
                    FarframeAccessPolicy.trialDuration
                )
            )
    )
}

@Test
func farframeTrialExpiresAtExactlySeventyTwoHours() {
    let trial = record(FarframeProductID.trial, at: farframeReferenceDate)
    let expiry = farframeReferenceDate.addingTimeInterval(
        FarframeAccessPolicy.trialDuration
    )

    #expect(evaluate(current: [trial], history: [trial], now: expiry) == .trialExpired)
}

@Test
func farframeRevokedFirstTrialCannotBeRestartedByLaterDuplicateHistory() {
    let revokedFirstTrial = record(
        FarframeProductID.trial,
        at: farframeReferenceDate,
        revokedAt: farframeReferenceDate.addingTimeInterval(60)
    )
    let laterDuplicate = record(
        FarframeProductID.trial,
        at: farframeReferenceDate.addingTimeInterval(120)
    )

    #expect(
        evaluate(
            current: [laterDuplicate],
            history: [laterDuplicate, revokedFirstTrial],
            now: farframeReferenceDate.addingTimeInterval(180)
        ) == .trialExpired
    )
}

@Test
func farframeFamilySharedTrialNeverConsumesPersonalEligibility() {
    let sharedTrial = record(
        FarframeProductID.trial,
        at: farframeReferenceDate,
        ownership: .familyShared
    )

    #expect(
        evaluate(current: [sharedTrial], history: [sharedTrial])
            == .trialEligible
    )
}

@Test(arguments: [
    FarframeLifetimeOwnership.purchased,
    FarframeLifetimeOwnership.familyShared,
])
func farframeCurrentLifetimeEntitlementUnlocksEveryOwnershipType(
    ownership: FarframeLifetimeOwnership
) {
    let lifetime = record(
        FarframeProductID.lifetime,
        at: farframeReferenceDate,
        ownership: ownership
    )

    #expect(
        evaluate(current: [lifetime], history: [lifetime])
            == .lifetimeUnlocked(ownership: ownership)
    )
}

@Test
func farframeLifetimeHistoryWithoutCurrentEntitlementDoesNotUnlock() {
    let historicalLifetime = record(
        FarframeProductID.lifetime,
        at: farframeReferenceDate
    )

    #expect(
        evaluate(current: [], history: [historicalLifetime])
            == .trialEligible
    )
}

@Test
func farframeRevokedLifetimeFallsBackToStillActiveTrial() {
    let trial = record(FarframeProductID.trial, at: farframeReferenceDate)
    let revokedLifetime = record(
        FarframeProductID.lifetime,
        at: farframeReferenceDate,
        revokedAt: farframeReferenceDate.addingTimeInterval(60)
    )

    #expect(
        evaluate(
            current: [revokedLifetime, trial],
            history: [revokedLifetime, trial],
            now: farframeReferenceDate.addingTimeInterval(120)
        ) == .trialActive(
            startedAt: farframeReferenceDate,
            expiresAt: farframeReferenceDate.addingTimeInterval(
                FarframeAccessPolicy.trialDuration
            )
        )
    )
}

@Test
func farframeUnknownProductsCannotChangeAccess() {
    let unknown = record("example.unknown.product", at: farframeReferenceDate)
    #expect(evaluate(current: [unknown], history: [unknown]) == .trialEligible)
}

@MainActor
@Test
func farframeStorefrontStartsInAStableLoadingState() {
    let store = FarframeAccessStore()

    #expect(store.state == .loading)
    #expect(store.allowsConnect == false)
    #expect(store.products.isEmpty)
    #expect(store.purchaseInProgressID == nil)
    #expect(store.isRestoring == false)
}

@MainActor
@Test
func farframeConnectionGateCommitsDenialBeforeQueuedSceneRefresh() async {
    let source = ControlledFarframeEntitlementLoader()
    let store = FarframeAccessStore {
        await source.load()
    }
    let lifetime = record(FarframeProductID.lifetime, at: farframeReferenceDate)

    let initialRefresh = Task { @MainActor in
        await store.revalidateConnectionStart()
    }
    await source.waitUntilStarted(0)
    let completedInitial = await source.complete(
        0,
        with: loadResult(current: [lifetime], history: [lifetime])
    )
    #expect(completedInitial)
    #expect(await initialRefresh.value)

    let connectionGateRefresh = Task { @MainActor in
        await store.revalidateConnectionStart()
    }
    await source.waitUntilStarted(1)

    let sceneRefresh = Task { @MainActor in
        await store.refreshEntitlements(now: farframeReferenceDate)
    }
    let sceneIsQueued = await waitForPendingRefreshCount(1, in: store)
    #expect(sceneIsQueued)
    #expect(await source.hasStarted(2) == false)

    // The connection gate owns the first serialized snapshot. Its authoritative
    // denial must commit and return false even though a later scene refresh is
    // already suspended behind it.
    let completedConnectionGate = await source.complete(
        1,
        with: loadResult(current: [], history: [lifetime])
    )
    #expect(completedConnectionGate)
    #expect(await connectionGateRefresh.value == false)
    #expect(store.state == .trialEligible)

    await source.waitUntilStarted(2)
    let completedSceneRefresh = await source.complete(
        2,
        with: loadResult(current: [], history: [lifetime])
    )
    #expect(completedSceneRefresh)
    await sceneRefresh.value
    #expect(store.state == .trialEligible)
}

@MainActor
@Test
func farframeConnectionGateUsesFinalDecisionTimeAcrossStoreKitSuspension() async {
    let source = ControlledFarframeEntitlementLoader()
    let trial = record(FarframeProductID.trial, at: farframeReferenceDate)
    let expiry = farframeReferenceDate.addingTimeInterval(
        FarframeAccessPolicy.trialDuration
    )
    let clock = MutableFarframeDate(
        expiry.addingTimeInterval(-1)
    )
    let store = FarframeAccessStore(
        entitlementSnapshotLoader: {
            await source.load()
        },
        nowProvider: {
            clock.value
        }
    )

    let connectionGate = Task { @MainActor in
        await store.revalidateConnectionStart()
    }
    await source.waitUntilStarted(0)

    // Cross the exact 72-hour boundary while StoreKit is still loading. The
    // final gate must sample time after the load, not when the task was queued.
    clock.value = expiry.addingTimeInterval(1)
    let completed = await source.complete(
        0,
        with: loadResult(current: [trial], history: [trial])
    )
    #expect(completed)
    #expect(await connectionGate.value == false)
    #expect(store.state == .trialExpired)
}

@MainActor
@Test
func farframeVerifiedPurchaseRemainsProvisionalUntilCurrentEntitlementsObserveIt() async {
    let source = ControlledFarframeEntitlementLoader()
    let store = FarframeAccessStore {
        await source.load()
    }
    let lifetime = record(FarframeProductID.lifetime, at: farframeReferenceDate)

    let olderRefresh = Task { @MainActor in
        await store.revalidateConnectionStart()
    }
    await source.waitUntilStarted(0)

    let purchaseRefresh = Task { @MainActor in
        await store.refreshEntitlements(
            now: farframeReferenceDate,
            including: lifetime
        )
    }
    let purchaseRefreshIsQueued = await waitForPendingRefreshCount(1, in: store)
    #expect(purchaseRefreshIsQueued)

    // Staging the signed transaction unlocks synchronously even while its
    // StoreKit refresh is serialized behind an older snapshot.
    #expect(store.state == .lifetimeUnlocked(ownership: .purchased))

    let completedOlder = await source.complete(
        0,
        with: loadResult(current: [], history: [])
    )
    #expect(completedOlder)
    #expect(await olderRefresh.value)

    await source.waitUntilStarted(1)
    let completedPurchaseLag = await source.complete(
        1,
        with: loadResult(current: [], history: [])
    )
    #expect(completedPurchaseLag)
    await purchaseRefresh.value
    #expect(store.state == .lifetimeUnlocked(ownership: .purchased))

    let propagationLagRefresh = Task { @MainActor in
        await store.revalidateConnectionStart()
    }
    await source.waitUntilStarted(2)
    let completedPropagationLag = await source.complete(
        2,
        with: loadResult(current: [], history: [lifetime])
    )
    #expect(completedPropagationLag)
    #expect(await propagationLagRefresh.value)

    let observationRefresh = Task { @MainActor in
        await store.revalidateConnectionStart()
    }
    await source.waitUntilStarted(3)
    let completedObservation = await source.complete(
        3,
        with: loadResult(current: [lifetime], history: [lifetime])
    )
    #expect(completedObservation)
    #expect(await observationRefresh.value)

    // Once StoreKit has emitted the transaction as current, the provisional
    // overlay retires and a later authoritative absence fails closed.
    let authoritativeAbsenceRefresh = Task { @MainActor in
        await store.revalidateConnectionStart()
    }
    await source.waitUntilStarted(4)
    let completedAuthoritativeAbsence = await source.complete(
        4,
        with: loadResult(current: [], history: [lifetime])
    )
    #expect(completedAuthoritativeAbsence)
    #expect(await authoritativeAbsenceRefresh.value == false)
    #expect(store.state == .trialEligible)
}

@MainActor
@Test
func farframeVerifiedRevocationFailsClosedAgainstProvisionalAndStaleCurrentState() async {
    let source = ControlledFarframeEntitlementLoader()
    let store = FarframeAccessStore {
        await source.load()
    }
    let lifetime = record(FarframeProductID.lifetime, at: farframeReferenceDate)
    let revokedLifetime = record(
        FarframeProductID.lifetime,
        at: farframeReferenceDate,
        revokedAt: farframeReferenceDate.addingTimeInterval(60)
    )

    let purchaseRefresh = Task { @MainActor in
        await store.refreshEntitlements(
            now: farframeReferenceDate,
            including: lifetime
        )
    }
    await source.waitUntilStarted(0)
    let completedPurchase = await source.complete(
        0,
        with: loadResult(current: [], history: [])
    )
    #expect(completedPurchase)
    await purchaseRefresh.value
    #expect(store.allowsConnect)

    let revocationRefresh = Task { @MainActor in
        await store.refreshEntitlements(
            now: farframeReferenceDate.addingTimeInterval(60),
            including: revokedLifetime
        )
    }
    await source.waitUntilStarted(1)

    // Revocation is applied before the injected StoreKit load resumes.
    #expect(store.allowsConnect == false)
    #expect(store.state == .trialEligible)

    let completedStaleSnapshot = await source.complete(
        1,
        with: loadResult(current: [lifetime], history: [lifetime])
    )
    #expect(completedStaleSnapshot)
    await revocationRefresh.value
    #expect(store.allowsConnect == false)
    #expect(store.state == .trialEligible)

    let repeatedStaleRefresh = Task { @MainActor in
        await store.revalidateConnectionStart()
    }
    await source.waitUntilStarted(2)
    let completedRepeatedStaleSnapshot = await source.complete(
        2,
        with: loadResult(current: [lifetime], history: [lifetime])
    )
    #expect(completedRepeatedStaleSnapshot)
    #expect(await repeatedStaleRefresh.value == false)
    #expect(store.state == .trialEligible)
}

private func record(
    _ productID: String,
    at date: Date,
    ownership: FarframeLifetimeOwnership = .purchased,
    revokedAt revocationDate: Date? = nil
) -> FarframeTransactionRecord {
    FarframeTransactionRecord(
        productID: productID,
        originalPurchaseDate: date,
        ownership: ownership,
        revocationDate: revocationDate
    )
}

private func evaluate(
    current: [FarframeTransactionRecord],
    history: [FarframeTransactionRecord],
    now: Date = farframeReferenceDate
) -> FarframeAccessState {
    FarframeAccessPolicy.evaluate(
        currentEntitlements: current,
        transactionHistory: history,
        now: now
    )
}

private func loadResult(
    current: [FarframeTransactionRecord],
    history: [FarframeTransactionRecord]
) -> FarframeEntitlementLoadResult {
    FarframeEntitlementLoadResult(
        snapshot: FarframeEntitlementSnapshot(
            currentEntitlements: current,
            transactionHistory: history
        )
    )
}

@MainActor
private func waitForPendingRefreshCount(
    _ expectedCount: Int,
    in store: FarframeAccessStore,
    timeout: Duration = .seconds(2)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    repeat {
        if store.pendingEntitlementRefreshCount == expectedCount {
            return true
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    } while clock.now < deadline
    return store.pendingEntitlementRefreshCount == expectedCount
}

private actor ControlledFarframeEntitlementLoader {
    private var nextCallID = 0
    private var startedCallIDs: Set<Int> = []
    private var pendingLoads: [
        Int: CheckedContinuation<FarframeEntitlementLoadResult, Never>
    ] = [:]
    private var startWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func load() async -> FarframeEntitlementLoadResult {
        let callID = nextCallID
        nextCallID += 1

        return await withCheckedContinuation { continuation in
            pendingLoads[callID] = continuation
            startedCallIDs.insert(callID)
            let waiters = startWaiters.removeValue(forKey: callID) ?? []
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilStarted(_ callID: Int) async {
        if startedCallIDs.contains(callID) { return }
        await withCheckedContinuation { continuation in
            startWaiters[callID, default: []].append(continuation)
        }
    }

    func hasStarted(_ callID: Int) -> Bool {
        startedCallIDs.contains(callID)
    }

    func complete(
        _ callID: Int,
        with result: FarframeEntitlementLoadResult
    ) -> Bool {
        guard let continuation = pendingLoads.removeValue(forKey: callID) else {
            return false
        }
        continuation.resume(returning: result)
        return true
    }
}

@MainActor
private final class MutableFarframeDate: @unchecked Sendable {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

private struct FarframeStoreKitFixture: Decodable {
    let products: [FarframeStoreKitProductFixture]
}

private struct FarframeStoreKitProductFixture: Decodable {
    let productID: String
    let type: String
    let familyShareable: Bool
}
