import Foundation
import Testing

@testable import AppleMediaCore
@testable import ExperienceDomain

// MARK: - Fixtures

private let fiveMinutes: Double = 300

private func audioQueue(
    receivedBuffers: Int = 30_000,
    renderedBuffers: Int = 30_000,
    droppedBuffers: Int = 0,
    stalePacketDrops: Int = 0,
    backpressureDrops: Int = 0,
    pendingOverflowDrops: Int = 0,
    invalidBuffers: Int = 0,
    underruns: Int = 0,
    targetLatencyMilliseconds: Double = 80,
    silenceMilliseconds: Double = 0,
    callbackGapP95Milliseconds: Double = 10
) -> AudioQueueSnapshot {
    AudioQueueSnapshot(
        receivedBuffers: receivedBuffers,
        renderedBuffers: renderedBuffers,
        droppedBuffers: droppedBuffers,
        stalePacketDrops: stalePacketDrops,
        backpressureDrops: backpressureDrops,
        pendingOverflowDrops: pendingOverflowDrops,
        invalidBuffers: invalidBuffers,
        sampleRate: 48_000,
        callbackGapP95Milliseconds: callbackGapP95Milliseconds,
        underruns: underruns,
        targetLatencyMilliseconds: targetLatencyMilliseconds,
        silenceMilliseconds: silenceMilliseconds
    )
}

private func audio(
    _ queue: AudioQueueSnapshot = audioQueue(),
    engineRecoveries: UInt64 = 0,
    activationFailures: UInt64 = 0
) -> StreamDiagnosticsInput.Audio {
    StreamDiagnosticsInput.Audio(
        queue: queue,
        engineRecoveries: engineRecoveries,
        activationFailures: activationFailures
    )
}

private func enhancement(
    mode: StreamUpscaling = .enhanced,
    backendName: String = "metalfx",
    framesUpscaled: UInt64 = 18_000,
    framesPassedThrough: UInt64 = 0,
    failures: UInt64 = 0,
    isDisabled: Bool = false
) -> StreamDiagnosticsInput.Video.Upscaling {
    StreamDiagnosticsInput.Video.Upscaling(
        mode: mode,
        backendName: backendName,
        framesUpscaled: framesUpscaled,
        framesPassedThrough: framesPassedThrough,
        failures: failures,
        isDisabled: isDisabled,
        outputWidth: backendName == "none" ? 0 : 3_840,
        outputHeight: backendName == "none" ? 0 : 2_160
    )
}

private func video(
    framesSubmitted: UInt64 = 18_000,
    framesEnqueued: UInt64 = 18_000,
    workerBackpressureDrops: UInt64 = 0,
    rendererBackpressureDrops: UInt64 = 0,
    invalidTimingDrops: UInt64 = 0,
    flushRecoveries: UInt64 = 0,
    suspendedDrops: UInt64 = 0,
    pacingEnabled: Bool = true,
    pacingTargetFrames: Int = 3,
    pacingUnderruns: UInt64 = 0,
    pacingSkips: UInt64 = 0,
    upscaling: StreamDiagnosticsInput.Video.Upscaling? = nil
) -> StreamDiagnosticsInput.Video {
    StreamDiagnosticsInput.Video(
        framesSubmitted: framesSubmitted,
        framesEnqueued: framesEnqueued,
        workerBackpressureDrops: workerBackpressureDrops,
        rendererBackpressureDrops: rendererBackpressureDrops,
        invalidTimingDrops: invalidTimingDrops,
        flushRecoveries: flushRecoveries,
        suspendedDrops: suspendedDrops,
        pacingEnabled: pacingEnabled,
        pacingQueuedFrames: pacingTargetFrames,
        pacingTargetFrames: pacingTargetFrames,
        pacingUnderruns: pacingUnderruns,
        pacingSkips: pacingSkips,
        upscaling: upscaling
    )
}

private func decoder(
    samplesAdmitted: UInt64 = 18_000,
    framesDecoded: UInt64 = 18_000,
    queueDrops: UInt64 = 0,
    keyframeRequests: UInt64 = 0,
    sessionRebuilds: UInt64 = 0,
    decodeFailures: UInt64 = 0,
    awaitingKeyframe: Bool = false
) -> StreamDiagnosticsInput.Decoder {
    StreamDiagnosticsInput.Decoder(
        samplesAdmitted: samplesAdmitted,
        framesDecoded: framesDecoded,
        queueDrops: queueDrops,
        keyframeRequests: keyframeRequests,
        sessionRebuilds: sessionRebuilds,
        decodeFailures: decodeFailures,
        maximumPendingFrames: 16,
        awaitingKeyframe: awaitingKeyframe
    )
}

private func environment(
    thermalState: StreamDiagnosticsThermalState = .nominal,
    lowPowerModeEnabled: Bool = false,
    networkInterface: StreamDiagnosticsNetworkInterface = .wifi,
    networkIsConstrained: Bool = false,
    networkIsExpensive: Bool = false
) -> StreamDiagnosticsInput.Environment {
    StreamDiagnosticsInput.Environment(
        thermalState: thermalState,
        lowPowerModeEnabled: lowPowerModeEnabled,
        networkInterface: networkInterface,
        networkIsConstrained: networkIsConstrained,
        networkIsExpensive: networkIsExpensive,
        requestedQuality: "1080p · 60 FPS · 12 Mbps",
        requestedFramesPerSecond: 60
    )
}

private func input(
    audio audioSection: StreamDiagnosticsInput.Audio? = audio(),
    video videoSection: StreamDiagnosticsInput.Video? = video(),
    decoder decoderSection: StreamDiagnosticsInput.Decoder? = decoder(),
    environment environmentSection: StreamDiagnosticsInput.Environment = environment(),
    observationWindowSeconds: Double? = fiveMinutes
) -> StreamDiagnosticsInput {
    StreamDiagnosticsInput(
        audio: audioSection,
        video: videoSection,
        decoder: decoderSection,
        environment: environmentSection,
        observationWindowSeconds: observationWindowSeconds
    )
}

private extension StreamDiagnosticsAdvice {
    func finding(_ id: String) -> StreamDiagnosticsFinding? {
        findings.first { $0.id == id }
    }

    var ids: [String] { findings.map(\.id) }
}

// MARK: - Healthy and framing

@Test
func healthyStreamSaysSoPlainlyAndAsksForNothing() {
    let advice = StreamDiagnosticsAdvisor.advise(input())

    #expect(advice.overall == .healthy)
    #expect(advice.ids == ["stream.healthy"])
    #expect(advice.headline.contains("healthy"))
    #expect(advice.finding("stream.healthy")?.actions.isEmpty == true)
    #expect(advice.sampleIsAdequate)
    // The healthy finding still quotes the numbers that justify it.
    #expect(advice.finding("stream.healthy")?.evidence.isEmpty == false)
}

@Test
func healthyVerdictAdmitsWhatItCannotSee() {
    let advice = StreamDiagnosticsAdvisor.advise(input())
    let why = try! #require(advice.finding("stream.healthy")).why
    // A clean report must not imply the whole experience was measured.
    #expect(why.contains("not something this app measures"))
}

@Test
func shortSessionRefusesToDiagnoseInsteadOfGuessing() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(
            audio: audio(audioQueue(receivedBuffers: 400, underruns: 3, targetLatencyMilliseconds: 200)),
            video: video(framesSubmitted: 200, pacingUnderruns: 4),
            observationWindowSeconds: 4
        )
    )

    #expect(advice.sampleIsAdequate == false)
    #expect(advice.finding("session.insufficient-sample")?.confidence == .insufficient)
    // None of the rate-based rules may fire on a sample this small.
    #expect(advice.finding("audio.jitter.target-high") == nil)
    #expect(advice.finding("video.pacing.underruns") == nil)
    #expect(advice.headline.contains("Not enough"))
}

@Test
func shortSessionStillReportsStatesThatDoNotNeedARate() {
    // A frozen picture or a hot device is true regardless of sample size.
    let advice = StreamDiagnosticsAdvisor.advise(
        input(
            decoder: decoder(samplesAdmitted: 40, framesDecoded: 0, awaitingKeyframe: true),
            environment: environment(thermalState: .critical),
            observationWindowSeconds: 5
        )
    )

    #expect(advice.finding("decoder.awaiting-keyframe")?.severity == .critical)
    #expect(advice.finding("device.thermal-pressure")?.severity == .critical)
    #expect(advice.finding("session.insufficient-sample") != nil)
}

@Test
func observationWindowIsEstimatedFromFrameCountsWhenNotSupplied() {
    let estimated = StreamDiagnosticsAdvisor.observedSeconds(
        input(video: video(framesSubmitted: 3_600), observationWindowSeconds: nil)
    )
    #expect(estimated == 60)

    let fromAudio = StreamDiagnosticsAdvisor.observedSeconds(
        StreamDiagnosticsInput(
            audio: audio(audioQueue(receivedBuffers: 6_000)),
            observationWindowSeconds: nil
        )
    )
    #expect(fromAudio == 60)

    #expect(StreamDiagnosticsAdvisor.observedSeconds(StreamDiagnosticsInput()) == nil)
}

// MARK: - Audio rules

@Test
func audioUnderrunsWithTheTargetNearItsCeilingReadAsAJitteryPath() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(audio: audio(audioQueue(
            underruns: 12,
            targetLatencyMilliseconds: 230,
            silenceMilliseconds: 380,
            callbackGapP95Milliseconds: 95
        )))
    )

    let finding = try! #require(advice.finding("audio.jitter.target-high"))
    #expect(finding.severity == .watch || finding.severity == .warning)
    #expect(finding.area == .network)
    #expect(finding.confidence == .likely)
    // The cheapest fix is first; the one that costs picture quality is last.
    #expect(finding.actions.first?.text.contains("closer to the router") == true)
    #expect(finding.actions.last?.tradeoff != nil)
    // It must say the app behaved correctly rather than implying a defect.
    #expect(finding.why.contains("not of the app"))
    #expect(advice.finding("audio.jitter.absorbed") == nil)
}

@Test
func aTargetPinnedAtTheCeilingIsAWarningRatherThanSomethingToWatch() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(audio: audio(audioQueue(underruns: 30, targetLatencyMilliseconds: 240)))
    )
    #expect(advice.finding("audio.jitter.target-high")?.severity == .warning)
}

@Test
func occasionalAudioStallsThatTheBufferAbsorbedNeedNoAction() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(audio: audio(audioQueue(underruns: 2, targetLatencyMilliseconds: 110)))
    )

    let finding = try! #require(advice.finding("audio.jitter.absorbed"))
    #expect(finding.severity == .informational)
    #expect(finding.actions.isEmpty)
    #expect(advice.finding("audio.jitter.target-high") == nil)
    // Informational findings alone still leave the overall verdict healthy.
    #expect(advice.overall == .healthy)
}

@Test
func audioBurstSkipsOnlyFireWhenTheyAreFrequentEnoughToMatter() {
    let rare = StreamDiagnosticsAdvisor.advise(
        input(audio: audio(audioQueue(backpressureDrops: 8)))
    )
    #expect(rare.finding("audio.burst-skips") == nil)

    let frequent = StreamDiagnosticsAdvisor.advise(
        input(audio: audio(audioQueue(backpressureDrops: 600, callbackGapP95Milliseconds: 70)))
    )
    let finding = try! #require(frequent.finding("audio.burst-skips"))
    #expect(finding.area == .network)
    #expect(finding.actions.isEmpty == false)
}

@Test
func audioLostForLackOfRoomNamesBothCausesInsteadOfPickingOne() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(audio: audio(audioQueue(pendingOverflowDrops: 40)))
    )

    let finding = try! #require(advice.finding("audio.ring-overflow"))
    #expect(finding.severity == .warning)
    #expect(finding.confidence == .ambiguous)
    #expect(finding.why.contains("cannot separate them"))
    // It points the reader at the field that breaks the tie.
    #expect(finding.evidence.contains { $0.label == "Thermal state" })
}

@Test
func staleAudioIsAttributedToThisDeviceNotTheNetwork() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(audio: audio(audioQueue(stalePacketDrops: 25)))
    )

    let finding = try! #require(advice.finding("audio.stale-packets"))
    #expect(finding.area == .audio)
    #expect(finding.why.contains("not the network"))
}

@Test
func audioFormatRejectsAreCalledAnAppOrConsoleProblem() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(audio: audio(audioQueue(invalidBuffers: 12)))
    )

    let finding = try! #require(advice.finding("audio.format-rejects"))
    #expect(finding.confidence == .confirmed)
    #expect(finding.why.contains("rather than anything about your network"))
}

@Test
func audioEngineRestartsAdmitTheyMayHaveBeenTheUsersOwnDoing() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(audio: audio(audioQueue(), engineRecoveries: 4))
    )

    let finding = try! #require(advice.finding("audio.engine-recoveries"))
    #expect(finding.confidence == .ambiguous)
    #expect(finding.why.contains("look identical here"))
    #expect(finding.severity == .watch)
}

@Test
func audioActivationFailuresAreReportedEvenOnAShortSession() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(
            audio: audio(audioQueue(receivedBuffers: 20), activationFailures: 3),
            observationWindowSeconds: 3
        )
    )
    #expect(advice.finding("audio.activation-failures")?.severity == .warning)
}

// MARK: - Video pacing

@Test
func aPacingLeadNearItsCeilingIsReportedAsInputLagWithItsTradeoff() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(video: video(pacingTargetFrames: 12, pacingUnderruns: 9))
    )

    let finding = try! #require(advice.finding("video.pacing.lead-at-ceiling"))
    #expect(finding.severity == .warning)
    #expect(finding.confidence == .confirmed)
    // 12 frames at 60 fps is 200 ms and the title has to say so.
    #expect(finding.title.contains("200 ms"))
    #expect(finding.why.contains("Aiming"))
    // Resetting the lead is offered first: it is the only action that fixes the
    // lag without giving up the feature, and it only became a real remedy once
    // the toggle started returning the learned lead to its starting point.
    let reset = try! #require(finding.actions.first)
    #expect(reset.text.contains("off and straight back on"))
    #expect(reset.tradeoff?.contains("climb again") == true)
    // Turning smoothing off is still offered, with its cost stated.
    let off = try! #require(finding.actions.dropFirst().first)
    #expect(off.text.contains("Smooth motion off"))
    #expect(off.tradeoff != nil)
    // The copy must not promise a fix the app cannot perform.
    #expect(finding.why.contains("starts the count over"))
}

@Test
func aPacingLeadBelowTheHighWaterMarkIsNotReported() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(video: video(pacingTargetFrames: 6))
    )
    #expect(advice.finding("video.pacing.lead-at-ceiling") == nil)
}

@Test
func videoAndAudioStallingTogetherIsAttributedToTheSharedPath() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(
            audio: audio(audioQueue(underruns: 14, targetLatencyMilliseconds: 200)),
            video: video(pacingTargetFrames: 8, pacingUnderruns: 40)
        )
    )

    let finding = try! #require(advice.finding("video.pacing.underruns"))
    #expect(finding.area == .network)
    #expect(finding.confidence == .likely)
    #expect(finding.severity == .warning)
    #expect(finding.why.contains("same path"))
    #expect(finding.actions.contains { $0.text.contains("Ethernet") })
}

/// The engine must decline to over-diagnose here: a running total cannot
/// distinguish a stalling path from slow console-to-device clock drift, and the
/// presenter treats those as different things for good reason.
@Test
func videoStallingWithCleanAudioIsDeclaredAmbiguousRatherThanBlamedOnTheNetwork() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(
            audio: audio(audioQueue(underruns: 0)),
            video: video(pacingTargetFrames: 5, pacingUnderruns: 30)
        )
    )

    let finding = try! #require(advice.finding("video.pacing.underruns"))
    #expect(finding.confidence == .ambiguous)
    #expect(finding.area == .video)
    // Named alternatives, not a guess.
    #expect(finding.why.contains("drift"))
    #expect(finding.why.contains("cannot separate"))
    // Severity is capped: an undecided finding must not shout.
    #expect(finding.severity == .watch)
    // And it must not hand out network fixes it cannot justify.
    #expect(finding.actions.contains { $0.text.contains("Ethernet") } == false)
}

@Test
func videoBurstSkipsAreReportedAsUnevenDeliveryNotLowBandwidth() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(video: video(pacingSkips: 40))
    )

    let finding = try! #require(advice.finding("video.pacing.skips"))
    #expect(finding.severity == .informational)
    #expect(finding.actions.first?.text.contains("not a bandwidth one") == true)
}

@Test
func pacingRulesStaySilentWhenSmoothMotionIsOff() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(video: video(
            pacingEnabled: false,
            pacingTargetFrames: 12,
            pacingUnderruns: 50,
            pacingSkips: 50
        ))
    )
    #expect(advice.finding("video.pacing.lead-at-ceiling") == nil)
    #expect(advice.finding("video.pacing.underruns") == nil)
    #expect(advice.finding("video.pacing.skips") == nil)
}

// MARK: - Renderer

@Test
func rendererDropsOnAFullyWatchedSessionAreAttributedToThisDevice() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(video: video(
            framesSubmitted: 18_000,
            workerBackpressureDrops: 900,
            rendererBackpressureDrops: 200
        ))
    )

    let finding = try! #require(advice.finding("video.renderer-drops"))
    #expect(finding.confidence == .likely)
    #expect(finding.severity == .warning)
    #expect(finding.what.contains("6.1%"))
    #expect(finding.actions.contains { $0.text.contains("Close other apps") })
}

/// Time spent off screen inflates every video ratio, so the engine must say the
/// measurement is unreliable instead of diagnosing a rendering problem.
@Test
func rendererDropsMeasuredPartlyOffScreenAreDeclaredUnreliable() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(video: video(
            framesSubmitted: 18_000,
            workerBackpressureDrops: 900,
            suspendedDrops: 4_000
        ))
    )

    let finding = try! #require(advice.finding("video.renderer-drops"))
    #expect(finding.confidence == .ambiguous)
    #expect(finding.why.contains("inflates this percentage"))
    // Its only advice is to re-measure, not to change settings.
    #expect(finding.actions.count == 1)
    #expect(finding.actions.first?.text.contains("Save another report") == true)
}

@Test
func timeOffScreenIsCalledOutEvenWhenDropRatesLookFine() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(video: video(suspendedDrops: 900))
    )

    let finding = try! #require(advice.finding("session.presentation-suspended"))
    #expect(finding.severity == .informational)
    #expect(advice.finding("video.renderer-drops") == nil)
}

@Test
func repeatedRendererResetsAreNotBlamedOnTheNetwork() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(video: video(flushRecoveries: 40))
    )

    let finding = try! #require(advice.finding("video.flush-recoveries"))
    #expect(finding.severity == .warning)
    #expect(finding.why.contains("not a network measurement"))
}

// MARK: - Video enhancement

/// The gap this rule closes: the setting reads "Enhanced" whatever the pass is
/// doing, so a user who never sees a finding has no way to learn it stopped.
@Test
func anEnhancementPassThatSwitchedItselfOffIsReportedRatherThanLeftSilent() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(video: video(upscaling: enhancement(
            framesUpscaled: 400,
            framesPassedThrough: 17_600,
            failures: 30,
            isDisabled: true
        )))
    )

    let finding = try! #require(advice.finding("video.enhancement.disabled"))
    #expect(finding.severity == .warning)
    #expect(finding.confidence == .confirmed)
    #expect(finding.area == .video)
    // The user has to be told the setting is now lying to them.
    #expect(finding.what.contains("still selected"))
    // And that playback was never the thing at risk.
    #expect(finding.why.contains("never at risk"))
    #expect(finding.actions.isEmpty == false)
}

/// A latched-off pass is a state, not a rate, so waiting for a long sample
/// before mentioning it would leave the user staring at a setting that stopped
/// working several minutes ago.
@Test
func aDisabledEnhancementPassIsReportedEvenOnAShortSession() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(
            video: video(
                framesSubmitted: 200,
                upscaling: enhancement(framesUpscaled: 30, failures: 30, isDisabled: true)
            ),
            observationWindowSeconds: 4
        )
    )

    #expect(advice.sampleIsAdequate == false)
    #expect(advice.finding("video.enhancement.disabled") != nil)
}

@Test
func theFallbackScalerIsDisclosedWithoutBeingTreatedAsAProblem() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(video: video(upscaling: enhancement(backendName: "lanczos")))
    )

    let finding = try! #require(advice.finding("video.enhancement.fallback-backend"))
    #expect(finding.severity == .informational)
    // Nothing the user can do about their own GPU, so nothing is asked of them.
    #expect(finding.actions.isEmpty)
    // An informational-only report still reads as healthy overall.
    #expect(advice.overall == .healthy)
}

@Test
func enhancementSkippingFramesInEnhancedModeIsReportedAsAmbiguous() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(video: video(upscaling: enhancement(
            framesUpscaled: 12_600,
            framesPassedThrough: 5_400
        )))
    )

    let finding = try! #require(advice.finding("video.enhancement.not-reaching-frames"))
    #expect(finding.severity == .warning)
    // A busy GPU and failing frames produce the same counters, so the finding
    // must name both rather than pick one.
    #expect(finding.confidence == .ambiguous)
    #expect(finding.what.contains("30.0%"))
    #expect(finding.actions.contains { $0.text.contains("Automatic") })
}

/// In `automatic` the pass is supposed to stand down for a small window. Firing
/// there would turn correct behaviour into a warning on every windowed session.
@Test
func passedThroughFramesInAutomaticModeAreNotTreatedAsAFault() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(video: video(upscaling: enhancement(
            mode: .automatic,
            framesUpscaled: 2_000,
            framesPassedThrough: 16_000
        )))
    )

    #expect(advice.finding("video.enhancement.not-reaching-frames") == nil)
    #expect(advice.overall == .healthy)
}

@Test
func anEnhancementPassThatCouldNeverBeBuiltIsReportedAsNeverStarting() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(video: video(upscaling: enhancement(
            backendName: "none",
            framesUpscaled: 0,
            framesPassedThrough: 0
        )))
    )

    let finding = try! #require(advice.finding("video.enhancement.unavailable"))
    #expect(finding.severity == .watch)
    #expect(finding.confidence == .confirmed)
    #expect(finding.evidence.contains { $0.value.hasPrefix("0 of") })
}

/// The pass is built asynchronously and sizes itself from the first frame, so
/// an empty counter in the first seconds is start-up, not a failure.
@Test
func anEnhancementPassIsNotJudgedBeforeItHasHadTimeToStart() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(
            video: video(
                framesSubmitted: 120,
                upscaling: enhancement(backendName: "none", framesUpscaled: 0)
            ),
            observationWindowSeconds: 2
        )
    )

    #expect(advice.finding("video.enhancement.unavailable") == nil)
}

@Test
func anEnhancementPassDoingItsJobProducesNoFindingAtAll() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(video: video(upscaling: enhancement()))
    )

    #expect(advice.ids == ["stream.healthy"])
}

/// A shell that does not report the pass at all must not be diagnosed as if it
/// had one that failed.
@Test
func aShellThatReportsNoEnhancementStateGetsNoEnhancementFindings() {
    let advice = StreamDiagnosticsAdvisor.advise(input(video: video(upscaling: nil)))

    #expect(advice.ids == ["stream.healthy"])
}

@Test
func enhancementCountersAreExplainedInTheExportedGlossary() {
    let names = StreamDiagnosticsAdvisor.metricNotes.map(\.name)
    #expect(names.contains("Frames enhanced"))
    #expect(names.contains("Frames shown without enhancement"))
    #expect(names.contains("Enhancement failures"))
}

/// The whole reason this is a rule and not a stats row: it reaches the shells
/// through the input the media layer already builds, with no per-shell UI.
@Test
func upscalerStateReachesTheAdvisorFromTheLivePresentationSnapshot() {
    let snapshot = SampleBufferVideoPresentationSnapshot(
        activeGeneration: 1,
        framesSubmitted: 600,
        framesEnqueued: 600,
        staleGenerationDrops: 0,
        noSurfaceDrops: 0,
        workerBackpressureDrops: 0,
        rendererBackpressureDrops: 0,
        invalidTimingDrops: 0,
        flushRecoveries: 0,
        upscaling: .enhanced,
        upscaler: VideoUpscalerDiagnostics(
            backendName: "lanczos",
            outputWidth: 3_840,
            outputHeight: 2_160,
            framesUpscaled: 500,
            framesPassedThrough: 100,
            upscaleFailures: 2,
            lastGPUMilliseconds: 1.2,
            disabled: true
        )
    )
    let mapped = try! #require(StreamDiagnosticsInput.Video(snapshot).upscaling)

    #expect(mapped.mode == .enhanced)
    #expect(mapped.backendName == "lanczos")
    #expect(mapped.framesUpscaled == 500)
    #expect(mapped.framesPassedThrough == 100)
    #expect(mapped.failures == 2)
    #expect(mapped.isDisabled)
    #expect(mapped.framesHandled == 600)
}

// MARK: - Decoder

@Test
func aFrozenPictureIsCriticalAndLeadsTheReport() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(
            audio: audio(audioQueue(underruns: 20, targetLatencyMilliseconds: 240)),
            decoder: decoder(keyframeRequests: 6, sessionRebuilds: 2, awaitingKeyframe: true)
        )
    )

    #expect(advice.overall == .critical)
    #expect(advice.findings.first?.id == "decoder.awaiting-keyframe")
    #expect(advice.headline.contains("Start here"))
}

@Test
func decoderQueueDropsAreAttributedToThisDeviceKeepingUp() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(decoder: decoder(samplesAdmitted: 17_000, queueDrops: 400))
    )

    let finding = try! #require(advice.finding("decoder.queue-drops"))
    #expect(finding.confidence == .confirmed)
    #expect(finding.severity == .warning)
    // The visible symptom is named so the user can match it to what they saw.
    #expect(finding.why.contains("pixelation"))
    #expect(finding.actions.last?.tradeoff != nil)
}

/// `keyframeRequests` only increments while recovering from a decoder restart,
/// at most twice a second. It is a recovery-duration counter. Nothing in this
/// engine may present it as evidence of packet loss.
@Test
func keyframeRequestsAreReportedAsRecoveryTimeAndNeverAsPacketLoss() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(decoder: decoder(keyframeRequests: 8, sessionRebuilds: 2))
    )

    let finding = try! #require(advice.finding("decoder.session-loss"))
    #expect(finding.what.contains("4 seconds"))
    #expect(finding.evidence.contains {
        $0.meaning.contains("not a count of lost packets")
    })
    for finding in advice.findings {
        #expect(finding.why.lowercased().contains("packet loss") == false)
        #expect(finding.what.lowercased().contains("packet loss") == false)
    }
}

@Test
func decoderRestartsWithTimeOffScreenAreExplainedRatherThanFlagged() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(
            video: video(suspendedDrops: 500),
            decoder: decoder(keyframeRequests: 4, sessionRebuilds: 1)
        )
    )

    let finding = try! #require(advice.finding("decoder.session-loss"))
    #expect(finding.confidence == .likely)
    #expect(finding.why.contains("recovering correctly"))
    #expect(finding.actions.first?.text.contains("Nothing to fix") == true)
}

@Test
func decoderRestartsWithNoTimeOffScreenAdmitTheCauseIsUnknown() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(decoder: decoder(keyframeRequests: 10, sessionRebuilds: 4))
    )

    let finding = try! #require(advice.finding("decoder.session-loss"))
    #expect(finding.confidence == .ambiguous)
    #expect(finding.why.contains("cannot say why"))
    // It still rules out what the evidence does exclude.
    #expect(finding.why.contains("not a bandwidth problem"))
}

@Test
func aDecodeFailureStormWhileOffScreenIsNamedAsTheKnownIssue() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(
            video: video(suspendedDrops: 2_000),
            decoder: decoder(framesDecoded: 9_000, sessionRebuilds: 3, decodeFailures: 4_554)
        )
    )

    let finding = try! #require(advice.finding("decoder.failure-storm"))
    #expect(finding.confidence == .likely)
    #expect(finding.why.contains("harmless to the picture"))
    #expect(finding.why.contains("known issue"))
    #expect(finding.actions.first?.text.contains("Disconnect when you take a long break") == true)
}

@Test
func aDecodeFailureStormWithNoTimeOffScreenIsLeftUndecided() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(decoder: decoder(decodeFailures: 600))
    )

    let finding = try! #require(advice.finding("decoder.failure-storm"))
    #expect(finding.confidence == .ambiguous)
    #expect(finding.why.contains("cannot tell those apart"))
}

@Test
func aHandfulOfDecodeFailuresAroundAReconnectIsNotReported() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(decoder: decoder(decodeFailures: 4))
    )
    #expect(advice.finding("decoder.failure-storm") == nil)
}

// MARK: - Device and path

@Test
func thermalThrottlingIsFlaggedAsTheThingToFixFirst() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(
            video: video(framesSubmitted: 18_000, workerBackpressureDrops: 700),
            environment: environment(thermalState: .serious)
        )
    )

    let finding = try! #require(advice.finding("device.thermal-pressure"))
    #expect(finding.severity == .warning)
    #expect(finding.why.contains("fix this one first"))
}

@Test
func nominalAndFairThermalStatesAreNotReported() {
    for state in [StreamDiagnosticsThermalState.nominal, .fair, .unknown] {
        let advice = StreamDiagnosticsAdvisor.advise(
            input(environment: environment(thermalState: state))
        )
        #expect(advice.finding("device.thermal-pressure") == nil)
    }
}

@Test
func lowPowerModeIsReportedWithItsCost() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(environment: environment(lowPowerModeEnabled: true))
    )

    let finding = try! #require(advice.finding("device.low-power-mode"))
    #expect(finding.severity == .informational)
    #expect(finding.actions.first?.tradeoff?.contains("battery") == true)
    // Informational only: the stream itself is still healthy.
    #expect(advice.overall == .healthy)
}

@Test
func aConstrainedOrCellularPathIsNamedBeforeAnythingElseIsBlamed() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(environment: environment(
            networkInterface: .cellular,
            networkIsConstrained: true,
            networkIsExpensive: true
        ))
    )

    let finding = try! #require(advice.finding("network.constrained-path"))
    #expect(finding.what.contains("cellular"))
    #expect(finding.what.contains("constrained"))
    #expect(finding.what.contains("metered"))
}

@Test
func anOrdinaryWiFiPathIsNotReportedAsAProblem() {
    let advice = StreamDiagnosticsAdvisor.advise(input())
    #expect(advice.finding("network.constrained-path") == nil)
}

// MARK: - Ranking and shape

@Test
func findingsAreRankedBySeverityWithTheWorstFirst() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(
            audio: audio(audioQueue(underruns: 20, targetLatencyMilliseconds: 240), engineRecoveries: 1),
            video: video(pacingTargetFrames: 12, pacingUnderruns: 30, pacingSkips: 40),
            decoder: decoder(queueDrops: 300),
            environment: environment(thermalState: .critical, lowPowerModeEnabled: true)
        )
    )

    #expect(advice.overall == .critical)
    let severities = advice.findings.map(\.severity)
    #expect(severities == severities.sorted(by: >))
    #expect(advice.findings.first?.severity == .critical)
    // The healthy verdict never appears alongside real problems.
    #expect(advice.finding("stream.healthy") == nil)
}

@Test
func everyFindingCarriesWhatWhyEvidenceAndAStableIdentifier() {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(
            audio: audio(audioQueue(pendingOverflowDrops: 5, underruns: 20, targetLatencyMilliseconds: 240)),
            video: video(flushRecoveries: 20, pacingTargetFrames: 12, pacingUnderruns: 30),
            decoder: decoder(queueDrops: 300, keyframeRequests: 6, sessionRebuilds: 2),
            environment: environment(thermalState: .serious, lowPowerModeEnabled: true)
        )
    )

    #expect(advice.findings.count >= 6)
    for finding in advice.findings {
        #expect(finding.id.isEmpty == false)
        #expect(finding.title.isEmpty == false)
        #expect(finding.what.count > 20)
        #expect(finding.why.count > 20)
        #expect(finding.evidence.isEmpty == false)
        for item in finding.evidence {
            #expect(item.meaning.isEmpty == false)
        }
    }
    #expect(Set(advice.ids).count == advice.ids.count)
}

@Test
func adviceSurvivesACodableRoundTrip() throws {
    let advice = StreamDiagnosticsAdvisor.advise(
        input(
            audio: audio(audioQueue(underruns: 9, targetLatencyMilliseconds: 210)),
            video: video(pacingTargetFrames: 11, pacingUnderruns: 20)
        )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(advice)
    let restored = try JSONDecoder().decode(StreamDiagnosticsAdvice.self, from: data)
    #expect(restored == advice)
}

@Test
func severityOrdersFromHealthyToCritical() {
    #expect(StreamDiagnosticsSeverity.healthy < .informational)
    #expect(StreamDiagnosticsSeverity.informational < .watch)
    #expect(StreamDiagnosticsSeverity.watch < .warning)
    #expect(StreamDiagnosticsSeverity.warning < .critical)
    #expect(StreamDiagnosticsSeverity.allCases.max() == .critical)
}

// MARK: - Shareable export

@Test
func theExportedTextExplainsItselfWithoutAnyOtherContext() {
    let source = input(
        audio: audio(audioQueue(underruns: 12, targetLatencyMilliseconds: 230, silenceMilliseconds: 400)),
        video: video(pacingTargetFrames: 12, pacingUnderruns: 25)
    )
    let advice = StreamDiagnosticsAdvisor.advise(source)
    let text = StreamDiagnosticsAdvisor.plainTextReport(
        advice,
        input: source,
        generatedAt: Date(timeIntervalSince1970: 1_788_000_000),
        appVersion: "1.0 (3)"
    )

    // It says what the product is, so a reader with no context can follow it.
    #expect(text.contains("streams a PlayStation 5"))
    #expect(text.contains("VERDICT"))
    #expect(text.contains("WHAT WAS MEASURED"))
    #expect(text.contains("HOW TO READ THESE NUMBERS"))
    #expect(text.contains("LIMITS OF THIS REPORT"))
    // Units and a normal range travel with every counter it can quote.
    #expect(text.contains("Normal:"))
    #expect(text.contains("milliseconds"))
    // Each finding carries its own confidence in words, not just a label.
    #expect(text.contains("one cause fits much better than the alternatives"))
    // Actions are numbered so the ranking survives being pasted as plain text.
    #expect(text.contains("What to try, cheapest and most likely to help first:"))
    #expect(text.contains("  1. "))
}

@Test
func theExportedTextStatesWhatItCannotMeasure() {
    let source = input()
    let text = StreamDiagnosticsAdvisor.plainTextReport(
        StreamDiagnosticsAdvisor.advise(source),
        input: source,
        generatedAt: Date(timeIntervalSince1970: 1_788_000_000)
    )

    #expect(text.contains("running total"))
    #expect(text.contains("Nothing here measures network bandwidth"))
    #expect(text.contains("Controller input timing is not measured at all"))
}

@Test
func theExportedTextCarriesNoIdentifiers() {
    let source = input(environment: environment(networkInterface: .cellular))
    let advice = StreamDiagnosticsAdvisor.advise(source)
    let text = StreamDiagnosticsAdvisor.plainTextReport(
        advice,
        input: source,
        generatedAt: Date(timeIntervalSince1970: 1_788_000_000)
    )

    // No addresses, host names or identifiers can reach the export, because
    // none of them are in the input in the first place.
    #expect(text.contains("@") == false)
    #expect(text.range(of: #"\b\d{1,3}(\.\d{1,3}){3}\b"#, options: .regularExpression) == nil)
    #expect(text.contains("no account, console, network address or device identifier"))
    // The only network fact it may carry is the interface class.
    #expect(text.contains("Network interface: cellular"))
}

@Test
func theGlossaryCoversTheCountersTheFindingsQuote() {
    #expect(StreamDiagnosticsAdvisor.metricNotes.count >= 12)
    for note in StreamDiagnosticsAdvisor.metricNotes {
        #expect(note.unit.isEmpty == false)
        #expect(note.normal.isEmpty == false)
    }
    // The counter most likely to be misread has its trap spelled out.
    let keyframe = try! #require(
        StreamDiagnosticsAdvisor.metricNotes.first { $0.name.contains("complete frame") }
    )
    #expect(keyframe.meaning.contains("not a count of lost packets"))
}

// MARK: - Adapters

@Test
func decoderDiagnosticsMapOntoTheAdvisorInputWithoutRenamingMeaning() {
    let diagnostics = HEVCDecoderDiagnostics(
        samplesAdmitted: 100,
        framesDecoded: 98,
        backpressureDrops: 5,
        keyframeRequests: 3,
        awaitingKeyframeDrops: 7,
        sessionRecoveries: 2,
        decodeFailures: 1,
        pendingFrames: 4,
        maximumPendingFrames: 16,
        awaitingKeyframe: true
    )
    let mapped = StreamDiagnosticsInput.Decoder(diagnostics)

    #expect(mapped.queueDrops == 5)
    #expect(mapped.sessionRebuilds == 2)
    #expect(mapped.awaitingKeyframe)
    #expect(mapped.maximumPendingFrames == 16)
    // The request cadence comes from the decoder's own policy, so the recovery
    // time the advisor reports stays correct if that policy changes.
    #expect(mapped.keyframeRequestIntervalSeconds == 0.5)
}

@Test
func videoSnapshotsCarryTheRealPacingRangeRatherThanACopiedConstant() {
    let snapshot = SampleBufferVideoPresentationSnapshot(
        activeGeneration: 1,
        framesSubmitted: 600,
        framesEnqueued: 590,
        staleGenerationDrops: 0,
        noSurfaceDrops: 0,
        workerBackpressureDrops: 6,
        rendererBackpressureDrops: 4,
        invalidTimingDrops: 0,
        flushRecoveries: 1,
        pacingEnabled: true,
        pacingQueuedFrames: 3,
        pacingTargetFrames: 5,
        pacingUnderruns: 2,
        pacingSkips: 1
    )
    let mapped = StreamDiagnosticsInput.Video(snapshot)

    #expect(mapped.pacingCeilingFrames == BoundedSampleBufferVideoPresenter.pacingMaximumTargetFrames)
    #expect(mapped.pacingFloorFrames == BoundedSampleBufferVideoPresenter.pacingMinimumTargetFrames)
    #expect(mapped.framesNotShown == 10)
}

@Test
func audioSnapshotsCarryTheRealJitterBufferRange() {
    let snapshot = PCMAudioPlaybackSnapshot(
        state: .playing,
        activeGeneration: 1,
        negotiatedFormat: nil,
        volume: 1,
        isMuted: false,
        queue: audioQueue(underruns: 3, targetLatencyMilliseconds: 140),
        recoveries: 2,
        activationFailures: 0
    )
    let mapped = StreamDiagnosticsInput.Audio(snapshot)

    let configuration = PCMJitterBuffer.Configuration.remotePlay
    let expectedCeiling = Double(configuration.maximumTargetFrames) * 1_000
        / Double(configuration.sampleRate)
    #expect(mapped.targetCeilingMilliseconds == expectedCeiling)
    #expect(mapped.engineRecoveries == 2)
    #expect(mapped.queue.underruns == 3)
}
