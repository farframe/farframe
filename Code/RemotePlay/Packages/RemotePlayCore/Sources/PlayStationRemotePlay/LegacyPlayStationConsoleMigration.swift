import Foundation

/// Codable shape of the legacy `PSPlayVision.RegisteredDevices` preferences blob.
public struct LegacyPlayStationConsoleRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let hostAddress: String
    public let macAddress: String?
    public let registrationKey: Data?
    public let rpKey: Data?
    public let isRegistered: Bool

    public init(
        id: UUID,
        name: String,
        hostAddress: String,
        macAddress: String?,
        registrationKey: Data?,
        rpKey: Data?,
        isRegistered: Bool
    ) {
        self.id = id
        self.name = name
        self.hostAddress = hostAddress
        self.macAddress = macAddress
        self.registrationKey = registrationKey
        self.rpKey = rpKey
        self.isRegistered = isRegistered
    }
}

public protocol LegacyPlayStationConsoleDataStore: Sendable {
    func load() async throws -> Data?
    func remove(ifUnchanged expectedData: Data) async throws
}

public actor UserDefaultsLegacyPlayStationConsoleDataStore: LegacyPlayStationConsoleDataStore {
    public static let defaultStorageKey = "PSPlayVision.RegisteredDevices"

    private let defaults: UserDefaults
    private let storageKey: String

    public init(
        suiteName: String? = nil,
        storageKey: String = UserDefaultsLegacyPlayStationConsoleDataStore.defaultStorageKey
    ) {
        if let suiteName {
            self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        } else {
            self.defaults = .standard
        }
        self.storageKey = storageKey
    }

    public func load() -> Data? {
        defaults.data(forKey: storageKey)
    }

    public func remove(ifUnchanged expectedData: Data) throws {
        guard defaults.data(forKey: storageKey) == expectedData else {
            throw LegacyPlayStationConsoleMigrationError.legacySourceChanged
        }
        defaults.removeObject(forKey: storageKey)
        guard defaults.data(forKey: storageKey) == nil else {
            throw LegacyPlayStationConsoleMigrationError.legacyRemovalVerificationFailed
        }
    }
}

public enum LegacyPlayStationConsoleMigrationResult: Equatable, Sendable {
    case noLegacyData
    case migrated(Int)
}

public enum LegacyPlayStationConsoleMigrationError: Error, Equatable, Sendable {
    case duplicateConsoleID(UUID)
    case recordIsNotRegistered(UUID)
    case invalidSecretMaterial(UUID)
    case pendingRegistrationNotInLegacySource(UUID)
    case pendingRegistrationMetadataConflict(UUID)
    case conflictingMigratedCredential(UUID)
    case conflictingMigratedMetadata(UUID)
    case migratedRecordVerificationFailed(UUID)
    case legacySourceChanged
    case legacyRemovalVerificationFailed
}

public actor LegacyPlayStationConsoleMigrator {
    private struct PreparedRecord: Sendable {
        let console: SavedPlayStationConsole
        let registration: PlayStationConsoleRegistration
    }

    private let source: any LegacyPlayStationConsoleDataStore
    private let repository: PlayStationConsoleRepository
    private let decoder = JSONDecoder()

    public init(
        source: any LegacyPlayStationConsoleDataStore,
        repository: PlayStationConsoleRepository
    ) {
        self.source = source
        self.repository = repository
    }

    public func migrate() async throws -> LegacyPlayStationConsoleMigrationResult {
        guard let legacyData = try await source.load() else { return .noLegacyData }
        let records = try decoder.decode([LegacyPlayStationConsoleRecord].self, from: legacyData)
        let prepared = try prepare(records)
        try await preflightCanonicalState(prepared)

        var resumedConsoleID: UUID?
        if let recovery = try await repository.recoverPendingRegistration() {
            let pendingConsole: SavedPlayStationConsole
            switch recovery {
            case let .needsRegistration(console), let .completed(console):
                pendingConsole = console
            }

            guard let pendingRecord = prepared.first(where: { $0.console.id == pendingConsole.id }) else {
                throw LegacyPlayStationConsoleMigrationError.pendingRegistrationNotInLegacySource(
                    pendingConsole.id
                )
            }
            guard pendingRecord.console == pendingConsole else {
                throw LegacyPlayStationConsoleMigrationError.pendingRegistrationMetadataConflict(
                    pendingConsole.id
                )
            }

            let verifiedRecovery = try await repository.recoverPendingRegistration(
                expectedRegistration: pendingRecord.registration
            )
            if verifiedRecovery == nil {
                try await repository.save(
                    pendingRecord.console,
                    registration: pendingRecord.registration
                )
            } else if case .needsRegistration = verifiedRecovery {
                try await repository.save(
                    pendingRecord.console,
                    registration: pendingRecord.registration
                )
            }
            resumedConsoleID = pendingConsole.id
        }

        for record in prepared where record.console.id != resumedConsoleID {
            try await repository.save(record.console, registration: record.registration)
        }

        let savedConsoles = try await repository.consoles()
        for record in prepared {
            guard savedConsoles.first(where: { $0.id == record.console.id }) == record.console,
                  try await repository.registration(for: record.console.id) == record.registration else {
                throw LegacyPlayStationConsoleMigrationError.migratedRecordVerificationFailed(record.console.id)
            }
        }

        try await source.remove(ifUnchanged: legacyData)
        guard try await source.load() == nil else {
            throw LegacyPlayStationConsoleMigrationError.legacyRemovalVerificationFailed
        }
        return .migrated(prepared.count)
    }

    private func preflightCanonicalState(_ prepared: [PreparedRecord]) async throws {
        let savedConsoles = try await repository.consoles()

        for record in prepared {
            if let savedConsole = savedConsoles.first(where: { $0.id == record.console.id }),
               savedConsole != record.console {
                throw LegacyPlayStationConsoleMigrationError.conflictingMigratedMetadata(
                    record.console.id
                )
            }

            if let savedRegistration = try await repository.registration(for: record.console.id),
               savedRegistration != record.registration {
                throw LegacyPlayStationConsoleMigrationError.conflictingMigratedCredential(
                    record.console.id
                )
            }
        }
    }

    private func prepare(_ records: [LegacyPlayStationConsoleRecord]) throws -> [PreparedRecord] {
        var seenIDs: Set<UUID> = []
        return try records.map { record in
            guard seenIDs.insert(record.id).inserted else {
                throw LegacyPlayStationConsoleMigrationError.duplicateConsoleID(record.id)
            }
            guard record.isRegistered else {
                throw LegacyPlayStationConsoleMigrationError.recordIsNotRegistered(record.id)
            }
            guard let registrationKey = record.registrationKey,
                  let remotePlayKey = record.rpKey,
                  let registration = try? PlayStationConsoleRegistration(
                    registrationKey: registrationKey,
                    remotePlayKey: remotePlayKey
                  ) else {
                throw LegacyPlayStationConsoleMigrationError.invalidSecretMaterial(record.id)
            }

            return PreparedRecord(
                console: SavedPlayStationConsole(
                    id: record.id,
                    displayName: record.name,
                    hostAddress: record.hostAddress,
                    macAddress: record.macAddress
                ),
                registration: registration
            )
        }
    }
}
