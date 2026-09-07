import Foundation

/// Non-secret recovery record for a registration transaction that crossed the
/// native PS5 boundary but has not finished its verified metadata cleanup.
/// The fingerprint is SHA-256 of the Keychain envelope, never the envelope.
public struct PendingPlayStationConsoleRegistration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt8 = 1

    public let schemaVersion: UInt8
    public let console: SavedPlayStationConsole
    public let previousConsole: SavedPlayStationConsole?
    public let registrationFingerprint: Data?
    public let supersededConsoles: [SavedPlayStationConsole]

    public init(
        console: SavedPlayStationConsole,
        previousConsole: SavedPlayStationConsole? = nil,
        registrationFingerprint: Data? = nil,
        supersededConsoles: [SavedPlayStationConsole] = []
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.console = console
        self.previousConsole = previousConsole
        self.registrationFingerprint = registrationFingerprint
        self.supersededConsoles = supersededConsoles
    }
}

public protocol PlayStationConsoleMetadataStore: Sendable {
    func load() async throws -> [SavedPlayStationConsole]
    func save(_ consoles: [SavedPlayStationConsole]) async throws
    func loadPendingRegistration() async throws -> SavedPlayStationConsole?
    func savePendingRegistration(_ console: SavedPlayStationConsole) async throws
    func clearPendingRegistration(ifMatching consoleID: UUID) async throws
    func loadPendingRegistrationTransaction() async throws
        -> PendingPlayStationConsoleRegistration?
    func savePendingRegistrationTransaction(
        _ transaction: PendingPlayStationConsoleRegistration
    ) async throws
}

public enum PlayStationConsoleMetadataStoreError: Error, Equatable, Sendable {
    case pendingRegistrationConflict(existing: UUID, requested: UUID)
    case verificationFailed
}

public actor InMemoryPlayStationConsoleMetadataStore: PlayStationConsoleMetadataStore {
    private var consoles: [SavedPlayStationConsole]
    private var pendingRegistration: PendingPlayStationConsoleRegistration?

    public init(
        consoles: [SavedPlayStationConsole] = [],
        pendingRegistration: SavedPlayStationConsole? = nil
    ) {
        self.consoles = consoles
        self.pendingRegistration = pendingRegistration.map {
            PendingPlayStationConsoleRegistration(console: $0)
        }
    }

    public func load() -> [SavedPlayStationConsole] {
        consoles
    }

    public func save(_ consoles: [SavedPlayStationConsole]) {
        self.consoles = consoles
    }

    public func loadPendingRegistration() -> SavedPlayStationConsole? {
        pendingRegistration?.console
    }

    public func savePendingRegistration(_ console: SavedPlayStationConsole) throws {
        let transaction = PendingPlayStationConsoleRegistration(console: console)
        if let pendingRegistration,
           pendingRegistration.console.id != transaction.console.id {
            throw PlayStationConsoleMetadataStoreError.pendingRegistrationConflict(
                existing: pendingRegistration.console.id,
                requested: transaction.console.id
            )
        }
        pendingRegistration = transaction
    }

    public func loadPendingRegistrationTransaction() async throws
        -> PendingPlayStationConsoleRegistration? {
        pendingRegistration
    }

    public func savePendingRegistrationTransaction(
        _ transaction: PendingPlayStationConsoleRegistration
    ) async throws {
        if let pendingRegistration,
           pendingRegistration.console.id != transaction.console.id {
            throw PlayStationConsoleMetadataStoreError.pendingRegistrationConflict(
                existing: pendingRegistration.console.id,
                requested: transaction.console.id
            )
        }
        pendingRegistration = transaction
    }

    public func clearPendingRegistration(ifMatching consoleID: UUID) throws {
        if let pendingRegistration, pendingRegistration.console.id != consoleID {
            throw PlayStationConsoleMetadataStoreError.pendingRegistrationConflict(
                existing: pendingRegistration.console.id,
                requested: consoleID
            )
        }
        pendingRegistration = nil
    }
}

public actor UserDefaultsPlayStationConsoleMetadataStore: PlayStationConsoleMetadataStore {
    public static let defaultStorageKey = "RemotePlay.PlayStation.Consoles.v1"
    public static let defaultPendingRegistrationKey = "RemotePlay.PlayStation.PendingRegistration.v1"

    private let defaults: UserDefaults
    private let storageKey: String
    private let pendingRegistrationKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        suiteName: String? = nil,
        storageKey: String = UserDefaultsPlayStationConsoleMetadataStore.defaultStorageKey,
        pendingRegistrationKey: String = UserDefaultsPlayStationConsoleMetadataStore.defaultPendingRegistrationKey
    ) {
        if let suiteName {
            self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        } else {
            self.defaults = .standard
        }
        self.storageKey = storageKey
        self.pendingRegistrationKey = pendingRegistrationKey
    }

    public func load() throws -> [SavedPlayStationConsole] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return try decoder.decode([SavedPlayStationConsole].self, from: data)
    }

    public func save(_ consoles: [SavedPlayStationConsole]) throws {
        let encoded = try encoder.encode(consoles)
        defaults.set(encoded, forKey: storageKey)
        guard defaults.data(forKey: storageKey) == encoded else {
            throw PlayStationConsoleMetadataStoreError.verificationFailed
        }
    }

    public func loadPendingRegistration() throws -> SavedPlayStationConsole? {
        try loadPendingRegistrationTransactionSynchronously()?.console
    }

    public func loadPendingRegistrationTransaction() async throws
        -> PendingPlayStationConsoleRegistration? {
        try loadPendingRegistrationTransactionSynchronously()
    }

    private func loadPendingRegistrationTransactionSynchronously() throws
        -> PendingPlayStationConsoleRegistration? {
        guard let data = defaults.data(forKey: pendingRegistrationKey) else { return nil }
        if let transaction = try? decoder.decode(
            PendingPlayStationConsoleRegistration.self,
            from: data
        ) {
            return transaction
        }
        // Read the pre-transaction journal shape so upgrades never strand an
        // interrupted legacy migration. It remains expected-registration gated.
        return PendingPlayStationConsoleRegistration(
            console: try decoder.decode(SavedPlayStationConsole.self, from: data)
        )
    }

    public func savePendingRegistration(_ console: SavedPlayStationConsole) throws {
        try savePendingRegistrationTransactionSynchronously(
            PendingPlayStationConsoleRegistration(console: console)
        )
    }

    public func savePendingRegistrationTransaction(
        _ transaction: PendingPlayStationConsoleRegistration
    ) async throws {
        try savePendingRegistrationTransactionSynchronously(transaction)
    }

    private func savePendingRegistrationTransactionSynchronously(
        _ transaction: PendingPlayStationConsoleRegistration
    ) throws {
        if let existing = try loadPendingRegistrationTransactionSynchronously(),
           existing.console.id != transaction.console.id {
            throw PlayStationConsoleMetadataStoreError.pendingRegistrationConflict(
                existing: existing.console.id,
                requested: transaction.console.id
            )
        }
        let encoded = try encoder.encode(transaction)
        defaults.set(encoded, forKey: pendingRegistrationKey)
        guard defaults.data(forKey: pendingRegistrationKey) == encoded else {
            throw PlayStationConsoleMetadataStoreError.verificationFailed
        }
    }

    public func clearPendingRegistration(ifMatching consoleID: UUID) throws {
        if let existing = try loadPendingRegistrationTransactionSynchronously(),
           existing.console.id != consoleID {
            throw PlayStationConsoleMetadataStoreError.pendingRegistrationConflict(
                existing: existing.console.id,
                requested: consoleID
            )
        }
        defaults.removeObject(forKey: pendingRegistrationKey)
        guard defaults.data(forKey: pendingRegistrationKey) == nil else {
            throw PlayStationConsoleMetadataStoreError.verificationFailed
        }
    }
}
