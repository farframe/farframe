import AVFoundation
import ExperienceDomain
import Foundation
import StreamingCore

public struct VideoPresentationRateSnapshot: Equatable, Sendable {
    public let counters: SampleBufferVideoPresentationSnapshot
    public let submittedFramesPerSecond: Double?
    public let enqueuedFramesPerSecond: Double?
}

/// Shared monotonic counter sampling. Rates measure submission/enqueue, not
/// display scan-out or transport loss. A surface/generation change starts fresh.
public struct VideoPresentationRateSampler {
    private var previous: SampleBufferVideoPresentationSnapshot?
    private var previousSurface: ObjectIdentifier?
    private var previousUptime: UInt64?

    public init() {}
    public mutating func reset() { self = Self() }

    public mutating func sample(
        _ counters: SampleBufferVideoPresentationSnapshot,
        surface: ObjectIdentifier,
        uptimeNanoseconds: UInt64
    ) -> VideoPresentationRateSnapshot {
        let old = previous
        let oldSurface = previousSurface
        let oldUptime = previousUptime
        previous = counters
        previousSurface = surface
        previousUptime = uptimeNanoseconds
        guard let generation = counters.activeGeneration,
              let old, old.activeGeneration == generation, oldSurface == surface,
              let oldUptime, uptimeNanoseconds > oldUptime,
              counters.framesSubmitted >= old.framesSubmitted,
              counters.framesEnqueued >= old.framesEnqueued else {
            return VideoPresentationRateSnapshot(counters: counters,
                submittedFramesPerSecond: nil, enqueuedFramesPerSecond: nil)
        }
        let seconds = Double(uptimeNanoseconds - oldUptime) / 1_000_000_000
        return VideoPresentationRateSnapshot(counters: counters,
            submittedFramesPerSecond: Double(counters.framesSubmitted - old.framesSubmitted) / seconds,
            enqueuedFramesPerSecond: Double(counters.framesEnqueued - old.framesEnqueued) / seconds)
    }
}

/// Provider-neutral capability for sessions that can present decoded video on
/// an Apple sample-buffer display surface.
public protocol SampleBufferVideoSurfaceSession: StreamingSession {
    var videoSurface: SampleBufferVideoSurfaceBinding { get }
}

/// Surface-only access to a session-owned presenter. Platform shells can bind
/// their display layer and read metrics, but cannot activate generations,
/// flush session state, or submit frames.
public final class SampleBufferVideoSurfaceBinding: @unchecked Sendable {
    private let presenter: BoundedSampleBufferVideoPresenter

    /// SwiftUI can create a replacement view before dismantling the prior one.
    /// Recording callbacks synchronously on MainActor and executing them through
    /// one FIFO tail preserves that ordering across every view coordinator.
    @MainActor private var operationTail: Task<Void, Never>?

    package init(presenter: BoundedSampleBufferVideoPresenter) {
        self.presenter = presenter
    }

    @MainActor
    public func attach(_ layer: AVSampleBufferDisplayLayer) {
        let predecessor = operationTail
        let presenter = self.presenter
        operationTail = Task { @MainActor in
            await predecessor?.value
            await presenter.attach(layer)
        }
    }

    @MainActor
    public func detach(_ layer: AVSampleBufferDisplayLayer) {
        let predecessor = operationTail
        let presenter = self.presenter
        operationTail = Task { @MainActor in
            await predecessor?.value
            await presenter.detach(layer)
        }
    }

    public func snapshot() -> SampleBufferVideoPresentationSnapshot {
        presenter.snapshot()
    }

    /// Platform shells call this from their scene-phase handling. Suspending
    /// only stops renderer submission; it never touches the session.
    public func setPresentationSuspended(_ suspended: Bool) {
        presenter.setPresentationSuspended(suspended)
    }

    /// Smooth-motion pacing; see `BoundedSampleBufferVideoPresenter`.
    public func setPacingEnabled(_ enabled: Bool) {
        presenter.setPacingEnabled(enabled)
    }

    /// Video enhancement; see `BoundedSampleBufferVideoPresenter`.
    public func setUpscaling(_ mode: StreamUpscaling) {
        presenter.setUpscaling(mode)
    }

    /// The hosting view reports its display layer's backing size in device
    /// pixels whenever it changes. `StreamUpscaling.automatic` uses it to skip
    /// the GPU pass while the video is drawn at or near its source size.
    public func setDisplayPixelSize(width: Int, height: Int) {
        presenter.setDisplayPixelSize(width: width, height: height)
    }

    /// Platform shells call this only after a real scene/app interruption. It
    /// recovers the renderer without gaining authority over session generations
    /// or restarting the provider transport.
    @MainActor
    public func recoverAfterInterruption() async -> SampleBufferVideoInterruptionRecovery {
        let predecessor = operationTail
        let presenter = self.presenter
        let recovery = Task { @MainActor in
            await predecessor?.value
            return await presenter.recoverAfterInterruption()
        }
        operationTail = Task { @MainActor in
            _ = await recovery.value
        }
        return await recovery.value
    }

    /// Session startup waits for surface work that was synchronously queued
    /// before Start. This barrier is intentionally unavailable to app targets.
    @MainActor
    package func synchronizeThroughCurrentOperations() async {
        await operationTail?.value
    }
}
