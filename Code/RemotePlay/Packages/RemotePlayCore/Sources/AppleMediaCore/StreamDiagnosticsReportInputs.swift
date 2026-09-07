import ExperienceDomain
import Foundation

/// Adapters from the live media snapshots to the shared report schema.
///
/// `StreamDiagnosticsReport` lives in `ExperienceDomain`, which cannot see the
/// media types, so the mapping belongs here. Doing it once also means the field
/// set a shell writes is not a per-shell transcription that can drift: every
/// platform gets the same counter in the same key from the same line of code.
extension StreamDiagnosticsReport.Audio {
    public init(_ snapshot: PCMAudioPlaybackSnapshot) {
        let queue = snapshot.queue
        self.init(
            received: queue.receivedBuffers,
            rendered: queue.renderedBuffers,
            dropped: queue.droppedBuffers,
            pressureDrops: queue.backpressureDrops,
            staleDrops: queue.stalePacketDrops,
            overflowDrops: queue.pendingOverflowDrops,
            schedulingDrops: queue.schedulingFailureDrops,
            queuedMilliseconds: queue.backlogMilliseconds,
            scheduledBuffers: queue.scheduledBuffers,
            highWaterMark: queue.highWaterMark,
            callbackGapP95Milliseconds: queue.callbackGapP95Milliseconds,
            workerWaitP95Milliseconds: queue.schedulerWaitP95Milliseconds,
            conversionP95Milliseconds: queue.conversionP95Milliseconds,
            outputLatencyMilliseconds: queue.outputLatencyMilliseconds,
            presentationLatencyMilliseconds: queue.presentationLatencyMilliseconds,
            recoveries: snapshot.recoveries,
            underruns: queue.underruns,
            targetLatencyMilliseconds: queue.targetLatencyMilliseconds,
            silenceMilliseconds: queue.silenceMilliseconds
        )
    }
}

extension StreamDiagnosticsReport.Video {
    public init(_ snapshot: VideoPresentationRateSnapshot) {
        let counters = snapshot.counters
        self.init(
            rendererFeedFramesPerSecond: snapshot.enqueuedFramesPerSecond,
            submittedFrames: counters.framesSubmitted,
            enqueuedFrames: counters.framesEnqueued,
            workerPressureDrops: counters.workerBackpressureDrops,
            rendererPressureDrops: counters.rendererBackpressureDrops,
            invalidTimingDrops: counters.invalidTimingDrops,
            flushRecoveries: counters.flushRecoveries,
            suspendedDrops: counters.suspendedDrops,
            pacingEnabled: counters.pacingEnabled,
            pacingTargetFrames: counters.pacingTargetFrames,
            pacingQueuedFrames: counters.pacingQueuedFrames,
            pacingUnderruns: counters.pacingUnderruns,
            pacingSkips: counters.pacingSkips
        )
    }
}

extension StreamDiagnosticsReport.Decoder {
    public init(_ diagnostics: HEVCDecoderDiagnostics) {
        self.init(
            samplesAdmitted: diagnostics.samplesAdmitted,
            framesDecoded: diagnostics.framesDecoded,
            queueDrops: diagnostics.backpressureDrops,
            keyframeRequests: diagnostics.keyframeRequests,
            sessionRebuilds: diagnostics.sessionRecoveries,
            decodeFailures: diagnostics.decodeFailures,
            maximumPendingFrames: diagnostics.maximumPendingFrames
        )
    }
}

extension StreamDiagnosticsReport.Sample {
    /// One point on the rolling timeline the shells keep alongside the
    /// cumulative counters. Absent sections stay nil rather than zero, so a
    /// reader can tell "not measured" from "measured as none".
    public init(
        capturedAt: Date,
        audio: PCMAudioPlaybackSnapshot?,
        video: VideoPresentationRateSnapshot?
    ) {
        self.init(
            capturedAt: capturedAt,
            audioReceived: audio?.queue.receivedBuffers,
            audioRendered: audio?.queue.renderedBuffers,
            audioDropped: audio?.queue.droppedBuffers,
            audioPressureDrops: audio?.queue.backpressureDrops,
            videoSubmitted: video?.counters.framesSubmitted,
            videoEnqueued: video?.counters.framesEnqueued,
            videoWorkerPressureDrops: video?.counters.workerBackpressureDrops,
            videoRendererPressureDrops: video?.counters.rendererBackpressureDrops,
            rendererFeedFramesPerSecond: video?.enqueuedFramesPerSecond
        )
    }
}

extension StreamDiagnosticsReport {
    /// The plain-language readout that sits above the raw counters, so the file
    /// opens with something a person can act on.
    public static func summaryLines(
        audio: PCMAudioPlaybackSnapshot?,
        videoCounters: SampleBufferVideoPresentationSnapshot?,
        decoder: HEVCDecoderDiagnostics?
    ) -> [String] {
        var lines: [String] = []
        if let queue = audio?.queue {
            let dropPercent = queue.receivedBuffers > 0
                ? Double(queue.droppedBuffers) / Double(queue.receivedBuffers) * 100 : 0
            lines.append(String(
                format: "Audio: %.1f%% of packets skipped (%d of %d), %d underruns, %.0f ms of silence, playout target %.0f ms, arrival gap p95 %.1f ms",
                dropPercent, queue.droppedBuffers, queue.receivedBuffers, queue.underruns,
                queue.silenceMilliseconds, queue.targetLatencyMilliseconds, queue.callbackGapP95Milliseconds
            ))
        }
        if let v = videoCounters {
            let drops = v.workerBackpressureDrops + v.rendererBackpressureDrops + v.invalidTimingDrops
            let dropPercent = v.framesSubmitted > 0 ? Double(drops) / Double(v.framesSubmitted) * 100 : 0
            lines.append(String(
                format: "Video: %.1f%% of decoded frames not shown (%llu of %llu), pacing %@ with a %d-frame lead, %llu pacing underruns, %llu frames skipped to catch up, %llu renderer flushes",
                dropPercent, drops, v.framesSubmitted, v.pacingEnabled ? "on" : "off",
                v.pacingTargetFrames, v.pacingUnderruns, v.pacingSkips, v.flushRecoveries
            ))
        }
        if let d = decoder {
            lines.append(String(
                format: "Decoder: %llu frames in, %llu out, %llu refused at the queue, %llu keyframes requested, %llu session rebuilds, %llu failures",
                d.samplesAdmitted, d.framesDecoded, d.backpressureDrops, d.keyframeRequests,
                d.sessionRecoveries, d.decodeFailures
            ))
        }
        lines.append("Reading: audio underruns and video pacing underruns are network stalls longer than the buffer; refused decoder frames or keyframe requests would be app-side; skipped audio and video are catch-up after bursts.")
        return lines
    }
}
