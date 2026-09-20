import AppleMediaCore
import ExperienceDomain
import FarframeCommerceUI
import Foundation
import FarframeStorefront
import GameController
import InputCore
import SwiftUI
import UIKit

/// The same health panel stays available after the flat window is dismissed.
struct VisionPlayerHealthHUD: View {
    @Bindable var coordinator: VisionRemotePlayCoordinator
    let mode: String
    let presentationIsActive: Bool
    var alwaysVisible = false
    var snapshotProvider: (() -> VisionPlayerDiagnostics?)? = nil
    @State private var diagnostics: VisionPlayerDiagnostics?
    private var isPresented: Bool { presentationIsActive && (alwaysVisible || coordinator.streamHealthHUDEnabled) }

    var body: some View {
        // A real container must own the task. A Group containing only an empty
        // conditional has no mounted child to start polling the first snapshot.
        VStack(alignment: .leading, spacing: 0) {
            if isPresented {
                if let diagnostics {
                    streamHealthOverlay(diagnostics)
                } else {
                    Text(coordinator.activeSessionID == nil ? "Stats appear while playing." : "Waiting for stream stats…")
                        .foregroundStyle(.secondary).padding(16)
                        .accessibilityIdentifier("farframe.stats.waiting")
                }
            }
        }
        .accessibilityIdentifier("farframe.stats.panel")
        .task(id: isPresented) {
            diagnostics = snapshotProvider?() ?? coordinator.playerDiagnosticsSnapshot()
            guard isPresented else { return }
            var diagnosticsTick = 0

            while Task.isCancelled == false {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                diagnostics = snapshotProvider?() ?? coordinator.playerDiagnosticsSnapshot()
                diagnosticsTick += 1
                #if DEBUG
                if diagnosticsTick.isMultiple(of: 4), let diagnostics {
                    let queue = diagnostics.audio.queue
                    print(
                        "[FARFRAME Audio] mode=\(mode) uptime=\(Int(ProcessInfo.processInfo.systemUptime)) in=\(queue.receivedBuffers) "
                            + "play=\(queue.renderedBuffers) "
                            + "queued=\(queue.backlogMilliseconds)ms "
                            + "target=\(Int(queue.targetLatencyMilliseconds))ms "
                            + "underruns=\(queue.underruns) "
                            + "silence=\(Int(queue.silenceMilliseconds))ms "
                            + "skip=\(queue.backpressureDrops) "
                            + "stale=\(queue.stalePacketDrops) "
                            + "overflow=\(queue.pendingOverflowDrops) "
                            + "gapP95=\(queue.callbackGapP95Milliseconds)ms "
                            + "waitP95=\(queue.schedulerWaitP95Milliseconds)ms "
                            + "conversionP95=\(queue.conversionP95Milliseconds)ms"
                    )
                    if let decoder = diagnostics.decoder {
                        print(
                            "[FARFRAME Video] mode=\(mode) uptime=\(Int(ProcessInfo.processInfo.systemUptime)) in=\(decoder.samplesAdmitted) "
                                + "out=\(decoder.framesDecoded) "
                                + "q=\(decoder.pendingFrames)/\(decoder.maximumPendingFrames) "
                                + "queueDrop=\(decoder.backpressureDrops) "
                                + "keyframeReq=\(decoder.keyframeRequests) "
                                + "rebuilds=\(decoder.sessionRecoveries) "
                                + "fail=\(decoder.decodeFailures) "
                                + "renderDrop=\(diagnostics.video.workerBackpressureDrops + diagnostics.video.rendererBackpressureDrops) "
                                + "suspended=\(diagnostics.video.suspendedDrops) "
                                + "pacing=\(diagnostics.video.pacingEnabled ? "on" : "off") "
                                + "paceQ=\(diagnostics.video.pacingQueuedFrames)/\(diagnostics.video.pacingTargetFrames) "
                                + "paceUnderruns=\(diagnostics.video.pacingUnderruns) "
                                + "paceSkips=\(diagnostics.video.pacingSkips)"
                        )
                    }
                }
                #endif
            }
        }
    }

    private func streamHealthOverlay(
        _ diagnostics: VisionPlayerDiagnostics
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stream Stats").accessibilityIdentifier("farframe.stats.loaded")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("Connected")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider().opacity(0.35)

            metricRow("Profile", diagnostics.quality.detail)
            metricRow("Decode", formattedDecoderStats(diagnostics.decoder))
            metricRow("Render", formattedVideoStats(diagnostics.video))
            metricRow("Pacing", formattedPacing(diagnostics.video))
            metricRow("Enhancement", formattedUpscaling(diagnostics.video))
            metricRow("Video Drops", formattedVideoDrops(diagnostics.video))
            metricRow("Audio", formattedAudioState(diagnostics.audio))
            if diagnostics.audio.state == .failed {
                Button("Restore Audio", systemImage: "speaker.wave.2") { coordinator.restoreAudioPlayback() }
                    .accessibilityIdentifier("farframe.audio.restore")
            }
            metricRow("Audio Queue", formattedAudioQueue(diagnostics.audio))
            metricRow("Audio Drops", formattedAudioDrops(diagnostics.audio))
            metricRow("Audio Timing", formattedAudioTiming(diagnostics.audio))
            metricRow("Audio Route", formattedAudioRoute(diagnostics.audio))
            metricRow(
                "Controller",
                diagnostics.controllerIsConnected
                    ? diagnostics.controllerName ?? "Connected"
                    : "Not Connected"
            )
            metricRow("Buttons", diagnostics.controllerHasInput ? "Active" : "Idle")
            metricRow("Mapping", "Standard · right Options · left Create")

            Divider().opacity(0.35)
            Toggle("Smooth Motion", isOn: $coordinator.smoothMotionEnabled)
                .font(.caption)
            Text("Changes immediately. Compare response and stalls in the same scene with this on and off. Copy Diagnosis for each setting.")
                .font(.caption2).foregroundStyle(.secondary)
            diagnosisRows(diagnostics.advice)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .foregroundStyle(.white)
    }

    /// The advisor's reading of the rows above: what the numbers mean and the
    /// first thing to try. This surface has room for the verdict and the top
    /// four findings, matching the Mobile and Mac panels. Anything past that is
    /// reachable through Copy Diagnosis, which puts every finding on the
    /// clipboard; there is no saved report on visionOS to point at instead.
    @ViewBuilder private func diagnosisRows(
        _ advice: StreamDiagnosticsAdvice
    ) -> some View {
        Text(advice.headline)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(advice.findings.prefix(4)) { finding in
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(severityColor(finding.severity))
                        .frame(width: 7, height: 7)
                    Text(finding.title)
                        .font(.caption2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let first = finding.actions.first {
                    Text("Try first: \(first.text)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if advice.findings.count > 4 {
            Text("\(advice.findings.count - 4) more. Use Copy Diagnosis for all of them.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func severityColor(_ severity: StreamDiagnosticsSeverity) -> Color {
        switch severity {
        case .healthy: .green
        case .informational: .white.opacity(0.6)
        case .watch: .yellow
        case .warning: .orange
        case .critical: .red
        }
    }

    private func formattedVideoStats(
        _ stats: SampleBufferVideoPresentationSnapshot
    ) -> String {
        guard stats.framesSubmitted > 0 else { return "--" }
        let drops = videoDropCount(stats)
        let percent = Double(drops) / Double(stats.framesSubmitted) * 100
        return "q \(stats.framesEnqueued)/\(stats.framesSubmitted) drop \(drops) (\(String(format: "%.1f", percent))%) flush \(stats.flushRecoveries)"
    }

    private func formattedDecoderStats(_ stats: HEVCDecoderDiagnostics?) -> String {
        guard let stats, stats.samplesAdmitted > 0 else { return "--" }
        return "in \(stats.samplesAdmitted) out \(stats.framesDecoded) q \(stats.pendingFrames)/\(stats.maximumPendingFrames) · queue-drop \(stats.backpressureDrops) · keyframe req \(stats.keyframeRequests) · rebuilds \(stats.sessionRecoveries) · fail \(stats.decodeFailures)"
    }

    private func formattedPacing(_ stats: SampleBufferVideoPresentationSnapshot) -> String {
        guard stats.pacingEnabled else { return "off (lowest latency)" }
        return "q \(stats.pacingQueuedFrames)/\(stats.pacingTargetFrames) frames · underruns \(stats.pacingUnderruns) · skipped \(stats.pacingSkips)"
    }

    private func formattedUpscaling(
        _ stats: SampleBufferVideoPresentationSnapshot
    ) -> String {
        guard stats.upscaling != .off else { return "off" }
        let upscaler = stats.upscaler
        guard upscaler.outputWidth > 0 else {
            return "\(stats.upscaling.displayName) · starting"
        }
        let gpu = String(format: "%.2f", upscaler.lastGPUMilliseconds)
        return "\(stats.upscaling.displayName) · \(upscaler.backendName)"
            + " \(upscaler.outputWidth)x\(upscaler.outputHeight)"
            + " · up \(upscaler.framesUpscaled) pass \(upscaler.framesPassedThrough)"
            + " fail \(upscaler.upscaleFailures) · gpu \(gpu)ms"
            + (upscaler.disabled ? " · DISABLED" : "")
    }

    private func formattedVideoDrops(
        _ stats: SampleBufferVideoPresentationSnapshot
    ) -> String {
        "worker \(stats.workerBackpressureDrops), renderer \(stats.rendererBackpressureDrops), timing \(stats.invalidTimingDrops)"
    }

    private func videoDropCount(
        _ stats: SampleBufferVideoPresentationSnapshot
    ) -> UInt64 {
        stats.staleGenerationDrops
            + stats.noSurfaceDrops
            + stats.workerBackpressureDrops
            + stats.rendererBackpressureDrops
            + stats.invalidTimingDrops
    }

    private func formattedAudioState(_ snapshot: PCMAudioPlaybackSnapshot) -> String {
        let state = switch snapshot.state {
        case .inactive: "Inactive"
        case .activating: "Starting"
        case .playing: "Playing"
        case .recovering: "Recovering"
        case .failed: "Failed"
        }
        guard let format = snapshot.negotiatedFormat else { return state }
        return "\(state) · \(format.channelCount)ch · \(format.sampleRate)Hz"
    }

    private func formattedAudioQueue(_ snapshot: PCMAudioPlaybackSnapshot) -> String {
        let queue = snapshot.queue
        return "\(queue.backlogMilliseconds)ms of \(Int(queue.targetLatencyMilliseconds))ms target · in \(queue.receivedBuffers) play \(queue.renderedBuffers) drop \(queue.droppedBuffers)"
    }

    private func formattedAudioDrops(_ snapshot: PCMAudioPlaybackSnapshot) -> String {
        let queue = snapshot.queue
        return "underruns \(queue.underruns) · silence \(Int(queue.silenceMilliseconds))ms · skipped \(queue.backpressureDrops) · stale \(queue.stalePacketDrops) · overflow \(queue.pendingOverflowDrops)"
    }

    private func formattedAudioTiming(_ snapshot: PCMAudioPlaybackSnapshot) -> String {
        let queue = snapshot.queue
        return "gap \(String(format: "%.1f", queue.callbackGapP95Milliseconds))ms wait \(String(format: "%.1f", queue.schedulerWaitP95Milliseconds))ms conv \(String(format: "%.2f", queue.conversionP95Milliseconds))ms"
    }

    private func formattedAudioRoute(_ snapshot: PCMAudioPlaybackSnapshot) -> String {
        let queue = snapshot.queue
        return "\(Int(queue.sampleRate))Hz io \(String(format: "%.1f", queue.ioBufferDurationMilliseconds))ms dev \(String(format: "%.1f", queue.outputLatencyMilliseconds))ms"
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .frame(width: 100, alignment: .leading)
                .foregroundStyle(.white.opacity(0.62))
            Spacer()
            Text(value)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }
}
