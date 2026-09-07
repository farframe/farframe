import Foundation
import Security

struct SystemKeychainBackend: KeychainBackend {
    func add(_ value: Data, for item: KeychainItem) -> OSStatus {
        var query = baseQuery(for: item)
        query[kSecAttrAccessible] = accessibilityValue(for: item.accessibility)
        query[kSecValueData] = value
        return SecItemAdd(query as CFDictionary, nil)
    }

    func update(_ value: Data, for item: KeychainItem) -> OSStatus {
        let attributes: [CFString: Any] = [
            kSecAttrAccessible: accessibilityValue(for: item.accessibility),
            kSecValueData: value,
        ]
        return SecItemUpdate(baseQuery(for: item) as CFDictionary, attributes as CFDictionary)
    }

    func read(_ item: KeychainItem) -> (status: OSStatus, value: Data?) {
        var query = baseQuery(for: item)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, nil) }
        guard let value = result as? Data else { return (errSecDecode, nil) }
        return (status, value)
    }

    func delete(_ item: KeychainItem) -> OSStatus {
        SecItemDelete(baseQuery(for: item) as CFDictionary)
    }

    private func baseQuery(for item: KeychainItem) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: item.service,
            kSecAttrAccount: item.account,
            kSecUseDataProtectionKeychain: item.usesDataProtectionKeychain ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
            kSecAttrSynchronizable: item.synchronizes ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
        ]
        if let accessGroup = item.accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }

    private func accessibilityValue(for accessibility: KeychainItemAccessibility) -> CFString {
        switch accessibility {
        case .whenUnlocked:
            kSecAttrAccessibleWhenUnlocked
        case .whenUnlockedThisDeviceOnly:
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }
}
