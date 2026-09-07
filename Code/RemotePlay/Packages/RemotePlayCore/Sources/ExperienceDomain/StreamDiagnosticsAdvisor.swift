import Foundation

// MARK: - Vocabulary

public enum StreamDiagnosticsSeverity: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
    /// Nothing in the numbers needs the user's attention.
    case healthy
    /// Worth knowing, no action required.
    case informational
    /// A real signal, but small enough that it may not be audible or visible.
    case watch
    /// The user is probably noticing this.
    case warning
    /// The stream is broken or about to be.
    case critical

    private var order: Int {
        switch self {
        case .healthy: 0
        case .informational: 1
        case .watch: 2
        case .warning: 3
        case .critical: 4
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }

    public var title: String {
        switch self {
        case .healthy: "Healthy"
        case .informational: "For information"
        case .watch: "Worth watching"
        case .warning: "Needs attention"
        case .critical: "Broken"
        }
    }
}

/// How well the measured counters separate one cause from the alternatives.
///
/// A confidently wrong diagnosis is worse than an honest "these numbers cannot
/// tell the two apart", so every finding declares which of these it is and the
/// text says what the other candidate causes are.
public enum StreamDiagnosticsConfidence: String, Codable, Hashable, Sendable {
    /// The counters can only be produced by this cause.
    case confirmed
    /// One cause fits the evidence much better than the alternatives.
    case likely
    /// Two or more causes fit the same numbers. The finding names them all.
    case ambiguous
    /// There is not enough of a session recorded to draw any conclusion.
    case insufficient
}

public enum StreamDiagnosticsArea: String, Codable, Hashable, Sendable {
    case audio
    case video
    case decoder
    case network
    case device
    case session
}

public enum StreamDiagnosticsThermalState: String, Codable, Hashable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    /// Accepts the lowercase strings the shells already put in their reports.
    public init(reportValue: String) {
        self = StreamDiagnosticsThermalState(rawValue: reportValue) ?? .unknown
    }
}

public enum StreamDiagnosticsNetworkInterface: String, Codable, Hashable, Sendable {
    case wifi
    case wiredEthernet = "wired-ethernet"
    case cellular
    case loopback
    case other
    case unknown

    /// Accepts the strings `MobileConnectionNetworkSnapshot` already records.
    public init(reportValue: String) {
        self = StreamDiagnosticsNetworkInterface(rawValue: reportValue) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .wiredEthernet: "wired Ethernet"
        case .cellular: "cellular"
        case .loopback: "loopback"
        case .other: "an unrecognised interface"
        case .unknown: "an unknown interface"
        }
    }
}

/// One thing the user can try. The array order is the ranking: cheapest and
/// most likely to help first.
public struct StreamDiagnosticsAction: Codable, Hashable, Sendable {
    public let text: String
    /// What the user gives up by doing this, when there is a real cost.
    public let tradeoff: String?

    public init(_ text: String, tradeoff: String? = nil) {
        self.text = text
        self.tradeoff = tradeoff
    }
}

/// One measurement quoted back to the user with its unit and meaning attached,
/// so the finding survives being pasted somewhere with no other context.
public struct StreamDiagnosticsEvidence: Codable, Hashable, Sendable {
    public let label: String
    public let value: String
    public let meaning: String

    public init(_ label: String, _ value: String, meaning: String) {
        self.label = label
        self.value = value
        self.meaning = meaning
    }
}

public struct StreamDiagnosticsFinding: Codable, Hashable, Sendable, Identifiable {
    /// Stable rule identifier. Safe for a reader to key on across versions.
    public let id: String
    public let title: String
    public let severity: StreamDiagnosticsSeverity
    public let area: StreamDiagnosticsArea
    public let confidence: StreamDiagnosticsConfidence
    /// What is happening, in the user's terms.
    public let what: String
    /// Why it is happening, including the causes the evidence cannot rule out.
    public let why: String
    public let evidence: [StreamDiagnosticsEvidence]
    /// Ranked cheapest and most likely to help first.
    public let actions: [StreamDiagnosticsAction]

    public init(
        id: String,
        title: String,
        severity: StreamDiagnosticsSeverity,
        area: StreamDiagnosticsArea,
        confidence: StreamDiagnosticsConfidence,
        what: String,
        why: String,
        evidence: [StreamDiagnosticsEvidence],
        actions: [StreamDiagnosticsAction]
    ) {
        self.id = id
        self.title = title
        self.severity = severity
        self.area = area
        self.confidence = confidence
        self.what = what
        self.why = why
        self.evidence = evidence
        self.actions = actions
    }
}

/// A counter explained once, so an exported report can be read by someone who
/// has never seen this codebase (or by an AI assistant the user pastes it into).
public struct StreamDiagnosticsMetricNote: Codable, Hashable, Sendable {
    public let name: String
    public let unit: String
    public let meaning: String
    public let normal: String

    public init(name: String, unit: String, meaning: String, normal: String) {
        self.name = name
        self.unit = unit
        self.meaning = meaning
        self.normal = normal
    }
}

public struct StreamDiagnosticsAdvice: Codable, Hashable, Sendable {
    /// One sentence a user can act on without reading anything else.
    public let headline: String
    public let overall: StreamDiagnosticsSeverity
    /// Highest severity first.
    public let findings: [StreamDiagnosticsFinding]
    /// How long a stretch of streaming the counters cover, when it is known or
    /// can be estimated. Nil means neither was possible.
    public let observedSeconds: Double?
    /// Whether the observed stretch was long enough for the rate-based rules.
    public let sampleIsAdequate: Bool

    public init(
        headline: String,
        overall: StreamDiagnosticsSeverity,
        findings: [StreamDiagnosticsFinding],
        observedSeconds: Double?,
        sampleIsAdequate: Bool
    ) {
        self.headline = headline
        self.overall = overall
        self.findings = findings
        self.observedSeconds = observedSeconds
        self.sampleIsAdequate = sampleIsAdequate
    }

    public var actionableFindings: [StreamDiagnosticsFinding] {
        findings.filter { $0.actions.isEmpty == false }
    }
}

// MARK: - Input

/// Everything the advisor is allowed to look at. Deliberately a value type with
/// no platform types in it: the media layer maps its live snapshots into this,
/// and the rules stay a pure function over structs.
///
/// Nothing here identifies a person, a console, or a network. The report built
/// from it is shareable by design.
public struct StreamDiagnosticsInput: Codable, Hashable, Sendable {
    public struct Audio: Codable, Hashable, Sendable {
        public let queue: AudioQueueSnapshot
        /// Times the audio engine was rebuilt mid-session.
        public let engineRecoveries: UInt64
        public let activationFailures: UInt64
        /// The jitter buffer's adaptive playout range, supplied by the media
        /// layer so the rules stay correct if the configuration changes.
        public let targetFloorMilliseconds: Double
        public let targetCeilingMilliseconds: Double
        public let initialTargetMilliseconds: Double

        public init(
            queue: AudioQueueSnapshot,
            engineRecoveries: UInt64 = 0,
            activationFailures: UInt64 = 0,
            targetFloorMilliseconds: Double = 40,
            targetCeilingMilliseconds: Double = 240,
            initialTargetMilliseconds: Double = 80
        ) {
            self.queue = queue
            self.engineRecoveries = engineRecoveries
            self.activationFailures = activationFailures
            self.targetFloorMilliseconds = targetFloorMilliseconds
            self.targetCeilingMilliseconds = targetCeilingMilliseconds
            self.initialTargetMilliseconds = initialTargetMilliseconds
        }
    }

    public struct Video: Codable, Hashable, Sendable {
        /// What the client-side enhancement pass actually did, as opposed to
        /// what the setting says. A user can select Enhanced and then have the
        /// pass fall back to a simpler backend, fail to be created at all, or
        /// latch itself off after a run of failures, and the setting still
        /// reads "Enhanced" throughout. These counters are the only way to
        /// tell, so the rules read them.
        public struct Upscaling: Codable, Hashable, Sendable {
            public let mode: StreamUpscaling
            /// `metalfx`, `lanczos`, or `none`. Stays `none` until the pass has
            /// built its pipeline, which happens on the first frame.
            public let backendName: String
            public let framesUpscaled: UInt64
            /// Frames that reached the display at the source resolution. In
            /// `automatic` this is expected; in `enhanced` it is not.
            public let framesPassedThrough: UInt64
            public let failures: UInt64
            /// The rolling-failure guard tripped and the pass is off for the
            /// rest of the session.
            public let isDisabled: Bool
            public let outputWidth: Int
            public let outputHeight: Int

            public init(
                mode: StreamUpscaling = .off,
                backendName: String = "none",
                framesUpscaled: UInt64 = 0,
                framesPassedThrough: UInt64 = 0,
                failures: UInt64 = 0,
                isDisabled: Bool = false,
                outputWidth: Int = 0,
                outputHeight: Int = 0
            ) {
                self.mode = mode
                self.backendName = backendName
                self.framesUpscaled = framesUpscaled
                self.framesPassedThrough = framesPassedThrough
                self.failures = failures
                self.isDisabled = isDisabled
                self.outputWidth = outputWidth
                self.outputHeight = outputHeight
            }

            /// Frames the pass was handed, whether or not it enhanced them.
            /// Zero after a real session means no pass was ever installed.
            public var framesHandled: UInt64 { framesUpscaled &+ framesPassedThrough }
        }

        public let framesSubmitted: UInt64
        public let framesEnqueued: UInt64
        public let workerBackpressureDrops: UInt64
        public let rendererBackpressureDrops: UInt64
        public let invalidTimingDrops: UInt64
        public let staleGenerationDrops: UInt64
        public let noSurfaceDrops: UInt64
        public let flushRecoveries: UInt64
        /// Frames refused because the scene was inactive. Any non-zero value
        /// means part of this session was not on screen.
        public let suspendedDrops: UInt64
        public let pacingEnabled: Bool
        public let pacingQueuedFrames: Int
        public let pacingTargetFrames: Int
        public let pacingFloorFrames: Int
        public let pacingCeilingFrames: Int
        public let pacingUnderruns: UInt64
        public let pacingSkips: UInt64
        public let enqueuedFramesPerSecond: Double?
        /// Nil when the shell does not report the enhancement pass at all, in
        /// which case every enhancement rule abstains.
        public let upscaling: Upscaling?

        public init(
            framesSubmitted: UInt64 = 0,
            framesEnqueued: UInt64 = 0,
            workerBackpressureDrops: UInt64 = 0,
            rendererBackpressureDrops: UInt64 = 0,
            invalidTimingDrops: UInt64 = 0,
            staleGenerationDrops: UInt64 = 0,
            noSurfaceDrops: UInt64 = 0,
            flushRecoveries: UInt64 = 0,
            suspendedDrops: UInt64 = 0,
            pacingEnabled: Bool = false,
            pacingQueuedFrames: Int = 0,
            pacingTargetFrames: Int = 0,
            pacingFloorFrames: Int = 2,
            pacingCeilingFrames: Int = 12,
            pacingUnderruns: UInt64 = 0,
            pacingSkips: UInt64 = 0,
            enqueuedFramesPerSecond: Double? = nil,
            upscaling: Upscaling? = nil
        ) {
            self.framesSubmitted = framesSubmitted
            self.framesEnqueued = framesEnqueued
            self.workerBackpressureDrops = workerBackpressureDrops
            self.rendererBackpressureDrops = rendererBackpressureDrops
            self.invalidTimingDrops = invalidTimingDrops
            self.staleGenerationDrops = staleGenerationDrops
            self.noSurfaceDrops = noSurfaceDrops
            self.flushRecoveries = flushRecoveries
            self.suspendedDrops = suspendedDrops
            self.pacingEnabled = pacingEnabled
            self.pacingQueuedFrames = pacingQueuedFrames
            self.pacingTargetFrames = pacingTargetFrames
            self.pacingFloorFrames = pacingFloorFrames
            self.pacingCeilingFrames = pacingCeilingFrames
            self.pacingUnderruns = pacingUnderruns
            self.pacingSkips = pacingSkips
            self.enqueuedFramesPerSecond = enqueuedFramesPerSecond
            self.upscaling = upscaling
        }

        /// Decoded frames the presenter received but never put on screen.
        public var framesNotShown: UInt64 {
            workerBackpressureDrops + rendererBackpressureDrops + invalidTimingDrops
        }
    }

    public struct Decoder: Codable, Hashable, Sendable {
        public let samplesAdmitted: UInt64
        public let framesDecoded: UInt64
        /// Samples refused because the in-flight queue was full.
        public let queueDrops: UInt64
        /// Ticks spent asking the console for a keyframe after a session loss.
        /// One tick is at most every 500 ms, so this is a recovery-duration
        /// counter, not a packet-loss counter.
        public let keyframeRequests: UInt64
        public let awaitingKeyframeDrops: UInt64
        public let sessionRebuilds: UInt64
        public let decodeFailures: UInt64
        public let pendingFrames: Int
        public let maximumPendingFrames: Int
        /// True right now: no picture is being produced until a keyframe lands.
        public let awaitingKeyframe: Bool
        /// Seconds between keyframe request ticks, from the decoder's policy.
        public let keyframeRequestIntervalSeconds: Double

        public init(
            samplesAdmitted: UInt64 = 0,
            framesDecoded: UInt64 = 0,
            queueDrops: UInt64 = 0,
            keyframeRequests: UInt64 = 0,
            awaitingKeyframeDrops: UInt64 = 0,
            sessionRebuilds: UInt64 = 0,
            decodeFailures: UInt64 = 0,
            pendingFrames: Int = 0,
            maximumPendingFrames: Int = 0,
            awaitingKeyframe: Bool = false,
            keyframeRequestIntervalSeconds: Double = 0.5
        ) {
            self.samplesAdmitted = samplesAdmitted
            self.framesDecoded = framesDecoded
            self.queueDrops = queueDrops
            self.keyframeRequests = keyframeRequests
            self.awaitingKeyframeDrops = awaitingKeyframeDrops
            self.sessionRebuilds = sessionRebuilds
            self.decodeFailures = decodeFailures
            self.pendingFrames = pendingFrames
            self.maximumPendingFrames = maximumPendingFrames
            self.awaitingKeyframe = awaitingKeyframe
            self.keyframeRequestIntervalSeconds = keyframeRequestIntervalSeconds
        }
    }

    public struct Environment: Codable, Hashable, Sendable {
        public let thermalState: StreamDiagnosticsThermalState
        public let lowPowerModeEnabled: Bool
        public let networkInterface: StreamDiagnosticsNetworkInterface
        public let networkIsConstrained: Bool
        public let networkIsExpensive: Bool
        /// The quality preset the user asked for, e.g. "1080p · 60 FPS · 12 Mbps".
        public let requestedQuality: String?
        public let requestedFramesPerSecond: Int?

        public init(
            thermalState: StreamDiagnosticsThermalState = .unknown,
            lowPowerModeEnabled: Bool = false,
            networkInterface: StreamDiagnosticsNetworkInterface = .unknown,
            networkIsConstrained: Bool = false,
            networkIsExpensive: Bool = false,
            requestedQuality: String? = nil,
            requestedFramesPerSecond: Int? = nil
        ) {
            self.thermalState = thermalState
            self.lowPowerModeEnabled = lowPowerModeEnabled
            self.networkInterface = networkInterface
            self.networkIsConstrained = networkIsConstrained
            self.networkIsExpensive = networkIsExpensive
            self.requestedQuality = requestedQuality
            self.requestedFramesPerSecond = requestedFramesPerSecond
        }
    }

    public let audio: Audio?
    public let video: Video?
    public let decoder: Decoder?
    public let environment: Environment
    /// Wall-clock seconds the counters cover, when the shell knows it. The
    /// advisor estimates it from frame counts when this is nil.
    public let observationWindowSeconds: Double?

    public init(
        audio: Audio? = nil,
        video: Video? = nil,
        decoder: Decoder? = nil,
        environment: Environment = Environment(),
        observationWindowSeconds: Double? = nil
    ) {
        self.audio = audio
        self.video = video
        self.decoder = decoder
        self.environment = environment
        self.observationWindowSeconds = observationWindowSeconds
    }
}

// MARK: - Engine

/// Turns one telemetry snapshot into a ranked, plain-English fix list.
///
/// Pure and synchronous: no UI, no I/O, no platform APIs, no clocks except the
/// date a caller hands in for the exported header. Every rule is grounded in a
/// counter this app actually increments; see the module documentation in
/// `Docs/` for the rules that were deliberately not written.
public enum StreamDiagnosticsAdvisor {
    /// Below this, the rate-based rules are suppressed: a handful of counters
    /// from a few seconds of play cannot support a diagnosis.
    public static let minimumObservationSeconds: Double = 20
    /// Fractions of the adaptive ranges that count as "pinned near the top".
    static let audioTargetHighFraction = 0.75
    static let pacingLeadHighFraction = 0.8

    public static func advise(_ input: StreamDiagnosticsInput) -> StreamDiagnosticsAdvice {
        let observed = observedSeconds(input)
        let adequate = isSampleAdequate(input, observedSeconds: observed)
        let context = Context(input: input, observedSeconds: observed, sampleIsAdequate: adequate)

        var findings: [StreamDiagnosticsFinding] = []

        // Device and path conditions apply whatever the sample size, because
        // they are states rather than accumulated counts.
        findings.append(contentsOf: [
            decoderStalledAwaitingKeyframe(context),
            decoderFailureStorm(context),
            thermalPressure(context),
            lowPowerMode(context),
            constrainedNetworkPath(context),
            audioActivationFailures(context),
            enhancementDisabled(context),
            enhancementFallbackBackend(context),
        ].compactMap { $0 })

        // Rate-based rules. Everything below reads an accumulated count and
        // divides it by the observed stretch, so none of it may run on a
        // sample too small to tell a real problem from normal start-up.
        if adequate {
            findings.append(contentsOf: [
                audioJitterTargetHigh(context),
                audioJitterAbsorbed(context),
                audioBurstSkips(context),
                audioRingOverflow(context),
                audioStalePackets(context),
                audioFormatRejects(context),
                audioEngineRecoveries(context),
                pacingLeadAtCeiling(context),
                pacingUnderruns(context),
                pacingSkips(context),
                rendererDrops(context),
                rendererFlushRecoveries(context),
                decoderQueueDrops(context),
                decoderSessionLoss(context),
                presentationSuspended(context),
                enhancementNotReachingFrames(context),
            ].compactMap { $0 })
        } else {
            findings.append(insufficientSample(context))
        }

        findings.sort { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.id < rhs.id
        }

        // The healthy verdict leads when nothing reached `.watch`. Informational
        // findings can sit under it: by construction none of them need fixing,
        // so the overall severity stays healthy rather than contradicting the
        // headline the user reads first.
        var isHealthy = false
        if findings.contains(where: { $0.severity >= .watch }) == false, adequate {
            findings.insert(healthy(context), at: 0)
            isHealthy = true
        }

        let overall = isHealthy ? .healthy : (findings.map(\.severity).max() ?? .healthy)
        return StreamDiagnosticsAdvice(
            headline: headline(for: findings, adequate: adequate),
            overall: overall,
            findings: findings,
            observedSeconds: observed,
            sampleIsAdequate: adequate
        )
    }

    // MARK: Context

    struct Context {
        let input: StreamDiagnosticsInput
        let observedSeconds: Double?
        let sampleIsAdequate: Bool

        var audio: StreamDiagnosticsInput.Audio? { input.audio }
        var video: StreamDiagnosticsInput.Video? { input.video }
        var decoder: StreamDiagnosticsInput.Decoder? { input.decoder }
        var environment: StreamDiagnosticsInput.Environment { input.environment }

        /// Events per minute, when the observation window is known.
        func perMinute(_ count: some BinaryInteger) -> Double? {
            guard let observedSeconds, observedSeconds > 0 else { return nil }
            return Double(count) / (observedSeconds / 60)
        }

        /// True when the audio jitter buffer also reported stalls, which is the
        /// strongest evidence that a video stall came from the network path
        /// rather than from this device.
        var audioAlsoUnderran: Bool { (audio?.queue.underruns ?? 0) > 0 }

        /// Any non-zero value means part of the measured window was spent with
        /// the scene inactive, so video ratios are overstated.
        var presentationWasSuspended: Bool { (video?.suspendedDrops ?? 0) > 0 }
    }

    // MARK: Sample sizing

    static func observedSeconds(_ input: StreamDiagnosticsInput) -> Double? {
        if let window = input.observationWindowSeconds, window > 0 { return window }
        if let video = input.video, video.framesSubmitted > 0 {
            let rate = Double(input.environment.requestedFramesPerSecond ?? 60)
            if rate > 0 { return Double(video.framesSubmitted) / rate }
        }
        if let audio = input.audio, audio.queue.receivedBuffers > 0 {
            // Remote Play delivers 10 ms PCM packets; this is an estimate and is
            // labelled as one wherever it is shown.
            return Double(audio.queue.receivedBuffers) * 0.01
        }
        return nil
    }

    static func isSampleAdequate(
        _ input: StreamDiagnosticsInput,
        observedSeconds: Double?
    ) -> Bool {
        guard let observedSeconds, observedSeconds >= minimumObservationSeconds else {
            return false
        }
        let videoFrames = input.video?.framesSubmitted ?? 0
        let audioPackets = input.audio?.queue.receivedBuffers ?? 0
        return videoFrames >= 300 || audioPackets >= 500
    }

    // MARK: Rules — session framing

    static func insufficientSample(_ context: Context) -> StreamDiagnosticsFinding {
        var evidence: [StreamDiagnosticsEvidence] = []
        if let seconds = context.observedSeconds {
            evidence.append(.init(
                "Measured stretch",
                format(seconds: seconds),
                meaning: "How much streaming these counters cover."
            ))
        }
        if let video = context.video {
            evidence.append(.init(
                "Decoded frames handed to the screen",
                "\(video.framesSubmitted)",
                meaning: "At 60 frames a second, one minute of play is about 3,600."
            ))
        }
        if let audio = context.audio {
            evidence.append(.init(
                "Audio packets received",
                "\(audio.queue.receivedBuffers)",
                meaning: "Each packet is about 10 ms of sound, so 6,000 is a minute."
            ))
        }
        return StreamDiagnosticsFinding(
            id: "session.insufficient-sample",
            title: "Not enough of a session to diagnose",
            severity: .informational,
            area: .session,
            confidence: .insufficient,
            what: "This report covers too short a stretch of streaming to tell a real problem from normal start-up.",
            why: "Every counter here starts at zero when the stream does. The first seconds of any session include priming the audio buffer and waiting for the first keyframe, so early numbers look alarming even on a perfect connection. The rate-based checks were skipped rather than run on a sample this small.",
            evidence: evidence,
            actions: [
                .init("Play for a minute or two, then save the report again."),
                .init("If a problem happens at a specific moment, save the report right after it, while the session is still running.")
            ]
        )
    }

    static func healthy(_ context: Context) -> StreamDiagnosticsFinding {
        var evidence: [StreamDiagnosticsEvidence] = []
        if let audio = context.audio {
            evidence.append(.init(
                "Audio underruns",
                "\(audio.queue.underruns)",
                meaning: "Times the speakers asked for sound the buffer did not have."
            ))
            evidence.append(.init(
                "Audio playout target",
                format(milliseconds: audio.queue.targetLatencyMilliseconds),
                meaning: "The delay the buffer is holding. It starts at \(format(milliseconds: audio.initialTargetMilliseconds)) and only rises after a stall."
            ))
        }
        if let video = context.video {
            evidence.append(.init(
                "Decoded frames not shown",
                "\(video.framesNotShown) of \(video.framesSubmitted)",
                meaning: "Frames the renderer received but could not display."
            ))
            if video.pacingEnabled {
                evidence.append(.init(
                    "Smooth motion stalls",
                    "\(video.pacingUnderruns)",
                    meaning: "Times the frame queue emptied at a display tick."
                ))
            }
        }
        if let decoder = context.decoder {
            evidence.append(.init(
                "Decoder frames refused",
                "\(decoder.queueDrops)",
                meaning: "Frames this device could not take because decoding was behind."
            ))
        }
        return StreamDiagnosticsFinding(
            id: "stream.healthy",
            title: "Your stream looks healthy",
            severity: .healthy,
            area: .session,
            confidence: .confirmed,
            what: "Nothing in these numbers points at a problem. Audio, video pacing and the decoder are all inside their normal ranges for this length of session.",
            why: "The counters that record real trouble, stalls, refused frames and dropped packets, are at or near zero. If the picture or sound still felt wrong, the cause is not something this app measures: a game's own frame rate, the TV or display's processing, or the controller itself are all outside these counters.",
            evidence: evidence,
            actions: []
        )
    }

    // MARK: Rules — audio

    static func audioJitterTargetHigh(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let audio = context.audio, audio.queue.underruns > 0 else { return nil }
        let target = audio.queue.targetLatencyMilliseconds
        let ceiling = audio.targetCeilingMilliseconds
        guard ceiling > 0, target >= ceiling * audioTargetHighFraction else { return nil }

        let severity: StreamDiagnosticsSeverity = target >= ceiling ? .warning : .watch
        var actions: [StreamDiagnosticsAction] = [
            .init("Move the device closer to the router, or move the router away from walls, metal and microwaves."),
            .init("Put the console on wired Ethernet. It is the single biggest fix, and it helps even when the problem looks like it is on the player's side."),
            .init("Stop anything else that is downloading, uploading or backing up on the same network."),
            .init("Use a 5 GHz Wi-Fi network rather than 2.4 GHz if both are available."),
        ]
        if context.environment.networkInterface == .wifi {
            actions.append(.init(
                "If the router supports it, put the console and this device on the same band and access point."
            ))
        }
        actions.append(.init(
            "Drop to a lower quality preset.",
            tradeoff: "A softer picture, in exchange for less data to move through the weak part of the path."
        ))

        return StreamDiagnosticsFinding(
            id: "audio.jitter.target-high",
            title: "Audio is holding extra delay to survive a jittery connection",
            severity: severity,
            area: .network,
            confidence: .likely,
            what: "Sound is intact, but it is arriving later than it needs to. The audio buffer has raised its delay to \(format(milliseconds: target)) out of a maximum of \(format(milliseconds: ceiling)) so that network stalls stop being audible.",
            why: "The buffer starts at \(format(milliseconds: audio.initialTargetMilliseconds)) and adds delay every time the network fails to deliver audio in time. It has done that \(audio.queue.underruns) time\(audio.queue.underruns == 1 ? "" : "s") this session, which means the path between the console and this device keeps pausing for longer than the buffer was holding. That is a property of the network, not of the app: the app's response was to trade latency for silence-free playback, and it worked.",
            evidence: [
                .init(
                    "Audio underruns",
                    "\(audio.queue.underruns)",
                    meaning: "Times the speakers asked for sound the buffer did not have. Each one adds delay."
                ),
                .init(
                    "Audio playout target",
                    "\(format(milliseconds: target)) of \(format(milliseconds: ceiling)) maximum",
                    meaning: "The delay the buffer holds so a stall of that length is inaudible."
                ),
                .init(
                    "Silence inserted",
                    format(milliseconds: audio.queue.silenceMilliseconds),
                    meaning: "Total sound the app had to invent while waiting, across the whole session."
                ),
                .init(
                    "Arrival gap, 95th percentile",
                    format(milliseconds: audio.queue.callbackGapP95Milliseconds),
                    meaning: "How far apart audio packets arrive in the worst 5% of cases. Steady delivery is about 10 ms."
                ),
            ],
            actions: actions
        )
    }

    static func audioJitterAbsorbed(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let audio = context.audio, audio.queue.underruns > 0 else { return nil }
        let ceiling = audio.targetCeilingMilliseconds
        guard ceiling <= 0 || audio.queue.targetLatencyMilliseconds < ceiling * audioTargetHighFraction
        else { return nil }

        return StreamDiagnosticsFinding(
            id: "audio.jitter.absorbed",
            title: "A few audio stalls, already absorbed",
            severity: .informational,
            area: .audio,
            confidence: .likely,
            what: "The connection paused a handful of times, the audio buffer covered it, and the extra delay it took on has mostly been given back.",
            why: "Each stall raises the playout delay, and five clean seconds start lowering it again. The delay sitting at \(format(milliseconds: audio.queue.targetLatencyMilliseconds)) rather than near its \(format(milliseconds: ceiling)) maximum says the stalls were occasional rather than constant. This is what a normal Wi-Fi session looks like.",
            evidence: [
                .init(
                    "Audio underruns",
                    "\(audio.queue.underruns)",
                    meaning: "Times the speakers asked for sound the buffer did not have."
                ),
                .init(
                    "Audio playout target",
                    "\(format(milliseconds: audio.queue.targetLatencyMilliseconds)) of \(format(milliseconds: ceiling)) maximum",
                    meaning: "Well below the ceiling, so the buffer is not fighting the network."
                ),
            ],
            actions: []
        )
    }

    static func audioBurstSkips(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let audio = context.audio, audio.queue.backpressureDrops > 0 else { return nil }
        guard let rate = context.perMinute(audio.queue.backpressureDrops), rate >= 6 else { return nil }

        return StreamDiagnosticsFinding(
            id: "audio.burst-skips",
            title: "Audio is arriving in bursts and being trimmed back",
            severity: rate >= 60 ? .watch : .informational,
            area: .network,
            confidence: .likely,
            what: "Sound is being delivered in clumps rather than steadily. When a clump leaves too much audio waiting, the app skips the oldest of it so the delay does not creep up for the rest of the session.",
            why: "This is the other half of a jittery path: nothing arrives for a stretch, then a dozen packets land at once. Skipping is the correct response, and each skip is short enough to be crossfaded, so it is usually inaudible. It becomes audible only when it happens constantly.",
            evidence: [
                .init(
                    "Audio packets skipped to recover delay",
                    "\(audio.queue.backpressureDrops) (about \(format(rate: rate)) a minute)",
                    meaning: "Packets discarded after a burst so the sound does not fall further behind."
                ),
                .init(
                    "Arrival gap, 95th percentile",
                    format(milliseconds: audio.queue.callbackGapP95Milliseconds),
                    meaning: "How far apart packets arrive in the worst 5% of cases. Steady delivery is about 10 ms."
                ),
            ],
            actions: [
                .init("Treat this the same as any Wi-Fi problem: closer to the router, 5 GHz, less other traffic."),
                .init("Wire the console to the router with Ethernet if you can."),
            ]
        )
    }

    static func audioRingOverflow(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let audio = context.audio, audio.queue.pendingOverflowDrops > 0 else { return nil }
        return StreamDiagnosticsFinding(
            id: "audio.ring-overflow",
            title: "Audio arrived faster than the buffer could hold",
            severity: .warning,
            area: .audio,
            confidence: .ambiguous,
            what: "Some sound was thrown away because the audio buffer was completely full when it arrived. This one can be audible as a click or a short gap.",
            why: "Two different things produce this and these counters cannot separate them. Either a delivery burst was larger than the buffer's whole capacity, which points at the network, or the audio hardware stopped pulling sound for long enough that the buffer filled behind it, which points at this device being busy or too hot. If the thermal state in this report is anything other than nominal, prefer the second explanation.",
            evidence: [
                .init(
                    "Audio dropped for lack of room",
                    "\(audio.queue.pendingOverflowDrops)",
                    meaning: "Packets discarded because the buffer had no space at all. Normal is 0."
                ),
                .init(
                    "Thermal state",
                    context.environment.thermalState.rawValue,
                    meaning: "Anything above nominal means the system is throttling this device."
                ),
            ],
            actions: [
                .init("Close other apps, especially anything recording, streaming or downloading."),
                .init("Let the device cool if it is warm, and take it out of any case."),
                .init("Disconnect and reconnect the stream. This clears the buffer and the audio engine."),
                .init(
                    "Drop to a lower quality preset.",
                    tradeoff: "A softer picture, in exchange for less work per second on this device."
                ),
            ]
        )
    }

    static func audioStalePackets(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let audio = context.audio, audio.queue.stalePacketDrops > 0 else { return nil }
        return StreamDiagnosticsFinding(
            id: "audio.stale-packets",
            title: "Some audio was too old to play by the time it reached the speakers",
            severity: .warning,
            area: .audio,
            confidence: .likely,
            what: "Sound arrived at the app but sat waiting inside this device long enough that playing it would have been worse than skipping it.",
            why: "This is measured after the audio is already here, so it is not the network. It means work on this device got in the way between receiving a packet and handing it to the audio buffer, which normally means the device is busy, throttling, or was interrupted by something else that wanted the audio hardware.",
            evidence: [
                .init(
                    "Audio packets discarded as too old",
                    "\(audio.queue.stalePacketDrops)",
                    meaning: "Packets that waited too long inside the app to be worth playing. Normal is 0."
                ),
                .init(
                    "Thermal state",
                    context.environment.thermalState.rawValue,
                    meaning: "Anything above nominal means the system is throttling this device."
                ),
                .init(
                    "Low power mode",
                    context.environment.lowPowerModeEnabled ? "on" : "off",
                    meaning: "Low power mode reduces processor speed and can starve real-time audio."
                ),
            ],
            actions: [
                .init("Turn off low power mode if it is on."),
                .init("Close other apps and stop any screen recording."),
                .init("Let the device cool down."),
            ]
        )
    }

    static func audioFormatRejects(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let audio = context.audio, audio.queue.invalidBuffers > 0 else { return nil }
        return StreamDiagnosticsFinding(
            id: "audio.format-rejects",
            title: "Some audio did not match the format the session negotiated",
            severity: .warning,
            area: .audio,
            confidence: .confirmed,
            what: "Audio arrived in a shape the player was not set up for and could not be played.",
            why: "The session agrees an audio format when it starts. Packets that do not match it are refused rather than played as noise. Seeing any of these means the stream changed format mid-session or the negotiated format was not what the console actually sent, which is an app or console problem rather than anything about your network.",
            evidence: [
                .init(
                    "Audio packets refused for format",
                    "\(audio.queue.invalidBuffers)",
                    meaning: "Packets whose channel count, sample rate or bit depth did not match the session. Normal is 0."
                ),
            ],
            actions: [
                .init("Disconnect and reconnect. A fresh session renegotiates the format."),
                .init("If it repeats every session, this is worth reporting, with this file attached."),
            ]
        )
    }

    static func audioEngineRecoveries(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let audio = context.audio, audio.engineRecoveries > 0 else { return nil }
        return StreamDiagnosticsFinding(
            id: "audio.engine-recoveries",
            title: "The audio engine restarted during the session",
            severity: audio.engineRecoveries >= 3 ? .watch : .informational,
            area: .audio,
            confidence: .ambiguous,
            what: "Audio playback was torn down and rebuilt \(audio.engineRecoveries) time\(audio.engineRecoveries == 1 ? "" : "s") while you were playing. Each rebuild is a short break in sound.",
            why: "Changing headphones, speakers or output device does this deliberately and is completely normal. So does another app taking the audio hardware, a phone call, or the system reconfiguring the route. These counters do not record which one happened, so a rebuild you caused and a rebuild that was forced on you look identical here.",
            evidence: [
                .init(
                    "Audio engine rebuilds",
                    "\(audio.engineRecoveries)",
                    meaning: "Times playback was restarted mid-session. Expected when you change output device."
                ),
            ],
            actions: [
                .init("If you did not change headphones or speakers, close other apps that use audio."),
                .init("Turn off anything that hands audio between devices automatically."),
            ]
        )
    }

    static func audioActivationFailures(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let audio = context.audio, audio.activationFailures > 0 else { return nil }
        return StreamDiagnosticsFinding(
            id: "audio.activation-failures",
            title: "Audio could not take the output device",
            severity: .warning,
            area: .audio,
            confidence: .likely,
            what: "The app tried to start playing sound and the system refused, \(audio.activationFailures) time\(audio.activationFailures == 1 ? "" : "s").",
            why: "Something else held the audio output, or the route it was handed was not usable. This is a system-level refusal rather than anything about the stream itself.",
            evidence: [
                .init(
                    "Audio session activation failures",
                    "\(audio.activationFailures)",
                    meaning: "Times the system refused to give this app the audio output. Normal is 0."
                ),
            ],
            actions: [
                .init("Quit other apps that play or record sound."),
                .init("Disconnect and reconnect your headphones or speakers, then reconnect the stream."),
            ]
        )
    }

    // MARK: Rules — video pacing and presentation

    static func pacingLeadAtCeiling(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let video = context.video, video.pacingEnabled else { return nil }
        let ceiling = video.pacingCeilingFrames
        guard ceiling > 0,
              Double(video.pacingTargetFrames) >= Double(ceiling) * pacingLeadHighFraction
        else { return nil }

        let fps = Double(context.environment.requestedFramesPerSecond ?? 60)
        let leadMilliseconds = fps > 0 ? Double(video.pacingTargetFrames) / fps * 1_000 : 0

        return StreamDiagnosticsFinding(
            id: "video.pacing.lead-at-ceiling",
            title: "Smooth motion is adding about \(format(milliseconds: leadMilliseconds)) of input lag",
            severity: .warning,
            area: .video,
            confidence: .confirmed,
            what: "Motion is being smoothed by holding \(video.pacingTargetFrames) frames back before showing them, which is near the maximum of \(ceiling). The picture looks fluid, but everything you do with the controller lands about \(format(milliseconds: leadMilliseconds)) later than it otherwise would.",
            why: "The pacer holds a small queue of frames so a network stall shows as steady motion instead of a freeze and a jump. Every stall makes it hold more, and it gives that back slowly, so on a path that stalls often it climbs to its ceiling and stays high. At that point the smoothing costs more than the stutter did. Aiming in shooters is where this is felt first. The held frames are not permanent: turning Smooth motion off and on again starts the count over.",
            evidence: [
                .init(
                    "Smooth motion lead",
                    "\(video.pacingTargetFrames) of \(ceiling) frames maximum",
                    meaning: "Frames held back before display. Each frame is about \(format(milliseconds: fps > 0 ? 1_000 / fps : 0)) of delay."
                ),
                .init(
                    "Smooth motion stalls",
                    "\(video.pacingUnderruns)",
                    meaning: "Times the queue emptied, which is what pushed the lead up."
                ),
            ],
            actions: [
                .init(
                    "Switch Smooth motion off and straight back on in Settings. The lead drops back to its smallest setting immediately and you keep the smoothing.",
                    tradeoff: "If the connection is still stalling often, the lead will climb again over the next few minutes."
                ),
                .init(
                    "Turn Smooth motion off in Settings if you are playing something that needs precise aim.",
                    tradeoff: "Motion gets less even on a jittery connection: stalls show as a freeze then a jump rather than as steady lag."
                ),
                .init("Improve the connection so the pacer stops needing the lead: wire the console, move closer to the router, or free up the network."),
                .init(
                    "Drop to a lower quality preset.",
                    tradeoff: "A softer picture, but fewer stalls to compensate for."
                ),
            ]
        )
    }

    static func pacingUnderruns(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let video = context.video, video.pacingEnabled, video.pacingUnderruns > 0 else {
            return nil
        }
        guard let rate = context.perMinute(video.pacingUnderruns), rate >= 1 else { return nil }

        // The strongest disambiguation available: if audio stalled too, one
        // shared delivery path stalled. If audio was clean, the same counters
        // are produced by console-to-device clock drift, and a cumulative
        // counter cannot say which, because it does not record when they fell.
        let networkWide = context.audioAlsoUnderran
        let severity: StreamDiagnosticsSeverity = rate >= 6 ? .warning : .watch

        let why: String
        let confidence: StreamDiagnosticsConfidence
        if networkWide {
            confidence = .likely
            why = "Audio stalled during this session too. Sound and picture travel the same path, so both running dry points at that path pausing rather than at either decoder or this device. The app's response, holding more frames and more sound, is the right one; it just cannot make the pauses stop."
        } else {
            confidence = .ambiguous
            why = "Video stalled but audio did not, and these counters cannot separate the two causes of that. It is either a delivery path that stalls for video specifically, or slow drift between the console's clock and this device's, which empties the frame queue on a long, regular cycle and is harmless. The difference is in when the stalls happened, and a running total does not record that. If the picture felt smooth, drift is the likely answer and there is nothing to fix."
        }

        return StreamDiagnosticsFinding(
            id: "video.pacing.underruns",
            title: networkWide
                ? "The connection is pausing long enough to empty the frame queue"
                : "The frame queue ran dry, and the cause is not decidable from these numbers",
            severity: networkWide ? severity : min(severity, .watch),
            area: networkWide ? .network : .video,
            confidence: confidence,
            what: "Smooth motion ran out of frames \(video.pacingUnderruns) time\(video.pacingUnderruns == 1 ? "" : "s"), about \(format(rate: rate)) a minute. Each one is a moment where the picture had nothing new to show.",
            why: why,
            evidence: [
                .init(
                    "Smooth motion stalls",
                    "\(video.pacingUnderruns) (about \(format(rate: rate)) a minute)",
                    meaning: "Times the frame queue was empty when the display asked for a frame."
                ),
                .init(
                    "Audio underruns",
                    "\(context.audio?.queue.underruns ?? 0)",
                    meaning: "The same measurement for sound. Both being non-zero points at the shared network path."
                ),
                .init(
                    "Smooth motion lead",
                    "\(video.pacingTargetFrames) of \(video.pacingCeilingFrames) frames maximum",
                    meaning: "How many frames are held back. It rises after each stall."
                ),
            ],
            actions: networkWide
                ? [
                    .init("Wire the console to the router with Ethernet."),
                    .init("Move this device closer to the router, and prefer 5 GHz Wi-Fi."),
                    .init("Stop other downloads, uploads and backups on the network."),
                    .init(
                        "Drop to a lower quality preset.",
                        tradeoff: "A softer picture, in exchange for a stream the path can carry."
                    ),
                ]
                : [
                    .init("If the picture looked smooth, no action is needed."),
                    .init("If it did not, save another report during a stretch where it looks wrong, so the two can be compared."),
                ]
        )
    }

    static func pacingSkips(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let video = context.video, video.pacingEnabled, video.pacingSkips > 0 else { return nil }
        guard let rate = context.perMinute(video.pacingSkips), rate >= 2 else { return nil }
        return StreamDiagnosticsFinding(
            id: "video.pacing.skips",
            title: "Video is arriving in bursts and being trimmed back",
            severity: .informational,
            area: .network,
            confidence: .likely,
            what: "Frames are turning up in clumps. When a clump leaves too many waiting, the oldest are dropped so the picture does not fall behind your controller.",
            why: "The same bursty delivery that affects audio. Dropping the backlog is the correct response, and it protects input latency. It is worth knowing about because it is the visible signature of a connection that delivers unevenly rather than slowly.",
            evidence: [
                .init(
                    "Frames skipped to catch up",
                    "\(video.pacingSkips) (about \(format(rate: rate)) a minute)",
                    meaning: "Queued frames dropped after a burst so the picture stays current."
                ),
            ],
            actions: [
                .init("Treat this as a Wi-Fi steadiness problem, not a bandwidth one: closer to the router, 5 GHz, less other traffic."),
            ]
        )
    }

    static func rendererDrops(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let video = context.video, video.framesSubmitted > 0 else { return nil }
        let dropped = video.framesNotShown
        guard dropped > 0 else { return nil }
        let percent = Double(dropped) / Double(video.framesSubmitted) * 100
        guard percent >= 1 else { return nil }

        let suspended = context.presentationWasSuspended
        return StreamDiagnosticsFinding(
            id: "video.renderer-drops",
            title: "Some decoded frames never reached the screen",
            severity: suspended ? .watch : (percent >= 5 ? .warning : .watch),
            area: .video,
            confidence: suspended ? .ambiguous : .likely,
            what: String(
                format: "%.1f%% of the frames that finished decoding were not displayed (%llu of %llu).",
                percent, dropped, video.framesSubmitted
            ),
            why: suspended
                ? "Part of this session was spent with the display not active, and frames refused during that time are counted here as well. That inflates this percentage by an unknown amount, so it cannot be read as a rendering problem until a report is captured from a session that stayed on screen throughout."
                : "The renderer refuses a frame when it is still busy with the previous one. That is a deliberate choice: dropping the newest frame keeps the picture current instead of building up lag. A steady few percent usually means this device is at its limit for the resolution and frame rate being asked of it.",
            evidence: [
                .init(
                    "Decoded frames not shown",
                    String(format: "%llu of %llu (%.1f%%)", dropped, video.framesSubmitted, percent),
                    meaning: "Frames the renderer received but skipped. Under about 1% is normal."
                ),
                .init(
                    "Frames refused while off screen",
                    "\(video.suspendedDrops)",
                    meaning: "Frames dropped because the window or headset display was not active. Any value above 0 makes the percentage above unreliable."
                ),
                .init(
                    "Thermal state",
                    context.environment.thermalState.rawValue,
                    meaning: "Anything above nominal means the system is throttling this device."
                ),
            ],
            actions: suspended
                ? [
                    .init("Save another report from a session you watched from start to finish, so this number means something."),
                ]
                : [
                    .init("Close other apps, especially anything using the GPU."),
                    .init("Let the device cool down, and take it out of any case."),
                    .init(
                        "Drop to a lower quality preset.",
                        tradeoff: "A softer picture, in exchange for frames this device can finish in time."
                    ),
                ]
        )
    }

    static func rendererFlushRecoveries(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let video = context.video, video.flushRecoveries > 0 else { return nil }
        guard let rate = context.perMinute(video.flushRecoveries), rate >= 1 else { return nil }
        return StreamDiagnosticsFinding(
            id: "video.flush-recoveries",
            title: "The video renderer had to reset itself repeatedly",
            severity: rate >= 6 ? .warning : .watch,
            area: .video,
            confidence: .likely,
            what: "The part of the app that puts frames on screen got into a state it could not continue from and was cleared \(video.flushRecoveries) time\(video.flushRecoveries == 1 ? "" : "s"). Each reset is a brief visible break.",
            why: "This happens when frames are handed over with timings the display layer rejects, or when the display layer fails behind the app's back. It is not a network measurement: the frames had already arrived and decoded by this point.",
            evidence: [
                .init(
                    "Renderer resets",
                    "\(video.flushRecoveries) (about \(format(rate: rate)) a minute)",
                    meaning: "Times the display layer was cleared and restarted. Normal is 0 or a small number at session start."
                ),
                .init(
                    "Frames with unusable timing",
                    "\(video.invalidTimingDrops)",
                    meaning: "Frames refused because their timestamps did not make sense."
                ),
            ],
            actions: [
                .init("Disconnect and reconnect the stream."),
                .init("If it happens every session, this is worth reporting, with this file attached."),
            ]
        )
    }

    static func presentationSuspended(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let video = context.video, video.suspendedDrops > 0 else { return nil }
        // The renderer-drops rule already explains the contamination when it
        // fires. This one exists for the case where drop rates were low.
        guard video.framesSubmitted == 0
            || Double(video.framesNotShown) / Double(video.framesSubmitted) * 100 < 1
        else { return nil }
        return StreamDiagnosticsFinding(
            id: "session.presentation-suspended",
            title: "Part of this session was not on screen",
            severity: .informational,
            area: .session,
            confidence: .confirmed,
            what: "Frames were refused because the window or headset display was inactive for a stretch of this session.",
            why: "Taking the headset off, switching apps or hiding the window all do this, and it is completely normal. It is called out because video percentages in this report cover that time as well, so they read slightly worse than what you actually watched.",
            evidence: [
                .init(
                    "Frames refused while off screen",
                    "\(video.suspendedDrops)",
                    meaning: "Frames dropped because nothing was being displayed."
                ),
            ],
            actions: []
        )
    }

    // MARK: Rules — video enhancement

    /// The pass gave up. This is a state, not a rate, so it is reported however
    /// short the session was: the setting will still read "Enhanced" and there
    /// is nothing else anywhere that tells the user otherwise.
    static func enhancementDisabled(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let upscaling = context.video?.upscaling,
              upscaling.mode != .off,
              upscaling.isDisabled else { return nil }
        return StreamDiagnosticsFinding(
            id: "video.enhancement.disabled",
            title: "Video Enhancement switched itself off",
            severity: .warning,
            area: .video,
            confidence: .confirmed,
            what: "Video Enhancement is still selected in Settings, but the GPU pass stopped after a run of failures and the picture is now reaching the screen exactly as the console sent it.",
            why: "The pass gives up after enough consecutive failures rather than retrying forever, because a failing pass costs GPU time and battery without improving anything. Playback was never at risk: every failed frame was shown in its original form. The pass stays off until the next connection.",
            evidence: [
                .init(
                    "Enhancement setting",
                    upscaling.mode.displayName,
                    meaning: "What was asked for. It does not change when the pass stops."
                ),
                .init(
                    "Enhancement failures",
                    "\(upscaling.failures)",
                    meaning: "Frames the GPU pass could not produce. Enough in a row turns the pass off."
                ),
                .init(
                    "Frames enhanced",
                    "\(upscaling.framesUpscaled)",
                    meaning: "Frames that did get the pass before it stopped."
                ),
            ],
            actions: [
                .init("Disconnect and reconnect. The pass is rebuilt from scratch on the next session."),
                .init("Let the device cool if it is warm; GPU work is the first thing to fail under thermal pressure."),
                .init(
                    "Set Video Enhancement to Off if it keeps happening.",
                    tradeoff: "The picture stays as the console sends it, which is what you are already getting."
                ),
            ]
        )
    }

    /// MetalFX was not available, so the simpler Lanczos tier is doing the work.
    /// Worth knowing and never worth acting on, hence informational.
    static func enhancementFallbackBackend(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let upscaling = context.video?.upscaling,
              upscaling.mode != .off,
              upscaling.isDisabled == false,
              upscaling.backendName == "lanczos",
              upscaling.framesUpscaled > 0 else { return nil }
        return StreamDiagnosticsFinding(
            id: "video.enhancement.fallback-backend",
            title: "Video Enhancement is running its simpler pass",
            severity: .informational,
            area: .video,
            confidence: .confirmed,
            what: "Enhancement is working, but on the fallback scaler rather than the higher-quality one. The difference is a slightly softer result, not a broken one.",
            why: "The preferred scaler needs hardware support this device or this build does not provide, so the pass was built on the simpler tier instead of being skipped altogether. This is a property of the device, not of the network or the console, and it will not change between sessions.",
            evidence: [
                .init(
                    "Enhancement backend",
                    upscaling.backendName,
                    meaning: "Which scaler is running. `metalfx` is the preferred one."
                ),
                .init(
                    "Frames enhanced",
                    "\(upscaling.framesUpscaled)",
                    meaning: "Frames the pass actually reconstructed."
                ),
            ],
            actions: []
        )
    }

    /// Enhancement is selected and frames are not getting it. Covers both the
    /// pass that could never be built and the pass that cannot keep up.
    static func enhancementNotReachingFrames(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let video = context.video,
              let upscaling = video.upscaling,
              upscaling.mode != .off,
              upscaling.isDisabled == false else { return nil }

        let handled = upscaling.framesHandled
        if handled == 0 {
            // No pass was ever installed, so no frame was even offered to one.
            // The pass is built asynchronously and needs a frame to size its
            // pipeline, so this must not be judged on a short session.
            guard video.framesSubmitted >= 300 else { return nil }
            return unavailableEnhancement(video: video, upscaling: upscaling)
        }

        // In `automatic` the pass deliberately steps aside when the video is
        // small, so passed-through frames there are the feature working as
        // designed and say nothing. Only `enhanced` promises every frame.
        guard upscaling.mode == .enhanced else { return nil }
        let ratio = Double(upscaling.framesPassedThrough) / Double(handled)
        guard ratio >= 0.05 else { return nil }
        let percent = ratio * 100

        return StreamDiagnosticsFinding(
            id: "video.enhancement.not-reaching-frames",
            title: "Video Enhancement is skipping a share of frames",
            severity: ratio >= 0.25 ? .warning : .watch,
            area: .video,
            confidence: .ambiguous,
            what: String(
                format: "Enhancement is set to always run, but %.1f%% of frames (%llu of %llu) reached the screen without it.",
                percent, upscaling.framesPassedThrough, handled
            ),
            why: "Two things produce this and these counters cannot separate them. Either the GPU pass is not finishing before the next frame arrives, so frames are handed straight through rather than queued behind it, or individual frames are failing and being shown in their original form. Either way the picture is inconsistent between enhanced and unenhanced frames, which can read as the sharpness flickering. Playback itself is never at risk.",
            evidence: [
                .init(
                    "Frames shown without enhancement",
                    "\(upscaling.framesPassedThrough) of \(handled)",
                    meaning: "In Enhanced this should be near zero; in Automatic it is expected."
                ),
                .init(
                    "Enhancement failures",
                    "\(upscaling.failures)",
                    meaning: "Above zero points at failing frames rather than a busy GPU."
                ),
                .init(
                    "Enhancement backend",
                    upscaling.backendName,
                    meaning: "Which scaler is running."
                ),
            ],
            actions: [
                .init(
                    "Switch Video Enhancement to Automatic.",
                    tradeoff: "The pass then runs only while the video is drawn large enough for it to be visible, which is where it helps most anyway."
                ),
                .init("Make the video window smaller, or close other apps using the GPU."),
                .init("Let the device cool if it is warm."),
                .init(
                    "Set Video Enhancement to Off.",
                    tradeoff: "A consistently unenhanced picture rather than an inconsistent one."
                ),
            ]
        )
    }

    private static func unavailableEnhancement(
        video: StreamDiagnosticsInput.Video,
        upscaling: StreamDiagnosticsInput.Video.Upscaling
    ) -> StreamDiagnosticsFinding {
        return StreamDiagnosticsFinding(
            id: "video.enhancement.unavailable",
            title: "Video Enhancement never started on this device",
            severity: .watch,
            area: .video,
            confidence: .confirmed,
            what: "Video Enhancement is selected, but no frame in this session went through the pass. The picture is reaching the screen exactly as the console sent it.",
            why: "The pass needs a usable GPU device to be created at all, and one was never available here. Nothing was lost: playback is unaffected and the setting costs nothing while it cannot run. It does mean the setting is not doing anything on this device.",
            evidence: [
                .init(
                    "Enhancement setting",
                    upscaling.mode.displayName,
                    meaning: "What was asked for."
                ),
                .init(
                    "Frames offered to the pass",
                    "0 of \(video.framesSubmitted)",
                    meaning: "Above 0 would mean the pass exists. Zero means it was never created."
                ),
            ],
            actions: [
                .init("Disconnect and reconnect; the pass is attempted again on the next session."),
                .init(
                    "Set Video Enhancement to Off.",
                    tradeoff: "None here. It is already having no effect on this device."
                ),
            ]
        )
    }

    // MARK: Rules — decoder

    static func decoderStalledAwaitingKeyframe(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let decoder = context.decoder, decoder.awaitingKeyframe else { return nil }
        return StreamDiagnosticsFinding(
            id: "decoder.awaiting-keyframe",
            title: "The picture is frozen while a fresh frame is requested",
            severity: .critical,
            area: .decoder,
            confidence: .confirmed,
            what: "Right now, no video is being produced. The decoder lost its session and is dropping everything until the console sends a complete picture it can restart from.",
            why: "Video is sent mostly as differences from previous frames, so once the decoder is reset it cannot use any of them. It asks the console for a complete frame twice a second and waits. This resolves itself in a second or two on a working connection. If it does not, the request or the reply is not getting through.",
            evidence: [
                .init(
                    "Waiting for a complete frame",
                    "yes",
                    meaning: "The decoder cannot produce a picture until one arrives."
                ),
                .init(
                    "Requests sent",
                    "\(decoder.keyframeRequests)",
                    meaning: "One roughly every \(format(milliseconds: decoder.keyframeRequestIntervalSeconds * 1_000)), so this counts how long has been spent waiting, across all recoveries this session."
                ),
                .init(
                    "Decoder restarts this session",
                    "\(decoder.sessionRebuilds)",
                    meaning: "Times the decoder had to be rebuilt from scratch."
                ),
            ],
            actions: [
                .init("Give it a few seconds. This usually clears itself."),
                .init("If you just took the headset off or switched apps, go back to the stream and it will recover."),
                .init("If the picture stays frozen, disconnect and reconnect."),
            ]
        )
    }

    static func decoderFailureStorm(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let decoder = context.decoder, decoder.decodeFailures > 0 else { return nil }
        // A handful of failures around a session change is ordinary. A storm is
        // the known off-screen case, where the decoder keeps feeding a session
        // the system has already invalidated.
        let offScreen = (context.video?.suspendedDrops ?? 0) > 0
        guard decoder.decodeFailures >= 30 else { return nil }
        let rate = context.perMinute(decoder.decodeFailures)

        return StreamDiagnosticsFinding(
            id: "decoder.failure-storm",
            title: offScreen
                ? "Video decoding kept failing while the stream was off screen"
                : "Video decoding is failing repeatedly",
            severity: .warning,
            area: .decoder,
            confidence: offScreen ? .likely : .ambiguous,
            what: "The decoder rejected \(decoder.decodeFailures) frames\(rate.map { " (about \(format(rate: $0)) a minute)" } ?? "") without producing a picture from them.",
            why: offScreen
                ? "This session spent time with nothing on screen, and in that state the decoder's hardware session becomes invalid while frames keep arriving. Each one fails. It is harmless to the picture, which comes back when you return, but it runs the processor hard the whole time, which is why the device gets warm during long breaks. This is a known issue being worked on."
                : "Failures at this rate without any period off screen mean either the incoming video is malformed or the hardware decoder is refusing work it should accept. These counters cannot tell those apart, and both are app or console side rather than network.",
            evidence: [
                .init(
                    "Decode failures",
                    "\(decoder.decodeFailures)",
                    meaning: "Frames the hardware decoder rejected. Normal is 0, or a handful around a reconnect."
                ),
                .init(
                    "Frames produced",
                    "\(decoder.framesDecoded) from \(decoder.samplesAdmitted) accepted",
                    meaning: "If failures are high while this stays flat, nothing is being decoded at all."
                ),
                .init(
                    "Frames refused while off screen",
                    "\(context.video?.suspendedDrops ?? 0)",
                    meaning: "Above 0 means the display was inactive for part of the session."
                ),
                .init(
                    "Decoder restarts this session",
                    "\(decoder.sessionRebuilds)",
                    meaning: "Times the decoder was rebuilt from scratch."
                ),
            ],
            actions: offScreen
                ? [
                    .init("Disconnect when you take a long break instead of leaving the stream running off screen. It saves battery and heat."),
                    .init("If the device is hot, let it cool before the next session."),
                ]
                : [
                    .init("Disconnect and reconnect the stream."),
                    .init("Let the device cool down if it is warm."),
                    .init("If it repeats every session, this is worth reporting, with this file attached."),
                ]
        )
    }

    static func decoderQueueDrops(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let decoder = context.decoder, decoder.queueDrops > 0 else { return nil }
        let percent = decoder.samplesAdmitted > 0
            ? Double(decoder.queueDrops) / Double(decoder.samplesAdmitted + decoder.queueDrops) * 100
            : 0
        return StreamDiagnosticsFinding(
            id: "decoder.queue-drops",
            title: "This device could not keep up with decoding",
            severity: percent >= 1 ? .warning : .watch,
            area: .decoder,
            confidence: .confirmed,
            what: String(
                format: "%llu incoming frames were refused because %d were already waiting to be decoded (%.2f%% of everything that arrived).",
                decoder.queueDrops, decoder.maximumPendingFrames, percent
            ),
            why: "The decoder holds a queue so that a burst of frames from a jittery connection can be absorbed. Filling that queue means frames are arriving faster than this device can decode them for a sustained stretch. Refused frames also break the chain the following frames depend on, which is what pixelation and blocky patches look like.",
            evidence: [
                .init(
                    "Frames refused at the decoder",
                    String(format: "%llu (%.2f%%)", decoder.queueDrops, percent),
                    meaning: "Frames dropped because the decode queue was full. Normal is 0."
                ),
                .init(
                    "Decode queue size",
                    "\(decoder.maximumPendingFrames) frames",
                    meaning: "How large a delivery burst the decoder can absorb before refusing."
                ),
                .init(
                    "Thermal state",
                    context.environment.thermalState.rawValue,
                    meaning: "Anything above nominal means the system is throttling this device."
                ),
                .init(
                    "Low power mode",
                    context.environment.lowPowerModeEnabled ? "on" : "off",
                    meaning: "Low power mode reduces processor and graphics speed."
                ),
            ],
            actions: [
                .init("Turn off low power mode if it is on."),
                .init("Close other apps, especially games, video and anything recording."),
                .init("Let the device cool down and take it out of any case."),
                .init(
                    "Drop to a lower quality preset, or to 30 frames a second.",
                    tradeoff: "A softer or less fluid picture, in exchange for a stream this device can decode in real time."
                ),
            ]
        )
    }

    static func decoderSessionLoss(_ context: Context) -> StreamDiagnosticsFinding? {
        guard let decoder = context.decoder,
              decoder.sessionRebuilds > 0,
              decoder.awaitingKeyframe == false
        else { return nil }
        let waitSeconds = Double(decoder.keyframeRequests) * decoder.keyframeRequestIntervalSeconds
        let offScreen = (context.video?.suspendedDrops ?? 0) > 0

        return StreamDiagnosticsFinding(
            id: "decoder.session-loss",
            title: "The video decoder was rebuilt \(decoder.sessionRebuilds) time\(decoder.sessionRebuilds == 1 ? "" : "s") during the session",
            severity: decoder.sessionRebuilds >= 3 ? .warning : .watch,
            area: .decoder,
            confidence: offScreen ? .likely : .ambiguous,
            what: "The picture went away and came back \(decoder.sessionRebuilds) time\(decoder.sessionRebuilds == 1 ? "" : "s"). Roughly \(format(seconds: waitSeconds)) in total was spent waiting for a complete frame before video resumed.",
            why: offScreen
                ? "The display was inactive for part of this session, which invalidates the hardware decoder. Taking the headset off, switching apps or locking the device all do it, and the rebuild on return is the app recovering correctly. If the breaks lined up with those moments, nothing is wrong."
                : "The hardware decoder was lost and rebuilt without the display ever going inactive, and these counters cannot say why. Interruptions from other apps, the system reclaiming the video hardware, and a malformed stream all produce exactly this. What can be said is that it is not a bandwidth problem: the frames were arriving.",
            evidence: [
                .init(
                    "Decoder restarts",
                    "\(decoder.sessionRebuilds)",
                    meaning: "Times the hardware decoder had to be rebuilt from scratch. Normal is 0."
                ),
                .init(
                    "Time spent waiting for a complete frame",
                    format(seconds: waitSeconds),
                    meaning: "Estimated from \(decoder.keyframeRequests) requests, one every \(format(milliseconds: decoder.keyframeRequestIntervalSeconds * 1_000)). This is recovery time, not a count of lost packets."
                ),
                .init(
                    "Frames refused while off screen",
                    "\(context.video?.suspendedDrops ?? 0)",
                    meaning: "Above 0 means the display went inactive, which explains the restarts."
                ),
            ],
            actions: offScreen
                ? [
                    .init("Nothing to fix if the breaks matched taking the headset off or leaving the app."),
                    .init("Disconnect during long breaks rather than leaving the stream running.")
                ]
                : [
                    .init("Close other apps that play video or use the camera."),
                    .init("Disconnect and reconnect the stream."),
                    .init("If it repeats with nothing else running, this is worth reporting, with this file attached."),
                ]
        )
    }

    // MARK: Rules — device and path

    static func thermalPressure(_ context: Context) -> StreamDiagnosticsFinding? {
        let state = context.environment.thermalState
        guard state == .serious || state == .critical else { return nil }
        return StreamDiagnosticsFinding(
            id: "device.thermal-pressure",
            title: "This device is too hot and is being slowed down",
            severity: state == .critical ? .critical : .warning,
            area: .device,
            confidence: .confirmed,
            what: "The system reports thermal state \"\(state.rawValue)\", which means it is actively reducing processor and graphics speed to cool down.",
            why: "Decoding and displaying 60 frames a second is sustained work, and a throttled device cannot always finish a frame before the next one arrives. Dropped frames, stutter and audio hiccups measured elsewhere in this report may all be downstream of this rather than separate problems, so fix this one first.",
            evidence: [
                .init(
                    "Thermal state",
                    state.rawValue,
                    meaning: "Reported by the system. Nominal and fair are fine; serious and critical mean active throttling."
                ),
                .init(
                    "Low power mode",
                    context.environment.lowPowerModeEnabled ? "on" : "off",
                    meaning: "Low power mode reduces speed further."
                ),
            ],
            actions: [
                .init("Take the device out of its case."),
                .init("Stop charging while you play, if you can."),
                .init("Move somewhere cooler and out of direct sun."),
                .init("Close other apps."),
                .init(
                    "Drop to a lower quality preset, or to 30 frames a second.",
                    tradeoff: "A softer or less fluid picture, but far less heat."
                ),
            ]
        )
    }

    static func lowPowerMode(_ context: Context) -> StreamDiagnosticsFinding? {
        guard context.environment.lowPowerModeEnabled else { return nil }
        return StreamDiagnosticsFinding(
            id: "device.low-power-mode",
            title: "Low power mode is on",
            severity: .informational,
            area: .device,
            confidence: .confirmed,
            what: "Low power mode is enabled on this device while streaming.",
            why: "It reduces processor and graphics speed and makes networking less aggressive. None of that is a problem on its own, but it lowers the ceiling for everything else in this report, so it is worth turning off before concluding anything about the network or the console.",
            evidence: [
                .init(
                    "Low power mode",
                    "on",
                    meaning: "System setting that trades performance for battery life."
                ),
            ],
            actions: [
                .init(
                    "Turn low power mode off while you play.",
                    tradeoff: "The battery drains faster."
                ),
            ]
        )
    }

    static func constrainedNetworkPath(_ context: Context) -> StreamDiagnosticsFinding? {
        let environment = context.environment
        let cellular = environment.networkInterface == .cellular
        guard cellular || environment.networkIsConstrained || environment.networkIsExpensive else {
            return nil
        }
        var reasons: [String] = []
        if cellular { reasons.append("this device is on cellular") }
        if environment.networkIsConstrained { reasons.append("the system has marked the connection as constrained, usually Low Data Mode") }
        if environment.networkIsExpensive { reasons.append("the system has marked the connection as metered") }

        return StreamDiagnosticsFinding(
            id: "network.constrained-path",
            title: "The connection is limited by a system setting, not just by speed",
            severity: .informational,
            area: .network,
            confidence: .confirmed,
            what: "The system reports that \(reasons.joined(separator: ", and ")).",
            why: "On a path marked this way, the system holds background and bulk traffic back, and a cellular path adds delay that varies far more than Wi-Fi does. Any stalls elsewhere in this report should be read against that before blaming the app or the console.",
            evidence: [
                .init(
                    "Network interface",
                    environment.networkInterface.displayName,
                    meaning: "How this device reached the console. Wired is steadiest, then Wi-Fi, then cellular."
                ),
                .init(
                    "Constrained",
                    environment.networkIsConstrained ? "yes" : "no",
                    meaning: "Low Data Mode or a similar system restriction is on."
                ),
                .init(
                    "Metered",
                    environment.networkIsExpensive ? "yes" : "no",
                    meaning: "The system treats data on this path as costly."
                ),
            ],
            actions: [
                .init("Turn off Low Data Mode for this network if it is on."),
                .init("Use Wi-Fi rather than cellular where you can."),
                .init(
                    "On cellular, use a lower quality preset.",
                    tradeoff: "A softer picture, but a stream that survives the variability."
                ),
            ]
        )
    }

    // MARK: Headline

    static func headline(
        for findings: [StreamDiagnosticsFinding],
        adequate: Bool
    ) -> String {
        guard adequate else {
            return "Not enough of a session was recorded to say anything useful yet."
        }
        guard let top = findings.first else {
            return "Your stream looks healthy."
        }
        switch top.severity {
        case .healthy:
            return "Your stream looks healthy. Nothing here needs fixing."
        case .informational:
            return "Nothing needs fixing. There are a couple of things worth knowing about."
        case .watch:
            return "Mostly healthy, with one thing worth watching: \(lowercasingFirstLetter(of: top.title))."
        case .warning:
            let others = findings.filter { $0.severity >= .warning }.count - 1
            let suffix = others > 0 ? " There \(others == 1 ? "is 1 other issue" : "are \(others) other issues") below." : ""
            return "\(top.title).\(suffix)"
        case .critical:
            return "\(top.title). Start here."
        }
    }

    // MARK: Glossary

    /// Every counter this advisor can quote, explained once. Included in the
    /// exported report so it can be read without this codebase.
    public static let metricNotes: [StreamDiagnosticsMetricNote] = [
        .init(
            name: "Audio underruns",
            unit: "count for the session",
            meaning: "Times the speakers asked for sound and the buffer had none. The buffer adds delay after each one so the next stall of that size is inaudible.",
            normal: "0 to a few in a ten-minute session on Wi-Fi. Steadily climbing means the path keeps pausing."
        ),
        .init(
            name: "Audio playout target",
            unit: "milliseconds",
            meaning: "The delay the audio buffer deliberately holds. It starts near 80 ms, rises 30 ms per underrun, and walks back down after five clean seconds.",
            normal: "80 to 120 ms on a good path. Near the maximum means the buffer is fighting a jittery connection."
        ),
        .init(
            name: "Audio packets skipped to recover delay",
            unit: "count for the session",
            meaning: "Sound discarded after a burst so that latency does not creep upward for the rest of the session.",
            normal: "A handful. Constant skipping means bursty delivery."
        ),
        .init(
            name: "Audio dropped for lack of room",
            unit: "count for the session",
            meaning: "Sound discarded because the buffer was completely full. Distinct from skipping, and can be audible.",
            normal: "0."
        ),
        .init(
            name: "Audio packets discarded as too old",
            unit: "count for the session",
            meaning: "Sound that reached the app but waited inside it too long to be worth playing. Measured after arrival, so it is about this device, not the network.",
            normal: "0."
        ),
        .init(
            name: "Arrival gap, 95th percentile",
            unit: "milliseconds",
            meaning: "How far apart audio packets arrive in the worst 5% of cases.",
            normal: "About 10 ms when delivery is steady. 25 to 100 ms is the signature of a jittery Wi-Fi path."
        ),
        .init(
            name: "Smooth motion lead",
            unit: "frames",
            meaning: "How many decoded frames are held back before display so that a network stall shows as steady motion rather than a freeze. Every frame of lead is added input lag.",
            normal: "2 to 4 frames. At or near the maximum, aiming feels heavy."
        ),
        .init(
            name: "Smooth motion stalls",
            unit: "count for the session",
            meaning: "Times the frame queue was empty when the display asked for a frame.",
            normal: "0 to a few. Note that slow clock drift between the console and this device also produces these, spread far apart, and is harmless."
        ),
        .init(
            name: "Frames skipped to catch up",
            unit: "count for the session",
            meaning: "Queued frames dropped after a delivery burst so the picture stays current with the controller.",
            normal: "A handful."
        ),
        .init(
            name: "Decoded frames not shown",
            unit: "count and percentage",
            meaning: "Frames that finished decoding but that the renderer skipped, usually because it was still busy with the previous one.",
            normal: "Under about 1%. Time spent off screen inflates this."
        ),
        .init(
            name: "Frames refused at the decoder",
            unit: "count for the session",
            meaning: "Frames dropped before decoding because the decode queue was full. These also break the chain later frames depend on, which looks like pixelation.",
            normal: "0."
        ),
        .init(
            name: "Decoder restarts",
            unit: "count for the session",
            meaning: "Times the hardware decoder was lost and rebuilt. The display going inactive is the usual cause.",
            normal: "0 in a session that stayed on screen."
        ),
        .init(
            name: "Requests for a complete frame",
            unit: "count for the session",
            meaning: "Sent at most twice a second while waiting to recover from a decoder restart. This measures how long recovery took. It is not a count of lost packets.",
            normal: "0, or a few per restart."
        ),
        .init(
            name: "Decode failures",
            unit: "count for the session",
            meaning: "Frames the hardware decoder rejected outright.",
            normal: "0, or a handful around a reconnect."
        ),
        .init(
            name: "Renderer resets",
            unit: "count for the session",
            meaning: "Times the display layer had to be cleared and restarted. Each is a brief visible break.",
            normal: "0, or one at session start."
        ),
        .init(
            name: "Frames enhanced",
            unit: "count for the session",
            meaning: "Frames the client-side Video Enhancement pass reconstructed on this device's GPU. The console still sends 1080p; this is presentation-side only.",
            normal: "Close to every frame when Enhancement is set to Enhanced. In Automatic it is only the frames drawn large enough to benefit."
        ),
        .init(
            name: "Frames shown without enhancement",
            unit: "count for the session",
            meaning: "Frames that reached the display at the source resolution because the pass did not run on them. This is the counter that explains a sharpness difference you can see.",
            normal: "Near zero in Enhanced. Any value is normal in Automatic, where the pass deliberately stands down for small windows."
        ),
        .init(
            name: "Enhancement failures",
            unit: "count for the session",
            meaning: "Frames the GPU pass could not produce. Each one is shown in its original form, so playback is never affected. Enough consecutive failures switch the pass off for the session.",
            normal: "0."
        ),
    ]

    // MARK: Shareable text

    /// A self-describing plain-text rendition of the advice, meant to be pasted
    /// somewhere with no other context, including into an AI assistant.
    ///
    /// Contains no account, console, network address or device identifier.
    public static func plainTextReport(
        _ advice: StreamDiagnosticsAdvice,
        input: StreamDiagnosticsInput,
        generatedAt: Date,
        appVersion: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("FARFRAME STREAM DIAGNOSIS")
        lines.append("Farframe streams a PlayStation 5 over the local network to this device.")
        lines.append("Generated \(iso8601(generatedAt)).")
        if let appVersion { lines.append("App version \(appVersion).") }
        lines.append("This report contains no account, console, network address or device identifier.")
        lines.append("")

        lines.append("VERDICT")
        lines.append(advice.headline)
        lines.append("Overall: \(advice.overall.rawValue) (\(advice.overall.title))")
        lines.append("")

        lines.append("WHAT WAS MEASURED")
        if let seconds = advice.observedSeconds {
            let estimated = input.observationWindowSeconds == nil ? ", estimated from frame counts" : ""
            lines.append("- Stretch of streaming covered: about \(format(seconds: seconds))\(estimated)")
        } else {
            lines.append("- Stretch of streaming covered: unknown")
        }
        if let quality = input.environment.requestedQuality {
            lines.append("- Quality requested: \(quality) (this is what was asked for, not a measurement of what was delivered)")
        }
        lines.append("- Network interface: \(input.environment.networkInterface.displayName)")
        lines.append("- Thermal state: \(input.environment.thermalState.rawValue)")
        lines.append("- Low power mode: \(input.environment.lowPowerModeEnabled ? "on" : "off")")
        lines.append("- Counters are cumulative from the moment the stream started.")
        lines.append("")

        if advice.findings.isEmpty {
            lines.append("FINDINGS: none.")
        } else {
            let total = advice.findings.count
            for (index, finding) in advice.findings.enumerated() {
                lines.append("FINDING \(index + 1) OF \(total) — \(finding.title)")
                lines.append("Severity: \(finding.severity.rawValue). Area: \(finding.area.rawValue). Confidence: \(finding.confidence.rawValue) (\(confidenceNote(finding.confidence))).")
                lines.append("What: \(finding.what)")
                lines.append("Why: \(finding.why)")
                if finding.evidence.isEmpty == false {
                    lines.append("Evidence:")
                    for item in finding.evidence {
                        lines.append("  - \(item.label): \(item.value) — \(item.meaning)")
                    }
                }
                if finding.actions.isEmpty {
                    lines.append("What to try: nothing. This one is informational.")
                } else {
                    lines.append("What to try, cheapest and most likely to help first:")
                    for (rank, action) in finding.actions.enumerated() {
                        var text = "  \(rank + 1). \(action.text)"
                        if let tradeoff = action.tradeoff {
                            text += " Trade-off: \(tradeoff)"
                        }
                        lines.append(text)
                    }
                }
                lines.append("")
            }
        }

        lines.append("HOW TO READ THESE NUMBERS")
        for note in metricNotes {
            lines.append("- \(note.name) (\(note.unit)): \(note.meaning) Normal: \(note.normal)")
        }
        lines.append("")
        lines.append("LIMITS OF THIS REPORT")
        lines.append("- Every number is a running total for the session. Nothing here records when an event happened, so a problem at one moment and the same problem spread evenly look identical.")
        lines.append("- Nothing here measures network bandwidth, packet loss, or round-trip time directly. Network conclusions are inferred from stalls in playback.")
        lines.append("- Requested quality is a request. There is no measurement of the resolution or bitrate the console actually sent.")
        lines.append("- Controller input timing is not measured at all.")
        return lines.joined(separator: "\n")
    }

    static func confidenceNote(_ confidence: StreamDiagnosticsConfidence) -> String {
        switch confidence {
        case .confirmed: "these counters can only be produced by this cause"
        case .likely: "one cause fits much better than the alternatives"
        case .ambiguous: "more than one cause fits; the alternatives are named above"
        case .insufficient: "there is not enough data to conclude anything"
        }
    }

    // MARK: Formatting

    static func format(milliseconds: Double) -> String {
        "\(Int(milliseconds.rounded())) ms"
    }

    static func format(seconds: Double) -> String {
        if seconds < 1 { return String(format: "%.1f seconds", seconds) }
        if seconds < 90 { return "\(Int(seconds.rounded())) seconds" }
        let minutes = seconds / 60
        return String(format: "%.1f minutes", minutes)
    }

    static func format(rate: Double) -> String {
        rate >= 10 ? "\(Int(rate.rounded()))" : String(format: "%.1f", rate)
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

extension StreamDiagnosticsAdvisor {
    /// Lets a finding title be spliced mid-sentence in the headline.
    static func lowercasingFirstLetter(of text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
