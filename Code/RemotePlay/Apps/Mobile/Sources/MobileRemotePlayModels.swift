import AppleMediaCore
import ExperienceDomain
import Foundation
import InputCore
import Network
import PlayStationRemotePlay
import PlayStationRemotePlayUI

enum MobileRemotePlayPhase: Equatable, Sendable {
    case loading
    case recoveryRequired(String)
    case ready
    case waking(UUID)
    case prepared(UUID)
    case connecting(UUID)
    case streaming(UUID)
    case disconnecting
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .loading, .recoveryRequired, .waking, .prepared, .connecting, .disconnecting:
            true
        case .ready, .streaming, .failed:
            false
        }
    }

    var statusText: String {
        switch self {
        case .loading: "Loading"
        case .recoveryRequired: "Needs attention"
        case .ready: "Ready"
        case .waking: "Waking"
        case .prepared, .connecting: "Connecting"
        case .streaming: "Playing"
        case .disconnecting: "Disconnecting"
        case .failed: "Action needed"
        }
    }
}

/// The shared preset list, aliased so the existing shell call sites and the
/// persisted raw values are untouched. The display strings are derived from the
/// resolved profile in `ExperienceDomain`, so a bitrate change is one edit.
typealias MobileStreamQuality = StreamQualityPreset

struct MobileConsoleSummary: Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let hostAddress: String
    var awayHostAddress: String? = nil
    var connectionRoute: PlayStationConnectionRoute = .home

    /// The address Wake and Connect currently target.
    var activeHostAddress: String {
        connectionRoute == .away ? (awayHostAddress ?? hostAddress) : hostAddress
    }

    var hasAwayAddress: Bool { awayHostAddress != nil }
}

/// Non-secret values needed to present a Mobile-owned PS5 pairing flow.
///
/// `existingConsoleID` is only populated when the target is already present in
/// the canonical repository snapshot. A crash-interrupted registration for a
/// console that was never committed must be treated as a fresh pairing rather
/// than inventing a saved-console identity.
struct MobilePairingTarget: Equatable, Identifiable, Sendable {
    let id: UUID
    let existingConsoleID: UUID?
    let displayName: String
    let hostAddress: String

    init(
        id: UUID = UUID(),
        existingConsoleID: UUID? = nil,
        displayName: String = "PlayStation 5",
        hostAddress: String = ""
    ) {
        self.id = id
        self.existingConsoleID = existingConsoleID
        self.displayName = displayName
        self.hostAddress = hostAddress
    }

    static func canonicalRecoveryConsoleID(
        pendingConsoleID: UUID,
        canonicalConsoleIDs: Set<UUID>
    ) -> UUID? {
        canonicalConsoleIDs.contains(pendingConsoleID) ? pendingConsoleID : nil
    }
}

struct MobileRegistrationRecovery: Equatable, Sendable {
    let message: String
    let target: MobilePairingTarget
}

struct MobileStartupSnapshot: Equatable, Sendable {
    let consoles: [MobileConsoleSummary]
    let recoveryMessage: String?
    let registrationRecovery: MobileRegistrationRecovery?

    init(
        consoles: [MobileConsoleSummary],
        recoveryMessage: String? = nil,
        registrationRecovery: MobileRegistrationRecovery? = nil
    ) {
        self.consoles = consoles
        self.recoveryMessage = recoveryMessage
        self.registrationRecovery = registrationRecovery
    }
}

struct MobileControllerConnection: Equatable, Sendable {
    let isConnected: Bool
    let name: String?

    static let disconnected = MobileControllerConnection(isConnected: false, name: nil)
}

struct MobileRemoteSessionSnapshot: Equatable, Sendable {
    let state: StreamingConnectionState
    let displayIsBlocked: Bool
    let lastQuitReason: PlayStationNativeQuitReason?

    init(
        state: StreamingConnectionState,
        displayIsBlocked: Bool,
        lastQuitReason: PlayStationNativeQuitReason? = nil
    ) {
        self.state = state
        self.displayIsBlocked = displayIsBlocked
        self.lastQuitReason = lastQuitReason
    }

    /// Only typed reason codes cross this presentation boundary, never native
    /// log text or a console address/credential. The shared explanation names
    /// the handshake stage the code stands for; the code stays in the sentence.
    var failureMessage: String {
        lastQuitReason?.explanation.message
            ?? "The Remote Play session ended unexpectedly."
    }
}

/// One atomic video-presentation capability. Production sessions can only
/// advertise availability by carrying the concrete shared sample-buffer
/// binding; there is no independent Boolean that can drift from the surface.
enum MobileRemotePlayVideoSurface: Sendable {
    case sampleBuffer(SampleBufferVideoSurfaceBinding)

#if DEBUG
    /// Deterministic app-target tests do not construct package-owned media
    /// presenters, but still need to exercise the coordinator after a concrete
    /// (non-nil) surface capability has been supplied.
    case testHarness
#endif

    var sampleBufferBinding: SampleBufferVideoSurfaceBinding? {
        switch self {
        case .sampleBuffer(let binding):
            binding
#if DEBUG
        case .testHarness:
            nil
#endif
        }
    }
}

protocol MobileRemotePlaySession: Sendable {
    var id: UUID { get }
    var videoSurface: MobileRemotePlayVideoSurface? { get }

    func start() async throws
    func stop() async
    func send(_ input: ControllerSnapshot) async
    func goHome() async throws
    func restAndDisconnect() async throws
    func snapshot() async -> MobileRemoteSessionSnapshot
    func audioSnapshot() async -> PCMAudioPlaybackSnapshot?
    func videoDecoderDiagnostics() -> HEVCDecoderDiagnostics?
    func recoverVideoAfterInterruption() async
    func setVolume(_ volume: Float)
    func setMuted(_ isMuted: Bool)
    func setControllerFeedbackHandler(
        _ handler: @escaping @Sendable (ControllerFeedbackEvent) -> Void
    ) async
}

extension MobileRemotePlaySession {
    /// A session without a controller output path simply drops feedback.
    func setControllerFeedbackHandler(
        _ handler: @escaping @Sendable (ControllerFeedbackEvent) -> Void
    ) async {}

    func audioSnapshot() async -> PCMAudioPlaybackSnapshot? { nil }
    func videoDecoderDiagnostics() -> HEVCDecoderDiagnostics? { nil }
}

protocol MobileRemotePlayControllerSource: Sendable {
    func snapshot() -> ControllerSnapshot
    func setInjectedSnapshot(_ snapshot: ControllerSnapshot)
    func setKeyboardControlsEnabled(_ enabled: Bool)
    func connectionSnapshot() -> MobileControllerConnection
    func connectionUpdates() -> AsyncStream<MobileControllerConnection>
    func applyControllerFeedback(_ event: ControllerFeedbackEvent)
    func setControllerFeedbackEnabled(_ enabled: Bool)
    func stopControllerFeedback()
}

extension MobileRemotePlayControllerSource {
    func setInjectedSnapshot(_ snapshot: ControllerSnapshot) {}

    /// Hardware-keyboard gameplay is optional. A source with no keyboard
    /// adapter, such as a test double, simply has nothing to gate.
    func setKeyboardControlsEnabled(_ enabled: Bool) {}

    /// Controller output is optional. A source without hardware feedback, such
    /// as a test double or the on-screen controls, ignores it entirely.
    func applyControllerFeedback(_ event: ControllerFeedbackEvent) {}
    func setControllerFeedbackEnabled(_ enabled: Bool) {}
    func stopControllerFeedback() {}

    /// Test and alternate sources may expose a stable one-shot value. The
    /// production Game Controller adapter overrides this with a live stream.
    func connectionUpdates() -> AsyncStream<MobileControllerConnection> {
        let initial = connectionSnapshot()
        return AsyncStream { continuation in
            continuation.yield(initial)
            continuation.finish()
        }
    }
}

/// Mobile-owned acquisition and registration seams. Production supplies one
/// retained composition, preflight, and identity acquirer; tests can replace
/// the effects without reaching Keychain, the network, or native Chiaki.
struct MobilePlayStationPairingDependencies: Sendable {
    let identityCapability: PlayStationAccountIdentityAcquisitionCapability
    let requestLocalNetworkAccess: @Sendable () async -> Bool
    let acquireAccountIdentity: @MainActor @Sendable () async throws
        -> PlayStationRemotePlayAccountIdentity
    let pair: @Sendable (PlayStationPairingRequest) async throws
        -> SavedPlayStationConsole
    let retryPendingSecureSave: @Sendable () async throws
        -> SavedPlayStationConsole
    let removeConsole: @Sendable (UUID) async throws -> Void
    /// Updates Home/Away addresses and the active route without re-pairing.
    let updateConnectionAddresses: @Sendable (
        UUID, String, String?, PlayStationConnectionRoute
    ) async throws -> Void

    init(
        identityCapability: PlayStationAccountIdentityAcquisitionCapability,
        requestLocalNetworkAccess: @escaping @Sendable () async -> Bool,
        acquireAccountIdentity: @escaping @MainActor @Sendable () async throws
            -> PlayStationRemotePlayAccountIdentity,
        pair: @escaping @Sendable (PlayStationPairingRequest) async throws
            -> SavedPlayStationConsole,
        retryPendingSecureSave: @escaping @Sendable () async throws
            -> SavedPlayStationConsole,
        removeConsole: @escaping @Sendable (UUID) async throws -> Void,
        updateConnectionAddresses: @escaping @Sendable (
            UUID, String, String?, PlayStationConnectionRoute
        ) async throws -> Void = { _, _, _, _ in
            throw PlayStationAccountIdentityAcquisitionError.unavailable
        }
    ) {
        self.identityCapability = identityCapability
        self.requestLocalNetworkAccess = requestLocalNetworkAccess
        self.acquireAccountIdentity = acquireAccountIdentity
        self.pair = pair
        self.retryPendingSecureSave = retryPendingSecureSave
        self.removeConsole = removeConsole
        self.updateConnectionAddresses = updateConnectionAddresses
    }

    static let unavailable = MobilePlayStationPairingDependencies(
        identityCapability: .unavailable,
        requestLocalNetworkAccess: { false },
        acquireAccountIdentity: {
            throw PlayStationAccountIdentityAcquisitionError.unavailable
        },
        pair: { _ in
            throw PlayStationAccountIdentityAcquisitionError.unavailable
        },
        retryPendingSecureSave: {
            throw PlayStationPairingError.noPendingSecureSave
        },
        removeConsole: { _ in
            throw PlayStationAccountIdentityAcquisitionError.unavailable
        }
    )
}

struct MobileRemotePlayDependencies: Sendable {
    let loadStartup: @Sendable () async throws -> MobileStartupSnapshot
    let wake: @Sendable (UUID) async throws -> Void
    let makeSession: @Sendable (
        MobileConsoleSummary,
        QualityProfile
    ) async throws -> any MobileRemotePlaySession
    let controllerSource: any MobileRemotePlayControllerSource
    let pairing: MobilePlayStationPairingDependencies
    let monitorInterval: Duration
    let controllerDeliveryInterval: Duration
    let waitForWakeSettling: @Sendable () async throws -> Void
    let connectionNetworkSnapshot: @Sendable () -> MobileConnectionNetworkSnapshot
    /// Production supplies the shared web sign-in so the root view can present
    /// it; tests leave it nil.
    var webSignInAcquirer: PlayStationWebAccountIdentityAcquirer? = nil

    init(
        loadStartup: @escaping @Sendable () async throws -> MobileStartupSnapshot,
        wake: @escaping @Sendable (UUID) async throws -> Void,
        makeSession: @escaping @Sendable (
            MobileConsoleSummary,
            QualityProfile
        ) async throws -> any MobileRemotePlaySession,
        controllerSource: any MobileRemotePlayControllerSource,
        pairing: MobilePlayStationPairingDependencies = .unavailable,
        monitorInterval: Duration = .milliseconds(100),
        controllerDeliveryInterval: Duration = .nanoseconds(8_333_333),
        waitForWakeSettling: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(4))
        },
        connectionNetworkSnapshot: @escaping @Sendable ()
            -> MobileConnectionNetworkSnapshot = { .unavailable }
    ) {
        self.loadStartup = loadStartup
        self.wake = wake
        self.makeSession = makeSession
        self.controllerSource = controllerSource
        self.pairing = pairing
        self.monitorInterval = monitorInterval
        self.controllerDeliveryInterval = controllerDeliveryInterval
        self.waitForWakeSettling = waitForWakeSettling
        self.connectionNetworkSnapshot = connectionNetworkSnapshot
    }
}

enum MobileRemotePlayCoordinatorError: Error, LocalizedError {
    case consoleNotFound
    case invalidSessionType
    case missingVideoSurface
    case registrationUnavailable
    case registrationOperationInProgress
    case sessionActive

    var errorDescription: String? {
        switch self {
        case .consoleNotFound:
            "The saved PlayStation 5 could not be found. Reload your consoles and try again."
        case .invalidSessionType:
            "The PlayStation provider returned an unsupported session."
        case .missingVideoSurface:
            "The PlayStation session could not create a Mobile video surface."
        case .registrationUnavailable:
            "PS5 pairing is not available while Remote Play is busy."
        case .registrationOperationInProgress:
            "Another PS5 registration change is already running."
        case .sessionActive:
            "Disconnect Remote Play before pairing, re-registering, or removing a PS5."
        }
    }
}

enum MobileConnectionAttemptStage: String, Codable, Sendable {
    case requested
    case sessionPrepared = "session-prepared"
    case surfaceQueued = "surface-queued"
    case nativeStartRequested = "native-start-requested"
    case nativeStartReturned = "native-start-returned"
    case streaming
    case failed
}

enum MobileConnectionEndpointClass: String, Codable, Sendable {
    case privateIPv4 = "private-ipv4"
    case publicIPv4 = "public-ipv4"
    case linkLocalIPv4 = "link-local-ipv4"
    case loopback = "loopback"
    case localIPv6 = "local-ipv6"
    case publicIPv6 = "public-ipv6"
    case hostname
    case invalid

    static func classify(_ rawAddress: String) -> Self {
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.isEmpty == false else { return .invalid }

        if let octets = ipv4Octets(address) {
            switch octets {
            case let value where value[0] == 10:
                return .privateIPv4
            case let value where value[0] == 172 && (16...31).contains(value[1]):
                return .privateIPv4
            case let value where value[0] == 192 && value[1] == 168:
                return .privateIPv4
            case let value where value[0] == 169 && value[1] == 254:
                return .linkLocalIPv4
            case let value where value[0] == 127:
                return .loopback
            default:
                return .publicIPv4
            }
        }

        if address.contains(":") {
            let lowercased = address.lowercased()
            if lowercased == "::1" { return .loopback }
            if lowercased.hasPrefix("fe80:")
                || lowercased.hasPrefix("fc")
                || lowercased.hasPrefix("fd") {
                return .localIPv6
            }
            return .publicIPv6
        }

        return address.contains(".") ? .hostname : .invalid
    }

    private static func ipv4Octets(_ address: String) -> [UInt8]? {
        let components = address.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }
        let octets = components.compactMap { UInt8($0) }
        return octets.count == 4 ? octets : nil
    }
}

struct MobileConnectionNetworkSnapshot: Codable, Equatable, Sendable {
    let status: String
    let interface: String
    let isExpensive: Bool
    let isConstrained: Bool
    let supportsIPv4: Bool
    let supportsIPv6: Bool
    let supportsDNS: Bool

    static let unavailable = MobileConnectionNetworkSnapshot(
        status: "unknown",
        interface: "unknown",
        isExpensive: false,
        isConstrained: false,
        supportsIPv4: false,
        supportsIPv6: false,
        supportsDNS: false
    )

    init(path: NWPath) {
        switch path.status {
        case .satisfied: status = "satisfied"
        case .requiresConnection: status = "requires-connection"
        case .unsatisfied: status = "unsatisfied"
        @unknown default: status = "unknown"
        }
        if path.usesInterfaceType(.cellular) {
            interface = "cellular"
        } else if path.usesInterfaceType(.wifi) {
            interface = "wifi"
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = "wired-ethernet"
        } else if path.usesInterfaceType(.loopback) {
            interface = "loopback"
        } else if path.usesInterfaceType(.other) {
            interface = "other"
        } else {
            interface = "unknown"
        }
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
        supportsDNS = path.supportsDNS
    }

    init(
        status: String,
        interface: String,
        isExpensive: Bool,
        isConstrained: Bool,
        supportsIPv4: Bool,
        supportsIPv6: Bool,
        supportsDNS: Bool
    ) {
        self.status = status
        self.interface = interface
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.supportsDNS = supportsDNS
    }
}

struct MobileConnectionAttemptReport: Codable, Sendable {
    struct Event: Codable, Equatable, Sendable {
        let stage: MobileConnectionAttemptStage
        let elapsedMilliseconds: Int
    }

    struct Environment: Codable, Sendable {
        let appVersion: String
        let buildNumber: String
        let operatingSystem: String
        let deviceClass: String
        let thermalState: String
        let lowPowerModeEnabled: Bool
    }

    let schemaVersion: Int
    let createdAt: Date
    let outcome: String
    let failureCategory: String?
    let nativeQuitCode: Int32?
    let nativeQuitCategory: String?
    let endpointClass: MobileConnectionEndpointClass
    let requestedQuality: String
    let wakeRequestWasSent: Bool
    let network: MobileConnectionNetworkSnapshot
    let environment: Environment
    let events: [Event]
    let privacy: String
}

struct MobileConnectionAttemptState: Sendable {
    let startedAt: Date
    let endpointClass: MobileConnectionEndpointClass
    let requestedQuality: String
    let wakeRequestWasSent: Bool
    let network: MobileConnectionNetworkSnapshot
    var events: [MobileConnectionAttemptReport.Event]

    init(
        startedAt: Date = Date(),
        hostAddress: String,
        requestedQuality: String,
        wakeRequestWasSent: Bool,
        network: MobileConnectionNetworkSnapshot
    ) {
        self.startedAt = startedAt
        endpointClass = .classify(hostAddress)
        self.requestedQuality = requestedQuality
        self.wakeRequestWasSent = wakeRequestWasSent
        self.network = network
        events = [.init(stage: .requested, elapsedMilliseconds: 0)]
    }

    mutating func record(_ stage: MobileConnectionAttemptStage, now: Date = Date()) {
        guard events.last?.stage != stage else { return }
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt) * 1_000))
        events.append(.init(stage: stage, elapsedMilliseconds: elapsed))
    }
}

final class MobileConnectionPathMonitor: @unchecked Sendable {
    static let shared = MobileConnectionPathMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(
        label: "com.unshackledpursuit.farframe.connection-path",
        qos: .utility
    )
    private let lock = NSLock()
    private var latestSnapshot = MobileConnectionNetworkSnapshot.unavailable

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let snapshot = MobileConnectionNetworkSnapshot(path: path)
            self.lock.withLock {
                self.latestSnapshot = snapshot
            }
        }
        monitor.start(queue: queue)
    }

    func snapshot() -> MobileConnectionNetworkSnapshot {
        lock.withLock { latestSnapshot }
    }
}

extension MobileConnectionAttemptReport {
    /// The category keys are the shared table's identifiers. This shell used to
    /// carry its own copy of the whole native enum, which is exactly the kind of
    /// fork that drifts the first time the source lock moves.
    static func nativeQuitCategory(for code: Int32?) -> String? {
        guard let code else { return nil }
        return PlayStationQuitReasonExplanation.forCode(code).identifier
    }
}

struct MobileConnectionTimeoutError: LocalizedError {
    var errorDescription: String? {
        "The PS5 did not answer within 45 seconds. If it was just woken, give it a few more seconds and connect again. If it is already on, check that both devices are on the same network."
    }
}
