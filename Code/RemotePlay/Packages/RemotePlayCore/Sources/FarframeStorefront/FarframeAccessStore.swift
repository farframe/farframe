import CommerceCore
import Foundation
import Observation
import StoreKit

public typealias FarframePurchaseAction =
    (Product) async throws -> Product.PurchaseResult

struct FarframeEntitlementLoadResult: Equatable, Sendable {
    let snapshot: FarframeEntitlementSnapshot
    let sawUnverifiedFarframeTransaction: Bool

    init(
        snapshot: FarframeEntitlementSnapshot,
        sawUnverifiedFarframeTransaction: Bool = false
    ) {
        self.snapshot = snapshot
        self.sawUnverifiedFarframeTransaction = sawUnverifiedFarframeTransaction
    }
}

typealias FarframeEntitlementSnapshotLoader =
    @Sendable () async -> FarframeEntitlementLoadResult

private struct FarframeTransactionIdentity: Hashable, Sendable {
    let productID: String
    let originalPurchaseDate: Date
    let isFamilyShared: Bool

    init(_ record: FarframeTransactionRecord) {
        productID = record.productID
        originalPurchaseDate = record.originalPurchaseDate
        isFamilyShared = record.ownership == .familyShared
    }
}

/// The single StoreKit owner used by every Farframe app shell.
///
/// UI presentation remains outside this type. Apps create one instance at the
/// scene root, refresh it when their scene becomes active, and consult
/// `allowsConnect` immediately before starting a new Remote Play connection.
@MainActor
@Observable
public final class FarframeAccessStore {
    public private(set) var state: FarframeAccessState = .loading
    public private(set) var products: [String: Product] = [:]
    public private(set) var isLoadingProducts = false
    public private(set) var purchaseInProgressID: String?
    public private(set) var isRestoring = false
    public private(set) var catalogError: String?
    public private(set) var notice: String?

    @ObservationIgnored private var transactionUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var hasPrepared = false
    @ObservationIgnored private let entitlementSnapshotLoader: FarframeEntitlementSnapshotLoader
    @ObservationIgnored private let nowProvider: @MainActor @Sendable () -> Date
    @ObservationIgnored private var isEntitlementRefreshInFlight = false
    @ObservationIgnored private var entitlementRefreshWaiters: [
        CheckedContinuation<Void, Never>
    ] = []
    @ObservationIgnored private var lastLoadedSnapshot = FarframeEntitlementSnapshot(
        currentEntitlements: [],
        transactionHistory: []
    )
    @ObservationIgnored private var provisionalTransactions: [
        FarframeTransactionIdentity: FarframeTransactionRecord
    ] = [:]
    @ObservationIgnored private var revocationBarriers: [
        FarframeTransactionIdentity: FarframeTransactionRecord
    ] = [:]
    #if DEBUG
    @ObservationIgnored private let debugProOverrideKey = "Farframe.Debug.PROOverride"
    @ObservationIgnored private let honorsDebugProOverride: Bool
    #endif

    public init() {
        entitlementSnapshotLoader = Self.loadStoreKitEntitlements
        nowProvider = { Date() }
        #if DEBUG
        honorsDebugProOverride = true
        #endif
        startTransactionUpdates()
    }

    init(
        entitlementSnapshotLoader: @escaping FarframeEntitlementSnapshotLoader,
        nowProvider: @escaping @MainActor @Sendable () -> Date = { Date() }
    ) {
        self.entitlementSnapshotLoader = entitlementSnapshotLoader
        self.nowProvider = nowProvider
        #if DEBUG
        honorsDebugProOverride = false
        #endif
    }

    var pendingEntitlementRefreshCount: Int {
        entitlementRefreshWaiters.count
    }

    private func startTransactionUpdates() {
        transactionUpdatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard Task.isCancelled == false, let self else { return }
                await self.handleTransactionUpdate(result)
            }
        }
    }

    deinit {
        transactionUpdatesTask?.cancel()
        expiryTask?.cancel()
    }

    public var allowsConnect: Bool {
        state.allowsConnect
    }

    public var trialProduct: Product? {
        products[FarframeProductID.trial]
    }

    public var lifetimeProduct: Product? {
        products[FarframeProductID.lifetime]
    }

    public var lifetimeDisplayPrice: String? {
        lifetimeProduct?.displayPrice
    }

    public var entryTitle: String {
        switch state {
        case .loading, .trialEligible, .trialExpired:
            "Upgrade to PRO"
        case .trialActive:
            "Trial active"
        case .lifetimeUnlocked:
            "PRO"
        }
    }

    public var entrySymbol: String {
        switch state {
        case .loading, .trialEligible:
            "sparkles"
        case .trialActive:
            "clock.fill"
        case .trialExpired:
            "lock.fill"
        case .lifetimeUnlocked:
            "checkmark.seal.fill"
        }
    }

    public var statusTitle: String {
        switch state {
        case .loading:
            "Checking access"
        case .trialEligible:
            "Ready to unlock"
        case .trialActive:
            "3-Day Trial active"
        case .trialExpired:
            "Trial complete"
        case .lifetimeUnlocked(let ownership):
            ownership == .familyShared
                ? "FARFRAME PRO shared"
                : "FARFRAME PRO active"
        }
    }

    public var statusDetail: String {
        switch state {
        case .loading:
            "FARFRAME is checking your App Store purchases."
        case .trialEligible:
            "Choose Lifetime Unlock to connect and play. Restore Purchases if you already have access."
        case .trialActive(_, let expiresAt):
            "Full access until \(expiresAt.formatted(date: .abbreviated, time: .shortened))."
        case .trialExpired:
            "Upgrade to FARFRAME PRO to keep connecting and playing."
        case .lifetimeUnlocked(let ownership):
            ownership == .familyShared
                ? "Connect and Remote Play are unlocked through Family Sharing."
                : "Connect and Remote Play are unlocked."
        }
    }

    public func prepare() async {
        if hasPrepared {
            await refresh()
            return
        }
        hasPrepared = true
        await refreshEntitlements()
        await loadProducts()
    }

    public func refresh() async {
        await refreshEntitlements()
        if products.count != FarframeProductID.all.count {
            await loadProducts()
        }
    }

    /// Reconciles only the signed App Store entitlement state immediately
    /// before a new Remote Play connection starts.
    ///
    /// Product-catalog loading is deliberately excluded from this gate so a
    /// temporary storefront merchandising failure cannot delay or replace the
    /// entitlement decision.
    @discardableResult
    public func revalidateConnectionStart() async -> Bool {
        await refreshEntitlements()
        return state.allowsConnect
    }

    public func loadProducts() async {
        guard isLoadingProducts == false else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let loaded = try await Product.products(for: FarframeProductID.all.sorted())
            products = Dictionary(uniqueKeysWithValues: loaded.compactMap { product in
                guard FarframeProductID.all.contains(product.id) else { return nil }
                return (product.id, product)
            })

            let missing = FarframeProductID.all.subtracting(products.keys)
            catalogError = missing.isEmpty
                ? nil
                : "The App Store did not return every FARFRAME purchase option. Try again shortly."
        } catch {
            catalogError = "Purchase options are unavailable. Check your connection and try again."
        }
    }

    public func purchaseTrial(using purchaseAction: FarframePurchaseAction) async {
        guard case .trialEligible = state else { return }
        await purchase(productID: FarframeProductID.trial, using: purchaseAction)
    }

    public func purchaseLifetime(using purchaseAction: FarframePurchaseAction) async {
        await purchase(productID: FarframeProductID.lifetime, using: purchaseAction)
    }

    public func restorePurchases() async {
        guard isRestoring == false else { return }
        isRestoring = true
        notice = nil
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            await loadProducts()
            switch state {
            case .lifetimeUnlocked(let ownership):
                notice = ownership == .familyShared
                    ? "Lifetime Unlock restored through Family Sharing."
                    : "Lifetime Unlock restored."
            case .trialActive:
                notice = "Your active 3-Day Trial was restored."
            case .trialExpired:
                notice = "Your 3-Day Trial history was restored. Upgrade to FARFRAME PRO to keep connecting and playing."
            case .trialEligible, .loading:
                notice = "No previous FARFRAME purchases were found for this Apple Account."
            }
        } catch {
            notice = "Purchases could not be restored. Check your connection and try again."
        }
    }

    public func clearNotice() {
        notice = nil
    }

    #if DEBUG
    public func enableDebugProAccess() {
        UserDefaults.standard.set(true, forKey: debugProOverrideKey)
        setState(.lifetimeUnlocked(ownership: .purchased))
        catalogError = nil
        notice = "FARFRAME PRO is enabled for this Debug build."
    }

    public func disableDebugProAccess() async {
        UserDefaults.standard.removeObject(forKey: debugProOverrideKey)
        notice = nil
        await refreshEntitlements()
    }
    #endif

    private func purchase(
        productID: String,
        using purchaseAction: FarframePurchaseAction
    ) async {
        guard purchaseInProgressID == nil else { return }
        notice = nil

        guard AppStore.canMakePayments else {
            notice = "Purchases are not allowed on this device."
            return
        }
        guard let product = products[productID] else {
            await loadProducts()
            guard let refreshedProduct = products[productID] else {
                notice = "That purchase option is unavailable. Try again shortly."
                return
            }
            await purchase(refreshedProduct, using: purchaseAction)
            return
        }
        await purchase(product, using: purchaseAction)
    }

    private func purchase(
        _ product: Product,
        using purchaseAction: FarframePurchaseAction
    ) async {
        purchaseInProgressID = product.id
        defer { purchaseInProgressID = nil }

        do {
            switch try await purchaseAction(product) {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    notice = "The App Store could not verify this purchase. No access was changed."
                    return
                }
                guard let record = Self.record(for: transaction) else { return }
                await refreshEntitlements(including: record)
                await transaction.finish()
                notice = record.revocationDate == nil
                    ? successNotice(for: product.id)
                    : "The App Store reported that this purchase is no longer active."

            case .pending:
                notice = "Waiting for approval. FARFRAME will unlock after the App Store confirms the purchase."

            case .userCancelled:
                break

            @unknown default:
                notice = "The App Store returned an unknown purchase result. No access was changed."
            }
        } catch {
            // A scene-bound purchase can commit locally and still throw while
            // dismissing its sheet. Reconcile the signed transaction before
            // showing a failure so a completed purchase cannot strand access.
            if await reconcileLatestTransaction(for: product.id) {
                notice = successNotice(for: product.id)
            } else {
                #if DEBUG
                notice = "The purchase could not be completed: \(error.localizedDescription)"
                #else
                notice = "The purchase could not be completed. Check your connection and try again."
                #endif
            }
        }
    }

    private func reconcileLatestTransaction(for productID: String) async -> Bool {
        guard let result = await Transaction.latest(for: productID) else { return false }
        guard case .verified(let transaction) = result,
              let record = Self.record(for: transaction) else {
            return false
        }

        await refreshEntitlements(including: record)
        await transaction.finish()
        return record.revocationDate == nil && state.allowsConnect
    }

    private func handleTransactionUpdate(
        _ result: VerificationResult<Transaction>
    ) async {
        switch result {
        case .verified(let transaction):
            guard let record = Self.record(for: transaction) else { return }
            // Include the just-verified transaction before finishing it. This
            // covers Ask to Buy, Family Sharing, and StoreKit propagation lag.
            await refreshEntitlements(including: record)
            await transaction.finish()
        case .unverified(let transaction, _):
            guard FarframeProductID.all.contains(transaction.productID) else { return }
            notice = "The App Store reported a purchase that FARFRAME could not verify. No access was changed."
        }
    }

    func refreshEntitlements(
        now explicitNow: Date? = nil,
        including verifiedRecord: FarframeTransactionRecord? = nil
    ) async {
        if let verifiedRecord {
            // Verified purchases and revocations affect the visible state
            // immediately; production still samples a fresh decision time after
            // the serialized StoreKit load below.
            stageVerifiedTransaction(
                verifiedRecord,
                now: explicitNow ?? nowProvider()
            )
        }

        await acquireEntitlementRefreshPermit()
        let loaded = await entitlementSnapshotLoader()
        // Default arguments are evaluated before an async call begins. Sampling
        // here instead ensures a trial that expires while this request waits for
        // the permit or StoreKit loader cannot authorize a new connection.
        commit(loaded, now: explicitNow ?? nowProvider())
        releaseEntitlementRefreshPermit()
    }

    private func acquireEntitlementRefreshPermit() async {
        guard isEntitlementRefreshInFlight else {
            isEntitlementRefreshInFlight = true
            return
        }

        await withCheckedContinuation { continuation in
            entitlementRefreshWaiters.append(continuation)
        }
    }

    private func releaseEntitlementRefreshPermit() {
        guard entitlementRefreshWaiters.isEmpty == false else {
            isEntitlementRefreshInFlight = false
            return
        }

        // Keep ownership asserted while handing the permit directly to the
        // oldest suspended request. StoreKit snapshots therefore commit in
        // request order even though MainActor methods are reentrant at await.
        entitlementRefreshWaiters.removeFirst().resume()
    }

    nonisolated private static func loadStoreKitEntitlements() async
        -> FarframeEntitlementLoadResult {
        var current: [FarframeTransactionRecord] = []
        var history: [FarframeTransactionRecord] = []
        var sawUnverifiedFarframeTransaction = false

        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                if let record = Self.record(for: transaction) {
                    current.append(record)
                }
            case .unverified(let transaction, _):
                if FarframeProductID.all.contains(transaction.productID) {
                    sawUnverifiedFarframeTransaction = true
                }
            }
        }

        for await result in Transaction.all {
            switch result {
            case .verified(let transaction):
                if let record = Self.record(for: transaction) {
                    history.append(record)
                }
            case .unverified(let transaction, _):
                if FarframeProductID.all.contains(transaction.productID) {
                    sawUnverifiedFarframeTransaction = true
                }
            }
        }

        return FarframeEntitlementLoadResult(
            snapshot: FarframeEntitlementSnapshot(
                currentEntitlements: current,
                transactionHistory: history
            ),
            sawUnverifiedFarframeTransaction: sawUnverifiedFarframeTransaction
        )
    }

    private func stageVerifiedTransaction(
        _ record: FarframeTransactionRecord,
        now: Date
    ) {
        guard FarframeProductID.all.contains(record.productID) else { return }
        let identity = FarframeTransactionIdentity(record)

        if record.revocationDate != nil {
            provisionalTransactions.removeValue(forKey: identity)
            revocationBarriers[identity] = record
        } else if revocationBarriers[identity] == nil {
            provisionalTransactions[identity] = record
        }

        // A verified purchase becomes usable synchronously before StoreKit's
        // sequences catch up. A verified revocation is the inverse: it removes
        // access before any asynchronous refresh can yield back to a Connect
        // attempt.
        applyCurrentState(now: now)
    }

    private func commit(
        _ loaded: FarframeEntitlementLoadResult,
        now: Date
    ) {
        let snapshot = FarframeEntitlementSnapshot(
            currentEntitlements: loaded.snapshot.currentEntitlements.filter {
                FarframeProductID.all.contains($0.productID)
            },
            transactionHistory: loaded.snapshot.transactionHistory.filter {
                FarframeProductID.all.contains($0.productID)
            }
        )

        // A signed revocation is a durable in-memory negative assertion. It
        // survives stale current-entitlement snapshots and is replaced only by
        // a distinct verified transaction identity.
        for record in snapshot.currentEntitlements + snapshot.transactionHistory
        where record.revocationDate != nil {
            let identity = FarframeTransactionIdentity(record)
            provisionalTransactions.removeValue(forKey: identity)
            revocationBarriers[identity] = record
        }

        // A positive transaction remains provisional until the authoritative
        // current-entitlement sequence emits that exact transaction. History
        // alone is insufficient because lifetime history does not authorize
        // access after a refund or account change.
        for record in snapshot.currentEntitlements where record.revocationDate == nil {
            provisionalTransactions.removeValue(
                forKey: FarframeTransactionIdentity(record)
            )
        }

        lastLoadedSnapshot = snapshot
        applyCurrentState(now: now)

        if loaded.sawUnverifiedFarframeTransaction {
            notice = "The App Store reported a purchase that FARFRAME could not verify. No access was changed."
        }
    }

    private func applyCurrentState(now: Date) {
        var current = lastLoadedSnapshot.currentEntitlements
        var history = lastLoadedSnapshot.transactionHistory

        for (identity, revokedRecord) in revocationBarriers {
            current.removeAll { FarframeTransactionIdentity($0) == identity }
            Self.replace(record: revokedRecord, in: &history)
        }

        for (identity, provisionalRecord) in provisionalTransactions
        where revocationBarriers[identity] == nil {
            Self.replace(record: provisionalRecord, in: &current)
            Self.replace(record: provisionalRecord, in: &history)
        }

        var evaluatedState = FarframeAccessPolicy.evaluate(
            currentEntitlements: current,
            transactionHistory: history,
            now: now
        )
        #if DEBUG
        if honorsDebugProOverride,
           UserDefaults.standard.bool(forKey: debugProOverrideKey) {
            evaluatedState = .lifetimeUnlocked(ownership: .purchased)
        }
        #endif
        setState(evaluatedState)
    }

    nonisolated private static func replace(
        record: FarframeTransactionRecord,
        in records: inout [FarframeTransactionRecord]
    ) {
        let identity = FarframeTransactionIdentity(record)
        records.removeAll { FarframeTransactionIdentity($0) == identity }
        records.append(record)
    }

    nonisolated private static func record(
        for transaction: Transaction
    ) -> FarframeTransactionRecord? {
        guard FarframeProductID.all.contains(transaction.productID) else { return nil }
        return FarframeTransactionRecord(
            productID: transaction.productID,
            originalPurchaseDate: transaction.originalPurchaseDate,
            ownership: transaction.ownershipType == .familyShared ? .familyShared : .purchased,
            revocationDate: transaction.revocationDate
        )
    }

    private func setState(_ newState: FarframeAccessState) {
        state = newState
        expiryTask?.cancel()
        expiryTask = nil

        guard case .trialActive(_, let expiresAt) = newState else { return }
        let remaining = max(0, expiresAt.timeIntervalSinceNow)
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                return
            }
            guard let self else { return }
            await self.refreshEntitlements()
        }
    }

    private func successNotice(for productID: String) -> String {
        productID == FarframeProductID.lifetime
            ? "FARFRAME PRO is active."
            : "Your 3-Day Trial is active."
    }
}
