import AccountsAndSecurity
import AppleMediaCore
import ExperienceDomain
import Foundation
import InputCore
import Observation
import PlayStationRemotePlay
import PlayStationRemotePlayUI
import StreamingCore

struct VisionPreparedSessionStartAuthorization: Equatable, Sendable {
    fileprivate let sessionID: UUID
    fileprivate let generationID: UUID
    fileprivate let requestID: UUID
}

enum VisionPreparedSessionStartResolution: Equatable, Sendable {
    case started
    case deferredUntilActive
    case denied(consoleID: UUID)
    case stale
}

enum VisionRemotePlayPhase: Equatable, Sendable {
    case loading
    case recoveryFailed(String)
    case registrationRequired(
        message: String,
        consoleID: UUID?,
        displayName: String,
        hostAddress: String
    )
    case ready
    case waking(UUID)
    case prepared(UUID)
    case connecting(UUID)
    case streaming(UUID)
    case disconnecting
    case removing(UUID)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .loading, .recoveryFailed, .registrationRequired,
             .waking, .prepared, .connecting, .disconnecting, .removing:
            true
        case .ready, .streaming, .failed:
            false
        }
    }
}

/// The shared preset list, aliased so the existing shell call sites and the
/// persisted raw values are untouched. The display strings are derived from the
/// resolved profile in `ExperienceDomain`, so a bitrate change is one edit.
typealias VisionStreamQuality = StreamQualityPreset

/// Vision-only composition root. Views receive plain state and actions; native
/// streaming objects stay retained here so future Home/Settings redesigns do
/// not disturb the proven transport, media, or teardown lifecycle.
@MainActor
@Observable
final class VisionRemotePlayCoordinator {
    private enum PreferenceKey {
        static let streamQuality = "PSPlayVision.streamBitrate"
        static let restOnPlayerClose = "PSPlayVision.restOnDisconnect"
        static let streamHealthHUDEnabled = "PSPlayVision.streamHealthHUDEnabled"
        static let smoothMotionEnabled = "PSPlayVision.smoothMotionEnabled"
        static let controllerFeedbackEnabled = "PSPlayVision.controllerFeedbackEnabled"
        static let videoEnhancement = "PSPlayVision.videoEnhancement"
        static let backgroundDisconnectMinutes = "PSPlayVision.backgroundDisconnectMinutes"
        static let pinnedPlayerControls = "PSPlayVision.pinnedPlayerControls"
    }

    private static let defaultPinnedPlayerControls: [VisionPlayerControlID] = [
        .psMenu,
        .showMain,
        .streamHUD,
        .sleep,
        .disconnect,
        .psOptions,
        .volume,
    ]

    private let repository: PlayStationConsoleRepository
    private let wakeService: PlayStationWakeService
    private let nativeSessionFactory: any PlayStationNativeSessionFactory
    private let pairingService: PlayStationPairingService
    private let legacyMigrator: LegacyPlayStationConsoleMigrator
    private let defaults: UserDefaults
    let controllerSource: AppleGameControllerSource
    let controllerFeedbackSink = AppleControllerFeedbackSink()
    /// Shared web sign-in (decision D-038); the Home container presents it.
    let webSignInAcquirer = PlayStationWebAccountIdentityAcquirer()

    private var activeSession: PlayStationRemotePlayStreamingSession?
    private var connectionTask: Task<Void, Never>?
    private var sessionMonitorTask: Task<Void, Never>?
    private var controllerDeliveryTask: Task<Void, Never>?
    private var blockedContentExitTask: Task<Void, Never>?
    private var preparedSessionHasStarted = false
    private var preparedSurfaceHasBeenQueued = false
    private var preparedSessionGenerationID: UUID?
    private var pendingPreparedSessionAuthorizationID: UUID?
    private var connectionOperationID: UUID?
    private var localSessionOperationID: UUID?
    private var playerSceneIsActive = true
    private var playerSceneWasInterrupted = false
    private var playerWindowOwnerID: UUID?
    private var visibleSetupWindowIDs: Set<UUID> = []

    private(set) var phase: VisionRemotePlayPhase = .loading
    private(set) var consoles: [SavedPlayStationConsole] = []
    private(set) var videoSurface: SampleBufferVideoSurfaceBinding?
    var activeSessionID: UUID? { activeSession?.id }
    private(set) var activeConsoleID: UUID?
    private(set) var activeStreamQuality: VisionStreamQuality?
    private(set) var remoteDisplayIsBlocked = false
    var audioVolume: Float = 0.7 {
        didSet {
            let clampedVolume = min(1, max(0, audioVolume.isFinite ? audioVolume : 0))
            if audioVolume != clampedVolume {
                audioVolume = clampedVolume
                return
            }
            activeSession?.audioControls.setVolume(clampedVolume)
        }
    }
    var audioIsMuted = false {
        didSet { activeSession?.audioControls.setMuted(audioIsMuted) }
    }

    var streamQuality: VisionStreamQuality {
        didSet {
            defaults.set(streamQuality.profile.targetBitrateKbps, forKey: PreferenceKey.streamQuality)
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

    var restOnPlayerClose: Bool {
        didSet {
            defaults.set(restOnPlayerClose, forKey: PreferenceKey.restOnPlayerClose)
        }
    }

    var streamHealthHUDEnabled: Bool {
        didSet {
            defaults.set(streamHealthHUDEnabled, forKey: PreferenceKey.streamHealthHUDEnabled)
        }
    }

    /// Holds a few frames so bursty Wi-Fi does not stutter; about 50 ms of
    /// added latency. Applies immediately to the live session.
    var smoothMotionEnabled: Bool {
        didSet {
            defaults.set(smoothMotionEnabled, forKey: PreferenceKey.smoothMotionEnabled)
            videoSurface?.setPacingEnabled(smoothMotionEnabled)
        }
    }

    /// Console-driven rumble, light bar, and adaptive triggers. Applies
    /// immediately: turning it off returns a held rumble to rest at once.
    var controllerFeedbackEnabled: Bool {
        didSet {
            defaults.set(
                controllerFeedbackEnabled,
                forKey: PreferenceKey.controllerFeedbackEnabled
            )
            controllerFeedbackSink.setEnabled(FarframeReleaseFeatures.advancedMedia && controllerFeedbackEnabled)
        }
    }

    /// Client-side spatial reconstruction of the decoded picture. Applies
    /// immediately to the live session. Defaults to off: the GPU pass has not
    /// yet been measured on a headset, and off is exactly today's behavior.
    var videoEnhancement: StreamUpscaling {
        didSet {
            defaults.set(videoEnhancement.rawValue, forKey: PreferenceKey.videoEnhancement)
            videoSurface?.setUpscaling(FarframeReleaseFeatures.advancedMedia ? videoEnhancement : .off)
        }
    }

    /// Minutes a session keeps running after the headset comes off or the app
    /// goes to the background before Farframe ends it. 0 ends it at once;
    /// a negative value never ends it.
    var backgroundDisconnectMinutes: Int {
        didSet {
            defaults.set(backgroundDisconnectMinutes, forKey: PreferenceKey.backgroundDisconnectMinutes)
            if playerSceneIsActive == false { scheduleBackgroundDisconnect() }
        }
    }
    private var backgroundDisconnectTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    /// A console that never answers used to leave "Connecting" on screen
    /// forever with no way out but Cancel. Chiaki's own timeouts are long and
    /// silent, so the shell bounds the whole connect-to-first-frame window.
    static let connectionTimeoutSeconds = 45

    var pinnedPlayerControlIDs: [VisionPlayerControlID] {
        didSet {
            defaults.set(
                pinnedPlayerControlIDs.map(\.rawValue),
                forKey: PreferenceKey.pinnedPlayerControls
            )
        }
    }

    var setupWindowIsPresented: Bool {
        visibleSetupWindowIDs.isEmpty == false
    }

    init(defaults: UserDefaults = .standard) {
        let metadataStore = UserDefaultsPlayStationConsoleMetadataStore()
        let credentialStore = KeychainCredentialStore()
        let repository = PlayStationConsoleRepository(
            metadataStore: metadataStore,
            credentialStore: credentialStore
        )

        self.defaults = defaults
        self.repository = repository
        self.wakeService = PlayStationWakeService(repository: repository)
        self.nativeSessionFactory = ChiakiPlayStationNativeSessionFactory()
        self.pairingService = PlayStationPairingService(
            repository: repository,
            nativeClientFactory: ChiakiPlayStationNativeRegistrationClientFactory()
        )
        self.legacyMigrator = LegacyPlayStationConsoleMigrator(
            source: UserDefaultsLegacyPlayStationConsoleDataStore(),
            repository: repository
        )
        self.controllerSource = AppleGameControllerSource()

        self.streamHealthHUDEnabled = defaults.bool(
            forKey: PreferenceKey.streamHealthHUDEnabled
        )
        self.smoothMotionEnabled = defaults.object(forKey: PreferenceKey.smoothMotionEnabled) == nil
            ? true
            : defaults.bool(forKey: PreferenceKey.smoothMotionEnabled)
        self.controllerFeedbackEnabled = defaults.object(
            forKey: PreferenceKey.controllerFeedbackEnabled
        ) == nil ? true : defaults.bool(forKey: PreferenceKey.controllerFeedbackEnabled)
        self.videoEnhancement = defaults.string(forKey: PreferenceKey.videoEnhancement)
            .flatMap(StreamUpscaling.init(rawValue:)) ?? .off
        self.backgroundDisconnectMinutes = defaults.object(
            forKey: PreferenceKey.backgroundDisconnectMinutes
        ) == nil ? 5 : defaults.integer(forKey: PreferenceKey.backgroundDisconnectMinutes)
        let rawPinnedControls = defaults.stringArray(
            forKey: PreferenceKey.pinnedPlayerControls
        ) ?? []
        var seenPinnedControls: Set<VisionPlayerControlID> = []
        let supportedPinnedControls = rawPinnedControls
            .compactMap(VisionPlayerControlID.init(rawValue:))
            .filter { seenPinnedControls.insert($0).inserted }
        self.pinnedPlayerControlIDs = supportedPinnedControls.isEmpty
            ? Self.defaultPinnedPlayerControls
            : supportedPinnedControls

        let storedBitrate = defaults.integer(forKey: PreferenceKey.streamQuality)
        self.streamQuality = switch storedBitrate {
        case 4_000: .performance
        case StreamBitratePreset.high.targetBitrateKbps: .high
        case StreamBitratePreset.maximum.targetBitrateKbps: .maximum
        case 8_000: .stability
        default: .balanced
        }
        self.restOnPlayerClose = defaults.bool(forKey: PreferenceKey.restOnPlayerClose)

        // The sink follows whichever controller the input source owns, so
        // rumble survives a controller swap without any extra bookkeeping.
        controllerFeedbackSink.setEnabled(FarframeReleaseFeatures.advancedMedia && controllerFeedbackEnabled)
        controllerSource.attachFeedbackSink(controllerFeedbackSink)
    }

    func prepare() async {
        guard phase == .loading else { return }
        await performPreparation()
    }

    private func performPreparation() async {
        phase = .loading
        do {
            // ABI-6 pairing journals carry a non-secret credential fingerprint,
            // so a crash after native registration can finish idempotently
            // before legacy migration or another pairing attempt begins.
            let recovery = try await repository.recoverPendingRegistration()
            let migration = try await legacyMigrator.migrate()
            try await reloadConsoles()
            if case let .some(.needsRegistration(pending)) = recovery,
               migration == .noLegacyData {
                let savedConsoleID = consoles.contains(where: { $0.id == pending.id })
                    ? pending.id
                    : nil
                phase = .registrationRequired(
                    message: savedConsoleID == nil
                        ? "A previous PS5 pairing was interrupted before its secure registration was saved. Request a fresh Link Device code to pair again."
                        : "Re-registration was interrupted before its secure registration was saved. Request a fresh Link Device code and re-register this PS5.",
                    consoleID: savedConsoleID,
                    displayName: pending.displayName,
                    hostAddress: pending.hostAddress
                )
            } else {
                phase = .ready
            }
        } catch {
            // Never expose Pair, Wake, or Connect while startup recovery is
            // unresolved. A canonical record may already be visible, but the
            // journal must finish before another registration mutation begins.
            do {
                try await reloadConsoles()
            } catch {
                consoles = []
            }
            phase = .recoveryFailed(error.localizedDescription)
        }
    }

    func reloadConsoles() async throws {
        consoles = try await repository.consoles().sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func wake(consoleID: UUID) async {
        guard phase.isBusy == false else { return }
        phase = .waking(consoleID)
        do {
            try await wakeService.wake(consoleID: consoleID)
            // Wake confirms that the datagram was sent, not that the PS5 is
            // already ready to accept a Remote Play session. A PS5 leaving rest
            // needs roughly ten seconds before it accepts one; connecting at
            // four seconds produced a hang the owner had to cancel. Keep
            // Connect disabled long enough that the first tap can succeed.
            try? await Task.sleep(for: .seconds(8))
            if phase == .waking(consoleID) {
                phase = .ready
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Creates and retains a session before the player window opens. Playback
    /// starts only after the Flat display host has synchronously queued its
    /// layer attachment and its exact entitlement authorization resolves.
    @discardableResult
    func prepareConnection(consoleID: UUID) async -> Bool {
        guard phase.isBusy == false, activeSession == nil else { return false }
        guard let console = consoles.first(where: { $0.id == consoleID }) else {
            phase = .failed("The saved PlayStation console could not be found.")
            return false
        }

        do {
            let selectedQuality = streamQuality
            let provider = PlayStationRemotePlayProvider(
                repository: repository,
                nativeSessionFactory: nativeSessionFactory,
                qualityProfile: selectedQuality.profile
            )
            let genericSession = try await provider.makeSession(for: console.remotePlayExperience)
            guard let session = genericSession as? PlayStationRemotePlayStreamingSession else {
                throw VisionRemotePlayCoordinatorError.invalidSessionType
            }

            activeSession = session
            await session.setControllerFeedbackHandler { [controllerFeedbackSink] _, feedback in
                controllerFeedbackSink.apply(feedback)
            }
            session.videoSurface.setPacingEnabled(smoothMotionEnabled)
            session.videoSurface.setUpscaling(FarframeReleaseFeatures.advancedMedia ? videoEnhancement : .off)
            activeStreamQuality = selectedQuality
            session.audioControls.setVolume(audioVolume)
            session.audioControls.setMuted(audioIsMuted)
            activeConsoleID = consoleID
            videoSurface = session.videoSurface
            remoteDisplayIsBlocked = false
            preparedSessionHasStarted = false
            preparedSurfaceHasBeenQueued = false
            preparedSessionGenerationID = UUID()
            pendingPreparedSessionAuthorizationID = nil
            phase = .prepared(consoleID)
            return true
        } catch {
            clearSessionState()
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    func surfaceWasQueued(
        sessionID: UUID
    ) -> VisionPreparedSessionStartAuthorization? {
        guard activeSessionID == sessionID,
              let consoleID = activeConsoleID,
              phase == .prepared(consoleID),
              preparedSessionHasStarted == false else { return nil }

        preparedSurfaceHasBeenQueued = true
        return issuePreparedSessionStartAuthorization()
    }

    func resolvePreparedSessionStart(
        _ authorization: VisionPreparedSessionStartAuthorization,
        isAuthorized: Bool
    ) async -> VisionPreparedSessionStartResolution {
        guard authorization == currentPreparedSessionStartAuthorization(),
              let session = activeSession,
              let consoleID = activeConsoleID else { return .stale }
        pendingPreparedSessionAuthorizationID = nil

        if isAuthorized {
            guard playerSceneIsActive else { return .deferredUntilActive }
            guard startPreparedSessionIfPossible() else { return .stale }
            return .started
        }

        let operationID = claimLocalSessionOperation()
        cancelSessionTasks()
        phase = .disconnecting
        await session.stop()
        guard localSessionOperationIsCurrent(operationID, sessionID: session.id) else {
            return .stale
        }
        clearSessionState()
        phase = .ready
        return .denied(consoleID: consoleID)
    }

    @discardableResult
    private func startPreparedSessionIfPossible() -> Bool {
        guard playerSceneIsActive,
              preparedSurfaceHasBeenQueued,
              preparedSessionHasStarted == false,
              let session = activeSession,
              let consoleID = activeConsoleID,
              phase == .prepared(consoleID) else { return false }

        preparedSessionHasStarted = true
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
            #if DEBUG
            print("[FARFRAME Session] connect timed out after \(Self.connectionTimeoutSeconds)s; tearing down")
            #endif
            await cancelConnection()
            phase = .failed(VisionRemotePlayCoordinatorError.connectionTimedOut.localizedDescription)
        }
        connectionTask = Task { [weak self, session] in
            do {
                try await session.start()
                guard Task.isCancelled == false,
                      let self,
                      self.activeSessionID == session.id,
                      self.connectionOperationID == operationID,
                      self.phase == .connecting(consoleID) else { return }
                self.connectionTask = nil
                self.connectionOperationID = nil
                self.startControllerDelivery(session: session)
                self.startMonitoring(session: session, consoleID: consoleID)
            } catch {
                let wasCancelled = error is CancellationError || Task.isCancelled
                await session.stop()
                // A console that never answers can quit the native session
                // while connect is still awaiting its start, and then the throw
                // says only "ended while connecting". The reason is recorded on
                // the session and is cleared at the next connect, so it can only
                // describe this attempt.
                let quitReason = await session.snapshot().lastQuitReason
                guard wasCancelled == false,
                      Task.isCancelled == false,
                      let self,
                      self.activeSessionID == session.id,
                      self.connectionOperationID == operationID,
                      self.phase == .connecting(consoleID) else { return }
                self.connectionTask = nil
                self.connectionOperationID = nil
                self.clearSessionState()
                self.phase = .failed(
                    quitReason.map(\.explanation.message) ?? error.localizedDescription
                )
            }
        }
        return true
    }

    func cancelConnection() async {
        await disconnect()
    }

    func disconnect() async {
        if case .disconnecting = phase { return }
        cancelSessionTasks()

        guard let session = activeSession else {
            clearSessionState()
            phase = .ready
            return
        }

        let operationID = claimLocalSessionOperation()
        phase = .disconnecting
        await session.stop()
        guard localSessionOperationIsCurrent(operationID, sessionID: session.id) else {
            return
        }
        clearSessionState()
        phase = .ready
    }

    func playerWindowClosed() async {
        if restOnPlayerClose {
            await restAndDisconnect()
        } else {
            await disconnect()
        }
    }

    /// Records loss of the player scene without touching the live Remote Play
    /// session. Another app's immersive space can make this scene inactive while
    /// the transport, audio, and input paths remain valid.
    /// `.background`: the process may not submit GPU work, so renderer
    /// submission stops until the scene is active again.
    func playerSceneBecameNonActive() {
        playerSceneBecameInactive()
        videoSurface?.setPresentationSuspended(true)
        scheduleBackgroundDisconnect()
    }

    /// The session survives headset removal on purpose (put it back on and the
    /// game is still there). Left alone, it would also run forever, so after
    /// the configured idle time Farframe ends it the same way closing the
    /// player does (Rest or Disconnect per the Session setting).
    private func scheduleBackgroundDisconnect() {
        backgroundDisconnectTask?.cancel()
        backgroundDisconnectTask = nil
        guard activeSession != nil, backgroundDisconnectMinutes >= 0 else { return }
        let minutes = backgroundDisconnectMinutes
        backgroundDisconnectTask = Task { [weak self] in
            if minutes > 0 {
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
            guard let self, Task.isCancelled == false,
                  playerSceneIsActive == false, activeSession != nil else { return }
            backgroundDisconnectTask = nil
            await playerWindowClosed()
        }
    }

    /// `.inactive`: Control Center, Record My View, a system dialog, or the
    /// moment before backgrounding. Drawing is still allowed, so video keeps
    /// flowing; only session-start authorization pauses. Suspending here made
    /// the player go black for the whole length of a screen recording.
    func playerSceneBecameInactive() {
        playerSceneIsActive = false
        pendingPreparedSessionAuthorizationID = nil
        guard activeSession != nil, preparedSessionHasStarted else { return }
        playerSceneWasInterrupted = true
    }

    /// Reconciles the presentation surface exactly once when a previously
    /// interrupted player scene becomes active again. Disconnect/reconnect stays
    /// available as the explicit fallback if device proof finds a deeper decoder
    /// or transport interruption.
    @discardableResult
    func playerSceneBecameActive() async
        -> VisionPreparedSessionStartAuthorization? {
        playerSceneIsActive = true
        backgroundDisconnectTask?.cancel()
        backgroundDisconnectTask = nil
        videoSurface?.setPresentationSuspended(false)
        if playerSceneWasInterrupted {
            playerSceneWasInterrupted = false
            if let videoSurface {
                _ = await videoSurface.recoverAfterInterruption()
            }
        }
        return issuePreparedSessionStartAuthorization()
    }

    func claimPlayerWindow(_ instanceID: UUID) {
        playerWindowOwnerID = instanceID
    }

    func claimSetupWindow(_ instanceID: UUID) {
        visibleSetupWindowIDs.insert(instanceID)
    }

    func resignSetupWindow(_ instanceID: UUID) {
        visibleSetupWindowIDs.remove(instanceID)
    }

    func isPlayerControlPinned(_ id: VisionPlayerControlID) -> Bool {
        pinnedPlayerControlIDs.contains(id)
    }

    func setPlayerControl(_ id: VisionPlayerControlID, pinned: Bool) {
        if pinned {
            guard pinnedPlayerControlIDs.contains(id) == false else { return }
            pinnedPlayerControlIDs.append(id)
        } else {
            pinnedPlayerControlIDs.removeAll { $0 == id }
        }
    }

    func playerDiagnosticsSnapshot() -> VisionPlayerDiagnostics? {
        guard let session = activeSession else { return nil }
        let controllerConnection = controllerSource.connectionSnapshot()
        return VisionPlayerDiagnostics(
            quality: activeStreamQuality ?? streamQuality,
            video: session.videoSurface.snapshot(),
            decoder: session.videoDecoderDiagnostics.snapshot(),
            audio: session.audioControls.snapshot(),
            controllerIsConnected: controllerConnection.isConnected,
            controllerName: controllerConnection.name,
            controllerHasInput: controllerSource.snapshot().hasInput
        )
    }

    /// The full diagnosis as self-describing plain text, for pasting into a
    /// message or into an AI assistant. Carries no identifiers.
    ///
    /// This is the headset's only way out. There is no file to save and no
    /// share sheet here, and retyping what the HUD shows while wearing the
    /// device is not a real option, so the clipboard carries every finding
    /// rather than only the four the HUD has room for.
    func streamDiagnosticsPlainText(now: Date = Date()) -> String? {
        guard let diagnostics = playerDiagnosticsSnapshot() else { return nil }
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return StreamDiagnosticsAdvisor.plainTextReport(
            diagnostics.advice,
            input: diagnostics.advisorInput,
            generatedAt: now,
            appVersion: version.map { "\($0) (\(build ?? "Unknown"))" }
        )
    }

    @discardableResult
    func playerWindowDidDisappear(_ instanceID: UUID) -> Bool {
        guard playerWindowOwnerID == instanceID else { return false }
        playerWindowOwnerID = nil
        return true
    }

    func pulse(_ button: ControllerButton, holdMilliseconds: UInt64 = 120) {
        guard activeSession != nil else { return }
        if case .streaming = phase {
            // Ordinary controller actions require decoded playback.
        } else {
            // The native restriction signal can arrive before a decoded frame.
            guard remoteDisplayIsBlocked else { return }
        }
        controllerSource.setInjected(button, pressed: true)
        if let session = activeSession {
            Task { await session.send(controllerSource.snapshot()) }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(holdMilliseconds))
            guard let self else { return }
            self.controllerSource.setInjected(button, pressed: false)
            if let session = self.activeSession {
                await session.send(self.controllerSource.snapshot())
            }
        }
    }

    func goHome() {
        guard let session = activeSession else { return }
        if case .streaming = phase {
            // The ordinary player action is available after decoded playback.
        } else {
            // A protected screen can be reported before a decodable frame. In
            // that case PS5 Home is the recovery action the user needs.
            guard remoteDisplayIsBlocked else { return }
        }
        Task { [weak self, session] in
            do {
                try await session.goHome()
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Escapes the PS Plus cloud-streaming prompt using the sequence already
    /// proven on the physical PS5: PS, D-pad down, then Cross.
    func exitBlockedRemotePlayContent() {
        guard remoteDisplayIsBlocked, activeSession != nil else { return }
        blockedContentExitTask?.cancel()
        blockedContentExitTask = Task { [weak self] in
            guard let self else { return }
            self.pulse(.playStation, holdMilliseconds: 120)
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            self.pulse(.dpadDown, holdMilliseconds: 90)
            do {
                try await Task.sleep(for: .milliseconds(220))
            } catch {
                return
            }
            self.pulse(.cross, holdMilliseconds: 90)
            self.blockedContentExitTask = nil
        }
    }

    func restAndDisconnect() async {
        if case .disconnecting = phase { return }
        cancelSessionTasks()

        guard let session = activeSession else {
            clearSessionState()
            phase = .ready
            return
        }
        let operationID = claimLocalSessionOperation()
        phase = .disconnecting
        do {
            try await session.restAndDisconnect()
            guard localSessionOperationIsCurrent(
                operationID,
                sessionID: session.id
            ) else { return }
            clearSessionState()
            phase = .ready
        } catch {
            guard localSessionOperationIsCurrent(
                operationID,
                sessionID: session.id
            ) else { return }
            // Rest is best effort, but a failed Rest command must never leave
            // the native session retained after its player window disappears.
            await session.stop()
            guard localSessionOperationIsCurrent(
                operationID,
                sessionID: session.id
            ) else { return }
            clearSessionState()
            phase = .failed(
                "Rest Mode could not be confirmed. Remote Play disconnected. \(error.localizedDescription)"
            )
        }
    }

    func pairConsole(
        existingConsoleID: UUID? = nil,
        hostAddress: String,
        fallbackDisplayName: String,
        accountID: String,
        linkDevicePIN: String
    ) async throws -> SavedPlayStationConsole {
        try await pairConsole(
            existingConsoleID: existingConsoleID,
            hostAddress: hostAddress,
            fallbackDisplayName: fallbackDisplayName,
            accountID: PlayStationAccountID(manualValue: accountID),
            linkDevicePIN: linkDevicePIN
        )
    }

    func pairConsole(
        existingConsoleID: UUID? = nil,
        hostAddress: String,
        fallbackDisplayName: String,
        accountID: PlayStationAccountID,
        linkDevicePIN: String
    ) async throws -> SavedPlayStationConsole {
        guard activeSession == nil else {
            throw VisionRemotePlayCoordinatorError.sessionActive
        }
        let request = try PlayStationPairingRequest(
            existingConsoleID: existingConsoleID,
            hostAddress: hostAddress,
            fallbackDisplayName: fallbackDisplayName,
            accountID: accountID,
            pin: PlayStationLinkDevicePIN(linkDevicePIN)
        )
        let console = try await pairingService.pair(request)
        try await reloadConsoles()
        phase = .ready
        return console
    }

    /// Presents the shared PlayStation sign-in and returns a transient identity.
    func acquirePairingAccountIdentity() async throws -> PlayStationRemotePlayAccountIdentity {
        guard activeSession == nil else {
            throw VisionRemotePlayCoordinatorError.sessionActive
        }
        return try await webSignInAcquirer.acquireAccountIdentity()
    }

    /// Saves Home/Away addresses and the active route without re-pairing.
    func updateConnectionAddresses(
        consoleID: UUID,
        hostAddress: String,
        awayHostAddress: String?,
        connectionRoute: PlayStationConnectionRoute
    ) async throws {
        guard phase.isBusy == false else {
            throw VisionRemotePlayCoordinatorError.operationInProgress
        }
        guard activeSession == nil else {
            throw VisionRemotePlayCoordinatorError.sessionActive
        }
        _ = try await repository.updateConnectionAddresses(
            consoleID: consoleID,
            hostAddress: hostAddress,
            awayHostAddress: awayHostAddress,
            connectionRoute: connectionRoute
        )
        try await reloadConsoles()
    }

    func retryPendingPairingSave() async throws -> SavedPlayStationConsole {
        let console = try await pairingService.retryPendingSecureSave()
        try await reloadConsoles()
        phase = .ready
        return console
    }

    func removeConsole(_ consoleID: UUID) async throws {
        guard phase.isBusy == false else {
            throw VisionRemotePlayCoordinatorError.operationInProgress
        }
        guard activeSession == nil else {
            throw VisionRemotePlayCoordinatorError.sessionActive
        }
        phase = .removing(consoleID)
        do {
            try await repository.remove(consoleID)
            try await reloadConsoles()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    func retryAfterError() async {
        if case .recoveryFailed = phase {
            await performPreparation()
            return
        }
        clearError()
        do {
            try await reloadConsoles()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func clearError() {
        if case .failed = phase {
            phase = .ready
        }
    }

    func reportError(_ error: any Error) {
        phase = .failed(error.localizedDescription)
    }

    private func startMonitoring(
        session: PlayStationRemotePlayStreamingSession,
        consoleID: UUID
    ) {
        sessionMonitorTask?.cancel()
        sessionMonitorTask = Task { [weak self, session] in
            while Task.isCancelled == false {
                let snapshot = await session.snapshot()
                guard let self,
                      Task.isCancelled == false,
                      self.activeSessionID == session.id,
                      self.localSessionOperationID == nil else { return }
                self.remoteDisplayIsBlocked = snapshot.displayIsBlocked
                switch snapshot.state {
                case .streaming:
                    self.phase = .streaming(consoleID)
                    self.connectionTimeoutTask?.cancel()
                    self.connectionTimeoutTask = nil
                case .preparing, .connecting:
                    self.phase = .connecting(consoleID)
                case .failed:
                    // A bare code told the owner nothing: round 9's connect
                    // failure reached the headset as "ended unexpectedly" while
                    // the native reason named the exact handshake stage.
                    self.phase = .failed(
                        snapshot.lastQuitReason.map(\.explanation.message)
                            ?? "The Remote Play session ended unexpectedly."
                    )
                    self.clearSessionState()
                    return
                case .disconnected:
                    self.clearSessionState()
                    self.phase = .ready
                    return
                case .idle, .disconnecting:
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func startControllerDelivery(session: PlayStationRemotePlayStreamingSession) {
        controllerDeliveryTask?.cancel()
        let source = controllerSource
        controllerDeliveryTask = Task.detached(priority: .userInitiated) {
            while Task.isCancelled == false {
                await session.send(source.snapshot())
                try? await Task.sleep(nanoseconds: 8_333_333)
            }
        }
    }

    private func clearSessionState() {
        // A rumble held when the stream ends would otherwise run forever.
        controllerFeedbackSink.stopAll()
        cancelSessionTasks()
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        backgroundDisconnectTask?.cancel()
        backgroundDisconnectTask = nil
        blockedContentExitTask?.cancel()
        blockedContentExitTask = nil
        localSessionOperationID = nil
        activeSession = nil
        activeConsoleID = nil
        activeStreamQuality = nil
        videoSurface = nil
        remoteDisplayIsBlocked = false
        preparedSessionHasStarted = false
        preparedSurfaceHasBeenQueued = false
        preparedSessionGenerationID = nil
        pendingPreparedSessionAuthorizationID = nil
        playerSceneWasInterrupted = false
    }

    private func cancelSessionTasks() {
        connectionTask?.cancel()
        connectionTask = nil
        connectionOperationID = nil
        sessionMonitorTask?.cancel()
        sessionMonitorTask = nil
        controllerDeliveryTask?.cancel()
        controllerDeliveryTask = nil
    }

    private func claimLocalSessionOperation() -> UUID {
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

    private func currentPreparedSessionStartAuthorization()
        -> VisionPreparedSessionStartAuthorization? {
        guard preparedSurfaceHasBeenQueued,
              preparedSessionHasStarted == false,
              let sessionID = activeSessionID,
              let consoleID = activeConsoleID,
              let generationID = preparedSessionGenerationID,
              let requestID = pendingPreparedSessionAuthorizationID,
              phase == .prepared(consoleID) else { return nil }
        return VisionPreparedSessionStartAuthorization(
            sessionID: sessionID,
            generationID: generationID,
            requestID: requestID
        )
    }

    private func issuePreparedSessionStartAuthorization()
        -> VisionPreparedSessionStartAuthorization? {
        guard preparedSurfaceHasBeenQueued,
              preparedSessionHasStarted == false,
              let sessionID = activeSessionID,
              let consoleID = activeConsoleID,
              let generationID = preparedSessionGenerationID,
              phase == .prepared(consoleID) else { return nil }
        let requestID = UUID()
        pendingPreparedSessionAuthorizationID = requestID
        return VisionPreparedSessionStartAuthorization(
            sessionID: sessionID,
            generationID: generationID,
            requestID: requestID
        )
    }
}

private enum VisionRemotePlayCoordinatorError: Error, LocalizedError {
    case invalidSessionType
    case operationInProgress
    case sessionActive
    case connectionTimedOut

    var errorDescription: String? {
        switch self {
        case .connectionTimedOut:
            "The PS5 did not answer within 45 seconds. If it was just woken, give it a few more seconds and connect again. If it is already on, check that both devices are on the same network."

        case .invalidSessionType:
            "The PlayStation provider returned an unsupported session."
        case .operationInProgress:
            "Wait for the current Remote Play action to finish, then try again."
        case .sessionActive:
            "Disconnect the current Remote Play session before changing saved PS5 registrations."
        }
    }
}
