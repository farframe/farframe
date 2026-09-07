import AppleMediaCore
import ExperienceDomain
import Foundation
import InputCore
import StreamingCore

/// The codec values the native PlayStation adapter must resolve at connect time.
public enum PlayStationVideoCodec: String, Equatable, Sendable {
    case hevc
    case hevcHDR
}

/// Provider-specific values resolved from a shared `QualityProfile` before the
/// native session is created. No UI or preset lookup remains after this point.
public struct PlayStationResolvedVideoProfile: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let maximumFramesPerSecond: UInt32
    public let bitrateKbps: UInt32
    public let codec: PlayStationVideoCodec
    public let automaticDowngrade: Bool

    public init(qualityProfile: QualityProfile) throws {
        guard let width = UInt32(exactly: qualityProfile.width),
              let height = UInt32(exactly: qualityProfile.height),
              let maximumFramesPerSecond = UInt32(exactly: qualityProfile.framesPerSecond),
              let bitrateKbps = UInt32(exactly: qualityProfile.targetBitrateKbps),
              width > 0,
              height > 0,
              maximumFramesPerSecond > 0,
              bitrateKbps > 0 else {
            throw PlayStationSessionCoordinatorError.invalidQualityProfile
        }

        self.width = width
        self.height = height
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.bitrateKbps = bitrateKbps
        self.codec = qualityProfile.dynamicRange == .hdr ? .hevcHDR : .hevc
        self.automaticDowngrade = true
    }
}

/// Complete native connect input. The two secret values deliberately remain
/// opaque `Data` and are never included in coordinator errors or descriptions.
public struct PlayStationConnectConfiguration: Equatable, Sendable {
    public let consoleID: UUID
    public let host: String
    public let registrationKey: Data
    public let remotePlayKey: Data
    public let videoProfile: PlayStationResolvedVideoProfile

    public init(
        consoleID: UUID,
        host: String,
        registrationKey: Data,
        remotePlayKey: Data,
        videoProfile: PlayStationResolvedVideoProfile
    ) {
        self.consoleID = consoleID
        self.host = host
        self.registrationKey = registrationKey
        self.remotePlayKey = remotePlayKey
        self.videoProfile = videoProfile
    }
}

extension PlayStationConnectConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        redactedDescription
    }

    public var debugDescription: String {
        redactedDescription
    }

    private var redactedDescription: String {
        "PlayStationConnectConfiguration(" +
            "consoleID: \(consoleID), " +
            "host: \(host), " +
            "registrationKey: <redacted \(registrationKey.count) bytes>, " +
            "remotePlayKey: <redacted \(remotePlayKey.count) bytes>, " +
            "videoProfile: \(videoProfile))"
    }
}

public enum PlayStationNativeQuitReason: Equatable, Sendable {
    case normal
    case remoteDisconnected
    case nativeFailure(code: Int32)
}

public enum PlayStationNativeSessionEvent: Equatable, Sendable {
    /// Chiaki's transport is established, but decoded media has not yet proven playback.
    case transportReady
    case quit(PlayStationNativeQuitReason)
    /// Console-driven controller output. Purely additive: a consumer that
    /// ignores it loses nothing else, and it never gates media.
    case controllerFeedback(ControllerFeedbackEvent)
}

public enum PlayStationNativeMediaEvent: Equatable, Sendable {
    case encodedVideo(EncodedVideoSample)
    case audioFormat(StreamingAudioFormat)
    case decodedAudio(InterleavedS16PCMBlock)
    case displayBlocked(Bool)
}

public typealias PlayStationNativeSessionEventHandler = @Sendable (
    PlayStationNativeSessionEvent
) -> Void

public typealias PlayStationNativeMediaEventHandler = @Sendable (
    PlayStationNativeMediaEvent
) -> Bool

/// Session media is tagged with its coordinator generation so a downstream
/// decoder can reject a late callback from a replaced native session.
public typealias PlayStationSessionMediaEventHandler = @Sendable (
    UInt64,
    PlayStationNativeMediaEvent
) -> Void

/// Controller feedback is tagged with its generation for the same reason, and
/// is delivered without entering the coordinator actor so a high-rate rumble
/// stream never queues behind session state work.
public typealias PlayStationSessionControllerFeedbackHandler = @Sendable (
    UInt64,
    ControllerFeedbackEvent
) -> Void

/// Swift seam for the opaque C session bridge.
public protocol PlayStationNativeSession: Sendable {
    func start(
        configuration: PlayStationConnectConfiguration,
        eventHandler: @escaping PlayStationNativeSessionEventHandler,
        mediaHandler: @escaping PlayStationNativeMediaEventHandler
    ) async throws

    func stop() async throws
    func join() async throws
    func sendControllerSnapshot(_ snapshot: ControllerSnapshot) async throws
    func goHome() async throws
    func goToBed() async throws
}

public extension PlayStationNativeSession {
    /// Test doubles and transport-only adapters remain source compatible while
    /// production capability claims stay gated by the concrete provider.
    func sendControllerSnapshot(_ snapshot: ControllerSnapshot) async throws {
        _ = snapshot
    }

    func goHome() async throws {
        throw PlayStationSessionCoordinatorError.nativeCommandUnavailable
    }

    func goToBed() async throws {
        throw PlayStationSessionCoordinatorError.nativeCommandUnavailable
    }
}

public protocol PlayStationNativeSessionFactory: Sendable {
    func makeSession() async throws -> any PlayStationNativeSession
}

public enum PlayStationSessionCoordinatorError: Error, Equatable, Sendable, LocalizedError {
    case consoleNotFound(UUID)
    case registrationMissing(UUID)
    case savedConsoleUnavailable(UUID)
    case invalidHost(UUID)
    case invalidQualityProfile
    case connectionAlreadyActive
    case nativeSessionCreationFailed
    case videoPresentationPreparationFailed
    case nativeConnectFailed
    case sessionEndedDuringConnect
    case unsupportedVideoDynamicRange
    case nativeCommandUnavailable
    case nativeCommandFailed

    public var errorDescription: String? {
        switch self {
        case .consoleNotFound:
            "The saved PlayStation console could not be found."
        case .registrationMissing:
            "Register this PlayStation console before connecting."
        case .savedConsoleUnavailable:
            "The saved PlayStation console could not be loaded."
        case .invalidHost:
            "The saved PlayStation address is invalid."
        case .invalidQualityProfile:
            "The selected stream quality is invalid."
        case .connectionAlreadyActive:
            "A PlayStation connection is already active."
        case .nativeSessionCreationFailed:
            "The PlayStation session could not be created."
        case .videoPresentationPreparationFailed:
            "The video presentation path could not be prepared."
        case .nativeConnectFailed:
            "The PlayStation connection could not be started."
        case .sessionEndedDuringConnect:
            "The PlayStation session ended while connecting."
        case .unsupportedVideoDynamicRange:
            "HDR playback is not available in this build. Select an SDR quality profile."
        case .nativeCommandUnavailable:
            "That PlayStation command is not available in this build."
        case .nativeCommandFailed:
            "The PlayStation command could not be sent."
        }
    }
}

public struct PlayStationSessionSnapshot: Equatable, Sendable {
    public let state: StreamingConnectionState
    public let generation: UInt64?
    public let transportIsReady: Bool
    public let firstDecodedFrameSeen: Bool
    public let displayIsBlocked: Bool
    public let lastQuitReason: PlayStationNativeQuitReason?
    /// True when this session started without sound because the system refused
    /// the audio output. The stream is deliberately allowed to run silent
    /// instead of being refused; see `UP-026`.
    public let audioIsUnavailable: Bool

    public init(
        state: StreamingConnectionState,
        generation: UInt64?,
        transportIsReady: Bool,
        firstDecodedFrameSeen: Bool = false,
        displayIsBlocked: Bool = false,
        lastQuitReason: PlayStationNativeQuitReason? = nil,
        audioIsUnavailable: Bool = false
    ) {
        self.state = state
        self.generation = generation
        self.transportIsReady = transportIsReady
        self.firstDecodedFrameSeen = firstDecodedFrameSeen
        self.displayIsBlocked = displayIsBlocked
        self.lastQuitReason = lastQuitReason
        self.audioIsUnavailable = audioIsUnavailable
    }
}

private final class PlayStationMediaAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isAccepting = true

    func acceptsMedia() -> Bool {
        lock.withLock { isAccepting }
    }

    func close() {
        lock.withLock { isAccepting = false }
    }
}

/// One synchronous display-restriction value belongs to exactly one admitted
/// native session generation. The native callback cannot await actor state, so
/// this tiny lock keeps ordered true/false delivery without unstructured tasks.
private final class PlayStationDisplayRestrictionState: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = true
    private var isBlocked = false

    func record(_ isBlocked: Bool) {
        lock.withLock {
            guard isOpen else { return }
            self.isBlocked = isBlocked
        }
    }

    func snapshot() -> Bool {
        lock.withLock { isOpen && isBlocked }
    }

    func close() {
        lock.withLock {
            isOpen = false
            isBlocked = false
        }
    }
}

/// Serializes one PlayStation transport and decoder lifecycle. Transport readiness
/// alone remains `.connecting`; only a current-generation decoded frame can unlock
/// `.streaming`, and teardown closes admission before any suspension point.
public actor PlayStationSessionCoordinator {
    private enum TeardownResult: Sendable {
        case succeeded
        case failed
    }

    private struct ActiveSession {
        let generation: UInt64
        let session: any PlayStationNativeSession
        let videoDecoder: any HEVCVideoDecoding
        let audioPlayer: BoundedPCMAudioPlayer
        let mediaAdmissionGate: PlayStationMediaAdmissionGate
        let displayRestrictionState: PlayStationDisplayRestrictionState
        var transportIsReady: Bool
        var firstDecodedFrameSeen: Bool
        var teardownTask: Task<TeardownResult, Never>?
        /// Set when an ordered stop -> join could not finish. The session stays
        /// retained so nothing is freed under a live native thread, and the next
        /// Connect retries the teardown rather than refusing forever.
        var teardownDidFail = false
    }

    private let repository: PlayStationConsoleRepository
    private let sessionFactory: any PlayStationNativeSessionFactory
    private let videoDecoderFactory: any HEVCVideoDecoderBuilding
    private let videoPresenter: BoundedSampleBufferVideoPresenter
    private let audioPlayer: BoundedPCMAudioPlayer
    /// Shell-readable decoder counters for the active session.
    public nonisolated let videoDecoderDiagnostics = VideoDecoderDiagnosticsProvider()
    /// Distinguishes two coordinators in a debug log. Every Connect builds a new
    /// coordinator, so the session generation is always 1 in a shipping build.
    private nonisolated var instanceTag: String {
        String(UInt(bitPattern: ObjectIdentifier(self)) & 0xffff, radix: 16)
    }

    private var state: StreamingConnectionState = .idle
    private var activeSession: ActiveSession?
    private var generationCounter: UInt64 = 0
    private var lastQuitReason: PlayStationNativeQuitReason?
    private var audioIsUnavailable = false
    /// One extra activation attempt absorbs the transient `Session lookup
    /// failed` (OSStatus -50) seen right after a previous session released the
    /// process audio route.
    private static let audioActivationRetryDelay = Duration.milliseconds(150)

    /// Actors are reentrant at suspension points. This gate makes overlapping
    /// public Connect/Disconnect requests execute as complete ordered operations.
    private var operationIsActive = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        repository: PlayStationConsoleRepository,
        sessionFactory: any PlayStationNativeSessionFactory,
        videoDecoderFactory: any HEVCVideoDecoderBuilding = VideoToolboxHEVCDecoderFactory()
    ) {
        self.repository = repository
        self.sessionFactory = sessionFactory
        self.videoDecoderFactory = videoDecoderFactory
        self.videoPresenter = BoundedSampleBufferVideoPresenter()
        self.audioPlayer = BoundedPCMAudioPlayer()
    }

    init(
        repository: PlayStationConsoleRepository,
        sessionFactory: any PlayStationNativeSessionFactory,
        videoDecoderFactory: any HEVCVideoDecoderBuilding = VideoToolboxHEVCDecoderFactory(),
        videoPresenter: BoundedSampleBufferVideoPresenter,
        audioPlayer: BoundedPCMAudioPlayer = BoundedPCMAudioPlayer()
    ) {
        self.repository = repository
        self.sessionFactory = sessionFactory
        self.videoDecoderFactory = videoDecoderFactory
        self.videoPresenter = videoPresenter
        self.audioPlayer = audioPlayer
    }

    public func snapshot() -> PlayStationSessionSnapshot {
        PlayStationSessionSnapshot(
            state: state,
            generation: activeSession?.generation,
            transportIsReady: activeSession?.transportIsReady ?? false,
            firstDecodedFrameSeen: activeSession?.firstDecodedFrameSeen ?? false,
            displayIsBlocked: activeSession?.displayRestrictionState.snapshot() ?? false,
            lastQuitReason: lastQuitReason,
            audioIsUnavailable: audioIsUnavailable
        )
    }

    /// Starts one native transport/decoder attempt and returns its generation.
    /// Successful native startup remains `.connecting` until transport and one
    /// current-generation decoded frame are both present.
    @discardableResult
    public func connect(
        consoleID: UUID,
        qualityProfile: QualityProfile,
        mediaHandler: @escaping PlayStationSessionMediaEventHandler = { _, _ in },
        decodedFrameHandler: @escaping HEVCDecodedFrameHandler = { _ in },
        controllerFeedbackHandler: @escaping PlayStationSessionControllerFeedbackHandler
            = { _, _ in }
    ) async throws -> UInt64 {
        await acquireOperationAccess()
        defer { releaseOperationAccess() }

        // A teardown that is still running is awaited, and one that already
        // failed is retried. Without the retry a stranded native session made
        // every later Connect throw `connectionAlreadyActive`, which is why a
        // process relaunch was the owner's only recovery on 2026-09-06.
        if let activeSession,
           activeSession.teardownTask != nil || activeSession.teardownDidFail {
            await teardown(generation: activeSession.generation)
        }
        guard activeSession == nil else {
            throw PlayStationSessionCoordinatorError.connectionAlreadyActive
        }

        lastQuitReason = nil
        audioIsUnavailable = false
        state = .preparing

        let console: SavedPlayStationConsole
        do {
            guard let savedConsole = try await repository.consoles().first(where: {
                $0.id == consoleID
            }) else {
                state = .failed
                throw PlayStationSessionCoordinatorError.consoleNotFound(consoleID)
            }
            console = savedConsole
        } catch let error as PlayStationSessionCoordinatorError {
            throw error
        } catch {
            state = .failed
            throw PlayStationSessionCoordinatorError.savedConsoleUnavailable(consoleID)
        }

        let registration: PlayStationConsoleRegistration
        do {
            guard let savedRegistration = try await repository.registration(for: consoleID) else {
                state = .failed
                throw PlayStationSessionCoordinatorError.registrationMissing(consoleID)
            }
            registration = savedRegistration
        } catch let error as PlayStationSessionCoordinatorError {
            throw error
        } catch {
            state = .failed
            throw PlayStationSessionCoordinatorError.savedConsoleUnavailable(consoleID)
        }

        // The saved route selects Home or Away; transport stays a direct connection.
        let hostAddress = console.activeHostAddress
        guard hostAddress.isEmpty == false,
              hostAddress.utf8.contains(0) == false else {
            state = .failed
            throw PlayStationSessionCoordinatorError.invalidHost(consoleID)
        }

        let videoProfile: PlayStationResolvedVideoProfile
        do {
            videoProfile = try PlayStationResolvedVideoProfile(qualityProfile: qualityProfile)
        } catch {
            state = .failed
            throw PlayStationSessionCoordinatorError.invalidQualityProfile
        }
        guard qualityProfile.dynamicRange == .sdr else {
            state = .failed
            throw PlayStationSessionCoordinatorError.unsupportedVideoDynamicRange
        }

        let session: any PlayStationNativeSession
        do {
            session = try await sessionFactory.makeSession()
        } catch {
            state = .failed
            throw PlayStationSessionCoordinatorError.nativeSessionCreationFailed
        }

        generationCounter &+= 1
        if generationCounter == 0 {
            generationCounter = 1
        }
        let generation = generationCounter

        let decoderConfiguration: HEVCDecodeConfiguration
        do {
            guard let framesPerSecond = Int32(exactly: videoProfile.maximumFramesPerSecond) else {
                throw HEVCDecoderConfigurationError.invalidFrameRate
            }
            decoderConfiguration = try HEVCDecodeConfiguration(
                generation: generation,
                framesPerSecond: framesPerSecond,
                dynamicRange: qualityProfile.dynamicRange
            )
        } catch {
            state = .failed
            throw PlayStationSessionCoordinatorError.invalidQualityProfile
        }
        let videoDecoder = videoDecoderFactory.makeDecoder(
            configuration: decoderConfiguration,
            frameHandler: { [weak self] frame in
                guard let self else { return }
                Task {
                    await self.receiveDecodedFrame(
                        frame,
                        decodedFrameHandler: decodedFrameHandler
                    )
                }
            },
            failureHandler: { _, _ in }
        )
        videoDecoderDiagnostics.attach(videoDecoder)
        let mediaAdmissionGate = PlayStationMediaAdmissionGate()
        let displayRestrictionState = PlayStationDisplayRestrictionState()

        // `UP-026`: audio activation is prepared before the native session so the
        // one-shot audio header is never missed, but it no longer gates the
        // connect. The device log of 2026-09-06 shows the system refusing the
        // audio route with OSStatus -50 on the attempts that followed a
        // disconnect; refusing the whole session there turned a transient audio
        // hiccup into "Farframe will not reconnect". A silent stream is a far
        // better outcome than no stream, and `audioIsUnavailable` plus the
        // player's own activation-failure counter make it visible.
        audioIsUnavailable = await activateAudio(generation: generation)

        do {
            try await videoPresenter.activate(generation: generation)
        } catch {
            mediaAdmissionGate.close()
            await audioPlayer.deactivate(generation: generation)
            await videoDecoder.stop()
            state = .failed
            throw PlayStationSessionCoordinatorError.videoPresentationPreparationFailed
        }

        activeSession = ActiveSession(
            generation: generation,
            session: session,
            videoDecoder: videoDecoder,
            audioPlayer: audioPlayer,
            mediaAdmissionGate: mediaAdmissionGate,
            displayRestrictionState: displayRestrictionState,
            transportIsReady: false,
            firstDecodedFrameSeen: false,
            teardownTask: nil
        )
        state = .connecting

        let configuration = PlayStationConnectConfiguration(
            consoleID: console.id,
            host: hostAddress,
            registrationKey: registration.registrationKey,
            remotePlayKey: registration.remotePlayKey,
            videoProfile: videoProfile
        )
        let audioPlayer = self.audioPlayer

        do {
            try await session.start(
                configuration: configuration,
                eventHandler: { [weak self] event in
                    // Feedback bypasses the coordinator actor: it carries no
                    // session state, and a rumble stream must not wait behind
                    // connect/teardown work on the actor's queue.
                    if case let .controllerFeedback(feedback) = event {
                        controllerFeedbackHandler(generation, feedback)
                        return
                    }
                    guard let self else { return }
                    Task {
                        await self.receive(event, generation: generation)
                    }
                },
                mediaHandler: { event in
                    guard mediaAdmissionGate.acceptsMedia() else { return false }
                    switch event {
                    case let .encodedVideo(sample):
                        // Returning false makes Chiaki report a corrupt frame,
                        // which is how the console is asked for a fresh IDR.
                        let admission = videoDecoder.admit(sample, generation: generation)
                        return admission == .accepted || admission == .awaitingKeyframe
                    case let .audioFormat(format):
                        let admission = audioPlayer.configure(format, generation: generation)
                        mediaHandler(generation, event)
                        return admission == .accepted
                    case let .decodedAudio(block):
                        let admission = audioPlayer.admit(block, generation: generation)
                        mediaHandler(generation, event)
                        return admission == .accepted
                    case let .displayBlocked(isBlocked):
                        displayRestrictionState.record(isBlocked)
                        mediaHandler(generation, event)
                        return true
                    }
                }
            )
        } catch {
            _ = await teardown(generation: generation)
            state = .failed
            throw PlayStationSessionCoordinatorError.nativeConnectFailed
        }

        guard let activeSession,
              activeSession.generation == generation,
              activeSession.teardownTask == nil,
              activeSession.mediaAdmissionGate.acceptsMedia() else {
            throw PlayStationSessionCoordinatorError.sessionEndedDuringConnect
        }

        updateStreamingState(generation: generation)
        return generation
    }

    public func disconnect() async {
        await acquireOperationAccess()
        defer { releaseOperationAccess() }

        guard let activeSession else {
            state = .disconnected
            return
        }
        await teardownWithRetry(generation: activeSession.generation)
    }

    public func sendControllerSnapshot(_ snapshot: ControllerSnapshot) async {
        guard let activeSession,
              activeSession.teardownTask == nil,
              activeSession.mediaAdmissionGate.acceptsMedia() else { return }
        try? await activeSession.session.sendControllerSnapshot(snapshot)
    }

    public func goHome() async throws {
        guard let activeSession,
              activeSession.teardownTask == nil,
              activeSession.mediaAdmissionGate.acceptsMedia() else {
            throw PlayStationSessionCoordinatorError.nativeCommandUnavailable
        }
        do {
            try await activeSession.session.goHome()
        } catch {
            throw PlayStationSessionCoordinatorError.nativeCommandFailed
        }
    }

    public func restAndDisconnect() async throws {
        await acquireOperationAccess()
        defer { releaseOperationAccess() }

        guard let activeSession else {
            state = .disconnected
            return
        }
        do {
            // Go To Bed must precede Stop/Join; reversing this order silently
            // disconnects while leaving the PS5 awake.
            try await activeSession.session.goToBed()
        } catch {
            throw PlayStationSessionCoordinatorError.nativeCommandFailed
        }
        await teardownWithRetry(generation: activeSession.generation)
    }

    public func audioSnapshot() -> PCMAudioPlaybackSnapshot {
        audioPlayer.snapshot()
    }

    /// One user-visible Disconnect must really disconnect. A failed stop -> join
    /// used to be recoverable only by "a later Disconnect", and no shell issues
    /// one: Vision, Mobile, and Mac all drop their session reference after a
    /// single Stop, which left a running native session and an undestroyable
    /// handle for the life of the process. If the retry also fails the session
    /// stays retained, and the next Connect tries the same ordered path again.
    private func teardownWithRetry(generation: UInt64) async {
        guard await teardown(generation: generation) == false else { return }
        _ = await teardown(generation: generation)
    }

    /// Returns true when the session must run without sound. The single retry
    /// exists because the first refusal after a previous session is usually the
    /// process audio route still being released, and it clears on its own.
    private func activateAudio(generation: UInt64) async -> Bool {
        do {
            try await audioPlayer.activate(generation: generation)
            return false
        } catch {
            try? await Task.sleep(for: Self.audioActivationRetryDelay)
        }
        do {
            try await audioPlayer.activate(generation: generation)
            return false
        } catch {
            return true
        }
    }

    private func receive(
        _ event: PlayStationNativeSessionEvent,
        generation: UInt64
    ) async {
        guard var activeSession, activeSession.generation == generation else {
            return
        }

        switch event {
        case .transportReady:
            #if DEBUG
            print(
                "[FARFRAME Session] transport ready "
                    + "(generation \(generation), session \(instanceTag))"
            )
            #endif
            guard activeSession.teardownTask == nil,
                  activeSession.mediaAdmissionGate.acceptsMedia() else { return }
            activeSession.transportIsReady = true
            self.activeSession = activeSession
            updateStreamingState(generation: generation)

        case let .quit(reason):
            #if DEBUG
            // Every connect builds a fresh coordinator, so the generation is
            // always 1 in a shipping build and cannot tell two attempts apart.
            // The instance tag can.
            print(
                "[FARFRAME Session] native quit \(reason) "
                    + "[\(reason.explanation.identifier)] "
                    + "(generation \(generation), session \(instanceTag))"
            )
            #endif
            // Recorded before the teardown gate: a teardown that fails used to
            // swallow the reason, and the shells then said "ended unexpectedly"
            // on exactly the failures that most needed naming.
            if generationCounter == generation {
                lastQuitReason = reason
            }
            guard await teardown(generation: generation) else {
                return
            }
            guard generationCounter == generation, self.activeSession == nil else {
                return
            }
            lastQuitReason = reason
            switch reason {
            case .normal, .remoteDisconnected:
                state = .disconnected
            case .nativeFailure:
                state = .failed
            }

        case .controllerFeedback:
            // Delivered straight to the feedback handler at the callback seam;
            // it carries no session state and never reaches this actor.
            break
        }
    }

    private func receiveDecodedFrame(
        _ frame: DecodedVideoFrame,
        decodedFrameHandler: HEVCDecodedFrameHandler
    ) {
        guard var activeSession,
              activeSession.generation == frame.generation,
              activeSession.teardownTask == nil,
              activeSession.mediaAdmissionGate.acceptsMedia() else {
            return
        }
        activeSession.firstDecodedFrameSeen = true
        self.activeSession = activeSession
        updateStreamingState(generation: frame.generation)
        _ = videoPresenter.submit(frame)
        decodedFrameHandler(frame)
    }

    private func updateStreamingState(generation: UInt64) {
        guard let activeSession,
              activeSession.generation == generation,
              activeSession.teardownTask == nil,
              activeSession.mediaAdmissionGate.acceptsMedia() else {
            return
        }
        state = activeSession.transportIsReady && activeSession.firstDecodedFrameSeen
            ? .streaming
            : .connecting
    }

    /// Every terminal path funnels through the same retained task, guaranteeing
    /// exactly one ordered stop -> join sequence for a generation.
    @discardableResult
    private func teardown(generation: UInt64) async -> Bool {
        guard var activeSession, activeSession.generation == generation else {
            return true
        }

        if let teardownTask = activeSession.teardownTask {
            return finishTeardown(
                await teardownTask.value,
                generation: generation
            )
        }

        activeSession.mediaAdmissionGate.close()
        activeSession.displayRestrictionState.close()
        activeSession.teardownDidFail = false
        state = .disconnecting
        let session = activeSession.session
        let videoDecoder = activeSession.videoDecoder
        let videoPresenter = self.videoPresenter
        let audioPlayer = activeSession.audioPlayer
        let teardownTask = Task {
            await audioPlayer.deactivate(generation: generation)
            let result: TeardownResult
            do {
                try await session.stop()
                try await session.join()
                await videoDecoder.stop()
                result = .succeeded
            } catch {
                result = .failed
            }
            await videoPresenter.deactivate(
                generation: generation,
                removingDisplayedImage: true
            )
            return result
        }
        activeSession.teardownTask = teardownTask
        self.activeSession = activeSession

        return finishTeardown(
            await teardownTask.value,
            generation: generation
        )
    }

    private func finishTeardown(
        _ result: TeardownResult,
        generation: UInt64
    ) -> Bool {
        guard var activeSession = self.activeSession,
              activeSession.generation == generation else {
            return true
        }

        switch result {
        case .succeeded:
            videoDecoderDiagnostics.detach()
            self.activeSession = nil
            state = .disconnected
            return true
        case .failed:
            // Keep strong ownership of the native session and clear only the
            // attempt task. Disconnect retries once immediately, and the next
            // Connect retries again, so the same safe stop -> join is the only
            // way this session is ever released.
            activeSession.teardownTask = nil
            activeSession.teardownDidFail = true
            self.activeSession = activeSession
            state = .failed
            return false
        }
    }

    private func acquireOperationAccess() async {
        guard operationIsActive else {
            operationIsActive = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperationAccess() {
        guard operationWaiters.isEmpty else {
            operationWaiters.removeFirst().resume()
            return
        }
        operationIsActive = false
    }
}
