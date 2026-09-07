import AccountsAndSecurity
import CryptoKit
import Foundation

public enum PlayStationConsoleRepositoryError: Error, Equatable, Sendable, LocalizedError {
    case duplicateMetadata(UUID)
    case pendingRegistrationConflict(existing: UUID, requested: UUID)
    case pendingRegistrationVerificationFailed(UUID)
    case credentialVerificationFailed(UUID)
    case credentialDeletionVerificationFailed(UUID)
    case metadataVerificationFailed(UUID)
    case pendingRegistrationCleanupFailed(UUID)
    case invalidPendingRegistrationJournal(UUID)
    case pendingRegistrationStateConflict(UUID)
    case consoleNotFound(UUID)
    case ambiguousPhysicalConsoleIdentity
    case physicalConsoleIdentityConflict(UUID)
    case invalidHostAddress(UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidHostAddress:
            "Enter a PS5 address before saving. The Home address cannot be empty."
        case .duplicateMetadata:
            "Remote Play found duplicate saved-console records. Remove the duplicate and try again."
        case .pendingRegistrationConflict:
            "Another PS5 registration is waiting to finish saving. Restart Remote Play before pairing again."
        case .pendingRegistrationVerificationFailed,
             .credentialVerificationFailed,
             .metadataVerificationFailed,
             .pendingRegistrationCleanupFailed:
            "Remote Play paired with the PS5 but could not verify the secure save. Restart the app before trying again."
        case .invalidPendingRegistrationJournal:
            "Remote Play found an invalid interrupted pairing record. Do not pair again until the saved data is repaired."
        case .pendingRegistrationStateConflict:
            "Saved PS5 data changed while an interrupted pairing was being recovered. Remote Play left it untouched."
        case .credentialDeletionVerificationFailed:
            "Remote Play could not securely remove this console. Restart the app and try again."
        case .consoleNotFound:
            "That saved PS5 is no longer available. Return to Home and choose it again."
        case .ambiguousPhysicalConsoleIdentity:
            "Remote Play found more than one saved record for this PS5. Remove the duplicate before pairing again."
        case .physicalConsoleIdentityConflict:
            "That network address belongs to a different saved PS5. Verify the PS5 address before pairing."
        }
    }
}

public enum PendingPlayStationConsoleRecovery: Equatable, Sendable {
    case needsRegistration(SavedPlayStationConsole)
    case completed(SavedPlayStationConsole)
}

public actor PlayStationConsoleRepository {
    public static let providerID = "playstation.remote-play"
    public static let registrationPurpose = "console-registration.v1"

    private let metadataStore: any PlayStationConsoleMetadataStore
    private let credentialStore: any CredentialStore
    private var mutationIsActive = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        metadataStore: any PlayStationConsoleMetadataStore,
        credentialStore: any CredentialStore
    ) {
        self.metadataStore = metadataStore
        self.credentialStore = credentialStore
    }

    public func consoles() async throws -> [SavedPlayStationConsole] {
        try await validatedConsoles()
    }

    public func registration(for consoleID: UUID) async throws -> PlayStationConsoleRegistration? {
        guard let value = try await credentialStore.value(for: credentialKey(for: consoleID)) else {
            return nil
        }
        return try PlayStationConsoleRegistration(envelope: value)
    }

    public func isRegistered(_ consoleID: UUID) async throws -> Bool {
        try await registration(for: consoleID) != nil
    }

    /// Completes a crash-interrupted current transaction when its non-secret
    /// fingerprint matches the Keychain envelope. Legacy journals still require
    /// the caller to provide the intended registration. An older envelope is
    /// never mistaken for the new re-registration.
    public func recoverPendingRegistration(
        expectedRegistration: PlayStationConsoleRegistration? = nil
    ) async throws -> PendingPlayStationConsoleRecovery? {
        await acquireMutationAccess()
        defer { releaseMutationAccess() }

        guard let transaction = try await metadataStore
            .loadPendingRegistrationTransaction() else { return nil }
        let pending = transaction.console
        try validatePendingTransaction(transaction)

        let storedRegistration = try await registration(for: pending.id)
        let fingerprintMatches = transaction.registrationFingerprint.map { fingerprint in
            storedRegistration.map(Self.registrationFingerprint) == fingerprint
        } ?? false
        let expectedMatches = expectedRegistration.map { storedRegistration == $0 } ?? false

        guard fingerprintMatches || expectedMatches else {
            // Current-schema transactions can prove that the intended Keychain
            // write did not survive. Clear only the journal; old metadata and an
            // older re-registration credential remain untouched. Legacy
            // journals stay in place until a caller supplies the expected key.
            if transaction.registrationFingerprint != nil {
                try await clearPendingRegistration(pending.id)
            }
            return .needsRegistration(pending)
        }

        try await finishPendingRegistration(transaction)
        return .completed(pending)
    }

    /// Writes and verifies the secret envelope before exposing its metadata as registered.
    public func save(
        _ console: SavedPlayStationConsole,
        registration: PlayStationConsoleRegistration
    ) async throws {
        await acquireMutationAccess()
        defer { releaseMutationAccess() }

        try await saveLocked(console, registration: registration)
    }

    /// Resolves a successful native registration to one canonical console row
    /// and commits its credential and metadata as a single serialized mutation.
    /// A nonzero MAC is authoritative; normalized host is only a fallback.
    public func reconcileAndSavePairing(
        existingConsoleID: UUID?,
        newConsoleID: UUID? = nil,
        hostAddress: String,
        fallbackDisplayName: String,
        serverNickname: String,
        macAddress: String?,
        registration: PlayStationConsoleRegistration
    ) async throws -> SavedPlayStationConsole {
        await acquireMutationAccess()
        defer { releaseMutationAccess() }

        let consoles = try await validatedConsoles()
        let normalizedHost = Self.normalizedHost(hostAddress)
        let normalizedMAC = Self.normalizedMAC(macAddress)

        let explicitConsole: SavedPlayStationConsole?
        if let existingConsoleID {
            guard let match = consoles.first(where: { $0.id == existingConsoleID }) else {
                throw PlayStationConsoleRepositoryError.consoleNotFound(existingConsoleID)
            }
            explicitConsole = match
        } else {
            explicitConsole = nil
        }

        let macMatches = normalizedMAC.map { incomingMAC in
            consoles.filter { Self.normalizedMAC($0.macAddress) == incomingMAC }
        } ?? []
        guard macMatches.count <= 1 else {
            throw PlayStationConsoleRepositoryError.ambiguousPhysicalConsoleIdentity
        }
        if let explicitConsole,
           let macMatch = macMatches.first,
           macMatch.id != explicitConsole.id {
            throw PlayStationConsoleRepositoryError.physicalConsoleIdentityConflict(macMatch.id)
        }

        let hostMatches = consoles.filter {
            Self.normalizedHost($0.hostAddress) == normalizedHost
        }
        let selected: SavedPlayStationConsole?
        if let explicitConsole {
            selected = explicitConsole
        } else if let macMatch = macMatches.first {
            selected = macMatch
        } else {
            let compatibleHostMatches = hostMatches.filter { console in
                guard let existingMAC = Self.normalizedMAC(console.macAddress),
                      let normalizedMAC else { return true }
                return existingMAC == normalizedMAC
            }
            guard compatibleHostMatches.count <= 1 else {
                throw PlayStationConsoleRepositoryError.ambiguousPhysicalConsoleIdentity
            }
            selected = compatibleHostMatches.first
        }

        if let selected,
           let existingMAC = Self.normalizedMAC(selected.macAddress),
           let normalizedMAC,
           existingMAC != normalizedMAC {
            throw PlayStationConsoleRepositoryError.physicalConsoleIdentityConflict(selected.id)
        }
        if let conflictingHost = hostMatches.first(where: { console in
            guard console.id != selected?.id,
                  let existingMAC = Self.normalizedMAC(console.macAddress),
                  let normalizedMAC else { return false }
            return existingMAC != normalizedMAC
        }) {
            throw PlayStationConsoleRepositoryError.physicalConsoleIdentityConflict(
                conflictingHost.id
            )
        }

        let displayName = serverNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = fallbackDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = SavedPlayStationConsole(
            id: selected?.id ?? newConsoleID ?? UUID(),
            displayName: displayName.isEmpty
                ? (fallbackName.isEmpty ? selected?.displayName ?? "PlayStation 5" : fallbackName)
                : displayName,
            hostAddress: hostAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            macAddress: normalizedMAC ?? selected?.macAddress,
            // Re-registration refreshes the Home address and registration only;
            // a previously saved Away address and route preference survive.
            awayHostAddress: selected?.awayHostAddress,
            connectionRoute: selected?.connectionRoute ?? .home
        )

        let duplicateConsoles = consoles.filter { console in
            guard console.id != canonical.id else { return false }
            let sameMAC = normalizedMAC != nil
                && Self.normalizedMAC(console.macAddress) == normalizedMAC
            let sameFallbackHost = Self.normalizedHost(console.hostAddress) == normalizedHost
                && (Self.normalizedMAC(console.macAddress) == nil
                    || Self.normalizedMAC(console.macAddress) == normalizedMAC)
            return sameMAC || sameFallbackHost
        }

        try await saveLocked(
            canonical,
            registration: registration,
            removingDuplicates: duplicateConsoles
        )
        return canonical
    }

    private func saveLocked(
        _ console: SavedPlayStationConsole,
        registration: PlayStationConsoleRegistration,
        removingDuplicates: [SavedPlayStationConsole] = []
    ) async throws {

        let existingPending = try await metadataStore.loadPendingRegistrationTransaction()
        if let existingPending, existingPending.console.id != console.id {
            throw PlayStationConsoleRepositoryError.pendingRegistrationConflict(
                existing: existingPending.console.id,
                requested: console.id
            )
        }
        var savedConsoles = try await validatedConsoles()
        let fingerprint = Self.registrationFingerprint(registration)
        let transaction: PendingPlayStationConsoleRegistration
        if let existingPending,
           existingPending.registrationFingerprint != nil {
            try validatePendingTransaction(existingPending)
            guard existingPending.console == console,
                  existingPending.registrationFingerprint == fingerprint else {
                throw PlayStationConsoleRepositoryError
                    .pendingRegistrationStateConflict(console.id)
            }
            transaction = existingPending
        } else {
            transaction = PendingPlayStationConsoleRegistration(
                console: console,
                previousConsole: savedConsoles.first(where: { $0.id == console.id }),
                registrationFingerprint: fingerprint,
                supersededConsoles: removingDuplicates.sorted {
                    $0.id.uuidString < $1.id.uuidString
                }
            )
        }
        try validatePendingTransaction(transaction)
        try await metadataStore.savePendingRegistrationTransaction(transaction)
        guard try await metadataStore.loadPendingRegistrationTransaction() == transaction else {
            throw PlayStationConsoleRepositoryError.pendingRegistrationVerificationFailed(console.id)
        }

        let consoleCredentialKey = credentialKey(for: console.id)
        let envelope = registration.envelope
        try await credentialStore.set(envelope, for: consoleCredentialKey)
        guard try await credentialStore.value(for: consoleCredentialKey) == envelope else {
            throw PlayStationConsoleRepositoryError.credentialVerificationFailed(console.id)
        }

        let effectiveDuplicates = transaction.supersededConsoles
        let removingDuplicateIDs = Set(effectiveDuplicates.map(\.id))
        savedConsoles.removeAll {
            $0.id == console.id || removingDuplicateIDs.contains($0.id)
        }
        savedConsoles.append(console)
        try await metadataStore.save(savedConsoles)
        let verifiedConsoles = try await validatedConsoles()
        guard verifiedConsoles.first(where: { $0.id == console.id }) == console,
              removingDuplicateIDs.allSatisfy({ duplicateID in
                  verifiedConsoles.contains(where: { $0.id == duplicateID }) == false
              }) else {
            throw PlayStationConsoleRepositoryError.metadataVerificationFailed(console.id)
        }

        // Remove superseded credentials only after the canonical metadata is
        // durable. A crash before this point must never leave a visible console
        // row whose credential was already destroyed.
        for duplicate in effectiveDuplicates {
            let duplicateCredentialKey = credentialKey(for: duplicate.id)
            try await credentialStore.removeValue(for: duplicateCredentialKey)
            guard try await credentialStore.value(for: duplicateCredentialKey) == nil else {
                throw PlayStationConsoleRepositoryError
                    .credentialDeletionVerificationFailed(duplicate.id)
            }
        }
        try await clearPendingRegistration(console.id)
    }

    /// Updates the non-secret Home/Away addresses and the active route for one
    /// saved console. The registration envelope is untouched, so this never
    /// requires a new Link Device code. An empty Away address clears the Away
    /// route and forces `.home`.
    @discardableResult
    public func updateConnectionAddresses(
        consoleID: UUID,
        hostAddress: String,
        awayHostAddress: String?,
        connectionRoute: PlayStationConnectionRoute
    ) async throws -> SavedPlayStationConsole {
        await acquireMutationAccess()
        defer { releaseMutationAccess() }

        let trimmedHost = hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedHost.isEmpty == false, trimmedHost.utf8.contains(0) == false else {
            throw PlayStationConsoleRepositoryError.invalidHostAddress(consoleID)
        }
        let consoles = try await validatedConsoles()
        guard let existing = consoles.first(where: { $0.id == consoleID }) else {
            throw PlayStationConsoleRepositoryError.consoleNotFound(consoleID)
        }
        if let pending = try await metadataStore.loadPendingRegistrationTransaction(),
           pending.console.id == consoleID {
            throw PlayStationConsoleRepositoryError.pendingRegistrationStateConflict(consoleID)
        }
        let normalizedHost = Self.normalizedHost(trimmedHost)
        if let conflict = consoles.first(where: { other in
            other.id != consoleID && Self.normalizedHost(other.hostAddress) == normalizedHost
        }) {
            throw PlayStationConsoleRepositoryError.physicalConsoleIdentityConflict(conflict.id)
        }

        let updated = SavedPlayStationConsole(
            id: existing.id,
            displayName: existing.displayName,
            hostAddress: trimmedHost,
            macAddress: existing.macAddress,
            awayHostAddress: awayHostAddress,
            connectionRoute: connectionRoute
        )
        try await upsertMetadata(updated)
        return updated
    }

    /// Removes the credential first so a metadata failure cannot leave a usable hidden secret.
    public func remove(_ consoleID: UUID) async throws {
        await acquireMutationAccess()
        defer { releaseMutationAccess() }

        let credentialKey = credentialKey(for: consoleID)
        try await credentialStore.removeValue(for: credentialKey)
        guard try await credentialStore.value(for: credentialKey) == nil else {
            throw PlayStationConsoleRepositoryError.credentialDeletionVerificationFailed(consoleID)
        }

        var savedConsoles = try await validatedConsoles()
        savedConsoles.removeAll { $0.id == consoleID }
        try await metadataStore.save(savedConsoles)
        guard try await metadataStore.load().contains(where: { $0.id == consoleID }) == false else {
            throw PlayStationConsoleRepositoryError.metadataVerificationFailed(consoleID)
        }

        if try await metadataStore.loadPendingRegistration()?.id == consoleID {
            try await clearPendingRegistration(consoleID)
        }
    }

    private func upsertMetadata(
        _ console: SavedPlayStationConsole,
        removingDuplicateIDs: Set<UUID> = []
    ) async throws {
        var savedConsoles = try await validatedConsoles()
        savedConsoles.removeAll { removingDuplicateIDs.contains($0.id) }
        if let index = savedConsoles.firstIndex(where: { $0.id == console.id }) {
            savedConsoles[index] = console
        } else {
            savedConsoles.append(console)
        }
        try await metadataStore.save(savedConsoles)

        let verifiedConsoles = try await validatedConsoles()
        guard verifiedConsoles.first(where: { $0.id == console.id }) == console else {
            throw PlayStationConsoleRepositoryError.metadataVerificationFailed(console.id)
        }
        guard removingDuplicateIDs.allSatisfy({ duplicateID in
            verifiedConsoles.contains(where: { $0.id == duplicateID }) == false
        }) else {
            throw PlayStationConsoleRepositoryError.metadataVerificationFailed(console.id)
        }
    }

    private func finishPendingRegistration(
        _ transaction: PendingPlayStationConsoleRegistration
    ) async throws {
        let console = transaction.console
        let current = try await validatedConsoles()

        if let currentCanonical = current.first(where: { $0.id == console.id }),
           currentCanonical != console,
           currentCanonical != transaction.previousConsole {
            throw PlayStationConsoleRepositoryError
                .pendingRegistrationStateConflict(console.id)
        }
        for superseded in transaction.supersededConsoles {
            if let currentSuperseded = current.first(where: { $0.id == superseded.id }),
               currentSuperseded != superseded {
                throw PlayStationConsoleRepositoryError
                    .pendingRegistrationStateConflict(superseded.id)
            }
        }

        let supersededIDs = Set(transaction.supersededConsoles.map(\.id))
        try await upsertMetadata(console, removingDuplicateIDs: supersededIDs)
        for superseded in transaction.supersededConsoles {
            let key = credentialKey(for: superseded.id)
            try await credentialStore.removeValue(for: key)
            guard try await credentialStore.value(for: key) == nil else {
                throw PlayStationConsoleRepositoryError
                    .credentialDeletionVerificationFailed(superseded.id)
            }
        }
        try await clearPendingRegistration(console.id)
    }

    private func validatePendingTransaction(
        _ transaction: PendingPlayStationConsoleRegistration
    ) throws {
        let consoleID = transaction.console.id
        guard transaction.schemaVersion
                == PendingPlayStationConsoleRegistration.currentSchemaVersion,
              transaction.registrationFingerprint.map({ $0.count == 32 }) ?? true else {
            throw PlayStationConsoleRepositoryError.invalidPendingRegistrationJournal(
                consoleID
            )
        }
        if let previousConsole = transaction.previousConsole,
           previousConsole.id != consoleID {
            throw PlayStationConsoleRepositoryError.invalidPendingRegistrationJournal(
                consoleID
            )
        }
        if transaction.registrationFingerprint == nil,
           transaction.previousConsole != nil
            || transaction.supersededConsoles.isEmpty == false {
            throw PlayStationConsoleRepositoryError.invalidPendingRegistrationJournal(
                consoleID
            )
        }
        var seen: Set<UUID> = []
        for superseded in transaction.supersededConsoles {
            guard superseded.id != consoleID,
                  seen.insert(superseded.id).inserted else {
                throw PlayStationConsoleRepositoryError.invalidPendingRegistrationJournal(
                    consoleID
                )
            }
        }
    }

    private static func registrationFingerprint(
        _ registration: PlayStationConsoleRegistration
    ) -> Data {
        Data(SHA256.hash(data: registration.envelope))
    }

    private func clearPendingRegistration(_ consoleID: UUID) async throws {
        try await metadataStore.clearPendingRegistration(ifMatching: consoleID)
        guard try await metadataStore.loadPendingRegistration() == nil else {
            throw PlayStationConsoleRepositoryError.pendingRegistrationCleanupFailed(consoleID)
        }
    }

    private func credentialKey(for consoleID: UUID) -> CredentialKey {
        CredentialKey(
            providerID: Self.providerID,
            accountID: consoleID.uuidString.lowercased(),
            purpose: Self.registrationPurpose
        )
    }

    private func validatedConsoles() async throws -> [SavedPlayStationConsole] {
        let consoles = try await metadataStore.load()
        var seenIDs: Set<UUID> = []
        for console in consoles where seenIDs.insert(console.id).inserted == false {
            throw PlayStationConsoleRepositoryError.duplicateMetadata(console.id)
        }
        return consoles
    }

    private static func normalizedHost(_ host: String) -> String {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("[") && normalized.hasSuffix("]") {
            normalized.removeFirst()
            normalized.removeLast()
        }
        while normalized.last == "." {
            normalized.removeLast()
        }
        return normalized
    }

    private static func normalizedMAC(_ macAddress: String?) -> String? {
        guard let macAddress else { return nil }
        let hexadecimal = macAddress.lowercased().filter(\.isHexDigit)
        guard hexadecimal.count == 12,
              hexadecimal != "000000000000" else { return nil }
        return stride(from: 0, to: 12, by: 2)
            .map { offset -> String in
                let start = hexadecimal.index(hexadecimal.startIndex, offsetBy: offset)
                let end = hexadecimal.index(start, offsetBy: 2)
                return String(hexadecimal[start..<end])
            }
            .joined(separator: ":")
    }

    /// Swift actors are reentrant across `await`; this gate keeps each multi-store
    /// credential/metadata transaction exclusive until its verification completes.
    private func acquireMutationAccess() async {
        guard mutationIsActive else {
            mutationIsActive = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationAccess() {
        guard mutationWaiters.isEmpty else {
            mutationWaiters.removeFirst().resume()
            return
        }
        mutationIsActive = false
    }
}
