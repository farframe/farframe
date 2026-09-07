import AppleMediaCore
import ExperienceDomain
import Foundation
import InputCore
import StreamingCore

/// Provider facade for the bounded PSR-130 transport/decode path. Its snapshot
/// reaches `.streaming` only after transport readiness and a current-generation
/// decoded frame. Decoded frames now feed the session-owned presenter, while a
/// platform display surface, audio playback, and input remain later slices.
public actor PlayStationRemotePlayStreamingSession:
    StreamingSession,
    SampleBufferVideoSurfaceSession,
    AudioPlaybackControllableSession
{
    public nonisolated let id: UUID
    public nonisolated let experience: ExperienceDescriptor
    public nonisolated let videoSurface: SampleBufferVideoSurfaceBinding
    public nonisolated let audioControls: AudioPlaybackControls
    public nonisolated var videoDecoderDiagnostics: VideoDecoderDiagnosticsProvider {
        coordinator.videoDecoderDiagnostics
    }
    nonisolated let videoPresenter: BoundedSampleBufferVideoPresenter
    nonisolated let audioPlayer: BoundedPCMAudioPlayer

    private let consoleID: UUID
    private let qualityProfile: QualityProfile
    private let coordinator: PlayStationSessionCoordinator
    private var controllerFeedbackHandler: PlayStationSessionControllerFeedbackHandler
        = { _, _ in }

    init(
        id: UUID = UUID(),
        experience: ExperienceDescriptor,
        consoleID: UUID,
        qualityProfile: QualityProfile,
        videoPresenter: BoundedSampleBufferVideoPresenter,
        audioPlayer: BoundedPCMAudioPlayer,
        coordinator: PlayStationSessionCoordinator
    ) {
        self.id = id
        self.experience = experience
        self.consoleID = consoleID
        self.qualityProfile = qualityProfile
        self.videoPresenter = videoPresenter
        self.videoSurface = SampleBufferVideoSurfaceBinding(presenter: videoPresenter)
        self.audioPlayer = audioPlayer
        self.audioControls = audioPlayer.makeControls()
        self.coordinator = coordinator
    }

    /// Installs the destination for console-driven controller feedback. Must be
    /// called before `start()`; a session that never gets one simply drops
    /// feedback, which is the correct behavior on a shell with no controller
    /// output path.
    public func setControllerFeedbackHandler(
        _ handler: @escaping PlayStationSessionControllerFeedbackHandler
    ) {
        controllerFeedbackHandler = handler
    }

    public func start() async throws {
        await videoSurface.synchronizeThroughCurrentOperations()
        _ = try await coordinator.connect(
            consoleID: consoleID,
            qualityProfile: qualityProfile,
            controllerFeedbackHandler: controllerFeedbackHandler
        )
    }

    /// Repeated calls are intentional: a failed native teardown retains its
    /// resources so the next Stop can retry the same ordered stop/join path.
    public func stop() async {
        await coordinator.disconnect()
    }

    public func send(_ input: ControllerSnapshot) async {
        await coordinator.sendControllerSnapshot(input)
    }

    public func goHome() async throws {
        try await coordinator.goHome()
    }

    public func restAndDisconnect() async throws {
        try await coordinator.restAndDisconnect()
    }

    public func snapshot() async -> PlayStationSessionSnapshot {
        await coordinator.snapshot()
    }

    public func audioSnapshot() async -> PCMAudioPlaybackSnapshot {
        await coordinator.audioSnapshot()
    }
}
