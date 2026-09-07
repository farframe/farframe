import Foundation

/// Why a report was written. `screenshot` is only reachable on the shells that
/// observe the system screenshot notification; the others simply never emit it.
public enum StreamDiagnosticsReportTrigger: String, Codable, Sendable {
    case manual
    case screenshot
    case sessionEnded = "session-ended"
}

/// The privacy-bounded stream health report every shell writes.
///
/// One schema, one version lineage. Before schema 5 the iPhone and Mac shells
/// each declared their own ~70-field mirror of this and both stamped them
/// `4`, so a consumer told "version 4" could not know which field set to
/// expect without also knowing which platform wrote the file. The two shapes
/// were not the same: Mac carried a `privacy` disclosure and the iPhone did
/// not, which meant a report shared from a phone said nothing about what it
/// contained while the identical action on a Mac did.
///
/// Schema 5 is that unification. Relative to a schema 4 file:
///
/// - `privacy` is now present on every platform, with the wording Mac already
///   used, so the disclosure is byte-identical to what schema 4 Macs wrote.
/// - `environment.audioOutputs` remains iOS-only and is simply absent
///   elsewhere. `AVAudioSession` has no macOS equivalent, so this is a real
///   platform difference rather than an oversight, and an absent optional key
///   is the honest encoding of it.
///
/// Everything schema 4 wrote is still written unchanged, so an older reader
/// keeps working by ignoring the added key.
public struct StreamDiagnosticsReport: Codable, Sendable {
    public struct Environment: Codable, Sendable {
        public let appVersion: String
        public let buildNumber: String
        public let operatingSystem: String
        public let deviceClass: String
        public let thermalState: String
        public let lowPowerModeEnabled: Bool
        /// iOS and visionOS only. The audio session route has no macOS
        /// equivalent, so this key is absent rather than empty on a Mac.
        public let audioOutputs: [String]?

        public init(
            appVersion: String,
            buildNumber: String,
            operatingSystem: String,
            deviceClass: String,
            thermalState: String,
            lowPowerModeEnabled: Bool,
            audioOutputs: [String]? = nil
        ) {
            self.appVersion = appVersion
            self.buildNumber = buildNumber
            self.operatingSystem = operatingSystem
            self.deviceClass = deviceClass
            self.thermalState = thermalState
            self.lowPowerModeEnabled = lowPowerModeEnabled
            self.audioOutputs = audioOutputs
        }
    }

    public struct Sample: Codable, Sendable {
        public let capturedAt: Date
        public let audioReceived: Int?
        public let audioRendered: Int?
        public let audioDropped: Int?
        public let audioPressureDrops: Int?
        public let videoSubmitted: UInt64?
        public let videoEnqueued: UInt64?
        public let videoWorkerPressureDrops: UInt64?
        public let videoRendererPressureDrops: UInt64?
        public let rendererFeedFramesPerSecond: Double?

        public init(
            capturedAt: Date,
            audioReceived: Int?,
            audioRendered: Int?,
            audioDropped: Int?,
            audioPressureDrops: Int?,
            videoSubmitted: UInt64?,
            videoEnqueued: UInt64?,
            videoWorkerPressureDrops: UInt64?,
            videoRendererPressureDrops: UInt64?,
            rendererFeedFramesPerSecond: Double?
        ) {
            self.capturedAt = capturedAt
            self.audioReceived = audioReceived
            self.audioRendered = audioRendered
            self.audioDropped = audioDropped
            self.audioPressureDrops = audioPressureDrops
            self.videoSubmitted = videoSubmitted
            self.videoEnqueued = videoEnqueued
            self.videoWorkerPressureDrops = videoWorkerPressureDrops
            self.videoRendererPressureDrops = videoRendererPressureDrops
            self.rendererFeedFramesPerSecond = rendererFeedFramesPerSecond
        }
    }

    public struct Audio: Codable, Sendable {
        public let received: Int
        public let rendered: Int
        public let dropped: Int
        public let pressureDrops: Int
        public let staleDrops: Int
        public let overflowDrops: Int
        public let schedulingDrops: Int
        public let queuedMilliseconds: Int
        public let scheduledBuffers: Int
        public let highWaterMark: Int
        public let callbackGapP95Milliseconds: Double
        public let workerWaitP95Milliseconds: Double
        public let conversionP95Milliseconds: Double
        public let outputLatencyMilliseconds: Double
        public let presentationLatencyMilliseconds: Double
        public let recoveries: UInt64
        public let underruns: Int
        public let targetLatencyMilliseconds: Double
        public let silenceMilliseconds: Double

        public init(
            received: Int,
            rendered: Int,
            dropped: Int,
            pressureDrops: Int,
            staleDrops: Int,
            overflowDrops: Int,
            schedulingDrops: Int,
            queuedMilliseconds: Int,
            scheduledBuffers: Int,
            highWaterMark: Int,
            callbackGapP95Milliseconds: Double,
            workerWaitP95Milliseconds: Double,
            conversionP95Milliseconds: Double,
            outputLatencyMilliseconds: Double,
            presentationLatencyMilliseconds: Double,
            recoveries: UInt64,
            underruns: Int,
            targetLatencyMilliseconds: Double,
            silenceMilliseconds: Double
        ) {
            self.received = received
            self.rendered = rendered
            self.dropped = dropped
            self.pressureDrops = pressureDrops
            self.staleDrops = staleDrops
            self.overflowDrops = overflowDrops
            self.schedulingDrops = schedulingDrops
            self.queuedMilliseconds = queuedMilliseconds
            self.scheduledBuffers = scheduledBuffers
            self.highWaterMark = highWaterMark
            self.callbackGapP95Milliseconds = callbackGapP95Milliseconds
            self.workerWaitP95Milliseconds = workerWaitP95Milliseconds
            self.conversionP95Milliseconds = conversionP95Milliseconds
            self.outputLatencyMilliseconds = outputLatencyMilliseconds
            self.presentationLatencyMilliseconds = presentationLatencyMilliseconds
            self.recoveries = recoveries
            self.underruns = underruns
            self.targetLatencyMilliseconds = targetLatencyMilliseconds
            self.silenceMilliseconds = silenceMilliseconds
        }
    }

    public struct Decoder: Codable, Sendable {
        public let samplesAdmitted: UInt64
        public let framesDecoded: UInt64
        public let queueDrops: UInt64
        public let keyframeRequests: UInt64
        public let sessionRebuilds: UInt64
        public let decodeFailures: UInt64
        public let maximumPendingFrames: Int

        public init(
            samplesAdmitted: UInt64,
            framesDecoded: UInt64,
            queueDrops: UInt64,
            keyframeRequests: UInt64,
            sessionRebuilds: UInt64,
            decodeFailures: UInt64,
            maximumPendingFrames: Int
        ) {
            self.samplesAdmitted = samplesAdmitted
            self.framesDecoded = framesDecoded
            self.queueDrops = queueDrops
            self.keyframeRequests = keyframeRequests
            self.sessionRebuilds = sessionRebuilds
            self.decodeFailures = decodeFailures
            self.maximumPendingFrames = maximumPendingFrames
        }
    }

    public struct Video: Codable, Sendable {
        public let rendererFeedFramesPerSecond: Double?
        public let submittedFrames: UInt64
        public let enqueuedFrames: UInt64
        public let workerPressureDrops: UInt64
        public let rendererPressureDrops: UInt64
        public let invalidTimingDrops: UInt64
        public let flushRecoveries: UInt64
        public let suspendedDrops: UInt64
        public let pacingEnabled: Bool
        public let pacingTargetFrames: Int
        public let pacingQueuedFrames: Int
        public let pacingUnderruns: UInt64
        public let pacingSkips: UInt64

        public init(
            rendererFeedFramesPerSecond: Double?,
            submittedFrames: UInt64,
            enqueuedFrames: UInt64,
            workerPressureDrops: UInt64,
            rendererPressureDrops: UInt64,
            invalidTimingDrops: UInt64,
            flushRecoveries: UInt64,
            suspendedDrops: UInt64,
            pacingEnabled: Bool,
            pacingTargetFrames: Int,
            pacingQueuedFrames: Int,
            pacingUnderruns: UInt64,
            pacingSkips: UInt64
        ) {
            self.rendererFeedFramesPerSecond = rendererFeedFramesPerSecond
            self.submittedFrames = submittedFrames
            self.enqueuedFrames = enqueuedFrames
            self.workerPressureDrops = workerPressureDrops
            self.rendererPressureDrops = rendererPressureDrops
            self.invalidTimingDrops = invalidTimingDrops
            self.flushRecoveries = flushRecoveries
            self.suspendedDrops = suspendedDrops
            self.pacingEnabled = pacingEnabled
            self.pacingTargetFrames = pacingTargetFrames
            self.pacingQueuedFrames = pacingQueuedFrames
            self.pacingUnderruns = pacingUnderruns
            self.pacingSkips = pacingSkips
        }
    }

    /// Schema 5 unifies the per-shell mirrors into this one type and adds
    /// `privacy` everywhere. See the type documentation for what changed.
    public static let currentSchemaVersion = 5

    /// The disclosure that ships inside every saved report. One string so the
    /// promise a user reads cannot differ between the device they saved it on
    /// and the device the person helping them reads it on.
    public static let privacyDisclosure =
        "No account identity, console credential, host address, MAC address, device identifier, or native log text is included."

    public let schemaVersion: Int
    public let createdAt: Date
    public let trigger: StreamDiagnosticsReportTrigger
    public let sessionState: String
    public let requestedQuality: String
    public let environment: Environment
    public let recentSamples: [Sample]
    public let audio: Audio?
    public let video: Video?
    /// Plain-language statement of what this file does and does not contain.
    public let privacy: String
    /// Decoder counters for the live session (nil once the session ended).
    public let decoder: Decoder?
    /// Plain-language readout of what matters; the raw fields above back it up.
    public let summary: [String]
    /// The ranked diagnosis. Each finding says what is happening, why, which
    /// numbers say so, and what the user can do, cheapest option first.
    public let advisor: StreamDiagnosticsAdvice?
    /// What each counter means and what normal looks like, so this file can be
    /// read, or handed to an AI assistant, with no other context.
    public let metricNotes: [StreamDiagnosticsMetricNote]

    public init(
        schemaVersion: Int = StreamDiagnosticsReport.currentSchemaVersion,
        createdAt: Date,
        trigger: StreamDiagnosticsReportTrigger,
        sessionState: String,
        requestedQuality: String,
        environment: Environment,
        recentSamples: [Sample],
        audio: Audio?,
        video: Video?,
        privacy: String = StreamDiagnosticsReport.privacyDisclosure,
        decoder: Decoder?,
        summary: [String],
        advisor: StreamDiagnosticsAdvice?,
        metricNotes: [StreamDiagnosticsMetricNote]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.trigger = trigger
        self.sessionState = sessionState
        self.requestedQuality = requestedQuality
        self.environment = environment
        self.recentSamples = recentSamples
        self.audio = audio
        self.video = video
        self.privacy = privacy
        self.decoder = decoder
        self.summary = summary
        self.advisor = advisor
        self.metricNotes = metricNotes
    }
}

public enum StreamDiagnosticsReportError: LocalizedError {
    case noMetrics

    public var errorDescription: String? {
        "No stream metrics are available yet."
    }
}
