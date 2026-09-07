import AccountsAndSecurity
import ChiakiNative
import Dispatch
import Foundation

public enum PlayStationPairingInputError: Error, Equatable, Sendable, LocalizedError {
    case invalidAccountID
    case invalidLinkDevicePIN
    case invalidHost

    public var errorDescription: String? {
        switch self {
        case .invalidAccountID:
            "Enter the exact PlayStation Account ID as Base64 or decimal. Prefix digit-only 16-digit hexadecimal with 0x."
        case .invalidLinkDevicePIN:
            "Enter all eight digits shown by Link Device on your PS5."
        case .invalidHost:
            "Enter the local IP address or host name of your PS5."
        }
    }
}

public struct PlayStationAccountID: Equatable, Sendable {
    public static let byteCount = 8
    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw PlayStationPairingInputError.invalidAccountID
        }
        self.bytes = bytes
    }

    /// Accepts the three representations used by established Remote Play tools.
    /// Decimal values are encoded little-endian, matching Sony's account codec.
    public init(manualValue: String) throws {
        let value = manualValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = Data(base64Encoded: value), decoded.count == Self.byteCount {
            try self.init(bytes: decoded)
            return
        }
        let explicitlyHexadecimal = value.lowercased().hasPrefix("0x")
        let hexadecimal = explicitlyHexadecimal ? String(value.dropFirst(2)) : value
        let hasHexadecimalLetter = hexadecimal.utf8.contains {
            (65...70).contains($0) || (97...102).contains($0)
        }
        if hexadecimal.count == Self.byteCount * 2,
           hexadecimal.allSatisfy(\.isHexDigit),
           explicitlyHexadecimal || hasHexadecimalLetter {
            var bytes = Data(capacity: Self.byteCount)
            var index = hexadecimal.startIndex
            for _ in 0..<Self.byteCount {
                let next = hexadecimal.index(index, offsetBy: 2)
                guard let byte = UInt8(hexadecimal[index..<next], radix: 16) else {
                    throw PlayStationPairingInputError.invalidAccountID
                }
                bytes.append(byte)
                index = next
            }
            try self.init(bytes: bytes)
            return
        }
        if let decimal = UInt64(value) {
            var littleEndian = decimal.littleEndian
            let bytes = withUnsafeBytes(of: &littleEndian) { Data($0) }
            try self.init(bytes: bytes)
            return
        }
        throw PlayStationPairingInputError.invalidAccountID
    }
}

public struct PlayStationLinkDevicePIN: Equatable, Sendable {
    public let digits: String

    public init(_ value: String) throws {
        guard value.utf8.count == 8,
              value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            throw PlayStationPairingInputError.invalidLinkDevicePIN
        }
        digits = value
    }
}

public struct PlayStationPairingRequest: Equatable, Sendable {
    public let existingConsoleID: UUID?
    public let hostAddress: String
    public let fallbackDisplayName: String
    public let accountID: PlayStationAccountID
    public let pin: PlayStationLinkDevicePIN

    public init(
        existingConsoleID: UUID? = nil,
        hostAddress: String,
        fallbackDisplayName: String = "PlayStation 5",
        accountID: PlayStationAccountID,
        pin: PlayStationLinkDevicePIN
    ) throws {
        let host = hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.isEmpty == false, host.utf8.contains(0) == false else {
            throw PlayStationPairingInputError.invalidHost
        }
        self.existingConsoleID = existingConsoleID
        self.hostAddress = host
        self.fallbackDisplayName = fallbackDisplayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.accountID = accountID
        self.pin = pin
    }
}

public struct PlayStationNativeRegistrationResult: Equatable, Sendable {
    public let registration: PlayStationConsoleRegistration
    public let serverNickname: String
    public let serverMAC: Data

    public init(
        registration: PlayStationConsoleRegistration,
        serverNickname: String,
        serverMAC: Data
    ) {
        self.registration = registration
        self.serverNickname = serverNickname
        self.serverMAC = serverMAC
    }
}

public protocol PlayStationNativeRegistrationClient: Sendable {
    func register(_ request: PlayStationPairingRequest) async throws
        -> PlayStationNativeRegistrationResult
}

public protocol PlayStationNativeRegistrationClientFactory: Sendable {
    func makeClient() throws -> any PlayStationNativeRegistrationClient
}

public enum PlayStationPairingError:
    Error, Equatable, Sendable, LocalizedError, CustomNSError {
    case alreadyInProgress
    case timedOut
    case invalidServerMAC
    case secureSavePending
    case noPendingSecureSave

    public var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            "Another PS5 pairing session is already running."
        case .timedOut:
            "Pairing timed out. Keep Link Device open on your PS5, request a new code, and try again."
        case .invalidServerMAC:
            "The PS5 returned an invalid network identity."
        case .secureSavePending:
            "The PS5 paired successfully, but Remote Play could not verify the secure save. Try saving again without requesting a new Link Device code."
        case .noPendingSecureSave:
            "There is no PS5 registration waiting to be saved."
        }
    }

    /// A stable error identity survives static-library image boundaries. That
    /// matters for hosted test bundles and any future plug-in process where a
    /// Swift enum's runtime metadata can be present more than once.
    public static let errorDomain =
        "com.unshackledpursuit.farframe.playstation-pairing"

    public var errorCode: Int {
        switch self {
        case .alreadyInProgress: 1
        case .timedOut: 2
        case .invalidServerMAC: 3
        case .secureSavePending: 4
        case .noPendingSecureSave: 5
        }
    }

    public var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: errorDescription ?? "PlayStation pairing failed."]
    }

    public static func isSecureSavePending(_ error: any Error) -> Bool {
        if let pairingError = error as? Self {
            return pairingError == .secureSavePending
        }
        let bridgedError = error as NSError
        return bridgedError.domain == errorDomain
            && bridgedError.code == Self.secureSavePending.errorCode
    }
}

/// Only these fixed storage-check categories may leave the repository boundary.
/// The associated console identifiers in repository errors are deliberately omitted.
public enum PlayStationSecureSaveRepositoryFailure: String, Equatable, Sendable {
    case pendingRegistrationVerification = "registration journal verification"
    case credentialVerification = "credential verification"
    case credentialDeletionVerification = "superseded credential removal verification"
    case metadataVerification = "console metadata verification"
    case pendingRegistrationCleanup = "registration journal cleanup"
}

/// A bounded diagnostic with no arbitrary error text, account/console identifiers,
/// Keychain queries, registration envelopes, or retained underlying error.
public enum PlayStationSecureSaveDiagnostic: Equatable, Sendable {
    case keychain(operation: KeychainOperation, status: Int32)
    case repository(PlayStationSecureSaveRepositoryFailure)

    public var summary: String {
        switch self {
        case let .keychain(operation, status):
            "Keychain \(operation.rawValue) failed (status \(status))."
        case let .repository(failure):
            "Secure save check failed: \(failure.rawValue)."
        }
    }
}

/// Preserves the existing secure-save error domain/code and retry classification
/// while letting every shell display only a generated, redacted diagnostic.
/// Callers should use `PlayStationPairingError.isSecureSavePending`, including
/// across NSError/static-library image boundaries, rather than a concrete cast.
public struct PlayStationSecureSavePendingError:
    Error, Equatable, Sendable, LocalizedError, CustomNSError {
    public let diagnostic: PlayStationSecureSaveDiagnostic

    public init(diagnostic: PlayStationSecureSaveDiagnostic) {
        self.diagnostic = diagnostic
    }

    public static let errorDomain = PlayStationPairingError.errorDomain

    public var errorCode: Int {
        PlayStationPairingError.secureSavePending.errorCode
    }

    public var errorDescription: String? {
        let guidance = PlayStationPairingError.secureSavePending.localizedDescription
        return "\(guidance)\n\(diagnostic.summary)"
    }

    public var errorUserInfo: [String: Any] {
        // Never attach NSUnderlyingErrorKey: it may contain private input or data.
        [NSLocalizedDescriptionKey: errorDescription ?? diagnostic.summary]
    }
}

public actor PlayStationPairingService {
    private struct PendingSecureSave: Sendable {
        let existingConsoleID: UUID?
        let newConsoleID: UUID
        let hostAddress: String
        let fallbackDisplayName: String
        let nativeResult: PlayStationNativeRegistrationResult
    }

    private let repository: PlayStationConsoleRepository
    private let nativeClientFactory: any PlayStationNativeRegistrationClientFactory
    private let timeout: Duration
    private var pairingIsActive = false
    private var pendingSecureSave: PendingSecureSave?

    public init(
        repository: PlayStationConsoleRepository,
        nativeClientFactory: any PlayStationNativeRegistrationClientFactory,
        timeout: Duration = .seconds(30)
    ) {
        self.repository = repository
        self.nativeClientFactory = nativeClientFactory
        self.timeout = timeout
    }

    public var isPairing: Bool { pairingIsActive }

    public func pair(_ request: PlayStationPairingRequest) async throws
        -> SavedPlayStationConsole {
        guard pairingIsActive == false else {
            throw PlayStationPairingError.alreadyInProgress
        }
        guard pendingSecureSave == nil else {
            throw PlayStationPairingError.secureSavePending
        }
        pairingIsActive = true
        defer { pairingIsActive = false }

        let client = try nativeClientFactory.makeClient()
        let nativeResult = try await withThrowingTaskGroup(
            of: PlayStationNativeRegistrationResult.self
        ) { group in
            group.addTask { try await client.register(request) }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw PlayStationPairingError.timedOut
            }

            do {
                guard let result = try await group.next() else {
                    throw PlayStationPairingError.timedOut
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }

        let pending = PendingSecureSave(
            existingConsoleID: request.existingConsoleID,
            newConsoleID: UUID(),
            hostAddress: request.hostAddress,
            fallbackDisplayName: request.fallbackDisplayName,
            nativeResult: nativeResult
        )
        pendingSecureSave = pending
        return try await persist(pending)
    }

    public func retryPendingSecureSave() async throws -> SavedPlayStationConsole {
        guard pairingIsActive == false else {
            throw PlayStationPairingError.alreadyInProgress
        }
        guard let pendingSecureSave else {
            throw PlayStationPairingError.noPendingSecureSave
        }
        do {
            if let recovery = try await repository.recoverPendingRegistration(
                expectedRegistration: pendingSecureSave.nativeResult.registration
            ) {
                switch recovery {
                case let .completed(console):
                    self.pendingSecureSave = nil
                    return console
                case .needsRegistration:
                    break
                }
            }
        } catch {
            try throwClassifiedPersistenceError(error)
        }
        return try await persist(pendingSecureSave)
    }

    private func persist(_ pending: PendingSecureSave) async throws
        -> SavedPlayStationConsole {
        let macAddress = try Self.macAddress(from: pending.nativeResult.serverMAC)
        do {
            let console = try await repository.reconcileAndSavePairing(
                existingConsoleID: pending.existingConsoleID,
                newConsoleID: pending.newConsoleID,
                hostAddress: pending.hostAddress,
                fallbackDisplayName: pending.fallbackDisplayName,
                serverNickname: pending.nativeResult.serverNickname,
                macAddress: macAddress,
                registration: pending.nativeResult.registration
            )
            pendingSecureSave = nil
            return console
        } catch {
            try throwClassifiedPersistenceError(error)
        }
    }

    private func throwClassifiedPersistenceError(_ error: any Error) throws -> Never {
        if let error = error as? KeychainCredentialStoreError {
            throw PlayStationSecureSavePendingError(
                diagnostic: .keychain(operation: error.operation, status: error.status)
            )
        }
        if let error = error as? PlayStationConsoleRepositoryError {
            switch error {
            case .duplicateMetadata,
                 .pendingRegistrationConflict,
                 .invalidPendingRegistrationJournal,
                 .pendingRegistrationStateConflict,
                 .consoleNotFound,
                 .ambiguousPhysicalConsoleIdentity,
                 .physicalConsoleIdentityConflict,
                 .invalidHostAddress:
                pendingSecureSave = nil
                throw error
            case .pendingRegistrationVerificationFailed:
                throw PlayStationSecureSavePendingError(
                    diagnostic: .repository(.pendingRegistrationVerification)
                )
            case .credentialVerificationFailed:
                throw PlayStationSecureSavePendingError(
                    diagnostic: .repository(.credentialVerification)
                )
            case .credentialDeletionVerificationFailed:
                throw PlayStationSecureSavePendingError(
                    diagnostic: .repository(.credentialDeletionVerification)
                )
            case .metadataVerificationFailed:
                throw PlayStationSecureSavePendingError(
                    diagnostic: .repository(.metadataVerification)
                )
            case .pendingRegistrationCleanupFailed:
                throw PlayStationSecureSavePendingError(
                    diagnostic: .repository(.pendingRegistrationCleanup)
                )
            }
        }
        // Unknown errors are not safe to stringify or retain in an underlying error.
        throw PlayStationPairingError.secureSavePending
    }

    private static func macAddress(from bytes: Data) throws -> String? {
        guard bytes.count == Int(RP_CHIAKI_SERVER_MAC_SIZE) else {
            throw PlayStationPairingError.invalidServerMAC
        }
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

public struct ChiakiPlayStationNativeRegistrationClientFactory:
    PlayStationNativeRegistrationClientFactory {
    public init() {}

    public func makeClient() throws -> any PlayStationNativeRegistrationClient {
        try ChiakiPlayStationNativeRegistrationClient()
    }
}

public enum ChiakiPlayStationRegistrationError: Error, Equatable, Sendable, LocalizedError {
    case allocationFailed
    case alreadyStarted
    case nativeStartFailed(Int32)
    case registrationFailed
    case canceled
    case joinFailed(Int32)
    case destroyFailed(Int32)
    case invalidNativeResult

    public var errorDescription: String? {
        switch self {
        case .allocationFailed:
            "Remote Play could not allocate the PS5 pairing session."
        case .alreadyStarted:
            "A PS5 pairing session is already running."
        case .nativeStartFailed:
            "Remote Play could not start PS5 pairing. Check the address and try again."
        case .registrationFailed:
            "The PS5 rejected pairing. Request a new Link Device code and try again."
        case .canceled:
            "PS5 pairing was canceled."
        case .joinFailed, .destroyFailed:
            "Remote Play could not finish the PS5 pairing session safely."
        case .invalidNativeResult:
            "The PS5 returned an invalid pairing response."
        }
    }
}

public final class ChiakiPlayStationNativeRegistrationClient:
    PlayStationNativeRegistrationClient, @unchecked Sendable {
    private enum Lifecycle {
        case ready
        case started
        case closed
    }

    private let queue = DispatchQueue(
        label: "com.unshackledpursuit.remoteplay.chiaki-registration",
        qos: .userInitiated
    )
    private let cancellationLock = NSLock()
    private let callbackBridge = ChiakiRegistrationCallbackBridge()
    private var cancellationRequested = false
    private var handle: ChiakiRegistrationHandleBox?
    private var retainedCallbackContext: UnsafeMutableRawPointer?
    private var continuation:
        CheckedContinuation<PlayStationNativeRegistrationResult, any Error>?
    private var lifecycle: Lifecycle = .ready

    public init() throws {
        guard let handle = ChiakiRegistrationHandleBox() else {
            throw ChiakiPlayStationRegistrationError.allocationFailed
        }
        self.handle = handle
    }

    public func register(_ request: PlayStationPairingRequest) async throws
        -> PlayStationNativeRegistrationResult {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard lifecycle == .ready,
                          self.continuation == nil,
                          let handlePointer = handle?.pointer else {
                        continuation.resume(
                            throwing: ChiakiPlayStationRegistrationError.alreadyStarted
                        )
                        return
                    }
                    self.continuation = continuation
                    guard isCancellationRequested == false else {
                        finish(.failure(CancellationError()))
                        return
                    }

                    callbackBridge.install { [weak self] event in
                        self?.queue.async { [weak self] in
                            self?.receive(event)
                        }
                    }
                    let callbackContext = Unmanaged.passRetained(callbackBridge).toOpaque()
                    retainedCallbackContext = callbackContext
                    let result = Self.start(
                        handle: handlePointer,
                        request: request,
                        callbackContext: callbackContext
                    )
                    guard result == RP_CHIAKI_BRIDGE_SUCCESS.rawValue else {
                        finish(
                            .failure(
                                ChiakiPlayStationRegistrationError.nativeStartFailed(result)
                            )
                        )
                        return
                    }
                    lifecycle = .started
                }
            }
        } onCancel: { [weak self] in
            self?.requestCancellation()
        }
    }

    private var isCancellationRequested: Bool {
        cancellationLock.withLock { cancellationRequested }
    }

    private func requestCancellation() {
        cancellationLock.withLock { cancellationRequested = true }
        queue.async { [weak self] in
            self?.finish(.failure(CancellationError()), requestStop: true)
        }
    }

    private func receive(_ event: ChiakiRegistrationCallbackEvent) {
        if isCancellationRequested {
            finish(.failure(CancellationError()), requestStop: true)
            return
        }
        switch event {
        case let .success(result):
            finish(.success(result))
        case .failed:
            finish(.failure(ChiakiPlayStationRegistrationError.registrationFailed))
        case .canceled:
            finish(.failure(ChiakiPlayStationRegistrationError.canceled))
        case .invalidResult:
            finish(.failure(ChiakiPlayStationRegistrationError.invalidNativeResult))
        }
    }

    private func finish(
        _ result: Result<PlayStationNativeRegistrationResult, any Error>,
        requestStop: Bool = false
    ) {
        guard let pendingContinuation = continuation else { return }
        continuation = nil

        if let handlePointer = handle?.pointer, lifecycle == .started {
            if requestStop {
                _ = rp_chiaki_registration_request_stop(handlePointer)
            }
            let joinResult = rp_chiaki_registration_join(handlePointer)
            guard joinResult == RP_CHIAKI_BRIDGE_SUCCESS.rawValue else {
                // Keep the callback context and native handle alive if Chiaki
                // could not join; releasing either would permit a use-after-free.
                handle?.abandonWithoutDestroying()
                lifecycle = .closed
                pendingContinuation.resume(
                    throwing: ChiakiPlayStationRegistrationError.joinFailed(joinResult)
                )
                return
            }
        }

        callbackBridge.clear()
        releaseCallbackContext()
        if let handle {
            let destroyResult = handle.destroy()
            guard destroyResult == RP_CHIAKI_BRIDGE_SUCCESS.rawValue else {
                lifecycle = .closed
                pendingContinuation.resume(
                    throwing: ChiakiPlayStationRegistrationError.destroyFailed(destroyResult)
                )
                return
            }
        }
        handle = nil
        lifecycle = .closed
        pendingContinuation.resume(with: result)
    }

    private static func start(
        handle: OpaquePointer,
        request: PlayStationPairingRequest,
        callbackContext: UnsafeMutableRawPointer
    ) -> Int32 {
        request.hostAddress.withCString { hostPointer in
            request.accountID.bytes.withUnsafeBytes { accountBytes in
                request.pin.digits.withCString { pinPointer in
                    var configuration = RPChiakiRegistrationConfiguration(
                        host: hostPointer,
                        psn_account_id: accountBytes.bindMemory(to: UInt8.self).baseAddress,
                        psn_account_id_size: accountBytes.count,
                        link_device_pin: pinPointer,
                        link_device_pin_size: request.pin.digits.utf8.count
                    )
                    var callbacks = RPChiakiRegistrationCallbacks(
                        user: callbackContext,
                        event: receiveChiakiRegistrationEvent
                    )
                    return rp_chiaki_registration_start(
                        handle,
                        &configuration,
                        &callbacks
                    )
                }
            }
        }
    }

    private func releaseCallbackContext() {
        guard let retainedCallbackContext else { return }
        Unmanaged<ChiakiRegistrationCallbackBridge>
            .fromOpaque(retainedCallbackContext)
            .release()
        self.retainedCallbackContext = nil
    }
}

private enum ChiakiRegistrationCallbackEvent: Sendable {
    case success(PlayStationNativeRegistrationResult)
    case failed
    case canceled
    case invalidResult
}

private func receiveChiakiRegistrationEvent(
    _ user: UnsafeMutableRawPointer?,
    _ eventType: RPChiakiRegistrationEventType,
    _ result: UnsafePointer<RPChiakiRegistrationResult>?
) {
    guard let user else { return }
    let bridge = Unmanaged<ChiakiRegistrationCallbackBridge>
        .fromOpaque(user)
        .takeUnretainedValue()
    switch eventType {
    case RP_CHIAKI_REGISTRATION_EVENT_SUCCEEDED:
        guard let result,
              let mapped = ChiakiRegistrationResultMapping.map(result.pointee) else {
            bridge.emit(.invalidResult)
            return
        }
        bridge.emit(.success(mapped))
    case RP_CHIAKI_REGISTRATION_EVENT_FAILED:
        bridge.emit(.failed)
    case RP_CHIAKI_REGISTRATION_EVENT_CANCELED:
        bridge.emit(.canceled)
    default:
        bridge.emit(.invalidResult)
    }
}

private enum ChiakiRegistrationResultMapping {
    static func map(_ nativeResult: RPChiakiRegistrationResult)
        -> PlayStationNativeRegistrationResult? {
        var nativeResult = nativeResult
        let registrationKey = withUnsafeBytes(of: &nativeResult.registration_key) {
            Data($0.prefix(Int(RP_CHIAKI_REGISTRATION_KEY_SIZE)))
        }
        let remotePlayKey = withUnsafeBytes(of: &nativeResult.remote_play_key) {
            Data($0.prefix(Int(RP_CHIAKI_REMOTE_PLAY_KEY_SIZE)))
        }
        let serverMAC = withUnsafeBytes(of: &nativeResult.server_mac) {
            Data($0.prefix(Int(RP_CHIAKI_SERVER_MAC_SIZE)))
        }
        let nickname = withUnsafePointer(to: &nativeResult.server_nickname) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: Int(RP_CHIAKI_SERVER_NICKNAME_SIZE)
            ) { String(cString: $0) }
        }
        guard let registration = try? PlayStationConsoleRegistration(
            registrationKey: registrationKey,
            remotePlayKey: remotePlayKey
        ), serverMAC.count == Int(RP_CHIAKI_SERVER_MAC_SIZE) else {
            return nil
        }
        return PlayStationNativeRegistrationResult(
            registration: registration,
            serverNickname: nickname,
            serverMAC: serverMAC
        )
    }
}

private final class ChiakiRegistrationCallbackBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (ChiakiRegistrationCallbackEvent) -> Void)?

    func install(_ handler: @escaping @Sendable (ChiakiRegistrationCallbackEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func emit(_ event: ChiakiRegistrationCallbackEvent) {
        let handler: (@Sendable (ChiakiRegistrationCallbackEvent) -> Void)? =
            lock.withLock { self.handler }
        handler?(event)
    }

    func clear() {
        lock.withLock { handler = nil }
    }
}

private final class ChiakiRegistrationHandleBox: @unchecked Sendable {
    private(set) var pointer: OpaquePointer?

    init?() {
        guard let pointer = rp_chiaki_registration_handle_create() else { return nil }
        self.pointer = pointer
    }

    func destroy() -> Int32 {
        guard let pointer else { return RP_CHIAKI_BRIDGE_SUCCESS.rawValue }
        let result = rp_chiaki_registration_handle_destroy(pointer)
        if result == RP_CHIAKI_BRIDGE_SUCCESS.rawValue {
            self.pointer = nil
        }
        return result
    }

    /// Deliberately relinquishes Swift ownership without touching a native
    /// operation that failed to join. This bounded leak is safer than freeing
    /// callback memory that Chiaki may still reference.
    func abandonWithoutDestroying() {
        pointer = nil
    }

    deinit {
        _ = destroy()
    }
}
