import AccountsAndSecurity
import Foundation
import Security
import Testing

@Test
func keychainStoreAddsUpdatesReadsAndDeletesWithoutUsingLoginKeychain() async throws {
    let backend = FakeKeychainBackend()
    let store = KeychainCredentialStore(backend: backend)
    let key = CredentialKey(
        providerID: "playstation.remote-play",
        accountID: "console-uuid",
        purpose: "console-registration.v1"
    )

    #expect(try await store.value(for: key) == nil)

    try await store.set(Data([0x01]), for: key)
    #expect(try await store.value(for: key) == Data([0x01]))

    try await store.set(Data([0x02]), for: key)
    #expect(try await store.value(for: key) == Data([0x02]))
    #expect(backend.addCalls == 2)
    #expect(backend.updateCalls == 1)

    try await store.removeValue(for: key)
    try await store.removeValue(for: key)
    #expect(try await store.value(for: key) == nil)
}

@Test
func keychainStoreUsesDeviceLocalDataProtectionAttributes() async throws {
    let backend = FakeKeychainBackend()
    let service = "test.remoteplay.credentials"
    let store = KeychainCredentialStore(service: service, backend: backend)
    let key = CredentialKey(providerID: "provider", accountID: "subject", purpose: "secret")

    try await store.set(Data([0xAA]), for: key)

    let item = try #require(backend.lastItem)
    #expect(item.service == service)
    #expect(item.account.count == 64)
    #expect(item.account.contains("provider") == false)
    #expect(item.account.contains("subject") == false)
    #expect(item.accessGroup == nil)
    #expect(item.accessibility == .whenUnlockedThisDeviceOnly)
    #expect(item.usesDataProtectionKeychain)
    #expect(item.synchronizes == false)
}

@Test
func keychainStoreBuildsSeparateOptInSynchronizableBootstrapItems() async throws {
    let backend = FakeKeychainBackend()
    let accessGroup = "TEAMID.com.unshackledpursuit.remoteplay.ecosystem"
    let configuration = KeychainCredentialStoreConfiguration.synchronizedBootstrap(
        accessGroup: accessGroup
    )
    let store = KeychainCredentialStore(configuration: configuration, backend: backend)
    let key = CredentialKey(
        providerID: "playstation.remote-play",
        accountID: "ecosystem-catalog",
        purpose: "console-registration-bootstrap.v1"
    )

    try await store.set(Data([0x01]), for: key)

    let item = try #require(backend.lastItem)
    #expect(item.service == KeychainCredentialStore.defaultSynchronizedBootstrapService)
    #expect(item.accessGroup == accessGroup)
    #expect(item.accessibility == .whenUnlocked)
    #expect(item.usesDataProtectionKeychain)
    #expect(item.synchronizes)
}

@Test
func keychainStoreCanPinDeviceLocalQueriesToAnExplicitAppGroup() async throws {
    let backend = FakeKeychainBackend()
    let accessGroup = "TEAMID.com.unshackledpursuit.remoteplay.vision"
    let configuration = KeychainCredentialStoreConfiguration.deviceLocal(
        accessGroup: accessGroup
    )
    let store = KeychainCredentialStore(configuration: configuration, backend: backend)

    try await store.set(
        Data([0x02]),
        for: CredentialKey(providerID: "provider", accountID: "subject", purpose: "secret")
    )

    let item = try #require(backend.lastItem)
    #expect(item.accessGroup == accessGroup)
    #expect(item.accessibility == .whenUnlockedThisDeviceOnly)
    #expect(item.synchronizes == false)
}

@Test
func keychainAccountNamespaceIsDeterministicAndLengthPrefixed() async throws {
    let backend = FakeKeychainBackend()
    let store = KeychainCredentialStore(backend: backend)
    let first = CredentialKey(providerID: "ab", accountID: "c", purpose: "")
    let second = CredentialKey(providerID: "a", accountID: "bc", purpose: "")

    try await store.set(Data([0x01]), for: first)
    let firstAccount = try #require(backend.lastItem?.account)
    try await store.set(Data([0x02]), for: second)
    let secondAccount = try #require(backend.lastItem?.account)

    #expect(firstAccount != secondAccount)

    let secondBackend = FakeKeychainBackend()
    let secondStore = KeychainCredentialStore(backend: secondBackend)
    try await secondStore.set(Data([0x03]), for: first)
    #expect(secondBackend.lastItem?.account == firstAccount)
}

@Test
func keychainStoreReportsTypedStatusWithoutCredentialMaterial() async throws {
    let backend = FakeKeychainBackend()
    backend.readStatusOverride = errSecAuthFailed
    let store = KeychainCredentialStore(backend: backend)
    let key = CredentialKey(providerID: "provider", accountID: "subject", purpose: "secret")

    do {
        _ = try await store.value(for: key)
        Issue.record("Expected a typed Keychain read error")
    } catch let error as KeychainCredentialStoreError {
        #expect(error.operation == .read)
        #expect(error.status == errSecAuthFailed)
        #expect(error.localizedDescription.contains("subject") == false)
    }
}

private final class FakeKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [KeychainItem: Data] = [:]
    private var _lastItem: KeychainItem?
    private var _addCalls = 0
    private var _updateCalls = 0
    private var _readStatusOverride: OSStatus?

    var lastItem: KeychainItem? {
        lock.lock()
        defer { lock.unlock() }
        return _lastItem
    }

    var addCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _addCalls
    }

    var updateCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _updateCalls
    }

    var readStatusOverride: OSStatus? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _readStatusOverride
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _readStatusOverride = newValue
        }
    }

    func add(_ value: Data, for item: KeychainItem) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        _lastItem = item
        _addCalls += 1
        guard values[item] == nil else { return errSecDuplicateItem }
        values[item] = value
        return errSecSuccess
    }

    func update(_ value: Data, for item: KeychainItem) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        _lastItem = item
        _updateCalls += 1
        guard values[item] != nil else { return errSecItemNotFound }
        values[item] = value
        return errSecSuccess
    }

    func read(_ item: KeychainItem) -> (status: OSStatus, value: Data?) {
        lock.lock()
        defer { lock.unlock() }
        _lastItem = item
        if let readStatusOverride = _readStatusOverride {
            return (readStatusOverride, nil)
        }
        guard let value = values[item] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, value)
    }

    func delete(_ item: KeychainItem) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        _lastItem = item
        guard values.removeValue(forKey: item) != nil else { return errSecItemNotFound }
        return errSecSuccess
    }
}
