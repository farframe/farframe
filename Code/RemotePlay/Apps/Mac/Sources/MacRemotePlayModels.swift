import AppleMediaCore
import ExperienceDomain
import Foundation
import InputCore
import PlayStationRemotePlay
import PlayStationRemotePlayUI

typealias MacVideoDiagnosticsSnapshot = VideoPresentationRateSnapshot
typealias MacVideoRateSampler = VideoPresentationRateSampler

enum MacRemotePlayPhase: Equatable, Sendable {
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
typealias MacStreamQuality = StreamQualityPreset

struct MacConsoleSummary: Equatable, Identifiable, Sendable {
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

/// Non-secret values needed to present a Mac-owned PS5 pairing flow.
///
/// `existingConsoleID` is only populated when the target is already present in
/// the canonical repository snapshot. A crash-interrupted registration for a
/// console that was never committed must be treated as a fresh pairing rather
/// than inventing a saved-console identity.
struct MacPairingTarget: Equatable, Identifiable, Sendable {
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

struct MacRegistrationRecovery: Equatable, Sendable {
    let message: String
    let target: MacPairingTarget
}

struct MacStartupSnapshot: Equatable, Sendable {
    let consoles: [MacConsoleSummary]
    let recoveryMessage: String?
    let registrationRecovery: MacRegistrationRecovery?

    init(
        consoles: [MacConsoleSummary],
        recoveryMessage: String? = nil,
        registrationRecovery: MacRegistrationRecovery? = nil
    ) {
        self.consoles = consoles
        self.recoveryMessage = recoveryMessage
        self.registrationRecovery = registrationRecovery
    }
}

struct MacControllerConnection: Equatable, Sendable {
    let isConnected: Bool
    let name: String?

    static let disconnected = MacControllerConnection(isConnected: false, name: nil)
}

struct MacRemoteSessionSnapshot: Equatable, Sendable {
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

    /// Only the typed reason crosses this presentation boundary, never native
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
enum MacRemotePlayVideoSurface: Sendable {
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

protocol MacRemotePlaySession: Sendable {
    var id: UUID { get }
    var videoSurface: MacRemotePlayVideoSurface? { get }

    func start() async throws
    func stop() async
    func send(_ input: ControllerSnapshot) async
    func goHome() async throws
    func restAndDisconnect() async throws
    func snapshot() async -> MacRemoteSessionSnapshot
    func audioSnapshot() async -> PCMAudioPlaybackSnapshot?
    func videoDecoderDiagnostics() -> HEVCDecoderDiagnostics?
    func recoverVideoAfterInterruption() async
    func setVolume(_ volume: Float)
    func setMuted(_ isMuted: Bool)
    func setControllerFeedbackHandler(
        _ handler: @escaping @Sendable (ControllerFeedbackEvent) -> Void
    ) async
}

extension MacRemotePlaySession {
    /// A session without a controller output path simply drops feedback.
    func setControllerFeedbackHandler(
        _ handler: @escaping @Sendable (ControllerFeedbackEvent) -> Void
    ) async {}

    func audioSnapshot() async -> PCMAudioPlaybackSnapshot? { nil }
    func videoDecoderDiagnostics() -> HEVCDecoderDiagnostics? { nil }
    func recoverVideoAfterInterruption() async {}
}

protocol MacRemotePlayControllerSource: Sendable {
    func snapshot() -> ControllerSnapshot
    func connectionSnapshot() -> MacControllerConnection
    func connectionUpdates() -> AsyncStream<MacControllerConnection>
    func setKeyboardControlsEnabled(_ enabled: Bool)
    func applyControllerFeedback(_ event: ControllerFeedbackEvent)
    func setControllerFeedbackEnabled(_ enabled: Bool)
    func stopControllerFeedback()
}

extension MacRemotePlayControllerSource {
    /// Controller output is optional. A source without hardware feedback, such
    /// as a test double or a keyboard-only surface, ignores it entirely.
    func applyControllerFeedback(_ event: ControllerFeedbackEvent) {}
    func setControllerFeedbackEnabled(_ enabled: Bool) {}
    func stopControllerFeedback() {}
}

extension MacRemotePlayControllerSource {
    /// Test and alternate sources may expose a stable one-shot value. The
    /// production Game Controller adapter overrides this with a live stream.
    func connectionUpdates() -> AsyncStream<MacControllerConnection> {
        let initial = connectionSnapshot()
        return AsyncStream { continuation in
            continuation.yield(initial)
            continuation.finish()
        }
    }

    /// Alternate and test sources do not need a keyboard adapter. Production
    /// enables its held-state keyboard only while a live gameplay surface owns
    /// input, then clears it immediately on interruption or teardown.
    func setKeyboardControlsEnabled(_ enabled: Bool) {}
}

/// Mac-owned acquisition and registration seams. Production supplies one
/// retained composition, preflight, and identity acquirer; tests can replace
/// the effects without reaching Keychain, the network, or native Chiaki.
struct MacPlayStationPairingDependencies: Sendable {
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

    static let unavailable = MacPlayStationPairingDependencies(
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

struct MacRemotePlayDependencies: Sendable {
    let loadStartup: @Sendable () async throws -> MacStartupSnapshot
    let wake: @Sendable (UUID) async throws -> Void
    let waitForWakeSettling: @Sendable () async throws -> Void
    let makeSession: @Sendable (
        MacConsoleSummary,
        QualityProfile
    ) async throws -> any MacRemotePlaySession
    let controllerSource: any MacRemotePlayControllerSource
    let pairing: MacPlayStationPairingDependencies
    let monitorInterval: Duration
    let controllerDeliveryInterval: Duration
    /// Production supplies the shared web sign-in so the root view can present
    /// it; tests leave it nil.
    var webSignInAcquirer: PlayStationWebAccountIdentityAcquirer? = nil

    init(
        loadStartup: @escaping @Sendable () async throws -> MacStartupSnapshot,
        wake: @escaping @Sendable (UUID) async throws -> Void,
        makeSession: @escaping @Sendable (
            MacConsoleSummary,
            QualityProfile
        ) async throws -> any MacRemotePlaySession,
        controllerSource: any MacRemotePlayControllerSource,
        waitForWakeSettling: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(4))
        },
        pairing: MacPlayStationPairingDependencies = .unavailable,
        monitorInterval: Duration = .milliseconds(100),
        controllerDeliveryInterval: Duration = .nanoseconds(8_333_333)
    ) {
        self.loadStartup = loadStartup
        self.wake = wake
        self.waitForWakeSettling = waitForWakeSettling
        self.makeSession = makeSession
        self.controllerSource = controllerSource
        self.pairing = pairing
        self.monitorInterval = monitorInterval
        self.controllerDeliveryInterval = controllerDeliveryInterval
    }
}

enum MacRemotePlayCoordinatorError: Error, LocalizedError {
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
            "The PlayStation session could not create a Mac video surface."
        case .registrationUnavailable:
            "PS5 pairing is not available while Remote Play is busy."
        case .registrationOperationInProgress:
            "Another PS5 registration change is already running."
        case .sessionActive:
            "Disconnect Remote Play before pairing, re-registering, or removing a PS5."
        }
    }
}

struct MacConnectionTimeoutError: LocalizedError {
    var errorDescription: String? {
        "The PS5 did not answer within 45 seconds. If it was just woken, give it a few more seconds and connect again. If it is already on, check that both devices are on the same network."
    }
}
