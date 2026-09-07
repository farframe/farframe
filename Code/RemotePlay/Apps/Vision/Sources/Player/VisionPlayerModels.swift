import AppleMediaCore
import ExperienceDomain

/// The supported, production-safe controls that can be pinned to the Vision
/// player's ornament. Raw values intentionally match the known-good app so an
/// in-place upgrade preserves the user's existing rail without importing any
/// retired display or capture experiments.
enum VisionPlayerControlID: String, CaseIterable, Hashable, Identifiable, Sendable {
    case psMenu
    case psOptions
    case psCreate
    case psHome
    case sleep
    case showMain
    case disconnect
    case streamHUD
    case copyDiagnosis
    case volume

    var id: String { rawValue }
}

struct VisionPlayerDiagnostics: Sendable {
    let quality: VisionStreamQuality
    let video: SampleBufferVideoPresentationSnapshot
    let decoder: HEVCDecoderDiagnostics?
    let audio: PCMAudioPlaybackSnapshot
    let controllerIsConnected: Bool
    let controllerName: String?
    let controllerHasInput: Bool
    /// The advisor's reading of the counters above: what they mean and what the
    /// user can do. Derived from the same snapshot, never from playback state.
    ///
    /// Stored rather than computed. The HUD reads this from a view body, and
    /// SwiftUI re-evaluates a body whenever anything it depends on changes, not
    /// only when the 500 ms refresh fires. Running all the rules and allocating
    /// the full finding list at that rate is work nobody asked for, so it is
    /// done once, where the snapshot itself is built.
    let advice: StreamDiagnosticsAdvice

    init(
        quality: VisionStreamQuality,
        video: SampleBufferVideoPresentationSnapshot,
        decoder: HEVCDecoderDiagnostics?,
        audio: PCMAudioPlaybackSnapshot,
        controllerIsConnected: Bool,
        controllerName: String?,
        controllerHasInput: Bool
    ) {
        self.quality = quality
        self.video = video
        self.decoder = decoder
        self.audio = audio
        self.controllerIsConnected = controllerIsConnected
        self.controllerName = controllerName
        self.controllerHasInput = controllerHasInput
        self.advice = StreamDiagnosticsAdvisor.advise(
            VisionPlayerDiagnostics.advisorInput(
                quality: quality,
                video: video,
                decoder: decoder,
                audio: audio
            )
        )
    }

    /// The advisor input for this snapshot. Shared with the plain-text export
    /// so the copied report is the same diagnosis the HUD is showing, not a
    /// second one assembled slightly differently.
    static func advisorInput(
        quality: VisionStreamQuality,
        video: SampleBufferVideoPresentationSnapshot,
        decoder: HEVCDecoderDiagnostics?,
        audio: PCMAudioPlaybackSnapshot
    ) -> StreamDiagnosticsInput {
        .live(
            audio: audio,
            video: StreamDiagnosticsInput.Video(video),
            decoder: decoder,
            requestedQuality: quality.detail,
            requestedFramesPerSecond: quality.profile.framesPerSecond
        )
    }

    var advisorInput: StreamDiagnosticsInput {
        VisionPlayerDiagnostics.advisorInput(
            quality: quality,
            video: video,
            decoder: decoder,
            audio: audio
        )
    }
}
