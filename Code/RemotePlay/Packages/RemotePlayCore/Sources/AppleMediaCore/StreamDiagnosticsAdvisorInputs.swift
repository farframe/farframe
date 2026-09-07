import ExperienceDomain
import Foundation

/// Adapters from the live media snapshots to the advisor's platform-free input.
///
/// The advisor lives in `ExperienceDomain`, which cannot see these types, so the
/// mapping belongs here. Doing it here also lets the adaptive ranges come from
/// the real jitter-buffer and pacer configuration rather than from constants
/// copied into the rules, so a policy change cannot silently invalidate a rule.
extension StreamDiagnosticsInput.Audio {
    public init(_ snapshot: PCMAudioPlaybackSnapshot) {
        let configuration = PCMJitterBuffer.Configuration.remotePlay
        let sampleRate = configuration.sampleRate > 0 ? Double(configuration.sampleRate) : 48_000
        func milliseconds(_ frames: Int) -> Double { Double(frames) * 1_000 / sampleRate }
        self.init(
            queue: snapshot.queue,
            engineRecoveries: snapshot.recoveries,
            activationFailures: snapshot.activationFailures,
            targetFloorMilliseconds: milliseconds(configuration.minimumTargetFrames),
            targetCeilingMilliseconds: milliseconds(configuration.maximumTargetFrames),
            initialTargetMilliseconds: milliseconds(configuration.initialTargetFrames)
        )
    }
}

extension StreamDiagnosticsInput.Video.Upscaling {
    public init(mode: StreamUpscaling, _ diagnostics: VideoUpscalerDiagnostics) {
        self.init(
            mode: mode,
            backendName: diagnostics.backendName,
            framesUpscaled: diagnostics.framesUpscaled,
            framesPassedThrough: diagnostics.framesPassedThrough,
            failures: diagnostics.upscaleFailures,
            isDisabled: diagnostics.disabled,
            outputWidth: diagnostics.outputWidth,
            outputHeight: diagnostics.outputHeight
        )
    }
}

extension StreamDiagnosticsInput.Video {
    public init(
        _ snapshot: SampleBufferVideoPresentationSnapshot,
        enqueuedFramesPerSecond: Double? = nil
    ) {
        self.init(
            framesSubmitted: snapshot.framesSubmitted,
            framesEnqueued: snapshot.framesEnqueued,
            workerBackpressureDrops: snapshot.workerBackpressureDrops,
            rendererBackpressureDrops: snapshot.rendererBackpressureDrops,
            invalidTimingDrops: snapshot.invalidTimingDrops,
            staleGenerationDrops: snapshot.staleGenerationDrops,
            noSurfaceDrops: snapshot.noSurfaceDrops,
            flushRecoveries: snapshot.flushRecoveries,
            suspendedDrops: snapshot.suspendedDrops,
            pacingEnabled: snapshot.pacingEnabled,
            pacingQueuedFrames: snapshot.pacingQueuedFrames,
            pacingTargetFrames: snapshot.pacingTargetFrames,
            pacingFloorFrames: BoundedSampleBufferVideoPresenter.pacingMinimumTargetFrames,
            pacingCeilingFrames: BoundedSampleBufferVideoPresenter.pacingMaximumTargetFrames,
            pacingUnderruns: snapshot.pacingUnderruns,
            pacingSkips: snapshot.pacingSkips,
            enqueuedFramesPerSecond: enqueuedFramesPerSecond,
            // Mapping this here is what lets the enhancement rules reach every
            // shell at once: a shell that already builds an advisor input gets
            // them with no per-platform stats row to write and keep in sync.
            upscaling: StreamDiagnosticsInput.Video.Upscaling(
                mode: snapshot.upscaling,
                snapshot.upscaler
            )
        )
    }

    public init(_ snapshot: VideoPresentationRateSnapshot) {
        self.init(
            snapshot.counters,
            enqueuedFramesPerSecond: snapshot.enqueuedFramesPerSecond
        )
    }
}

extension StreamDiagnosticsThermalState {
    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }
}

extension StreamDiagnosticsInput {
    /// Assembles the advisor input from live snapshots plus the ambient device
    /// conditions, so all three shells map the same values the same way.
    ///
    /// `observationWindowSeconds` is left to the caller and is usually nil: the
    /// counters are cumulative for the whole session while the shells keep only
    /// a rolling window of samples, so the advisor's own estimate from frame
    /// counts covers a longer and more representative stretch.
    public static func live(
        audio: PCMAudioPlaybackSnapshot?,
        video: StreamDiagnosticsInput.Video?,
        decoder: HEVCDecoderDiagnostics?,
        requestedQuality: String? = nil,
        requestedFramesPerSecond: Int? = nil,
        networkInterface: StreamDiagnosticsNetworkInterface = .unknown,
        networkIsConstrained: Bool = false,
        networkIsExpensive: Bool = false,
        observationWindowSeconds: Double? = nil,
        processInfo: ProcessInfo = .processInfo
    ) -> StreamDiagnosticsInput {
        StreamDiagnosticsInput(
            audio: audio.map(StreamDiagnosticsInput.Audio.init),
            video: video,
            decoder: decoder.map(StreamDiagnosticsInput.Decoder.init),
            environment: Environment(
                thermalState: StreamDiagnosticsThermalState(processInfo.thermalState),
                lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
                networkInterface: networkInterface,
                networkIsConstrained: networkIsConstrained,
                networkIsExpensive: networkIsExpensive,
                requestedQuality: requestedQuality,
                requestedFramesPerSecond: requestedFramesPerSecond
            ),
            observationWindowSeconds: observationWindowSeconds
        )
    }
}

extension StreamDiagnosticsInput.Decoder {
    public init(_ diagnostics: HEVCDecoderDiagnostics) {
        self.init(
            samplesAdmitted: diagnostics.samplesAdmitted,
            framesDecoded: diagnostics.framesDecoded,
            queueDrops: diagnostics.backpressureDrops,
            keyframeRequests: diagnostics.keyframeRequests,
            awaitingKeyframeDrops: diagnostics.awaitingKeyframeDrops,
            sessionRebuilds: diagnostics.sessionRecoveries,
            decodeFailures: diagnostics.decodeFailures,
            pendingFrames: diagnostics.pendingFrames,
            maximumPendingFrames: diagnostics.maximumPendingFrames,
            awaitingKeyframe: diagnostics.awaitingKeyframe,
            keyframeRequestIntervalSeconds: Double(
                BoundedHEVCDecoder.keyframeRequestIntervalNanoseconds
            ) / 1_000_000_000
        )
    }
}
