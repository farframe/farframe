#if DEBUG
import AccountsAndSecurity
import Darwin
import Foundation

/// A real signed-host check, unlike tests using an injected Keychain backend.
/// Uses a unique synthetic namespace and never reads or changes paired consoles.
enum MacKeychainSelfTest {
    private enum Failure: Error { case unexpectedValue }

    static func runAndExit() async {
        let store = KeychainCredentialStore(
            service: "com.unshackledpursuit.farframe.keychain-self-test.\(UUID().uuidString)"
        )
        let key = CredentialKey(
            providerID: "signing-self-test", accountID: "synthetic", purpose: "disposable"
        )
        do {
            let first = Data("synthetic-create".utf8)
            let second = Data("synthetic-update".utf8)
            try await store.set(first, for: key)
            guard try await store.value(for: key) == first else { throw Failure.unexpectedValue }
            try await store.set(second, for: key)
            guard try await store.value(for: key) == second else { throw Failure.unexpectedValue }
            try await store.removeValue(for: key)
            guard try await store.value(for: key) == nil else { throw Failure.unexpectedValue }
            print("Farframe signed-host Keychain self-test: PASS (create/read/update/read/delete/absent)")
            exit(EXIT_SUCCESS)
        } catch {
            // Only these typed, non-sensitive fields can reach diagnostic output.
            if let failure = error as? KeychainCredentialStoreError {
                print("Farframe signed-host Keychain self-test: FAIL (\(failure.operation.rawValue), \(failure.status))")
            } else {
                print("Farframe signed-host Keychain self-test: FAIL (verification)")
            }
            do {
                try await store.removeValue(for: key)
            } catch {
                print("Farframe signed-host Keychain self-test: synthetic-item cleanup failed")
            }
            exit(EXIT_FAILURE)
        }
    }
}
#endif
