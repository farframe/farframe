import ExperienceDomain
import Foundation

public struct CredentialKey: Hashable, Sendable {
    /// Provider-scoped credential subject. This is opaque and must not be assumed to be a PSN ID.
    public let providerID: String
    public let accountID: String
    public let purpose: String

    public init(providerID: String, accountID: String, purpose: String) {
        self.providerID = providerID
        self.accountID = accountID
        self.purpose = purpose
    }
}

public protocol CredentialStore: Sendable {
    func value(for key: CredentialKey) async throws -> Data?
    func set(_ value: Data, for key: CredentialKey) async throws
    func removeValue(for key: CredentialKey) async throws
}

public actor InMemoryCredentialStore: CredentialStore {
    private var values: [CredentialKey: Data] = [:]

    public init() {}

    public func value(for key: CredentialKey) -> Data? {
        values[key]
    }

    public func set(_ value: Data, for key: CredentialKey) {
        values[key] = value
    }

    public func removeValue(for key: CredentialKey) {
        values[key] = nil
    }
}
