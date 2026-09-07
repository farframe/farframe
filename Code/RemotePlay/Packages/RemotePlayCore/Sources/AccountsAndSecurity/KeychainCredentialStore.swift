import CryptoKit
import Foundation
import Security

public enum KeychainItemAccessibility: String, Sendable {
    case whenUnlocked
    case whenUnlockedThisDeviceOnly
}

/// Explicit storage attributes for one Keychain-backed credential namespace.
/// The production default remains device-local. A synchronized configuration
/// is a separate opt-in bootstrap channel and must never use a ThisDeviceOnly
/// accessibility class.
public struct KeychainCredentialStoreConfiguration: Equatable, Sendable {
    public let service: String
    public let accessGroup: String?
    public let accessibility: KeychainItemAccessibility
    public let usesDataProtectionKeychain: Bool
    public let synchronizes: Bool

    public static func deviceLocal(
        service: String = KeychainCredentialStore.defaultService,
        accessGroup: String? = nil
    ) -> Self {
        Self(
            service: service,
            accessGroup: accessGroup,
            accessibility: .whenUnlockedThisDeviceOnly,
            usesDataProtectionKeychain: true,
            synchronizes: false
        )
    }

    public static func synchronizedBootstrap(
        service: String = KeychainCredentialStore.defaultSynchronizedBootstrapService,
        accessGroup: String
    ) -> Self {
        Self(
            service: service,
            accessGroup: accessGroup,
            accessibility: .whenUnlocked,
            usesDataProtectionKeychain: true,
            synchronizes: true
        )
    }
}

/// Provider-neutral item attributes passed through the injectable backend seam.
public struct KeychainItem: Hashable, Sendable {
    public let service: String
    public let account: String
    public let accessGroup: String?
    public let accessibility: KeychainItemAccessibility
    public let usesDataProtectionKeychain: Bool
    public let synchronizes: Bool

    public init(
        service: String,
        account: String,
        accessGroup: String? = nil,
        accessibility: KeychainItemAccessibility,
        usesDataProtectionKeychain: Bool,
        synchronizes: Bool
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.accessibility = accessibility
        self.usesDataProtectionKeychain = usesDataProtectionKeychain
        self.synchronizes = synchronizes
    }
}

public protocol KeychainBackend: Sendable {
    func add(_ value: Data, for item: KeychainItem) -> OSStatus
    func update(_ value: Data, for item: KeychainItem) -> OSStatus
    func read(_ item: KeychainItem) -> (status: OSStatus, value: Data?)
    func delete(_ item: KeychainItem) -> OSStatus
}

public enum KeychainOperation: String, Sendable {
    case add
    case update
    case read
    case remove
}

public struct KeychainCredentialStoreError: Error, Equatable, Sendable, LocalizedError {
    public let operation: KeychainOperation
    public let status: OSStatus

    public init(operation: KeychainOperation, status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    public var errorDescription: String? {
        "Keychain \(operation.rawValue) failed with status \(status)."
    }
}

/// Device-local production storage for small provider credentials.
public actor KeychainCredentialStore: CredentialStore {
    public static let defaultService = "com.unshackledpursuit.remoteplay.credentials.v1"
    public static let defaultSynchronizedBootstrapService =
        "com.unshackledpursuit.remoteplay.ecosystem.credentials.v1"

    private let configuration: KeychainCredentialStoreConfiguration
    private let backend: any KeychainBackend

    public init(service: String = KeychainCredentialStore.defaultService) {
        self.configuration = .deviceLocal(service: service)
        self.backend = SystemKeychainBackend()
    }

    public init(
        service: String = KeychainCredentialStore.defaultService,
        backend: any KeychainBackend
    ) {
        self.configuration = .deviceLocal(service: service)
        self.backend = backend
    }

    public init(configuration: KeychainCredentialStoreConfiguration) {
        self.configuration = configuration
        self.backend = SystemKeychainBackend()
    }

    public init(
        configuration: KeychainCredentialStoreConfiguration,
        backend: any KeychainBackend
    ) {
        self.configuration = configuration
        self.backend = backend
    }

    public func value(for key: CredentialKey) throws -> Data? {
        let result = backend.read(item(for: key))
        switch result.status {
        case errSecSuccess:
            guard let value = result.value else {
                throw KeychainCredentialStoreError(operation: .read, status: errSecDecode)
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainCredentialStoreError(operation: .read, status: result.status)
        }
    }

    public func set(_ value: Data, for key: CredentialKey) throws {
        let item = item(for: key)
        let addStatus = backend.add(value, for: item)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = backend.update(value, for: item)
            guard updateStatus == errSecSuccess else {
                throw KeychainCredentialStoreError(operation: .update, status: updateStatus)
            }
        default:
            throw KeychainCredentialStoreError(operation: .add, status: addStatus)
        }
    }

    public func removeValue(for key: CredentialKey) throws {
        let status = backend.delete(item(for: key))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialStoreError(operation: .remove, status: status)
        }
    }

    private func item(for key: CredentialKey) -> KeychainItem {
        KeychainItem(
            service: configuration.service,
            account: Self.hashedAccount(for: key),
            accessGroup: configuration.accessGroup,
            accessibility: configuration.accessibility,
            usesDataProtectionKeychain: configuration.usesDataProtectionKeychain,
            synchronizes: configuration.synchronizes
        )
    }

    private static func hashedAccount(for key: CredentialKey) -> String {
        var namespace = Data()
        append(key.providerID, to: &namespace)
        append(key.accountID, to: &namespace)
        append(key.purpose, to: &namespace)
        return SHA256.hash(data: namespace).map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ component: String, to namespace: inout Data) {
        let bytes = Data(component.utf8)
        var length = UInt64(bytes.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { namespace.append(contentsOf: $0) }
        namespace.append(bytes)
    }
}
