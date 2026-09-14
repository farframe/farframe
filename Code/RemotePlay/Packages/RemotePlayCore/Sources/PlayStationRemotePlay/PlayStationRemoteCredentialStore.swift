import AccountsAndSecurity
import Foundation

/// Renewable authorization is separate from the console's home registration.
/// Only this versioned record enters the device-only Keychain namespace.
public struct PlayStationRemoteAuthorization: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let schemaVersion: Int
    public let accountID: String
    public let accessToken: String
    public let refreshToken: String
    public let issuedAt: Date
    public let expiresAt: Date

    public init(accountID: String, accessToken: String, refreshToken: String, issuedAt: Date, expiresAt: Date) throws {
        self.schemaVersion = 1
        self.accountID = accountID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == 1, Data(base64Encoded: accountID)?.count == 8,
              Self.validToken(accessToken), Self.validToken(refreshToken),
              issuedAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > issuedAt else { throw PlayStationAwayPlayError.invalidAuthorization }
    }

    private static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 16_384 && token.utf8.allSatisfy { $0 > 32 && $0 < 127 }
    }

    public var description: String { "PlayStationRemoteAuthorization(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum PlayStationAwayPlayError: Error, LocalizedError, Equatable, Sendable {
    case disabled, signInRequired, accountMismatch, invalidAuthorization, secureStorageUnavailable, cleanupRequired, cancelled
    public var errorDescription: String? {
        switch self {
        case .disabled: "Away Play is off on this device."
        case .signInRequired: "Sign in again to use Away Play. Home pairing is still saved."
        case .accountMismatch: "Use the PlayStation account paired with this console."
        case .invalidAuthorization: "PlayStation returned an unusable sign-in. Try signing in again."
        case .secureStorageUnavailable: "Secure storage is unavailable. Unlock this device and try again."
        case .cleanupRequired: "Away Play is off. Unlock this device to finish removing its saved sign-in."
        case .cancelled: "Away Play was cancelled."
        }
    }
}

/// Non-secret, durable consent. Turning it off precedes Keychain deletion so a
/// locked Keychain or process exit cannot restore remote access on next launch.
public protocol PlayStationAwayPlayConsentStore: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool)
}

public final class PlayStationAwayPlayDeviceConsent: PlayStationAwayPlayConsentStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "Farframe.AwayPlay.Consent.v1"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var isEnabled: Bool { defaults.bool(forKey: key) }
    public func setEnabled(_ enabled: Bool) { defaults.set(enabled, forKey: key) }
}

public protocol PlayStationRemoteAuthorizationRefreshing: Sendable {
    func refresh(_ authorization: PlayStationRemoteAuthorization) async throws -> PlayStationRemoteAuthorization
}

/// A FIFO storage boundary is necessary even for a reentrant async test/backend.
/// Disable's delete always follows any in-flight write; it never races a save.
private actor AwayPlayCredentialIO {
    let store: any CredentialStore
    let key = CredentialKey(providerID: "playstation-remote-play", accountID: "this-device", purpose: "away-authorization-v1")
    private var tail: Task<Void, Never>?
    private var permittedGeneration: UUID?
    func authorize(_ generation: UUID) { permittedGeneration = generation }
    init(store: any CredentialStore) { self.store = store }

    func read() async throws -> Data? {
        let previous = tail
        let work = Task { [store, key] in
            await previous?.value
            return try await store.value(for: key)
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }
    func write(_ data: Data, generation: UUID) async throws {
        guard permittedGeneration == generation else { throw PlayStationAwayPlayError.cancelled }
        let previous = tail
        let work = Task { [store, key] in
            await previous?.value
            guard self.permittedGeneration == generation else { throw PlayStationAwayPlayError.cancelled }
            try await store.set(data, for: key)
        }
        tail = Task { _ = try? await work.value }
        try await work.value
    }
    func remove() async throws {
        permittedGeneration = nil
        let previous = tail
        let work = Task { [store, key] in
            await previous?.value
            try await store.removeValue(for: key)
        }
        tail = Task { _ = try? await work.value }
        try await work.value
    }
}

/// One device-local owner for consent, rotation and forgetting. Platform shells
/// share this instance. It has no dependency on home registration or media.
public actor PlayStationRemoteCredentialStore {
    public enum Status: Equatable, Sendable { case off, enabling, ready, signInRequired, cleanupRequired }
    public private(set) var status: Status = .off
    private let io: AwayPlayCredentialIO
    private let consent: any PlayStationAwayPlayConsentStore
    private let refresher: any PlayStationRemoteAuthorizationRefreshing
    private let now: @Sendable () -> Date
    private var generation = UUID()
    private var authorization: PlayStationRemoteAuthorization?
    private var refreshTask: Task<PlayStationRemoteAuthorization, any Error>?
    private var restoreTask: Task<Data?, any Error>?
    private var restored = false

    public init(credentials: any CredentialStore = KeychainCredentialStore(),
                consent: any PlayStationAwayPlayConsentStore = PlayStationAwayPlayDeviceConsent(),
                refresher: any PlayStationRemoteAuthorizationRefreshing,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.io = AwayPlayCredentialIO(store: credentials)
        self.consent = consent
        self.refresher = refresher
        self.now = now
    }

    public func restore() async throws {
        guard !restored else { return }
        let stamp = generation
        if !consent.isEnabled {
            // Also retry interrupted cleanup from a previous process.
            try await disable()
            return
        }
        let work: Task<Data?, any Error>
        if let restoreTask { work = restoreTask }
        else {
            work = Task { [io] in try await io.read() }
            restoreTask = work
        }
        do {
            let data = try await work.value
            try ensureCurrent(stamp)
            restoreTask = nil
            restored = true
            guard let data else { status = .signInRequired; return }
            guard data.count <= 65_536 else { throw PlayStationAwayPlayError.invalidAuthorization }
            let record = try JSONDecoder().decode(PlayStationRemoteAuthorization.self, from: data)
            try record.validate()
            authorization = record
            await io.authorize(stamp)
            try ensureCurrent(stamp)
            status = .ready
        } catch {
            guard generation == stamp else { throw PlayStationAwayPlayError.cancelled }
            restoreTask = nil
            status = .signInRequired
            throw PlayStationAwayPlayError.secureStorageUnavailable
        }
    }

    /// Call only with the result of the explicit pre-login Away Play opt-in.
    /// No implicit save occurs during ordinary home account lookup.
    public func enable(with record: PlayStationRemoteAuthorization, expectedAccountID: String) async throws {
        try record.validate()
        guard record.accountID == expectedAccountID else { throw PlayStationAwayPlayError.accountMismatch }
        guard record.issuedAt <= now(), record.expiresAt > now() else { throw PlayStationAwayPlayError.invalidAuthorization }
        guard status != .cleanupRequired, status != .enabling else { throw PlayStationAwayPlayError.cleanupRequired }
        if let authorization, authorization.accountID != expectedAccountID { throw PlayStationAwayPlayError.accountMismatch }
        generation = UUID()
        let stamp = generation
        refreshTask?.cancel(); refreshTask = nil
        consent.setEnabled(false)
        authorization = nil
        status = .enabling
        do {
            await io.authorize(stamp)
            try ensureCurrent(stamp)
            try await io.write(JSONEncoder().encode(record), generation: stamp)
            try ensureCurrent(stamp)
            authorization = record
            restored = true
            consent.setEnabled(true)
            status = .ready
        } catch {
            guard generation == stamp else { throw PlayStationAwayPlayError.cancelled }
            status = .cleanupRequired
            throw PlayStationAwayPlayError.secureStorageUnavailable
        }
    }

    public func validAuthorization(for accountID: String) async throws -> PlayStationRemoteAuthorization {
        try await restore()
        guard consent.isEnabled, status == .ready else {
            if status == .cleanupRequired { throw PlayStationAwayPlayError.cleanupRequired }
            throw status == .off ? PlayStationAwayPlayError.disabled : .signInRequired
        }
        guard let record = authorization else { throw PlayStationAwayPlayError.signInRequired }
        guard record.accountID == accountID else { throw PlayStationAwayPlayError.accountMismatch }
        let stamp = generation
        if record.issuedAt <= now(), record.expiresAt.timeIntervalSince(now()) > 60 { return record }
        let work: Task<PlayStationRemoteAuthorization, any Error>
        if let refreshTask { work = refreshTask }
        else {
            work = Task { [refresher, io, now] in
                let replacement = try await refresher.refresh(record)
                try Task.checkCancellation()
                try replacement.validate()
                guard replacement.accountID == record.accountID else { throw PlayStationAwayPlayError.accountMismatch }
                guard replacement.issuedAt <= now(), replacement.expiresAt > now() else { throw PlayStationAwayPlayError.invalidAuthorization }
                // Cancellation check immediately before enqueue. A concurrently
                // queued disable deletion follows this write through the FIFO.
                try Task.checkCancellation()
                try await io.write(JSONEncoder().encode(replacement), generation: stamp)
                try Task.checkCancellation()
                return replacement
            }
            refreshTask = work
        }
        let replacement: PlayStationRemoteAuthorization
        do {
            replacement = try await work.value
        } catch {
            guard generation == stamp else { throw PlayStationAwayPlayError.cancelled }
            authorization = nil
            refreshTask = nil
            status = .signInRequired
            throw PlayStationAwayPlayError.signInRequired
        }
        guard generation == stamp, consent.isEnabled else { throw PlayStationAwayPlayError.cancelled }
        // A caller's cancellation must not discard a rotation shared with other
        // callers or leave the old one-use refresh token in memory.
        authorization = replacement
        refreshTask = nil
        if Task.isCancelled { throw PlayStationAwayPlayError.cancelled }
        return replacement
    }

    /// The caller cancels its remote session before awaiting this cleanup.
    /// Invalidating this owner immediately rejects late refresh/enable results.
    public func disable() async throws {
        generation = UUID()
        let stamp = generation
        consent.setEnabled(false)
        authorization = nil
        refreshTask?.cancel(); refreshTask = nil
        restoreTask?.cancel(); restoreTask = nil
        restored = true
        status = .cleanupRequired
        do {
            try await io.remove()
            guard generation == stamp else { return }
            status = .off
        } catch {
            throw PlayStationAwayPlayError.cleanupRequired
        }
    }

    private func ensureCurrent(_ stamp: UUID) throws {
        guard generation == stamp, !Task.isCancelled else { throw PlayStationAwayPlayError.cancelled }
    }
}
