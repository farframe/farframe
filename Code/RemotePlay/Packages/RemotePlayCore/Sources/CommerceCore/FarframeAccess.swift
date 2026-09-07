import Foundation

/// Immutable App Store Connect identifiers shared by every Farframe shell.
///
/// The historical `vision` component is intentionally preserved because an
/// In-App Purchase product identifier cannot be renamed after creation.
public enum FarframeProductID {
    public static let trial = "Farframe.vision.trial.3day"
    public static let lifetime = "Farframe.Vision.Lifetime"
    public static let all: Set<String> = [trial, lifetime]
}

public enum FarframeLifetimeOwnership: Equatable, Sendable {
    case purchased
    case familyShared
}

public enum FarframeAccessState: Equatable, Sendable {
    case loading
    case trialEligible
    case trialActive(startedAt: Date, expiresAt: Date)
    case trialExpired
    case lifetimeUnlocked(ownership: FarframeLifetimeOwnership)

    public var allowsConnect: Bool {
        switch self {
        case .trialActive, .lifetimeUnlocked:
            true
        case .loading, .trialEligible, .trialExpired:
            false
        }
    }

    public var isLifetimeUnlocked: Bool {
        if case .lifetimeUnlocked = self { return true }
        return false
    }
}

/// Store-independent facts extracted only from a verified StoreKit
/// transaction. No receipt, account identifier, or signed transaction data is
/// retained in the domain layer.
public struct FarframeTransactionRecord: Equatable, Sendable {
    public let productID: String
    public let originalPurchaseDate: Date
    public let ownership: FarframeLifetimeOwnership
    public let revocationDate: Date?

    public init(
        productID: String,
        originalPurchaseDate: Date,
        ownership: FarframeLifetimeOwnership = .purchased,
        revocationDate: Date? = nil
    ) {
        self.productID = productID
        self.originalPurchaseDate = originalPurchaseDate
        self.ownership = ownership
        self.revocationDate = revocationDate
    }
}

public struct FarframeEntitlementSnapshot: Equatable, Sendable {
    public let currentEntitlements: [FarframeTransactionRecord]
    public let transactionHistory: [FarframeTransactionRecord]

    public init(
        currentEntitlements: [FarframeTransactionRecord],
        transactionHistory: [FarframeTransactionRecord]
    ) {
        self.currentEntitlements = currentEntitlements
        self.transactionHistory = transactionHistory
    }
}

/// Pure access policy shared by visionOS, iOS, iPadOS, and macOS.
public enum FarframeAccessPolicy {
    public static let trialDuration: TimeInterval = 72 * 60 * 60

    public static func evaluate(
        currentEntitlements: [FarframeTransactionRecord],
        transactionHistory: [FarframeTransactionRecord],
        now: Date
    ) -> FarframeAccessState {
        evaluate(
            snapshot: FarframeEntitlementSnapshot(
                currentEntitlements: currentEntitlements,
                transactionHistory: transactionHistory
            ),
            now: now
        )
    }

    public static func evaluate(
        snapshot: FarframeEntitlementSnapshot,
        now: Date
    ) -> FarframeAccessState {
        if let lifetime = snapshot.currentEntitlements
            .filter({
                $0.productID == FarframeProductID.lifetime
                    && $0.revocationDate == nil
            })
            .max(by: { $0.originalPurchaseDate < $1.originalPurchaseDate }) {
            return .lifetimeUnlocked(ownership: lifetime.ownership)
        }

        let personalTrialHistory = snapshot.transactionHistory.filter {
            $0.productID == FarframeProductID.trial
                && $0.ownership == .purchased
        }
        guard let firstTrial = personalTrialHistory.min(by: {
            $0.originalPurchaseDate < $1.originalPurchaseDate
        }) else {
            return .trialEligible
        }

        // The first personal trial permanently consumes eligibility. Selecting
        // it before checking revocation prevents a later duplicate transaction
        // from restarting the 72-hour window.
        guard firstTrial.revocationDate == nil else {
            return .trialExpired
        }

        let expiry = firstTrial.originalPurchaseDate.addingTimeInterval(trialDuration)
        guard now < expiry else {
            return .trialExpired
        }
        return .trialActive(
            startedAt: firstTrial.originalPurchaseDate,
            expiresAt: expiry
        )
    }
}
