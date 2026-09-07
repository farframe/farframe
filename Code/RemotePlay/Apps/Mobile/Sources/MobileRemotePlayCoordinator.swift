import AppleMediaCore
import AVFAudio
import ExperienceDomain
import Foundation
import InputCore
import Observation
import PlayStationRemotePlay
import PlayStationRemotePlayUI
import UIKit

struct MobilePreparedSessionStartAuthorization: Equatable, Sendable {
    fileprivate let sessionID: UUID
    fileprivate let generationID: UUID
    fileprivate let requestID: UUID
}

enum MobilePreparedSessionStartResolution: Equatable, Sendable {
    case started
    case deferredUntilActive
    case denied(consoleID: UUID)
    case stale
}

@MainActor
@Observable
final class MobileRemotePlayCoordinator {
    private enum RegistrationOperationState: Equatable {
        case idle
        case running(UUID)
        case secureSavePending
    }

    private enum PreferenceKey {
        static let smoothMotion = "RemotePlayMobile.smoothMotion"
        static let controllerFeedback = "RemotePlayMobile.controllerFeedback"
        static let videoEnhancement = "RemotePlayMobile.videoEnhancement"
        static let streamQuality = "RemotePlayMobile.streamQuality"
        static let audioVolume = "RemotePlayMobile.audioVolume"
        static let audioMuted = "RemotePlayMobile.audioMuted"
        static let keyboardControls = "RemotePlayMobile.keyboardControlsEnabled"
    }

    private let dependencies: MobileRemotePlayDependencies
    private let defaults: UserDefaults
    private let lifetimeToken = MobileCoordinatorLifetimeToken()

    private var activeSession: (any MobileRemotePlaySession)?
    private var connectionTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var controllerDeliveryTask: Task<Void, Never>?
    // Deinitializers are nonisolated in Swift 6. The task itself is Sendable;
    // all mutation remains MainActor-owned, while deinit may cancel the final
    // retained handle after the coordinator becomes unreachable.
    @ObservationIgnored nonisolated(unsafe)
    private var controllerConnectionTask: Task<Void, Never>?
    private var preparedSessionHasStarted = false
    private var preparedSurfaceHasBeenQueued = false
    private var preparedSessionGenerationID: UUID?
    private var pendingPreparedSessionAuthorizationID: UUID?
    private var applicationIsActive = true
    private var presentationWasInterrupted = false
    private var pendingLifecycleOperationID: UUID?
    private var connectionOperationID: UUID?
    private var localSessionOperationID: UUID?
    private var registrationOperationState: RegistrationOperationState = .idle
    private var startupRecoveryIsResolved = false

    private(set) var phase: MobileRemotePlayPhase = .loading
    private(set) var consoles: [MobileConsoleSummary] = []
    private(set) var videoSurface: SampleBufferVideoSurfaceBinding?
    private(set) var activeSessionID: UUID?
    private(set) var activeConsoleID: UUID?
    private(set) var activeStreamQuality: MobileStreamQuality?
    private(set) var remoteDisplayIsBlocked = false
    private(set) var audioPlaybackSnapshot: PCMAudioPlaybackSnapshot?
    private(set) var lastSessionAudioSnapshot: PCMAudioPlaybackSnapshot?
    private(set) var videoDiagnosticsSnapshot: VideoPresentationRateSnapshot?
    private(set) var lastSessionVideoSnapshot: VideoPresentationRateSnapshot?
    private(set) var latestDiagnosticsReportURL: URL?
    private(set) var diagnosticsReportStatusMessage: String?
    private(set) var latestConnectionReportURL: URL?
    private(set) var connectionReportStatusMessage: String?
    private var videoRateSampler = VideoPresentationRateSampler()
    private var recentDiagnosticsSamples: [StreamDiagnosticsReport.Sample] = []
    private var lastSessionDiagnosticsSamples: [StreamDiagnosticsReport.Sample] = []
    private var connectionAttempt: MobileConnectionAttemptState?
    private(set) var controllerConnection = MobileControllerConnection.disconnected
    private(set) var touchControlsAreEnabled = false
    private(set) var actionErrorMessage: String?
    private(set) var registrationRecovery: MobileRegistrationRecovery?
    private(set) var wakeRequestWasSent = false
    private(set) var wakeStatusMessage: String?

    var streamQuality: MobileStreamQuality {
        didSet {
            defaults.set(streamQuality.rawValue, forKey: PreferenceKey.streamQuality)
        }
    }

    /// Writes the two settings a play style stands for, through the same
    /// stored properties the direct controls use. Nothing extra is persisted,
    /// so the controls stay the record of what is set and a style can never
    /// disagree with them.
    func apply(_ style: StreamPlayStyle) {
        streamQuality = style.quality
        smoothMotionEnabled = style.smoothMotionEnabled
    }

    var audioVolume: Float {
        didSet {
            let finiteValue = audioVolume.isFinite ? audioVolume : 0
            let clampedValue = min(1, max(0, finiteValue))
            if clampedValue != audioVolume {
                audioVolume = clampedValue
                return
            }
            defaults.set(clampedValue, forKey: PreferenceKey.audioVolume)
            activeSession?.setVolume(clampedValue)
        }
    }

    var audioIsMuted: Bool {
        didSet {
            defaults.set(audioIsMuted, forKey: PreferenceKey.audioMuted)
            activeSession?.setMuted(audioIsMuted)
        }
    }

    /// Paced presentation: holds a few frames so bursty Wi-Fi does not stutter,
    /// at about 50 ms of added latency. Applies to the live session.
    var smoothMotionEnabled: Bool {
        didSet {
            defaults.set(smoothMotionEnabled, forKey: PreferenceKey.smoothMotion)
            videoSurface?.setPacingEnabled(smoothMotionEnabled)
        }
    }

    /// Console-driven rumble, light bar, and adaptive triggers. Applies
    /// immediately: turning it off returns a held rumble to rest at once.
    var controllerFeedbackEnabled: Bool {
        didSet {
            defaults.set(controllerFeedbackEnabled, forKey: PreferenceKey.controllerFeedback)
            dependencies.controllerSource.setControllerFeedbackEnabled(
                FarframeReleaseFeatures.advancedMedia && controllerFeedbackEnabled
            )
        }
    }

    /// Client-side spatial reconstruction of the decoded picture. Applies
    /// immediately to the live session. Defaults to off: the GPU pass has not
    /// yet been measured on a device, and off is exactly today's behavior.
    var videoEnhancement: StreamUpscaling {
        didSet {
            defaults.set(videoEnhancement.rawValue, forKey: PreferenceKey.videoEnhancement)
            videoSurface?.setUpscaling(FarframeReleaseFeatures.advancedMedia ? videoEnhancement : .off)
        }
    }

    /// Gameplay from an attached hardware keyboard, using the same adapter the
    /// Mac shell ships. Defaults to off, unlike the Mac: iOS has no click-to-
    /// focus gesture to arm it with, a keyboard paired to a phone should not
    /// silently start pressing PS5 buttons, and this has never been exercised
    /// on a physical iPad. Turning it on is a deliberate choice in Settings.
    var keyboardControlsEnabled: Bool {
        didSet {
            defaults.set(keyboardControlsEnabled, forKey: PreferenceKey.keyboardControls)
            synchronizeKeyboardControls()
        }
    }
    private var gameplaySurfaceIsActive = false

    /// UI status and input delivery must describe the same gate.
    ///
    /// The feature flag is part of the gate rather than only hiding the
    /// controls, so a preference left `true` by a build that offered the toggle
    /// cannot keep feeding keystrokes to the PS5 after the toggle is gone.
    var keyboardGameplayIsActive: Bool {
        MobileFeatureFlags.keyboardGameplayUI
            && keyboardControlsEnabled && gameplaySurfaceIsActive
    }

    /// The player view owns the only surface where a keystroke may reach the
    /// PS5. Anything that covers it — a sheet, the diagnostics overlay, an
    /// error, backgrounding — closes the gate, exactly as it does for touch.
    func setGameplaySurfaceActive(_ isActive: Bool) {
        gameplaySurfaceIsActive = isActive
        synchronizeKeyboardControls()
    }

    private func synchronizeKeyboardControls() {
        dependencies.controllerSource.setKeyboardControlsEnabled(keyboardGameplayIsActive)
    }

    private var connectionTimeoutTask: Task<Void, Never>?
    static let connectionTimeoutSeconds = 45

    init(defaults: UserDefaults = .standard) {
        self.dependencies = .production()
        self.defaults = defaults
        self.streamQuality = Self.loadQuality(from: defaults)
        self.audioVolume = Self.loadVolume(from: defaults)
        self.audioIsMuted = defaults.bool(forKey: PreferenceKey.audioMuted)
        self.smoothMotionEnabled = defaults.object(forKey: PreferenceKey.smoothMotion) == nil
            ? true : defaults.bool(forKey: PreferenceKey.smoothMotion)
        self.videoEnhancement = defaults.string(forKey: PreferenceKey.videoEnhancement)
            .flatMap(StreamUpscaling.init(rawValue:)) ?? .off
        self.keyboardControlsEnabled = defaults.bool(forKey: PreferenceKey.keyboardControls)
        self.controllerFeedbackEnabled = defaults.object(
            forKey: PreferenceKey.controllerFeedback
        ) == nil ? true : defaults.bool(forKey: PreferenceKey.controllerFeedback)
        self.dependencies.controllerSource.setControllerFeedbackEnabled(
            FarframeReleaseFeatures.advancedMedia && controllerFeedbackEnabled
        )
    }

    init(
        dependencies: MobileRemotePlayDependencies,
        defaults: UserDefaults
    ) {
        self.dependencies = dependencies
        self.defaults = defaults
        self.streamQuality = Self.loadQuality(from: defaults)
        self.audioVolume = Self.loadVolume(from: defaults)
        self.audioIsMuted = defaults.bool(forKey: PreferenceKey.audioMuted)
        self.smoothMotionEnabled = defaults.object(forKey: PreferenceKey.smoothMotion) == nil
            ? true : defaults.bool(forKey: PreferenceKey.smoothMotion)
        self.videoEnhancement = defaults.string(forKey: PreferenceKey.videoEnhancement)
            .flatMap(StreamUpscaling.init(rawValue:)) ?? .off
        self.keyboardControlsEnabled = defaults.bool(forKey: PreferenceKey.keyboardControls)
        self.controllerFeedbackEnabled = defaults.object(
            forKey: PreferenceKey.controllerFeedback
        ) == nil ? true : defaults.bool(forKey: PreferenceKey.controllerFeedback)
        self.dependencies.controllerSource.setControllerFeedbackEnabled(
            FarframeReleaseFeatures.advancedMedia && controllerFeedbackEnabled
        )
    }

    deinit {
        controllerConnectionTask?.cancel()
    }

    var selectedConsole: MobileConsoleSummary? {
        guard let activeConsoleID else { return nil }
        return consoles.first { $0.id == activeConsoleID }
    }

    var hasActiveSession: Bool { activeSession != nil }

    /// Home and the actions share this gate: a failed attempt is retryable,
    /// but retained transport, registration work and startup recovery are not.
    var canStartConsoleAction: Bool {
        guard startupRecoveryIsResolved,
              activeSession == nil,
              pendingLifecycleOperationID == nil,
              localSessionOperationID == nil,
              connectionOperationID == nil,
              registrationOperationState == .idle,
              registrationRecovery == nil else { return false }
        switch phase {
        case .ready, .failed:
            return true
        case .loading, .recoveryRequired, .waking, .prepared, .connecting,
             .streaming, .disconnecting:
            return false
        }
    }

    var requiresStartupRecovery: Bool { startupRecoveryIsResolved == false }

    var accountIdentityCapability: PlayStationAccountIdentityAcquisitionCapability {
        dependencies.pairing.identityCapability
    }

    var registrationOperationIsActive: Bool {
        if case .running = registrationOperationState { return true }
        return false
    }

    var pairingSecureSaveIsPending: Bool {
        registrationOperationState == .secureSavePending
    }

    var canPresentPairing: Bool {
        activeSession == nil
            && registrationOperationState == .idle
            && phaseAllowsRegistrationMutation
    }

    func prepare() async {
        startControllerConnectionMonitoring()
        guard phase == .loading else { return }
        await adoptStoredReports()
        await loadStartupState()
    }

    func retryStartup() async {
        guard activeSession == nil,
              registrationOperationState == .idle else { return }
        switch phase {
        case .ready, .recoveryRequired, .failed:
            break
        case .loading, .waking, .prepared, .connecting, .streaming, .disconnecting:
            return
        }
        phase = .loading
        await loadStartupState()
    }

    func dismissError() {
        guard case .failed = phase, canStartConsoleAction else { return }
        phase = .ready
    }

    func dismissActionError() {
        actionErrorMessage = nil
    }

    func setTouchControlsEnabled(_ isEnabled: Bool) {
        touchControlsAreEnabled = isEnabled
        if isEnabled == false {
            dependencies.controllerSource.setInjectedSnapshot(.neutral)
        }
    }

    func setTouchControllerSnapshot(_ snapshot: ControllerSnapshot) {
        guard touchControlsAreEnabled else { return }
        dependencies.controllerSource.setInjectedSnapshot(snapshot)
    }

    /// The pairing model owns exact-once presentation semantics; this method
    /// only exposes the retained production preflight through an injectable
    /// coordinator boundary.
    func requestLocalNetworkPairingAccess() async -> Bool {
        await dependencies.pairing.requestLocalNetworkAccess()
    }

    func acquirePairingAccountIdentity() async throws
        -> PlayStationRemotePlayAccountIdentity {
        guard activeSession == nil, phaseAllowsRegistrationMutation else {
            throw MobileRemotePlayCoordinatorError.registrationUnavailable
        }
        guard registrationOperationState == .idle else {
            throw MobileRemotePlayCoordinatorError.registrationOperationInProgress
        }
        return try await dependencies.pairing.acquireAccountIdentity()
    }

    @discardableResult
    func pairConsole(_ request: PlayStationPairingRequest) async throws
        -> MobileConsoleSummary {
        try beginRegistrationMutation()
        let operationID = currentRegistrationOperationID

        do {
            let savedConsole = try await dependencies.pairing.pair(request)
            try Task.checkCancellation()
            guard registrationOperationIsCurrent(operationID) else {
                throw CancellationError()
            }
            return try await finishSuccessfulRegistration(
                savedConsole,
                operationID: operationID
            )
        } catch {
            guard registrationOperationIsCurrent(operationID) else {
                throw CancellationError()
            }
            if PlayStationPairingError.isSecureSavePending(error) {
                registrationOperationState = .secureSavePending
            } else {
                finishRegistrationMutation(operationID)
            }
            throw error
        }
    }

    @discardableResult
    func retryPendingPairingSave() async throws -> MobileConsoleSummary {
        guard activeSession == nil else {
            throw MobileRemotePlayCoordinatorError.sessionActive
        }
        guard registrationOperationState == .secureSavePending else {
            throw PlayStationPairingError.noPendingSecureSave
        }
        guard phaseAllowsRegistrationMutation else {
            throw MobileRemotePlayCoordinatorError.registrationUnavailable
        }

        let operationID = UUID()
        registrationOperationState = .running(operationID)
        do {
            let savedConsole = try await dependencies.pairing.retryPendingSecureSave()
            try Task.checkCancellation()
            guard registrationOperationIsCurrent(operationID) else {
                throw CancellationError()
            }
            return try await finishSuccessfulRegistration(
                savedConsole,
                operationID: operationID
            )
        } catch {
            guard registrationOperationIsCurrent(operationID) else {
                throw CancellationError()
            }
            if PlayStationPairingError.isSecureSavePending(error) {
                registrationOperationState = .secureSavePending
            } else {
                finishRegistrationMutation(operationID)
            }
            throw error
        }
    }

    /// The shared web sign-in presenter, when this build supplies one.
    var webSignInAcquirer: PlayStationWebAccountIdentityAcquirer? {
        dependencies.webSignInAcquirer
    }

    /// Saves Home/Away addresses and the active route for a paired console.
    /// Uses the same registration-mutation gate as Remove so it never races a
    /// pairing, and never touches the Keychain envelope.
    func updateConnectionAddresses(
        consoleID: UUID,
        hostAddress: String,
        awayHostAddress: String?,
        connectionRoute: PlayStationConnectionRoute
    ) async throws {
        guard consoles.contains(where: { $0.id == consoleID }) else {
            throw MobileRemotePlayCoordinatorError.consoleNotFound
        }
        try beginRegistrationMutation(requiresReadyPhase: true)
        let operationID = currentRegistrationOperationID

        do {
            try await dependencies.pairing.updateConnectionAddresses(
                consoleID, hostAddress, awayHostAddress, connectionRoute
            )
            try Task.checkCancellation()
            guard registrationOperationIsCurrent(operationID) else {
                throw CancellationError()
            }
            let startup = try await dependencies.loadStartup()
            try Task.checkCancellation()
            guard registrationOperationIsCurrent(operationID) else {
                throw CancellationError()
            }
            finishRegistrationMutation(operationID)
            applyStartupSnapshot(startup)
        } catch {
            guard registrationOperationIsCurrent(operationID) else {
                throw CancellationError()
            }
            finishRegistrationMutation(operationID)
            throw error
        }
    }

    func removeConsole(_ consoleID: UUID) async throws {
        guard consoles.contains(where: { $0.id == consoleID }) else {
            throw MobileRemotePlayCoordinatorError.consoleNotFound
        }
        try beginRegistrationMutation(requiresReadyPhase: true)
        let operationID = currentRegistrationOperationID

        do {
            try await dependencies.pairing.removeConsole(consoleID)
            try Task.checkCancellation()
            guard registrationOperationIsCurrent(operationID) else {
                throw CancellationError()
            }

            consoles.removeAll { $0.id == consoleID }

            let startup = try await dependencies.loadStartup()
            try Task.checkCancellation()
            guard registrationOperationIsCurrent(operationID) else {
                throw CancellationError()
            }

            finishRegistrationMutation(operationID)
            applyStartupSnapshot(startup)
        } catch {
            guard registrationOperationIsCurrent(operationID) else {
                throw CancellationError()
            }
            finishRegistrationMutation(operationID)
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    func wake(consoleID: UUID) async {
        guard canStartConsoleAction, Task.isCancelled == false else { return }
        guard consoles.contains(where: { $0.id == consoleID }) else {
            phase = .failed(MobileRemotePlayCoordinatorError.consoleNotFound.localizedDescription)
            return
        }

        let operationID = beginLifecycleOperation()
        clearWakeStatus()
        phase = .waking(consoleID)
        do {
            try await dependencies.wake(consoleID)
            try Task.checkCancellation()
            guard isCurrentLifecycleOperation(operationID),
                  phase == .waking(consoleID),
                  activeSession == nil else { return }
            // UDP completion is not an acknowledgement from the console.
            wakeRequestWasSent = true
            wakeStatusMessage = "Wake request sent. Console readiness is not confirmed. Try Connect when your PS5 is ready."
            try await dependencies.waitForWakeSettling()
            try Task.checkCancellation()
            guard isCurrentLifecycleOperation(operationID),
                  phase == .waking(consoleID),
                  activeSession == nil else { return }
            finishLifecycleOperation(operationID)
            phase = .ready
        } catch {
            guard isCurrentLifecycleOperation(operationID),
                  phase == .waking(consoleID),
                  activeSession == nil else { return }
            finishLifecycleOperation(operationID)
            clearWakeStatus()
            phase = error is CancellationError || Task.isCancelled
                ? .ready
                : .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func prepareConnection(consoleID: UUID) async -> Bool {
        guard canStartConsoleAction, Task.isCancelled == false else { return false }
        guard let console = consoles.first(where: { $0.id == consoleID }) else {
            phase = .failed(MobileRemotePlayCoordinatorError.consoleNotFound.localizedDescription)
            return false
        }

        beginConnectionAttempt(console: console)

        // Reserve the one-session lane before the first suspension point so
        // two rapid Connect actions cannot create competing provider sessions.
        let operationID = beginLifecycleOperation()
        clearWakeStatus()
        phase = .connecting(consoleID)
        do {
            let selectedQuality = streamQuality
            let session = try await dependencies.makeSession(console, selectedQuality.profile)

            guard isCurrentLifecycleOperation(operationID),
                  phase == .connecting(consoleID),
                  activeSession == nil else {
                await session.stop()
                return false
            }

            guard let sessionVideoSurface = session.videoSurface else {
                await session.stop()
                guard isCurrentLifecycleOperation(operationID),
                      phase == .connecting(consoleID),
                      activeSession == nil else { return false }
                finishLifecycleOperation(operationID)
                await finishConnectionAttemptFailure(category: "video-surface-unavailable")
                phase = .failed(MobileRemotePlayCoordinatorError.missingVideoSurface.localizedDescription)
                return false
            }
            session.setVolume(audioVolume)
            session.setMuted(audioIsMuted)

            activeSession = session
            await session.setControllerFeedbackHandler {
                [controllerSource = dependencies.controllerSource] feedback in
                controllerSource.applyControllerFeedback(feedback)
            }
            activeSessionID = session.id
            activeConsoleID = consoleID
            activeStreamQuality = selectedQuality
            videoSurface = sessionVideoSurface.sampleBufferBinding
            videoSurface?.setPacingEnabled(smoothMotionEnabled)
            videoSurface?.setUpscaling(FarframeReleaseFeatures.advancedMedia ? videoEnhancement : .off)
            recentDiagnosticsSamples = []
            remoteDisplayIsBlocked = false
            actionErrorMessage = nil
            preparedSessionHasStarted = false
            preparedSurfaceHasBeenQueued = false
            preparedSessionGenerationID = UUID()
            presentationWasInterrupted = false
            recordConnectionAttemptStage(.sessionPrepared)
            finishLifecycleOperation(operationID)
            phase = .prepared(consoleID)
            return true
        } catch {
            guard isCurrentLifecycleOperation(operationID),
                  phase == .connecting(consoleID),
                  activeSession == nil else { return false }
            finishLifecycleOperation(operationID)
            clearSessionState()
            await finishConnectionAttemptFailure(category: "session-preparation-failed")
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    /// The UIKit host invokes this only after it synchronously queues the
    /// session surface attachment. The returned value names this exact prepared
    /// session generation; entitlement work must resolve through it after every
    /// suspension point instead of acting on whatever session is current later.
    func surfaceWasQueued(
        sessionID: UUID
    ) -> MobilePreparedSessionStartAuthorization? {
        guard activeSessionID == sessionID,
              let consoleID = activeConsoleID,
              phase == .prepared(consoleID),
              preparedSessionHasStarted == false else { return nil }

        preparedSurfaceHasBeenQueued = true
        recordConnectionAttemptStage(.surfaceQueued)
        return issuePreparedSessionStartAuthorization()
    }

    /// Commits one entitlement result only while it still owns the exact
    /// unstarted preparation that requested it. A delayed denial therefore
    /// cannot disconnect active playback or a replacement session.
    func resolvePreparedSessionStart(
        _ authorization: MobilePreparedSessionStartAuthorization,
        isAuthorized: Bool
    ) async -> MobilePreparedSessionStartResolution {
        guard authorization == currentPreparedSessionStartAuthorization(),
              let session = activeSession,
              let consoleID = activeConsoleID else { return .stale }
        pendingPreparedSessionAuthorizationID = nil

        if isAuthorized {
            guard applicationIsActive else { return .deferredUntilActive }
            guard startPreparedSessionIfPossible() else { return .stale }
            return .started
        }

        // Claim teardown synchronously before the first suspension point. This
        // prevents another authorization callback from starting this session
        // while its entitlement denial is stopping native transport.
        invalidateLifecycleOperation()
        cancelBackgroundTasks()
        let operationID = beginLocalSessionOperation()
        phase = .disconnecting
        await session.stop()
        guard localSessionOperationIsCurrent(operationID, sessionID: session.id) else {
            return .stale
        }
        let snapshot = await session.snapshot()
        guard localSessionOperationIsCurrent(operationID, sessionID: session.id) else {
            return .stale
        }
        if snapshot.state == .disconnected {
            clearSessionState()
            phase = .ready
        } else {
            finishLocalSessionOperation(operationID)
            phase = .failed(
                "Remote Play could not confirm a clean disconnect. Choose Disconnect again to retry."
            )
        }
        return .denied(consoleID: consoleID)
    }

    @discardableResult
    private func startPreparedSessionIfPossible() -> Bool {
        guard applicationIsActive,
              preparedSurfaceHasBeenQueued,
              preparedSessionHasStarted == false,
              let session = activeSession,
              let consoleID = activeConsoleID,
              phase == .prepared(consoleID) else { return false }

        preparedSessionHasStarted = true
        recordConnectionAttemptStage(.nativeStartRequested)
        phase = .connecting(consoleID)
        connectionTask?.cancel()
        let operationID = UUID()
        connectionOperationID = operationID
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { [weak self, session] in
            try? await Task.sleep(for: .seconds(Self.connectionTimeoutSeconds))
            guard let self, Task.isCancelled == false,
                  activeSessionID == session.id,
                  phase == .connecting(consoleID) else { return }
            connectionTimeoutTask = nil
            await cancelConnection()
            phase = .failed(MobileConnectionTimeoutError().localizedDescription)
        }
        connectionTask = Task { [weak self, session] in
            do {
                try await session.start()
                guard Task.isCancelled == false,
                      let self,
                      self.activeSessionID == session.id,
                      self.connectionOperationID == operationID,
                      self.phase == .connecting(consoleID) else { return }
                self.recordConnectionAttemptStage(.nativeStartReturned)
                self.connectionTask = nil
                self.connectionOperationID = nil
                if self.applicationIsActive {
                    self.startControllerDelivery(session: session)
                } else {
                    self.presentationWasInterrupted = true
                    await session.send(.neutral)
                }
                self.startMonitoring(session: session, consoleID: consoleID)
                await self.refreshActiveSession()
            } catch {
                let wasCancelled = error is CancellationError || Task.isCancelled
                await session.stop()
                guard wasCancelled == false,
                      Task.isCancelled == false,
                      let self,
                      self.activeSessionID == session.id,
                      self.connectionOperationID == operationID,
                      self.phase == .connecting(consoleID) else { return }
                let teardownSnapshot = await session.snapshot()
                guard Task.isCancelled == false,
                      self.activeSessionID == session.id,
                      self.connectionOperationID == operationID,
                      self.phase == .connecting(consoleID) else { return }
                self.connectionOperationID = nil
                // A console that never answers can quit the native session while
                // connect is still awaiting its start, and then the throw says
                // only "ended while connecting". The teardown snapshot already
                // in hand carries the reason, which is cleared at the next
                // connect and so can only describe this attempt.
                let cause = teardownSnapshot.lastQuitReason
                    .map(\.explanation.message) ?? error.localizedDescription
                if teardownSnapshot.state == .disconnected {
                    self.clearSessionState()
                    await self.finishConnectionAttemptFailure(category: "native-start-failed")
                    self.phase = .failed(cause)
                } else {
                    self.cancelBackgroundTasks()
                    await self.finishConnectionAttemptFailure(category: "native-start-cleanup-failed")
                    self.phase = .failed(
                        "The connection failed and cleanup could not be confirmed. Choose Disconnect again to retry. \(cause)"
                    )
                }
            }
        }
        return true
    }

    /// Deterministic app-target test seam; production UI never needs to wait on
    /// native startup synchronously.
    func waitForConnectionAttempt() async {
        await connectionTask?.value
    }

    /// A transient iOS interruption pauses controller delivery without
    /// inventing a disconnect. One neutral snapshot prevents a held control
    /// from remaining latched while the app is not interactive.
    func applicationWillResignActive() async {
        // Any answer produced after this point predates the interruption. A
        // later activation must issue a new request and revalidate again.
        pendingPreparedSessionAuthorizationID = nil
        guard applicationIsActive else { return }
        applicationIsActive = false
        let deliveryTask = controllerDeliveryTask
        controllerDeliveryTask = nil
        deliveryTask?.cancel()
        // A detached delivery iteration may already have passed its
        // cancellation check. Await it before neutralizing so no held input can
        // overtake the final neutral snapshot while the app is inactive.
        await deliveryTask?.value

        guard preparedSessionHasStarted,
              let session = activeSession,
              activeSessionID == session.id else { return }
        presentationWasInterrupted = true
        await session.send(.neutral)
    }

    /// Foreground recovery is session-scoped and exact-once. A stale recovery
    /// cannot resume input for a disconnected or replacement session.
    @discardableResult
    func applicationDidBecomeActive() async
        -> MobilePreparedSessionStartAuthorization? {
        let wasInactive = applicationIsActive == false
        applicationIsActive = true

        if wasInactive,
           presentationWasInterrupted,
           preparedSessionHasStarted,
           let session = activeSession,
           activeSessionID == session.id {
            presentationWasInterrupted = false
            await session.recoverVideoAfterInterruption()

            if applicationIsActive,
               activeSessionID == session.id,
               localSessionOperationID == nil,
               connectionOperationID == nil {
                switch phase {
                case .connecting, .streaming:
                    startControllerDelivery(session: session)
                case .loading, .recoveryRequired, .ready, .waking, .prepared,
                     .disconnecting, .failed:
                    break
                }
            }
        }

        // An inactive prepared session never starts as a side effect of scene
        // activation. The root must run a fresh entitlement revalidation and
        // resolve this exact generation first.
        return issuePreparedSessionStartAuthorization()
    }

    /// iOS does not keep Remote Play transport alive in the background. The
    /// application shell may wrap this await in a UIKit background-task lease
    /// so native Stop/Join receives bounded completion time.
    func applicationDidEnterBackground() async {
        await applicationWillResignActive()
        presentationWasInterrupted = false
        await disconnect()
    }

    func cancelConnection() async {
        connectionTask?.cancel()
        connectionTask = nil
        await disconnect()
    }

    func disconnect() async {
        if case .disconnecting = phase { return }
        invalidateLifecycleOperation()
        cancelBackgroundTasks()
        guard let session = activeSession else {
            clearSessionState()
            phase = .ready
            return
        }

        let operationID = beginLocalSessionOperation()
        phase = .disconnecting
        await session.stop()
        guard localSessionOperationIsCurrent(operationID, sessionID: session.id) else { return }
        let snapshot = await session.snapshot()
        guard localSessionOperationIsCurrent(operationID, sessionID: session.id) else { return }
        guard snapshot.state == .disconnected else {
            finishLocalSessionOperation(operationID)
            phase = .failed(
                "Remote Play could not confirm a clean disconnect. Choose Disconnect again to retry."
            )
            return
        }
        clearSessionState()
        phase = .ready
    }

    func restAndDisconnect() async {
        guard case .streaming = phase else { return }
        let operationID = beginLocalSessionOperation()
        cancelBackgroundTasks()
        guard let session = activeSession else {
            clearSessionState()
            phase = .ready
            return
        }

        phase = .disconnecting
        do {
            try await session.restAndDisconnect()
            guard localSessionOperationIsCurrent(operationID, sessionID: session.id) else { return }
            let snapshot = await session.snapshot()
            guard localSessionOperationIsCurrent(operationID, sessionID: session.id) else { return }
            if snapshot.state == .disconnected {
                clearSessionState()
                phase = .ready
            } else {
                finishLocalSessionOperation(operationID)
                phase = .failed(
                    "Rest Mode was requested, but Remote Play could not confirm a clean disconnect. Choose Disconnect again to retry."
                )
            }
        } catch {
            guard localSessionOperationIsCurrent(operationID, sessionID: session.id) else { return }
            await session.stop()
            guard localSessionOperationIsCurrent(operationID, sessionID: session.id) else { return }
            let snapshot = await session.snapshot()
            guard localSessionOperationIsCurrent(operationID, sessionID: session.id) else { return }
            if snapshot.state == .disconnected {
                clearSessionState()
                phase = .failed(
                    "Rest Mode could not be confirmed. Remote Play disconnected. \(error.localizedDescription)"
                )
            } else {
                finishLocalSessionOperation(operationID)
                phase = .failed(
                    "Rest Mode and a clean disconnect could not be confirmed. Choose Disconnect again to retry. \(error.localizedDescription)"
                )
            }
        }
    }

    func goHome() async {
        guard let session = activeSession else { return }
        if case .streaming = phase {
            // Available during ordinary decoded playback.
        } else {
            guard remoteDisplayIsBlocked else { return }
        }
        actionErrorMessage = nil
        do {
            try await session.goHome()
        } catch {
            guard activeSessionID == session.id else { return }
            actionErrorMessage = error.localizedDescription
        }
    }

    func refreshActiveSession() async {
        guard let session = activeSession else { return }
        let snapshot = await session.snapshot()
        let audioSnapshot = await session.audioSnapshot()
        guard activeSessionID == session.id,
              let consoleID = activeConsoleID,
              localSessionOperationID == nil,
              phaseAllowsSnapshotRefresh(consoleID: consoleID) else { return }
        let refreshPhase = phase

        controllerConnection = dependencies.controllerSource.connectionSnapshot()
        remoteDisplayIsBlocked = snapshot.displayIsBlocked
        audioPlaybackSnapshot = audioSnapshot
        if let videoSurface {
            videoDiagnosticsSnapshot = videoRateSampler.sample(
                videoSurface.snapshot(), surface: ObjectIdentifier(videoSurface),
                uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
        }
        appendDiagnosticsSample(audio: audioSnapshot, video: videoDiagnosticsSnapshot)

        switch snapshot.state {
        case .streaming:
            recordConnectionAttemptStage(.streaming)
            connectionAttempt = nil
            phase = .streaming(consoleID)
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
        case .preparing, .connecting:
            phase = .connecting(consoleID)
        case .disconnecting:
            phase = .disconnecting
        case .failed:
            let nativeQuitCode: Int32?
            if case .nativeFailure(let code) = snapshot.lastQuitReason {
                nativeQuitCode = code
            } else {
                nativeQuitCode = nil
            }
            cancelBackgroundTasks()
            await session.stop()
            guard refreshStillOwnsSession(
                sessionID: session.id,
                consoleID: consoleID,
                phase: refreshPhase
            ) else { return }
            let teardownSnapshot = await session.snapshot()
            guard refreshStillOwnsSession(
                sessionID: session.id,
                consoleID: consoleID,
                phase: refreshPhase
            ) else { return }
            if teardownSnapshot.state == .disconnected {
                clearSessionState()
                await finishConnectionAttemptFailure(
                    category: "native-session-failed",
                    nativeQuitCode: nativeQuitCode
                )
                phase = .failed(snapshot.failureMessage)
            } else {
                await finishConnectionAttemptFailure(
                    category: "native-session-cleanup-failed",
                    nativeQuitCode: nativeQuitCode
                )
                phase = .failed(
                    snapshot.failureMessage + " Cleanup could not be confirmed. Choose Disconnect again to retry."
                )
            }
        case .disconnected:
            if snapshot.lastQuitReason == .remoteDisconnected {
                await finishConnectionAttemptFailure(category: "remote-disconnected-before-stream")
            }
            clearSessionState()
            phase = snapshot.lastQuitReason == .remoteDisconnected
                ? .failed(snapshot.failureMessage)
                : .ready
        case .idle:
            break
        }
    }

    @discardableResult
    func saveDiagnosticsReport(
        trigger: StreamDiagnosticsReportTrigger,
        now: Date = Date()
    ) async throws -> URL {
        let audio = hasActiveSession ? audioPlaybackSnapshot : lastSessionAudioSnapshot
        let video = hasActiveSession ? videoDiagnosticsSnapshot : lastSessionVideoSnapshot
        let recentSamples = hasActiveSession
            ? recentDiagnosticsSamples : lastSessionDiagnosticsSamples
        guard audio != nil || video != nil else {
            throw StreamDiagnosticsReportError.noMetrics
        }

        let decoderDiagnostics = activeSession?.videoDecoderDiagnostics()
        let advisorInput = diagnosticsAdvisorInput(
            audio: audio,
            video: video,
            decoder: decoderDiagnostics
        )
        let report = StreamDiagnosticsReport(
            createdAt: now,
            trigger: trigger,
            sessionState: phase.statusText,
            requestedQuality: (activeStreamQuality ?? streamQuality).detail,
            environment: diagnosticsEnvironment(),
            recentSamples: recentSamples,
            audio: audio.map(StreamDiagnosticsReport.Audio.init),
            video: video.map(StreamDiagnosticsReport.Video.init),
            decoder: decoderDiagnostics.map(StreamDiagnosticsReport.Decoder.init),
            summary: StreamDiagnosticsReport.summaryLines(
                audio: audio, videoCounters: video?.counters, decoder: decoderDiagnostics
            ),
            advisor: StreamDiagnosticsAdvisor.advise(advisorInput),
            metricNotes: StreamDiagnosticsAdvisor.metricNotes
        )

        let url = try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let base = try manager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = base
                .appendingPathComponent("Farframe", isDirectory: true)
                .appendingPathComponent("Diagnostics", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
            let url = directory.appendingPathComponent("farframe-\(stamp)-\(trigger.rawValue).json")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
            return url
        }.value
        latestDiagnosticsReportURL = url
        diagnosticsReportStatusMessage = trigger == .screenshot
            ? "Screenshot-time report saved locally."
            : "Diagnostics report saved locally."
        return url
    }

    /// Reports of each kind kept on disk. Nothing else enumerates this
    /// directory, so without a bound it grows for the life of the install.
    private static let keptReportsPerKind = 5

    /// Restores the newest saved report of each kind, and deletes the rest.
    ///
    /// The files were always written to Application Support and always
    /// survived. The only path to them was an in-memory property, so quitting
    /// the app made every report ever written permanently unreachable while it
    /// sat on disk untouched. That also made the Diagnostics copy untrue: it
    /// tells the reader a connection report "stays here until the next
    /// attempt", and a relaunch is not an attempt.
    ///
    /// Newest by modification date rather than by parsing the timestamp out of
    /// the file name, because the name is a display detail and the two kinds
    /// do not even share a shape.
    private func adoptStoredReports() async {
        let keep = Self.keptReportsPerKind
        let found = await Task.detached(priority: .utility) { () -> (URL?, URL?) in
            let manager = FileManager.default
            guard let base = try? manager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ) else { return (nil, nil) }
            let directory = base
                .appendingPathComponent("Farframe", isDirectory: true)
                .appendingPathComponent("Diagnostics", isDirectory: true)
            guard let entries = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return (nil, nil) }

            func newestFirst(_ urls: [URL]) -> [URL] {
                urls.sorted { left, right in
                    let leftDate = (try? left.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ).contentModificationDate) ?? .distantPast
                    let rightDate = (try? right.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ).contentModificationDate) ?? .distantPast
                    return leftDate > rightDate
                }
            }

            let json = entries.filter { $0.pathExtension == "json" }
            let connection = newestFirst(
                json.filter { $0.lastPathComponent.hasPrefix("farframe-connection-") }
            )
            // Both kinds live here and both start "farframe-", so the
            // connection prefix is what separates them.
            let diagnostics = newestFirst(
                json.filter {
                    $0.lastPathComponent.hasPrefix("farframe-")
                        && $0.lastPathComponent.hasPrefix("farframe-connection-") == false
                }
            )
            for stale in Array(connection.dropFirst(keep)) + Array(diagnostics.dropFirst(keep)) {
                try? manager.removeItem(at: stale)
            }
            return (connection.first, diagnostics.first)
        }.value

        // Never overwrite something this session produced.
        if latestConnectionReportURL == nil { latestConnectionReportURL = found.0 }
        if latestDiagnosticsReportURL == nil { latestDiagnosticsReportURL = found.1 }
    }

    private func beginConnectionAttempt(console: MobileConsoleSummary, now: Date = Date()) {
        latestConnectionReportURL = nil
        connectionReportStatusMessage = nil
        connectionAttempt = MobileConnectionAttemptState(
            startedAt: now,
            hostAddress: console.activeHostAddress,
            requestedQuality: streamQuality.detail,
            wakeRequestWasSent: wakeRequestWasSent,
            network: dependencies.connectionNetworkSnapshot()
        )
    }

    private func recordConnectionAttemptStage(
        _ stage: MobileConnectionAttemptStage,
        now: Date = Date()
    ) {
        connectionAttempt?.record(stage, now: now)
    }

    private func finishConnectionAttemptFailure(
        category: String,
        nativeQuitCode: Int32? = nil,
        now: Date = Date()
    ) async {
        guard var attempt = connectionAttempt,
              attempt.events.contains(where: { $0.stage == .streaming }) == false else {
            return
        }
        attempt.record(.failed, now: now)
        connectionAttempt = attempt

        let info = ProcessInfo.processInfo
        let thermalState: String
        switch info.thermalState {
        case .nominal: thermalState = "nominal"
        case .fair: thermalState = "fair"
        case .serious: thermalState = "serious"
        case .critical: thermalState = "critical"
        @unknown default: thermalState = "unknown"
        }
        let bundle = Bundle.main
        let report = MobileConnectionAttemptReport(
            schemaVersion: 1,
            createdAt: now,
            outcome: "failed",
            failureCategory: category,
            nativeQuitCode: nativeQuitCode,
            nativeQuitCategory: MobileConnectionAttemptReport.nativeQuitCategory(
                for: nativeQuitCode
            ),
            endpointClass: attempt.endpointClass,
            requestedQuality: attempt.requestedQuality,
            wakeRequestWasSent: attempt.wakeRequestWasSent,
            network: attempt.network,
            environment: .init(
                appVersion: bundle.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "Unknown",
                buildNumber: bundle.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String ?? "Unknown",
                operatingSystem: info.operatingSystemVersionString,
                deviceClass: UIDevice.current.model,
                thermalState: thermalState,
                lowPowerModeEnabled: info.isLowPowerModeEnabled
            ),
            events: attempt.events,
            privacy: "No account identity, console credential, full host address, MAC address, device identifier, or native log text is included."
        )

        do {
            let url = try await writeConnectionReport(report, now: now)
            latestConnectionReportURL = url
            connectionReportStatusMessage = "Connection report ready to share."
        } catch {
            latestConnectionReportURL = nil
            connectionReportStatusMessage = "The connection report could not be saved."
        }
    }

    private func writeConnectionReport(
        _ report: MobileConnectionAttemptReport,
        now: Date
    ) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let base = try manager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = base
                .appendingPathComponent("Farframe", isDirectory: true)
                .appendingPathComponent("Diagnostics", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
            let url = directory.appendingPathComponent(
                "farframe-connection-\(stamp).json"
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
            return url
        }.value
    }

    /// The advisor reads snapshots and never participates in playback, so it is
    /// safe to build this on demand from whatever the last sample recorded.
    private func diagnosticsAdvisorInput(
        audio: PCMAudioPlaybackSnapshot?,
        video: VideoPresentationRateSnapshot?,
        decoder: HEVCDecoderDiagnostics?
    ) -> StreamDiagnosticsInput {
        let quality = activeStreamQuality ?? streamQuality
        let network = dependencies.connectionNetworkSnapshot()
        return .live(
            audio: audio,
            video: video.map(StreamDiagnosticsInput.Video.init),
            decoder: decoder,
            requestedQuality: quality.detail,
            requestedFramesPerSecond: quality.profile.framesPerSecond,
            networkInterface: StreamDiagnosticsNetworkInterface(reportValue: network.interface),
            networkIsConstrained: network.isConstrained,
            networkIsExpensive: network.isExpensive
        )
    }

    /// Ranked findings for the live session, or for the last one once it ended.
    var streamDiagnosticsAdvice: StreamDiagnosticsAdvice {
        StreamDiagnosticsAdvisor.advise(
            diagnosticsAdvisorInput(
                audio: hasActiveSession ? audioPlaybackSnapshot : lastSessionAudioSnapshot,
                video: hasActiveSession ? videoDiagnosticsSnapshot : lastSessionVideoSnapshot,
                decoder: activeSession?.videoDecoderDiagnostics()
            )
        )
    }

    /// The same diagnosis as self-describing plain text, for pasting into a
    /// message or into an AI assistant. Carries no identifiers.
    func streamDiagnosticsPlainText(now: Date = Date()) -> String {
        let input = diagnosticsAdvisorInput(
            audio: hasActiveSession ? audioPlaybackSnapshot : lastSessionAudioSnapshot,
            video: hasActiveSession ? videoDiagnosticsSnapshot : lastSessionVideoSnapshot,
            decoder: activeSession?.videoDecoderDiagnostics()
        )
        let environment = diagnosticsEnvironment()
        return StreamDiagnosticsAdvisor.plainTextReport(
            StreamDiagnosticsAdvisor.advise(input),
            input: input,
            generatedAt: now,
            appVersion: "\(environment.appVersion) (\(environment.buildNumber))"
        )
    }

    private func diagnosticsEnvironment() -> StreamDiagnosticsReport.Environment {
        let info = ProcessInfo.processInfo
        let bundle = Bundle.main
        let thermalState: String
        switch info.thermalState {
        case .nominal: thermalState = "nominal"
        case .fair: thermalState = "fair"
        case .serious: thermalState = "serious"
        case .critical: thermalState = "critical"
        @unknown default: thermalState = "unknown"
        }
        return .init(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown",
            operatingSystem: info.operatingSystemVersionString,
            deviceClass: UIDevice.current.model,
            thermalState: thermalState,
            lowPowerModeEnabled: info.isLowPowerModeEnabled,
            audioOutputs: AVAudioSession.sharedInstance().currentRoute.outputs.map {
                $0.portType.rawValue
            }
        )
    }

    private func appendDiagnosticsSample(
        audio: PCMAudioPlaybackSnapshot?,
        video: VideoPresentationRateSnapshot?,
        now: Date = Date()
    ) {
        guard audio != nil || video != nil else { return }
        recentDiagnosticsSamples.append(.init(capturedAt: now, audio: audio, video: video))
        let maximumSamples = 15
        if recentDiagnosticsSamples.count > maximumSamples {
            recentDiagnosticsSamples.removeFirst(recentDiagnosticsSamples.count - maximumSamples)
        }
    }

    private func loadStartupState() async {
        startupRecoveryIsResolved = false
        clearWakeStatus()
        do {
            let startup = try await dependencies.loadStartup()
            controllerConnection = dependencies.controllerSource.connectionSnapshot()
            applyStartupSnapshot(startup)
        } catch {
            consoles = []
            registrationRecovery = nil
            phase = .failed(error.localizedDescription)
        }
    }

    /// Controller presence is app-scoped, not session-scoped. Home and
    /// Settings therefore stay current while the transport is idle, while the
    /// separate 120 Hz delivery loop exists only for an active session.
    private func startControllerConnectionMonitoring() {
        guard controllerConnectionTask == nil else { return }
        let updates = dependencies.controllerSource.connectionUpdates()
        controllerConnectionTask = Task { [weak self] in
            for await connection in updates {
                guard Task.isCancelled == false, let self else { return }
                self.controllerConnection = connection
            }
        }
    }

    private func applyStartupSnapshot(_ startup: MobileStartupSnapshot) {
        consoles = startup.consoles.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        registrationRecovery = startup.registrationRecovery
        let recoveryMessage = startup.recoveryMessage ?? startup.registrationRecovery?.message
        startupRecoveryIsResolved = recoveryMessage == nil
        if let recoveryMessage {
            phase = .recoveryRequired(recoveryMessage)
        } else {
            phase = .ready
        }
    }

    private func finishSuccessfulRegistration(
        _ savedConsole: SavedPlayStationConsole,
        operationID: UUID
    ) async throws -> MobileConsoleSummary {
        let summary = MobileConsoleSummary(
            id: savedConsole.id,
            name: savedConsole.displayName,
            hostAddress: savedConsole.hostAddress,
            awayHostAddress: savedConsole.awayHostAddress,
            connectionRoute: savedConsole.connectionRoute
        )
        consoles.removeAll { $0.id == summary.id }
        consoles.append(summary)
        consoles.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        do {
            let startup = try await dependencies.loadStartup()
            try Task.checkCancellation()
            guard registrationOperationIsCurrent(operationID) else {
                throw CancellationError()
            }
            finishRegistrationMutation(operationID)
            applyStartupSnapshot(startup)
        } catch {
            try Task.checkCancellation()
            guard registrationOperationIsCurrent(operationID) else {
                throw CancellationError()
            }
            // Native registration and the verified device-local save already
            // succeeded. A list-refresh failure must not ask the user to pair
            // again with a new short-lived code.
            finishRegistrationMutation(operationID)
            registrationRecovery = nil
            startupRecoveryIsResolved = true
            phase = .ready
        }
        return summary
    }

    private func startMonitoring(
        session: any MobileRemotePlaySession,
        consoleID: UUID
    ) {
        monitorTask?.cancel()
        let interval = dependencies.monitorInterval
        monitorTask = Task { [weak self, session] in
            while Task.isCancelled == false {
                guard let self,
                      self.activeSessionID == session.id,
                      self.activeConsoleID == consoleID else { return }
                await self.refreshActiveSession()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    private func startControllerDelivery(session: any MobileRemotePlaySession) {
        guard applicationIsActive else { return }
        controllerDeliveryTask?.cancel()
        let source = dependencies.controllerSource
        let interval = dependencies.controllerDeliveryInterval
        let lifetime = MobileWeakCoordinatorLifetimeToken(lifetimeToken)
        controllerDeliveryTask = Task.detached(priority: .userInitiated) {
            while Task.isCancelled == false {
                guard lifetime.value != nil else { return }
                await session.send(source.snapshot())
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    private func cancelBackgroundTasks() {
        connectionTask?.cancel()
        connectionTask = nil
        connectionOperationID = nil
        monitorTask?.cancel()
        monitorTask = nil
        controllerDeliveryTask?.cancel()
        controllerDeliveryTask = nil
    }

    private func clearSessionState() {
        // A rumble held when the stream ends would otherwise run forever.
        dependencies.controllerSource.stopControllerFeedback()
        // Retain only bounded, non-identifying counters in memory. Do not let
        // repeated cleanup erase the previous run or carry it into live metrics.
        if activeSessionID != nil,
           audioPlaybackSnapshot != nil || videoDiagnosticsSnapshot != nil {
            lastSessionAudioSnapshot = audioPlaybackSnapshot
            lastSessionVideoSnapshot = videoDiagnosticsSnapshot
            lastSessionDiagnosticsSamples = recentDiagnosticsSamples
            Task { [weak self] in
                try? await self?.saveDiagnosticsReport(trigger: .sessionEnded)
            }
        }
        recentDiagnosticsSamples = []
        videoDiagnosticsSnapshot = nil
        videoRateSampler.reset()
        cancelBackgroundTasks()
        clearWakeStatus()
        dependencies.controllerSource.setInjectedSnapshot(.neutral)
        touchControlsAreEnabled = false
        localSessionOperationID = nil
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        activeSession = nil
        activeSessionID = nil
        activeConsoleID = nil
        activeStreamQuality = nil
        videoSurface = nil
        remoteDisplayIsBlocked = false
        audioPlaybackSnapshot = nil
        actionErrorMessage = nil
        preparedSessionHasStarted = false
        preparedSurfaceHasBeenQueued = false
        preparedSessionGenerationID = nil
        pendingPreparedSessionAuthorizationID = nil
        presentationWasInterrupted = false
    }

    private func clearWakeStatus() {
        wakeRequestWasSent = false
        wakeStatusMessage = nil
    }

    private func currentPreparedSessionStartAuthorization()
        -> MobilePreparedSessionStartAuthorization? {
        guard preparedSurfaceHasBeenQueued,
              preparedSessionHasStarted == false,
              let sessionID = activeSessionID,
              let consoleID = activeConsoleID,
              let generationID = preparedSessionGenerationID,
              let requestID = pendingPreparedSessionAuthorizationID,
              phase == .prepared(consoleID) else { return nil }
        return MobilePreparedSessionStartAuthorization(
            sessionID: sessionID,
            generationID: generationID,
            requestID: requestID
        )
    }

    private func issuePreparedSessionStartAuthorization()
        -> MobilePreparedSessionStartAuthorization? {
        guard preparedSurfaceHasBeenQueued,
              preparedSessionHasStarted == false,
              let sessionID = activeSessionID,
              let consoleID = activeConsoleID,
              let generationID = preparedSessionGenerationID,
              phase == .prepared(consoleID) else { return nil }
        let requestID = UUID()
        pendingPreparedSessionAuthorizationID = requestID
        return MobilePreparedSessionStartAuthorization(
            sessionID: sessionID,
            generationID: generationID,
            requestID: requestID
        )
    }

    private func beginLifecycleOperation() -> UUID {
        let operationID = UUID()
        pendingLifecycleOperationID = operationID
        return operationID
    }

    private func isCurrentLifecycleOperation(_ operationID: UUID) -> Bool {
        pendingLifecycleOperationID == operationID
    }

    private func finishLifecycleOperation(_ operationID: UUID) {
        guard pendingLifecycleOperationID == operationID else { return }
        pendingLifecycleOperationID = nil
    }

    private func invalidateLifecycleOperation() {
        pendingLifecycleOperationID = nil
    }

    private var phaseAllowsRegistrationMutation: Bool {
        switch phase {
        case .ready, .recoveryRequired:
            true
        case .loading, .waking, .prepared, .connecting, .streaming,
             .disconnecting, .failed:
            false
        }
    }

    private var currentRegistrationOperationID: UUID {
        guard case .running(let operationID) = registrationOperationState else {
            preconditionFailure("A registration mutation must reserve its operation before use.")
        }
        return operationID
    }

    private func beginRegistrationMutation(
        requiresReadyPhase: Bool = false
    ) throws {
        guard activeSession == nil else {
            throw MobileRemotePlayCoordinatorError.sessionActive
        }
        guard registrationOperationState == .idle else {
            throw MobileRemotePlayCoordinatorError.registrationOperationInProgress
        }
        if requiresReadyPhase {
            guard phase == .ready else {
                throw MobileRemotePlayCoordinatorError.registrationUnavailable
            }
        } else {
            guard phaseAllowsRegistrationMutation else {
                throw MobileRemotePlayCoordinatorError.registrationUnavailable
            }
        }
        registrationOperationState = .running(UUID())
    }

    private func registrationOperationIsCurrent(_ operationID: UUID) -> Bool {
        registrationOperationState == .running(operationID)
    }

    private func finishRegistrationMutation(_ operationID: UUID) {
        guard registrationOperationIsCurrent(operationID) else { return }
        registrationOperationState = .idle
    }

    private func beginLocalSessionOperation() -> UUID {
        let operationID = UUID()
        localSessionOperationID = operationID
        return operationID
    }

    private func localSessionOperationIsCurrent(
        _ operationID: UUID,
        sessionID: UUID
    ) -> Bool {
        localSessionOperationID == operationID && activeSessionID == sessionID
    }

    private func finishLocalSessionOperation(_ operationID: UUID) {
        guard localSessionOperationID == operationID else { return }
        localSessionOperationID = nil
    }

    private func phaseAllowsSnapshotRefresh(consoleID: UUID) -> Bool {
        switch phase {
        case .prepared(let phaseConsoleID),
             .connecting(let phaseConsoleID),
             .streaming(let phaseConsoleID):
            phaseConsoleID == consoleID
        case .disconnecting:
            true
        case .loading, .recoveryRequired, .ready, .waking, .failed:
            false
        }
    }

    private func refreshStillOwnsSession(
        sessionID: UUID,
        consoleID: UUID,
        phase refreshPhase: MobileRemotePlayPhase
    ) -> Bool {
        localSessionOperationID == nil
            && activeSessionID == sessionID
            && activeConsoleID == consoleID
            && phase == refreshPhase
    }

    private static func loadQuality(from defaults: UserDefaults) -> MobileStreamQuality {
        guard let rawValue = defaults.string(forKey: PreferenceKey.streamQuality),
              let quality = MobileStreamQuality(rawValue: rawValue) else {
            return .balanced
        }
        return quality
    }

    private static func loadVolume(from defaults: UserDefaults) -> Float {
        guard defaults.object(forKey: PreferenceKey.audioVolume) != nil else { return 0.7 }
        let value = defaults.float(forKey: PreferenceKey.audioVolume)
        return min(1, max(0, value.isFinite ? value : 0.7))
    }
}

private final class MobileCoordinatorLifetimeToken: @unchecked Sendable {}

private final class MobileWeakCoordinatorLifetimeToken: @unchecked Sendable {
    weak var value: MobileCoordinatorLifetimeToken?

    init(_ value: MobileCoordinatorLifetimeToken) {
        self.value = value
    }
}

private extension MobileRemotePlayDependencies {
    @MainActor
    static func production() -> Self {
        let composition = PlayStationRemotePlayComposition()
        let localNetworkPreflight = PlayStationLocalNetworkPreflight()
        // Shared web sign-in (decision D-038). Manual Account ID stays under
        // Advanced as the fallback path.
        let accountIdentityAcquirer = PlayStationWebAccountIdentityAcquirer()
        let controllerSource = MobileAppleGameControllerSource()

        var dependencies = Self(
            loadStartup: {
                let recovery = try await composition.repository.recoverPendingRegistration()
                let savedConsoles = try await composition.repository.consoles()
                let consoles = savedConsoles.map {
                    MobileConsoleSummary(
                        id: $0.id,
                        name: $0.displayName,
                        hostAddress: $0.hostAddress,
                        awayHostAddress: $0.awayHostAddress,
                        connectionRoute: $0.connectionRoute
                    )
                }

                let registrationRecovery: MobileRegistrationRecovery?
                switch recovery {
                case .needsRegistration(let pending):
                    let canonicalID = MobilePairingTarget.canonicalRecoveryConsoleID(
                        pendingConsoleID: pending.id,
                        canonicalConsoleIDs: Set(savedConsoles.map(\.id))
                    )
                    let message = canonicalID == nil
                        ? "A previous pairing did not finish. Pair this PS5 again to complete its device-local registration."
                        : "This saved PS5 needs to be re-registered before Remote Play can connect."
                    registrationRecovery = MobileRegistrationRecovery(
                        message: message,
                        target: MobilePairingTarget(
                            existingConsoleID: canonicalID,
                            displayName: pending.displayName,
                            hostAddress: pending.hostAddress
                        )
                    )
                case .completed, nil:
                    registrationRecovery = nil
                }
                return MobileStartupSnapshot(
                    consoles: consoles,
                    recoveryMessage: registrationRecovery?.message,
                    registrationRecovery: registrationRecovery
                )
            },
            wake: { consoleID in
                try await composition.wakeService.wake(consoleID: consoleID)
            },
            makeSession: { console, qualityProfile in
                let provider = composition.makeProvider(qualityProfile: qualityProfile)
                let savedConsole = SavedPlayStationConsole(
                    id: console.id,
                    displayName: console.name,
                    hostAddress: console.hostAddress,
                    awayHostAddress: console.awayHostAddress,
                    connectionRoute: console.connectionRoute
                )
                let genericSession = try await provider.makeSession(
                    for: savedConsole.remotePlayExperience
                )
                guard let session = genericSession as? PlayStationRemotePlayStreamingSession else {
                    throw MobileRemotePlayCoordinatorError.invalidSessionType
                }
                return MobilePlayStationRemotePlaySession(session: session)
            },
            controllerSource: controllerSource,
            pairing: MobilePlayStationPairingDependencies(
                identityCapability: accountIdentityAcquirer.capability,
                requestLocalNetworkAccess: {
                    await localNetworkPreflight.requestAccess()
                },
                acquireAccountIdentity: {
                    try await accountIdentityAcquirer.acquireAccountIdentity()
                },
                pair: { request in
                    try await composition.pairingService.pair(request)
                },
                retryPendingSecureSave: {
                    try await composition.pairingService.retryPendingSecureSave()
                },
                removeConsole: { consoleID in
                    try await composition.repository.remove(consoleID)
                },
                updateConnectionAddresses: { consoleID, host, away, route in
                    _ = try await composition.repository.updateConnectionAddresses(
                        consoleID: consoleID,
                        hostAddress: host,
                        awayHostAddress: away,
                        connectionRoute: route
                    )
                }
            ),
            connectionNetworkSnapshot: {
                MobileConnectionPathMonitor.shared.snapshot()
            }
        )
        dependencies.webSignInAcquirer = accountIdentityAcquirer
        return dependencies
    }
}

private final class MobilePlayStationRemotePlaySession: MobileRemotePlaySession, @unchecked Sendable {
    private let session: PlayStationRemotePlayStreamingSession

    init(session: PlayStationRemotePlayStreamingSession) {
        self.session = session
    }

    var id: UUID { session.id }
    var videoSurface: MobileRemotePlayVideoSurface? {
        .sampleBuffer(session.videoSurface)
    }

    func start() async throws { try await session.start() }
    func stop() async { await session.stop() }
    func send(_ input: ControllerSnapshot) async { await session.send(input) }
    func goHome() async throws { try await session.goHome() }
    func restAndDisconnect() async throws { try await session.restAndDisconnect() }

    func snapshot() async -> MobileRemoteSessionSnapshot {
        let snapshot = await session.snapshot()
        return MobileRemoteSessionSnapshot(
            state: snapshot.state,
            displayIsBlocked: snapshot.displayIsBlocked,
            lastQuitReason: snapshot.lastQuitReason
        )
    }

    func audioSnapshot() async -> PCMAudioPlaybackSnapshot? {
        await session.audioSnapshot()
    }

    func videoDecoderDiagnostics() -> HEVCDecoderDiagnostics? {
        session.videoDecoderDiagnostics.snapshot()
    }

    func recoverVideoAfterInterruption() async {
        _ = await session.videoSurface.recoverAfterInterruption()
    }

    func setControllerFeedbackHandler(
        _ handler: @escaping @Sendable (ControllerFeedbackEvent) -> Void
    ) async {
        await session.setControllerFeedbackHandler { _, feedback in
            handler(feedback)
        }
    }

    func setVolume(_ volume: Float) { session.audioControls.setVolume(volume) }
    func setMuted(_ isMuted: Bool) { session.audioControls.setMuted(isMuted) }
}

private final class MobileAppleGameControllerSource: MobileRemotePlayControllerSource, @unchecked Sendable {
    private let source: AppleGameControllerSource
    private let keyboardSource: AppleKeyboardControllerSource
    private let feedbackSink = AppleControllerFeedbackSink()

    @MainActor
    init() {
        self.source = AppleGameControllerSource()
        self.keyboardSource = AppleKeyboardControllerSource()
        source.attachFeedbackSink(feedbackSink)
    }

    /// A gamepad, the on-screen controls and a hardware keyboard can all be
    /// present at once. Merging keeps any of them able to press a button
    /// without the others having to be neutral first.
    func snapshot() -> ControllerSnapshot {
        source.snapshot().merging(keyboardSource.snapshot())
    }

    func setInjectedSnapshot(_ snapshot: ControllerSnapshot) {
        source.setInjectedSnapshot(snapshot)
    }

    func setKeyboardControlsEnabled(_ enabled: Bool) {
        keyboardSource.setEnabled(enabled)
    }

    func applyControllerFeedback(_ event: ControllerFeedbackEvent) {
        feedbackSink.apply(event)
    }

    func setControllerFeedbackEnabled(_ enabled: Bool) {
        feedbackSink.setEnabled(enabled)
    }

    func stopControllerFeedback() {
        feedbackSink.stopAll()
    }

    func connectionSnapshot() -> MobileControllerConnection {
        let snapshot = source.connectionSnapshot()
        return MobileControllerConnection(
            isConnected: snapshot.isConnected,
            name: snapshot.name
        )
    }

    func connectionUpdates() -> AsyncStream<MobileControllerConnection> {
        let updates = source.connectionUpdates()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let deliveryTask = Task {
                for await snapshot in updates {
                    guard Task.isCancelled == false else { return }
                    continuation.yield(
                        MobileControllerConnection(
                            isConnected: snapshot.isConnected,
                            name: snapshot.name
                        )
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in deliveryTask.cancel() }
        }
    }
}
