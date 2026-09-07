import AVFoundation
import CoreMedia
import CoreVideo
import ExperienceDomain
import Foundation

public enum SampleBufferVideoPresentationError: Error, Equatable, Sendable {
    case invalidGeneration
    case invalidPresentationTime
    case formatDescriptionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
}

public enum SampleBufferVideoPresentationAdmission: Equatable, Sendable {
    case accepted
    case staleGeneration
    case notRunning
    case noSurface
    case backpressure
    /// The hosting scene is inactive; no GPU work may be submitted.
    case suspended
}

/// Result of reconciling a live presentation surface after the containing app
/// or scene temporarily lost permission to use video-rendering resources.
public enum SampleBufferVideoInterruptionRecovery: Equatable, Sendable {
    case notRunning
    case noSurface
    case recovered
}

public struct SampleBufferVideoPresentationSnapshot: Equatable, Sendable {
    public let activeGeneration: UInt64?
    public let framesSubmitted: UInt64
    public let framesEnqueued: UInt64
    public let staleGenerationDrops: UInt64
    public let noSurfaceDrops: UInt64
    public let workerBackpressureDrops: UInt64
    public let rendererBackpressureDrops: UInt64
    public let invalidTimingDrops: UInt64
    public let flushRecoveries: UInt64
    public let suspendedDrops: UInt64
    public let pacingEnabled: Bool
    public let pacingQueuedFrames: Int
    public let pacingTargetFrames: Int
    public let pacingUnderruns: UInt64
    public let pacingSkips: UInt64
    public let upscaling: StreamUpscaling
    public let upscaler: VideoUpscalerDiagnostics

    public init(
        activeGeneration: UInt64?,
        framesSubmitted: UInt64,
        framesEnqueued: UInt64,
        staleGenerationDrops: UInt64,
        noSurfaceDrops: UInt64,
        workerBackpressureDrops: UInt64,
        rendererBackpressureDrops: UInt64,
        invalidTimingDrops: UInt64,
        flushRecoveries: UInt64,
        suspendedDrops: UInt64 = 0,
        pacingEnabled: Bool = false,
        pacingQueuedFrames: Int = 0,
        pacingTargetFrames: Int = 0,
        pacingUnderruns: UInt64 = 0,
        pacingSkips: UInt64 = 0,
        upscaling: StreamUpscaling = .off,
        upscaler: VideoUpscalerDiagnostics = VideoUpscalerDiagnostics()
    ) {
        self.activeGeneration = activeGeneration
        self.framesSubmitted = framesSubmitted
        self.framesEnqueued = framesEnqueued
        self.staleGenerationDrops = staleGenerationDrops
        self.noSurfaceDrops = noSurfaceDrops
        self.workerBackpressureDrops = workerBackpressureDrops
        self.rendererBackpressureDrops = rendererBackpressureDrops
        self.invalidTimingDrops = invalidTimingDrops
        self.flushRecoveries = flushRecoveries
        self.suspendedDrops = suspendedDrops
        self.pacingEnabled = pacingEnabled
        self.pacingQueuedFrames = pacingQueuedFrames
        self.pacingTargetFrames = pacingTargetFrames
        self.pacingUnderruns = pacingUnderruns
        self.pacingSkips = pacingSkips
        self.upscaling = upscaling
        self.upscaler = upscaler
    }
}

/// Runs on the presenter's private serial presentation queue. The handler must
/// return promptly and must not synchronously call presenter surface methods;
/// schedule follow-up work in a separate `Task` instead.
public typealias SampleBufferVideoPresentationFailureHandler = @Sendable (
    UInt64,
    SampleBufferVideoPresentationError
) -> Void

enum SampleBufferPresentationBackendReadiness: Sendable {
    case ready
    case backpressure
    case requiresFlush
    case unavailable
}

protocol SampleBufferPresentationBackend: AnyObject, Sendable {
    var identity: ObjectIdentifier { get }

    func readiness() -> SampleBufferPresentationBackendReadiness
    func enqueue(_ sampleBuffer: CMSampleBuffer)
    func flush(
        removingDisplayedImage: Bool,
        completion: @escaping @Sendable () -> Void
    )
}

struct SampleBufferPresentationWorkSlot: Sendable {
    private(set) var owner: UInt64?
    private var nextToken: UInt64 = 1

    mutating func reserve() -> UInt64? {
        guard owner == nil else { return nil }
        let token = nextToken
        nextToken &+= 1
        if nextToken == 0 { nextToken = 1 }
        owner = token
        return token
    }

    mutating func release(ifOwnedBy token: UInt64) {
        guard owner == token else { return }
        owner = nil
    }

    mutating func reset() {
        owner = nil
    }
}

/// An off-main presenter for live decoded video with two modes.
///
/// Immediate (default): one-frame bounded. Admission is synchronous and never
/// creates more than one pending render job; renderer congestion drops frames
/// instead of accumulating latency.
///
/// Paced: frames wait in a short queue and a steady timer releases one per
/// frame period. Jittery Wi-Fi delivers video in bursts after stalls; shown
/// immediately, that is a freeze followed by a jump. Pacing holds a few frames
/// of lead so the stall is invisible, raises the lead after an underrun, and
/// skips ahead when a burst leaves too much queued. It is the video twin of
/// `PCMJitterBuffer`, costing about `pacingInitialTargetFrames` frames of
/// latency.
public final class BoundedSampleBufferVideoPresenter: @unchecked Sendable {
    /// Paced-mode policy in frames at the stream's frame rate.
    static let pacingInitialTargetFrames = 3
    static let pacingMinimumTargetFrames = 2
    static let pacingMaximumTargetFrames = 12
    static let pacingRaiseStepFrames = 2
    static let pacingSkipSlackFrames = 4
    /// Frames released without an underrun before the target drops by one.
    /// Five seconds at 60 fps. The raise is two frames and instant, so a long
    /// quiet window makes the lead a one-way ratchet: a Wi-Fi burst adds 33 ms
    /// of latency that a session never gives back, which is the aiming lag in
    /// `UP-024`. Five seconds of clean release is strong evidence the path
    /// recovered, and each step returns only one frame, so the lead walks down
    /// gradually instead of snapping and re-underrunning.
    static let pacingQuietWindowFrames = 300
    /// An underrun this long after the previous one is clock drift between the
    /// console and this device, not jitter; re-prime without raising the target.
    /// Measured by `pacingFramesSinceUnderrun`, which only an underrun resets.
    /// It used to share one counter with the step-down cadence below, and every
    /// step-down set that counter back to zero, so while the target was walking
    /// down the counter could never reach 3,600: drift was only ever detectable
    /// once the target had already reached the minimum. Effect was a delay, not
    /// a dead branch — 110 s of clean release before drift suppression armed,
    /// against the 60 s this constant states. Two jobs now use two counters.
    static let pacingDriftWindowFrames = 3_600
    static let pacingCapacityFrames = 18

    private enum Lifecycle {
        case inactive
        case activating
        case running
    }

    private struct Work: @unchecked Sendable {
        let frame: DecodedVideoFrame
        let epoch: UInt64
        let token: UInt64
    }

    private struct PacedFrame: @unchecked Sendable {
        let frame: DecodedVideoFrame
        let epoch: UInt64
    }

    private let lock = NSLock()
    private let presentationQueue = DispatchQueue(
        label: "com.unshackledpursuit.remoteplay.video-presentation",
        qos: .userInteractive
    )
    private let lifecycleGate = SampleBufferPresentationLifecycleGate()
    private let failureHandler: SampleBufferVideoPresentationFailureHandler

    // Lock-protected admission and metrics state.
    private var lifecycle: Lifecycle = .inactive
    private var activeGeneration: UInt64?
    private var epoch: UInt64 = 1
    private var workSlot = SampleBufferPresentationWorkSlot()
    private var surfaceAttached = false
    private var framesSubmitted: UInt64 = 0
    private var framesEnqueued: UInt64 = 0
    private var staleGenerationDrops: UInt64 = 0
    private var noSurfaceDrops: UInt64 = 0
    private var workerBackpressureDrops: UInt64 = 0
    private var rendererBackpressureDrops: UInt64 = 0
    private var invalidTimingDrops: UInt64 = 0
    private var flushRecoveries: UInt64 = 0
    private var suspendedDrops: UInt64 = 0
    private var presentationSuspended = false
    private var pacingEnabled = false
    private var pacedFrames: [PacedFrame] = []
    private var pacingTargetFrames = BoundedSampleBufferVideoPresenter.pacingInitialTargetFrames
    private var pacingPriming = true
    /// Released frames since the last underrun. Drift detection only.
    private var pacingFramesSinceUnderrun = 0
    /// Released frames since the target last moved or an underrun reset the
    /// streak. Step-down cadence only.
    private var pacingQuietFrames = 0
    private var pacingUnderruns: UInt64 = 0
    private var pacingSkips: UInt64 = 0
    private var pacingTimerRequested = false
    private let usesInternalPacingTimer: Bool
    private var upscalingMode: StreamUpscaling = .off
    /// The display layer's backing size in device pixels, as last reported by
    /// the platform shell. Zero means the shell has not reported one.
    private var displayPixelWidth = 0
    private var displayPixelHeight = 0
    /// Only the presentation queue installs or releases it, but the Stats
    /// surface reads its counters from the main actor, so the reference itself
    /// is lock protected like the rest of the metrics state.
    private var upscaler: MetalVideoUpscaler?

    // Presentation-queue-confined state.
    private var backend: (any SampleBufferPresentationBackend)?
    private var cachedFormatDescription: CMVideoFormatDescription?
    private var lastPresentationTimeStamp: CMTime?
    private var upscalerBuildInFlight = false
    /// Set once when this device cannot construct the pass at all. Section 9.4
    /// tier two: no retries, and playback continues on the original frames.
    private var upscalerUnavailable = false
    private var recoveryTask: Task<Void, Never>?
    private var recoveryTaskEpoch: UInt64?
    private var pacingTimer: DispatchSourceTimer?
    private var pacingTimerInterval: Double = 0

    public init(
        failureHandler: @escaping SampleBufferVideoPresentationFailureHandler = { _, _ in }
    ) {
        self.failureHandler = failureHandler
        self.usesInternalPacingTimer = true
    }

    /// Tests drive the pacing clock by hand through `advancePacingForTesting()`.
    init(
        usesInternalPacingTimer: Bool,
        failureHandler: @escaping SampleBufferVideoPresentationFailureHandler = { _, _ in }
    ) {
        self.failureHandler = failureHandler
        self.usesInternalPacingTimer = usesInternalPacingTimer
    }

    /// Begins a new stream generation only after all previously queued presenter
    /// work has drained and the old displayed image has been flushed.
    public func activate(generation: UInt64) async throws {
        guard generation > 0 else {
            throw SampleBufferVideoPresentationError.invalidGeneration
        }

        await lifecycleGate.perform { [self] in
            let nextEpoch = lock.withLock { () -> UInt64 in
                lifecycle = .activating
                activeGeneration = generation
                epoch &+= 1
                if epoch == 0 { epoch = 1 }
                return epoch
            }

            await flushBackend(removingDisplayedImage: true)

            lock.withLock {
                guard epoch == nextEpoch, activeGeneration == generation else { return }
                resetAdmissionStateLocked()
                // A new session gets a fresh read of the network. Mid-session
                // flush and interruption recovery deliberately keep the lead:
                // there the network has not changed, only our renderer.
                resetPacingAdaptationLocked()
                lifecycle = .running
            }
        }
    }

    /// Stops accepting immediately, then drains and flushes all previously
    /// accepted work before returning.
    public func deactivate(
        generation: UInt64,
        removingDisplayedImage: Bool = true
    ) async {
        await lifecycleGate.perform { [self] in
            let deactivationEpoch = lock.withLock { () -> UInt64? in
                guard activeGeneration == generation else { return nil }
                lifecycle = .inactive
                activeGeneration = nil
                epoch &+= 1
                if epoch == 0 { epoch = 1 }
                return epoch
            }
            guard let deactivationEpoch else { return }

            await flushBackend(removingDisplayedImage: removingDisplayedImage)
            lock.withLock {
                guard epoch == deactivationEpoch, activeGeneration == nil else { return }
                resetAdmissionStateLocked()
            }
            await performOnPresentationQueue { [self] in cancelPacingTimer() }
        }
    }

    /// Attaches a long-lived display layer. The backend keeps weak ownership of
    /// the layer while retaining its background-safe renderer handle, so SwiftUI
    /// view teardown remains authoritative.
    @MainActor
    public func attach(_ layer: AVSampleBufferDisplayLayer) async {
        await attach(backend: AVSampleBufferDisplayLayerBackend(layer: layer))
    }

    /// A late detach for an old SwiftUI view cannot detach a newer surface.
    @MainActor
    public func detach(_ layer: AVSampleBufferDisplayLayer) async {
        await detachBackend(identity: ObjectIdentifier(layer))
    }

    /// While the hosting scene is inactive (headset removed, another app's
    /// immersive space, background), no sample may reach the renderer: the
    /// system refuses GPU work from a background process and logs an error
    /// per frame. The session, decoder, audio, and controller keep running.
    public func setPresentationSuspended(_ suspended: Bool) {
        lock.withLock {
            presentationSuspended = suspended
            if suspended {
                // Whatever was waiting is stale by the time drawing resumes.
                pacedFrames.removeAll(keepingCapacity: true)
                pacingPriming = true
            }
        }
        guard suspended else { return }
        // An idle upscaler still holds a buffer pool worth tens of megabytes.
        // Give it back while the headset is off rather than holding it for a
        // session that may not resume for minutes.
        presentationQueue.async { [self] in
            lock.withLock { upscaler }?.releaseTransientResources()
        }
    }

    /// Client-side spatial reconstruction. Every failure path presents the
    /// original frame, so this can never be the reason playback stops.
    public func setUpscaling(_ mode: StreamUpscaling) {
        let changed = lock.withLock { () -> Bool in
            guard upscalingMode != mode else { return false }
            upscalingMode = mode
            return true
        }
        guard changed else { return }
        presentationQueue.async { [self] in
            // The cached format description encodes dimensions, pixel format,
            // and extensions, all of which change with the mode. The
            // buffer-matching check below would catch it on its own; resetting
            // here makes the transition explicit rather than incidental.
            cachedFormatDescription = nil
            guard mode != .off,
                  upscaler == nil,
                  upscalerBuildInFlight == false,
                  upscalerUnavailable == false else { return }
            upscalerBuildInFlight = true
            MetalVideoUpscaler.makeAsynchronously(
                deliveryQueue: presentationQueue
            ) { [weak self] built in
                guard let self else { return }
                upscalerBuildInFlight = false
                guard let built else {
                    upscalerUnavailable = true
                    return
                }
                lock.withLock {
                    guard upscalingMode != .off else { return }
                    upscaler = built
                }
            }
        }
    }

    /// The platform shell reports its display layer's backing size in device
    /// pixels. `automatic` needs it to know whether the video is being
    /// magnified enough for the pass to be worth running.
    public func setDisplayPixelSize(width: Int, height: Int) {
        lock.withLock {
            displayPixelWidth = max(0, width)
            displayPixelHeight = max(0, height)
        }
    }

    /// Paced mode trades a few frames of latency for smooth motion on jittery
    /// networks. Switching modes mid-session discards queued frames only.
    public func setPacingEnabled(_ enabled: Bool) {
        let shouldCancelTimer = lock.withLock { () -> Bool in
            guard pacingEnabled != enabled else { return false }
            pacingEnabled = enabled
            pacedFrames.removeAll(keepingCapacity: true)
            pacingPriming = true
            pacingTimerRequested = false
            if enabled { resetPacingAdaptationLocked() }
            return enabled == false
        }
        if shouldCancelTimer {
            presentationQueue.async { [self] in cancelPacingTimer() }
        }
    }

    /// Drives one pacing tick without the internal timer.
    func advancePacingForTesting() async {
        await performOnPresentationQueue { [self] in pacingTick() }
    }

    @discardableResult
    public func submit(
        _ frame: DecodedVideoFrame
    ) -> SampleBufferVideoPresentationAdmission {
        let result = lock.withLock {
            () -> (SampleBufferVideoPresentationAdmission, Work?) in
            framesSubmitted &+= 1
            guard lifecycle == .running else { return (.notRunning, nil) }
            guard activeGeneration == frame.generation else {
                staleGenerationDrops &+= 1
                return (.staleGeneration, nil)
            }
            guard presentationSuspended == false else {
                suspendedDrops &+= 1
                return (.suspended, nil)
            }
            guard surfaceAttached else {
                noSurfaceDrops &+= 1
                return (.noSurface, nil)
            }
            if pacingEnabled {
                pacedFrames.append(PacedFrame(frame: frame, epoch: epoch))
                if pacedFrames.count > Self.pacingCapacityFrames {
                    pacedFrames.removeFirst(pacedFrames.count - Self.pacingCapacityFrames)
                    pacingSkips &+= 1
                }
                return (.accepted, nil)
            }
            guard let workToken = workSlot.reserve() else {
                workerBackpressureDrops &+= 1
                return (.backpressure, nil)
            }
            return (
                .accepted,
                Work(frame: frame, epoch: epoch, token: workToken)
            )
        }
        if result.0 == .accepted, result.1 == nil {
            ensurePacingTimerIfNeeded(frameDuration: frame.duration)
            return .accepted
        }
        guard let work = result.1 else { return result.0 }

        presentationQueue.async { [self, work] in
            process(work)
            lock.withLock { workSlot.release(ifOwnedBy: work.token) }
        }
        return .accepted
    }

    private func ensurePacingTimerIfNeeded(frameDuration: CMTime) {
        guard usesInternalPacingTimer else { return }
        let shouldStart = lock.withLock { () -> Bool in
            guard pacingTimerRequested == false else { return false }
            pacingTimerRequested = true
            return true
        }
        guard shouldStart else { return }
        let seconds = frameDuration.seconds
        let interval = (seconds.isFinite && seconds > 1.0 / 121 && seconds < 1.0 / 23)
            ? seconds : 1.0 / 60
        presentationQueue.async { [self] in ensurePacingTimer(interval: interval) }
    }

    // Presentation-queue confined.
    private func ensurePacingTimer(interval: Double) {
        if pacingTimer != nil, abs(pacingTimerInterval - interval) < 0.000_1 { return }
        pacingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: presentationQueue)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in self?.pacingTick() }
        timer.resume()
        pacingTimer = timer
        pacingTimerInterval = interval
    }

    private func cancelPacingTimer() {
        pacingTimer?.cancel()
        pacingTimer = nil
        pacingTimerInterval = 0
        lock.withLock { pacingTimerRequested = false }
    }

    /// One frame period elapsed. Release the oldest queued frame, or hold while
    /// priming, or record an underrun when the queue ran dry.
    private func pacingTick() {
        let next: PacedFrame? = lock.withLock {
            guard lifecycle == .running, pacingEnabled, presentationSuspended == false else {
                return nil
            }
            if pacingPriming {
                guard pacedFrames.count >= pacingTargetFrames else { return nil }
                pacingPriming = false
            }
            guard pacedFrames.isEmpty == false else {
                pacingUnderruns &+= 1
                pacingPriming = true
                if pacingFramesSinceUnderrun < Self.pacingDriftWindowFrames {
                    pacingTargetFrames = min(
                        Self.pacingMaximumTargetFrames,
                        pacingTargetFrames + Self.pacingRaiseStepFrames
                    )
                }
                pacingFramesSinceUnderrun = 0
                pacingQuietFrames = 0
                return nil
            }
            let released = pacedFrames.removeFirst()
            let ceiling = pacingTargetFrames + Self.pacingSkipSlackFrames
            if pacedFrames.count > ceiling {
                let excess = pacedFrames.count - pacingTargetFrames
                pacedFrames.removeFirst(excess)
                pacingSkips &+= UInt64(excess)
            }
            pacingFramesSinceUnderrun += 1
            pacingQuietFrames += 1
            if pacingQuietFrames >= Self.pacingQuietWindowFrames,
               pacingTargetFrames > Self.pacingMinimumTargetFrames {
                pacingTargetFrames -= 1
                pacingQuietFrames = 0
            }
            return released
        }
        guard let next else { return }
        process(Work(frame: next.frame, epoch: next.epoch, token: 0))
    }

    public func flush(removingDisplayedImage: Bool = false) async {
        await lifecycleGate.perform { [self] in
            let flushEpoch = lock.withLock { () -> UInt64 in
                lifecycle = activeGeneration == nil ? .inactive : .activating
                epoch &+= 1
                if epoch == 0 { epoch = 1 }
                return epoch
            }

            await flushBackend(removingDisplayedImage: removingDisplayedImage)
            lock.withLock {
                guard epoch == flushEpoch else { return }
                resetAdmissionStateLocked()
                if activeGeneration != nil {
                    lifecycle = .running
                }
            }
        }
    }

    /// Reconciles only the renderer path after a platform lifecycle
    /// interruption. The active Remote Play generation remains owned by the
    /// provider; transport, decoder, audio, and controller delivery are not
    /// restarted. New presentation work is rejected until the renderer flush
    /// completion is observed.
    public func recoverAfterInterruption() async -> SampleBufferVideoInterruptionRecovery {
        await lifecycleGate.perform { [self] in
            let recovery = lock.withLock {
                () -> (SampleBufferVideoInterruptionRecovery, UInt64?) in
                guard activeGeneration != nil,
                      lifecycle == .running else {
                    return (.notRunning, nil)
                }
                guard surfaceAttached else {
                    return (.noSurface, nil)
                }

                lifecycle = .activating
                epoch &+= 1
                if epoch == 0 { epoch = 1 }
                flushRecoveries &+= 1
                return (.recovered, epoch)
            }
            guard let recoveryEpoch = recovery.1 else { return recovery.0 }

            // Preserve the last displayed image if the renderer still owns it;
            // a resumed frame will replace it after the flush completes.
            await flushBackend(removingDisplayedImage: false)
            lock.withLock {
                guard epoch == recoveryEpoch,
                      activeGeneration != nil else { return }
                resetAdmissionStateLocked()
                lifecycle = .running
            }
            return recovery.0
        }
    }

    public func snapshot() -> SampleBufferVideoPresentationSnapshot {
        // Read off the presentation queue: the upscaler keeps its own lock and
        // the Stats surface polls this from the main actor.
        let upscalerDiagnostics = upscalerDiagnosticsSnapshot()
        return lock.withLock {
            SampleBufferVideoPresentationSnapshot(
                activeGeneration: activeGeneration,
                framesSubmitted: framesSubmitted,
                framesEnqueued: framesEnqueued,
                staleGenerationDrops: staleGenerationDrops,
                noSurfaceDrops: noSurfaceDrops,
                workerBackpressureDrops: workerBackpressureDrops,
                rendererBackpressureDrops: rendererBackpressureDrops,
                invalidTimingDrops: invalidTimingDrops,
                flushRecoveries: flushRecoveries,
                suspendedDrops: suspendedDrops,
                pacingEnabled: pacingEnabled,
                pacingQueuedFrames: pacedFrames.count,
                pacingTargetFrames: pacingEnabled ? pacingTargetFrames : 0,
                pacingUnderruns: pacingUnderruns,
                pacingSkips: pacingSkips,
                upscaling: upscalingMode,
                upscaler: upscalerDiagnostics
            )
        }
    }

    /// Lock must be held. Returns the paced lead to its starting point.
    ///
    /// The lead is learned from one network over one session. Nothing used to
    /// give it back: not the Smooth motion toggle, not a flush, not a new
    /// session. A lead ratcheted to the 12-frame ceiling by one bad evening
    /// therefore outlived the conditions that earned it and could only be
    /// cleared by quitting the app, so the one remedy a user would reach for --
    /// switch it off and on again -- did nothing at all. Called when the user
    /// turns pacing on, and when a new session activates.
    private func resetPacingAdaptationLocked() {
        pacingTargetFrames = Self.pacingInitialTargetFrames
        pacingFramesSinceUnderrun = 0
        pacingQuietFrames = 0
    }

    /// Lock must be held. Clears every admission structure on an epoch change.
    private func resetAdmissionStateLocked() {
        workSlot.reset()
        pacedFrames.removeAll(keepingCapacity: true)
        pacingPriming = true
    }

    func attach(backend newBackend: any SampleBufferPresentationBackend) async {
        await lifecycleGate.perform { [self] in
            await replaceBackend(with: newBackend)
        }
    }

    func detachBackend(identity: ObjectIdentifier) async {
        await lifecycleGate.perform { [self] in
            await removeBackend(identity: identity)
        }
    }

    func waitUntilIdleForTesting() async {
        await performOnPresentationQueue {}
        let pendingRecovery: Task<Void, Never>? = await withCheckedContinuation {
            continuation in
            presentationQueue.async { [self] in
                continuation.resume(returning: recoveryTask)
            }
        }
        await pendingRecovery?.value
        await lifecycleGate.perform {}
        await performOnPresentationQueue {}
    }

    func lifecycleIsOccupiedForTesting() async -> Bool {
        await lifecycleGate.isOccupiedForTesting()
    }

    /// Test seam. Runs the render path for one already-admitted frame exactly
    /// as the block `submit` dispatches does. `submit` decides admission and
    /// then hops onto the presentation queue, so a frame can be admitted while
    /// the scene is live and processed after it is gone. That window is the one
    /// that reaches the GPU from the background, and it is only reproducible by
    /// separating the two halves.
    func processAdmittedFrameForTesting(_ frame: DecodedVideoFrame) async {
        let work = lock.withLock { Work(frame: frame, epoch: epoch, token: 0) }
        await performOnPresentationQueue { [self] in process(work) }
    }

    /// Settles the asynchronous upscaler construction started by
    /// `setUpscaling`. Returns whether a pass was actually installed; a machine
    /// without a usable Metal device correctly reports false.
    func waitForUpscalerInstallationForTesting() async -> Bool {
        for _ in 0..<400 {
            let installed = lock.withLock { upscaler != nil }
            if installed { return true }
            let settled = await withCheckedContinuation { continuation in
                presentationQueue.async { [self] in
                    continuation.resume(
                        returning: upscalerUnavailable || upscalerBuildInFlight == false
                    )
                }
            }
            if settled { return lock.withLock { upscaler != nil } }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return lock.withLock { upscaler != nil }
    }

    private func process(_ work: Work) {
        guard isCurrent(work) else { return }
        guard let backend else {
            lock.withLock {
                surfaceAttached = false
                noSurfaceDrops &+= 1
            }
            return
        }

        switch backend.readiness() {
        case .unavailable:
            lock.withLock {
                surfaceAttached = false
                noSurfaceDrops &+= 1
            }
            return
        case .backpressure:
            lock.withLock { rendererBackpressureDrops &+= 1 }
            return
        case .requiresFlush:
            beginRendererRecovery(
                backend: backend,
                generation: work.frame.generation,
                expectedEpoch: work.epoch
            )
            return
        case .ready:
            break
        }

        let presentationTimeStamp = work.frame.presentationTimeStamp
        guard presentationTimeStamp.isValid,
              presentationTimeStamp.isNumeric,
              presentationTimeStamp.timescale > 0,
              lastPresentationTimeStamp.map({
                  CMTimeCompare(presentationTimeStamp, $0) > 0
              }) ?? true else {
            lock.withLock { invalidTimingDrops &+= 1 }
            failureHandler(work.frame.generation, .invalidPresentationTime)
            return
        }

        let (mode, activeUpscaler, suspended) = lock.withLock {
            (upscalingMode, upscaler, presentationSuspended)
        }
        if let activeUpscaler {
            // Releasing the upscaler is only safe once it owes no completions:
            // a frame still in flight has to reach the renderer through the
            // upscaler's FIFO or it would arrive behind a frame submitted
            // after it.
            if mode == .off, activeUpscaler.isIdle {
                lock.withLock { upscaler = nil }
            } else {
                // The GPU gate. `submit` already refuses frames while the scene
                // is suspended, but it refuses them before the hop onto this
                // queue, so a frame admitted a moment before the scene went
                // away arrives here after the process has lost permission to
                // use the GPU. Submitting then earns one
                // `MTLCommandBufferError.Code.notPermitted` abort per frame.
                // This read is the last point before the encode; the frame
                // still travels the same FIFO, so ordering is untouched and it
                // simply reaches the display at the source resolution.
                activeUpscaler.submit(
                    work.frame,
                    upscale: suspended == false
                        && mode != .off
                        && shouldUpscale(work.frame, mode: mode)
                ) { [weak self] upscaled in
                    // Delivered on the presentation queue, in submission order.
                    // Any failure at any level arrives here as nil and the
                    // original frame is presented.
                    self?.present(work, frame: upscaled ?? work.frame)
                }
                return
            }
        }

        present(work, frame: work.frame)
    }

    /// The tail of the render path, reached either directly or from an upscale
    /// completion. `frame` is the buffer to show; it carries the same
    /// generation, presentation timestamp, and duration either way.
    private func present(_ work: Work, frame: DecodedVideoFrame) {
        guard isCurrent(work) else { return }
        guard let backend else {
            lock.withLock {
                surfaceAttached = false
                noSurfaceDrops &+= 1
            }
            return
        }

        // The guard in `process` ran before the GPU pass, when the last
        // presented timestamp could still be one frame behind. Re-checking
        // costs one comparison and keeps the monotonic invariant exact.
        let presentationTimeStamp = frame.presentationTimeStamp
        guard lastPresentationTimeStamp.map({
            CMTimeCompare(presentationTimeStamp, $0) > 0
        }) ?? true else {
            lock.withLock { invalidTimingDrops &+= 1 }
            failureHandler(frame.generation, .invalidPresentationTime)
            return
        }

        let sampleBuffer: CMSampleBuffer
        do {
            sampleBuffer = try makeSampleBuffer(frame: frame)
        } catch let error as SampleBufferVideoPresentationError {
            failureHandler(frame.generation, error)
            return
        } catch {
            failureHandler(frame.generation, .sampleBufferCreationFailed(-1))
            return
        }

        guard isCurrent(work) else { return }
        backend.enqueue(sampleBuffer)
        lastPresentationTimeStamp = presentationTimeStamp
        lock.withLock { framesEnqueued &+= 1 }
    }

    /// `automatic` runs the pass only while the video is drawn large enough for
    /// reconstruction to be visible. With `videoGravity = .resizeAspect` the
    /// picture is fitted inside the layer, so the magnification is the smaller
    /// of the two axis ratios. A shell that never reports a size gets the pass,
    /// because the alternative is silently doing nothing.
    private func shouldUpscale(_ frame: DecodedVideoFrame, mode: StreamUpscaling) -> Bool {
        let (width, height) = lock.withLock {
            (displayPixelWidth, displayPixelHeight)
        }
        switch mode {
        case .off:
            return false
        case .enhanced:
            return true
        case .automatic:
            guard width > 0, height > 0, frame.width > 0, frame.height > 0 else {
                return true
            }
            let magnification = min(
                Double(width) / Double(frame.width),
                Double(height) / Double(frame.height)
            )
            return magnification > MetalVideoUpscaler.minimumUsefulScale
        }
    }

    private func makeSampleBuffer(
        frame: DecodedVideoFrame
    ) throws -> CMSampleBuffer {
        if let cachedFormatDescription,
           CMVideoFormatDescriptionMatchesImageBuffer(
               cachedFormatDescription,
               imageBuffer: frame.pixelBuffer
           ) == false {
            self.cachedFormatDescription = nil
        }
        if cachedFormatDescription == nil {
            var formatDescription: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.pixelBuffer,
                formatDescriptionOut: &formatDescription
            )
            guard status == noErr, let formatDescription else {
                throw SampleBufferVideoPresentationError
                    .formatDescriptionCreationFailed(status)
            }
            cachedFormatDescription = formatDescription
        }
        guard let cachedFormatDescription else {
            throw SampleBufferVideoPresentationError
                .formatDescriptionCreationFailed(kCMFormatDescriptionError_InvalidParameter)
        }

        var timing = CMSampleTimingInfo(
            duration: frame.duration,
            presentationTimeStamp: frame.presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescription: cachedFormatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw SampleBufferVideoPresentationError
                .sampleBufferCreationFailed(status)
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) as? [NSMutableDictionary], let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sampleBuffer
    }

    private func isCurrent(_ work: Work) -> Bool {
        lock.withLock {
            lifecycle == .running
                && activeGeneration == work.frame.generation
                && epoch == work.epoch
        }
    }

    private func resetQueueState() {
        cachedFormatDescription = nil
        lastPresentationTimeStamp = nil
        // Renderer flush and interruption recovery both land here. A frame
        // composed after recovery must not reuse a texture mapping cached
        // before it.
        lock.withLock { upscaler }?.invalidateCaches()
    }

    private func upscalerDiagnosticsSnapshot() -> VideoUpscalerDiagnostics {
        guard let upscaler = lock.withLock({ upscaler }) else {
            return VideoUpscalerDiagnostics()
        }
        return upscaler.diagnostics()
    }

    private func beginRendererRecovery(
        backend: any SampleBufferPresentationBackend,
        generation: UInt64,
        expectedEpoch: UInt64
    ) {
        let recoveryEpoch = lock.withLock { () -> UInt64? in
            guard lifecycle == .running,
                  activeGeneration == generation,
                  epoch == expectedEpoch else { return nil }
            lifecycle = .activating
            epoch &+= 1
            if epoch == 0 { epoch = 1 }
            flushRecoveries &+= 1
            return epoch
        }
        guard let recoveryEpoch else { return }
        recoveryTaskEpoch = recoveryEpoch
        recoveryTask = Task { [weak self, backend] in
            guard let self else { return }
            await lifecycleGate.perform { [self] in
                let shouldRecover = lock.withLock {
                    lifecycle == .activating
                        && epoch == recoveryEpoch
                        && activeGeneration == generation
                }
                guard shouldRecover else { return }

                await flushBackend(
                    backend: backend,
                    removingDisplayedImage: false
                )
                lock.withLock {
                    guard epoch == recoveryEpoch,
                          activeGeneration == generation else { return }
                    lifecycle = .running
                }
            }
            await performOnPresentationQueue { [weak self] in
                guard self?.recoveryTaskEpoch == recoveryEpoch else { return }
                self?.recoveryTask = nil
                self?.recoveryTaskEpoch = nil
            }
        }
    }

    private func flushBackend(removingDisplayedImage: Bool) async {
        await flushBackend(backend: nil, removingDisplayedImage: removingDisplayedImage)
    }

    private func flushBackend(
        backend requestedBackend: (any SampleBufferPresentationBackend)?,
        removingDisplayedImage: Bool
    ) async {
        await withCheckedContinuation { continuation in
            presentationQueue.async { [self] in
                guard let targetBackend = requestedBackend ?? backend else {
                    resetQueueState()
                    continuation.resume()
                    return
                }
                targetBackend.flush(
                    removingDisplayedImage: removingDisplayedImage
                ) { [self] in
                    presentationQueue.async { [self] in
                        resetQueueState()
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func replaceBackend(
        with newBackend: any SampleBufferPresentationBackend
    ) async {
        await withCheckedContinuation { continuation in
            presentationQueue.async { [self] in
                guard backend?.identity != newBackend.identity else {
                    lock.withLock {
                        surfaceAttached = true
                        if activeGeneration != nil, lifecycle == .activating {
                            lifecycle = .running
                        }
                    }
                    continuation.resume()
                    return
                }

                let replacementEpoch = lock.withLock { () -> UInt64 in
                    surfaceAttached = false
                    epoch &+= 1
                    if epoch == 0 { epoch = 1 }
                    return epoch
                }
                guard let oldBackend = backend else {
                    resetQueueState()
                    backend = newBackend
                    lock.withLock {
                        guard epoch == replacementEpoch else { return }
                        resetAdmissionStateLocked()
                        surfaceAttached = true
                        lifecycle = activeGeneration == nil ? .inactive : .running
                    }
                    continuation.resume()
                    return
                }

                oldBackend.flush(removingDisplayedImage: true) { [self] in
                    presentationQueue.async { [self] in
                        resetQueueState()
                        backend = newBackend
                        lock.withLock {
                            guard epoch == replacementEpoch else { return }
                            resetAdmissionStateLocked()
                            surfaceAttached = true
                            lifecycle = activeGeneration == nil ? .inactive : .running
                        }
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func removeBackend(identity: ObjectIdentifier) async {
        await withCheckedContinuation { continuation in
            presentationQueue.async { [self] in
                guard let currentBackend = backend,
                      currentBackend.identity == identity else {
                    continuation.resume()
                    return
                }
                let removalEpoch = lock.withLock { () -> UInt64 in
                    surfaceAttached = false
                    epoch &+= 1
                    if epoch == 0 { epoch = 1 }
                    return epoch
                }
                currentBackend.flush(removingDisplayedImage: true) { [self] in
                    presentationQueue.async { [self] in
                        guard backend?.identity == identity else {
                            continuation.resume()
                            return
                        }
                        backend = nil
                        resetQueueState()
                        lock.withLock {
                            guard epoch == removalEpoch else { return }
                            resetAdmissionStateLocked()
                            surfaceAttached = false
                            lifecycle = activeGeneration == nil ? .inactive : .running
                        }
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func performOnPresentationQueue(
        _ operation: @escaping @Sendable () -> Void
    ) async {
        await withCheckedContinuation { continuation in
            presentationQueue.async {
                operation()
                continuation.resume()
            }
        }
    }
}

private final class AVSampleBufferDisplayLayerBackend:
    SampleBufferPresentationBackend,
    @unchecked Sendable
{
    private weak var layer: AVSampleBufferDisplayLayer?
    // AVSampleBufferDisplayLayer is UI-actor isolated. Capture its renderer on
    // that actor once; Apple documents the renderer as safe for background
    // enqueue, and this backend is confined to the presentation queue.
    private let renderer: AVSampleBufferVideoRenderer
    let identity: ObjectIdentifier

    @MainActor
    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
        renderer = layer.sampleBufferRenderer
        identity = ObjectIdentifier(layer)
    }

    func readiness() -> SampleBufferPresentationBackendReadiness {
        guard layer != nil else { return .unavailable }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            return .requiresFlush
        }
        return renderer.isReadyForMoreMediaData ? .ready : .backpressure
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard layer != nil else { return }
        renderer.enqueue(sampleBuffer)
    }

    func flush(
        removingDisplayedImage: Bool,
        completion: @escaping @Sendable () -> Void
    ) {
        guard layer != nil else {
            completion()
            return
        }
        renderer.flush(
            removingDisplayedImage: removingDisplayedImage,
            completionHandler: completion
        )
    }
}

/// Serializes asynchronous renderer lifecycle transactions through completion.
/// Dispatch serialization alone is insufficient because AVFoundation completes
/// a flush after the initiating queue block has returned.
private actor SampleBufferPresentationLifecycleGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func perform<Result: Sendable>(
        _ operation: @escaping @Sendable () async -> Result
    ) async -> Result {
        await acquire()
        let result = await operation()
        release()
        return result
    }

    private func acquire() async {
        guard occupied else {
            occupied = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard waiters.isEmpty == false else {
            occupied = false
            return
        }
        waiters.removeFirst().resume()
    }

    func isOccupiedForTesting() -> Bool {
        occupied
    }
}
