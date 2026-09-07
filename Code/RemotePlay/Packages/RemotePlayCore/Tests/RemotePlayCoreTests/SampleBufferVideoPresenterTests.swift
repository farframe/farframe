import AVFoundation
import AppleMediaCore
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import AppleMediaCore

@Test
func presenterRequiresActiveGenerationAndAttachedSurface() async throws {
    let presenter = BoundedSampleBufferVideoPresenter()
    let backend = FakeSampleBufferPresentationBackend()
    let generationOne = try presentationFrame(generation: 1, pts: 1)
    let generationTwo = try presentationFrame(generation: 2, pts: 2)

    #expect(presenter.submit(generationOne) == .notRunning)
    try await presenter.activate(generation: 1)
    #expect(presenter.submit(generationOne) == .noSurface)

    await presenter.attach(backend: backend)
    #expect(presenter.submit(generationTwo) == .staleGeneration)
    #expect(presenter.submit(generationOne) == .accepted)
    await presenter.waitUntilIdleForTesting()

    #expect(backend.enqueuedPresentationTimes() == [generationOne.presentationTimeStamp])
    #expect(backend.everySampleDisplaysImmediately())
    #expect(
        presenter.snapshot()
            == SampleBufferVideoPresentationSnapshot(
                activeGeneration: 1,
                framesSubmitted: 4,
                framesEnqueued: 1,
                staleGenerationDrops: 1,
                noSurfaceDrops: 1,
                workerBackpressureDrops: 0,
                rendererBackpressureDrops: 0,
                invalidTimingDrops: 0,
                flushRecoveries: 0
            )
    )
}

@Test
func presenterBoundsAcceptedWorkToOnePendingFrame() async throws {
    let presenter = BoundedSampleBufferVideoPresenter()
    let backend = FakeSampleBufferPresentationBackend(blockFirstEnqueue: true)
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 3)

    #expect(presenter.submit(try presentationFrame(generation: 3, pts: 1)) == .accepted)
    #expect(backend.waitForFirstEnqueueToStart())
    #expect(presenter.submit(try presentationFrame(generation: 3, pts: 2)) == .backpressure)

    backend.releaseFirstEnqueue()
    await presenter.waitUntilIdleForTesting()
    #expect(backend.enqueuedPresentationTimes().count == 1)
    #expect(presenter.snapshot().workerBackpressureDrops == 1)
}

@Test
func presenterRejectsNonMonotonicPresentationTime() async throws {
    let failures = LockedPresentationFailures()
    let presenter = BoundedSampleBufferVideoPresenter { generation, error in
        failures.record(generation: generation, error: error)
    }
    let backend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 5)

    #expect(presenter.submit(try presentationFrame(generation: 5, pts: 2)) == .accepted)
    await presenter.waitUntilIdleForTesting()
    #expect(presenter.submit(try presentationFrame(generation: 5, pts: 1)) == .accepted)
    await presenter.waitUntilIdleForTesting()

    #expect(backend.enqueuedPresentationTimes().count == 1)
    #expect(presenter.snapshot().invalidTimingDrops == 1)
    #expect(
        failures.values()
            == [RecordedPresentationFailure(
                generation: 5,
                error: .invalidPresentationTime
            )]
    )
}

@Test
func presenterFlushesRendererLossBeforeResumingOnNextFrame() async throws {
    let presenter = BoundedSampleBufferVideoPresenter()
    let backend = FakeSampleBufferPresentationBackend(readiness: .requiresFlush)
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 7)
    backend.clearFlushHistory()

    #expect(presenter.submit(try presentationFrame(generation: 7, pts: 1)) == .accepted)
    await presenter.waitUntilIdleForTesting()
    #expect(backend.flushHistory() == [false])
    #expect(backend.enqueuedPresentationTimes().isEmpty)
    #expect(presenter.snapshot().flushRecoveries == 1)

    backend.setReadiness(.ready)
    #expect(presenter.submit(try presentationFrame(generation: 7, pts: 2)) == .accepted)
    await presenter.waitUntilIdleForTesting()
    #expect(backend.enqueuedPresentationTimes().count == 1)
}

@Test
func lateDetachCannotRemoveReplacementSurface() async throws {
    let presenter = BoundedSampleBufferVideoPresenter()
    let firstBackend = FakeSampleBufferPresentationBackend()
    let replacementBackend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: firstBackend)
    try await presenter.activate(generation: 9)

    await presenter.attach(backend: replacementBackend)
    await presenter.detachBackend(identity: firstBackend.identity)
    #expect(presenter.submit(try presentationFrame(generation: 9, pts: 1)) == .accepted)
    await presenter.waitUntilIdleForTesting()

    #expect(firstBackend.enqueuedPresentationTimes().isEmpty)
    #expect(replacementBackend.enqueuedPresentationTimes().count == 1)
}

@Test
func deactivationRejectsLateFramesAndFlushesDisplayedImage() async throws {
    let presenter = BoundedSampleBufferVideoPresenter()
    let backend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 11)
    backend.clearFlushHistory()

    await presenter.deactivate(generation: 11)
    #expect(presenter.submit(try presentationFrame(generation: 11, pts: 1)) == .notRunning)
    #expect(backend.flushHistory() == [true])
    #expect(presenter.snapshot().activeGeneration == nil)
}

@Test
func activationDoesNotAcceptFramesUntilDisplayFlushCompletes() async throws {
    let presenter = BoundedSampleBufferVideoPresenter()
    let backend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: backend)
    backend.delayNextFlush()

    let activation = Task {
        try await presenter.activate(generation: 13)
    }
    #expect(await presenterEventually { backend.pendingFlushCount() == 1 })
    #expect(presenter.submit(try presentationFrame(generation: 13, pts: 1)) == .notRunning)

    backend.completeNextFlush()
    try await activation.value
    #expect(presenter.submit(try presentationFrame(generation: 13, pts: 1)) == .accepted)
    await presenter.waitUntilIdleForTesting()
    #expect(backend.enqueuedPresentationTimes().count == 1)
}

@Test
func deactivationReturnsOnlyAfterDisplayFlushCompletes() async throws {
    let presenter = BoundedSampleBufferVideoPresenter()
    let backend = FakeSampleBufferPresentationBackend()
    let completion = LockedPresentationCompletion()
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 15)
    backend.delayNextFlush()

    let deactivation = Task {
        await presenter.deactivate(generation: 15)
        completion.markCompleted()
    }
    #expect(await presenterEventually { backend.pendingFlushCount() == 1 })
    #expect(completion.isCompleted() == false)
    #expect(presenter.submit(try presentationFrame(generation: 15, pts: 1)) == .notRunning)

    backend.completeNextFlush()
    await deactivation.value
    #expect(completion.isCompleted())
}

@Test
func explicitFlushBlocksNewFramesUntilRendererCompletion() async throws {
    let presenter = BoundedSampleBufferVideoPresenter()
    let backend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 17)
    backend.delayNextFlush()

    let flush = Task {
        await presenter.flush(removingDisplayedImage: true)
    }
    #expect(await presenterEventually { backend.pendingFlushCount() == 1 })
    #expect(presenter.submit(try presentationFrame(generation: 17, pts: 1)) == .notRunning)

    backend.completeNextFlush()
    await flush.value
    #expect(presenter.submit(try presentationFrame(generation: 17, pts: 1)) == .accepted)
    await presenter.waitUntilIdleForTesting()
}

@Test
func interruptionRecoveryFlushesOnlyLivePresentationAndResumesAdmission() async throws {
    let presenter = BoundedSampleBufferVideoPresenter()
    let backend = FakeSampleBufferPresentationBackend()

    #expect(await presenter.recoverAfterInterruption() == .notRunning)
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 18)
    backend.clearFlushHistory()
    backend.delayNextFlush()

    let recovery = Task {
        await presenter.recoverAfterInterruption()
    }
    #expect(await presenterEventually { backend.pendingFlushCount() == 1 })
    #expect(presenter.submit(try presentationFrame(generation: 18, pts: 1)) == .notRunning)
    #expect(backend.flushHistory() == [false])

    backend.completeNextFlush()
    #expect(await recovery.value == .recovered)
    #expect(presenter.snapshot().activeGeneration == 18)
    #expect(presenter.snapshot().flushRecoveries == 1)
    #expect(presenter.submit(try presentationFrame(generation: 18, pts: 2)) == .accepted)
    await presenter.waitUntilIdleForTesting()
    #expect(backend.enqueuedPresentationTimes().count == 1)
}

@Test
func interruptionRecoveryWithoutSurfaceIsANonMutatingNoOp() async throws {
    let presenter = BoundedSampleBufferVideoPresenter()
    try await presenter.activate(generation: 20)

    #expect(await presenter.recoverAfterInterruption() == .noSurface)
    #expect(presenter.snapshot().activeGeneration == 20)
    #expect(presenter.snapshot().flushRecoveries == 0)
    #expect(presenter.submit(try presentationFrame(generation: 20, pts: 1)) == .noSurface)
}

@Test
@MainActor
func surfaceBindingQueuesInterruptionRecoveryBehindSurfaceReplacement() async throws {
    let presenter = BoundedSampleBufferVideoPresenter()
    let blockingBackend = FakeSampleBufferPresentationBackend()
    let binding = SampleBufferVideoSurfaceBinding(presenter: presenter)
    await presenter.attach(backend: blockingBackend)
    try await presenter.activate(generation: 24)
    blockingBackend.clearFlushHistory()
    blockingBackend.delayNextFlush()

    let replacementLayer = AVSampleBufferDisplayLayer()
    binding.attach(replacementLayer)
    let recovery = Task { @MainActor in
        await binding.recoverAfterInterruption()
    }

    #expect(await presenterEventually { blockingBackend.pendingFlushCount() == 1 })
    #expect(blockingBackend.flushHistory() == [true])
    blockingBackend.completeNextFlush()

    #expect(await recovery.value == .recovered)
    #expect(binding.snapshot().activeGeneration == 24)
    #expect(binding.snapshot().flushRecoveries == 1)
}

@Test
func sameShapeAttachmentChangeRebuildsCompatibleFormatDescription() async throws {
    let failures = LockedPresentationFailures()
    let presenter = BoundedSampleBufferVideoPresenter { generation, error in
        failures.record(generation: generation, error: error)
    }
    let backend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 19)

    #expect(
        presenter.submit(
            try presentationFrame(generation: 19, pts: 1)
        ) == .accepted
    )
    await presenter.waitUntilIdleForTesting()
    #expect(
        presenter.submit(
            try presentationFrame(
                generation: 19,
                pts: 2,
                colorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2
            )
        ) == .accepted
    )
    await presenter.waitUntilIdleForTesting()

    #expect(backend.enqueuedPresentationTimes().count == 2)
    #expect(failures.values().isEmpty)
}

@Test
func overlappingActivationsSerializeRendererFlushesThroughCompletion() async throws {
    let presenter = BoundedSampleBufferVideoPresenter()
    let backend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: backend)
    backend.delayNextFlush()

    let firstActivation = Task {
        try await presenter.activate(generation: 21)
    }
    #expect(await presenterEventually { backend.pendingFlushCount() == 1 })

    backend.delayNextFlush()
    let secondEntered = LockedPresentationCompletion()
    let secondActivation = Task {
        secondEntered.markCompleted()
        try await presenter.activate(generation: 22)
    }
    #expect(await presenterEventually { secondEntered.isCompleted() })
    try await Task.sleep(for: .milliseconds(20))

    #expect(backend.flushHistory().count == 1)
    #expect(backend.pendingFlushCount() == 1)
    #expect(
        presenter.submit(
            try presentationFrame(generation: 21, pts: 1)
        ) == .notRunning
    )

    backend.completeNextFlush()
    #expect(await presenterEventually { backend.flushHistory().count == 2 })
    #expect(backend.pendingFlushCount() == 1)
    #expect(
        presenter.submit(
            try presentationFrame(generation: 22, pts: 1)
        ) == .notRunning
    )

    backend.completeNextFlush()
    try await firstActivation.value
    try await secondActivation.value

    #expect(presenter.snapshot().activeGeneration == 22)
    #expect(
        presenter.submit(
            try presentationFrame(generation: 21, pts: 1)
        ) == .staleGeneration
    )
    #expect(
        presenter.submit(
            try presentationFrame(generation: 22, pts: 1)
        ) == .accepted
    )
    await presenter.waitUntilIdleForTesting()
}

@Test
func recoverySupersededBySurfaceReplacementRestoresRunningLifecycle() async throws {
    let presenter = BoundedSampleBufferVideoPresenter()
    let firstBackend = FakeSampleBufferPresentationBackend(
        readiness: .requiresFlush,
        blockFirstReadiness: true
    )
    let replacementBackend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: firstBackend)
    try await presenter.activate(generation: 23)

    #expect(
        presenter.submit(
            try presentationFrame(generation: 23, pts: 1)
        ) == .accepted
    )
    #expect(firstBackend.waitForFirstReadinessToStart())

    let replacement = Task {
        await presenter.attach(backend: replacementBackend)
    }
    #expect(await presenterLifecycleEventuallyOccupied(presenter))
    firstBackend.releaseFirstReadiness()
    await replacement.value
    await presenter.waitUntilIdleForTesting()

    #expect(presenter.snapshot().activeGeneration == 23)
    #expect(
        presenter.submit(
            try presentationFrame(generation: 23, pts: 2)
        ) == .accepted
    )
    await presenter.waitUntilIdleForTesting()
    #expect(replacementBackend.enqueuedPresentationTimes().count == 1)
}

@Test
func staleWorkTokenCannotReleaseNewerReservedSlot() {
    var slot = SampleBufferPresentationWorkSlot()
    let staleToken = slot.reserve()
    #expect(staleToken != nil)

    slot.reset()
    let currentToken = slot.reserve()
    #expect(currentToken != nil)
    #expect(currentToken != staleToken)

    slot.release(ifOwnedBy: staleToken!)
    #expect(slot.owner == currentToken)
    #expect(slot.reserve() == nil)

    slot.release(ifOwnedBy: currentToken!)
    #expect(slot.owner == nil)
}

@Test
@MainActor
func surfaceBindingSerializesReplacementAndIdentitySafeDetach() async throws {
    let presenter = BoundedSampleBufferVideoPresenter()
    let blockingBackend = FakeSampleBufferPresentationBackend()
    let binding = SampleBufferVideoSurfaceBinding(presenter: presenter)
    await presenter.attach(backend: blockingBackend)
    blockingBackend.delayNextFlush()

    let firstLayer = AVSampleBufferDisplayLayer()
    let replacementLayer = AVSampleBufferDisplayLayer()
    binding.attach(firstLayer)
    binding.detach(firstLayer)
    binding.attach(replacementLayer)

    #expect(await presenterEventually { blockingBackend.pendingFlushCount() == 1 })
    blockingBackend.completeNextFlush()
    await binding.synchronizeThroughCurrentOperations()
    try await presenter.activate(generation: 25)

    #expect(
        presenter.submit(
            try presentationFrame(generation: 25, pts: 1)
        ) == .accepted
    )
    await presenter.waitUntilIdleForTesting()

    binding.detach(firstLayer)
    await binding.synchronizeThroughCurrentOperations()
    #expect(
        presenter.submit(
            try presentationFrame(generation: 25, pts: 2)
        ) == .accepted
    )
    await presenter.waitUntilIdleForTesting()

    binding.detach(replacementLayer)
    await binding.synchronizeThroughCurrentOperations()
    #expect(
        presenter.submit(
            try presentationFrame(generation: 25, pts: 3)
        ) == .noSurface
    )
    #expect(binding.snapshot() == presenter.snapshot())
}

final class FakeSampleBufferPresentationBackend:
    SampleBufferPresentationBackend,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let firstEnqueueStarted = DispatchSemaphore(value: 0)
    private let firstEnqueueRelease = DispatchSemaphore(value: 0)
    private let firstReadinessStarted = DispatchSemaphore(value: 0)
    private let firstReadinessRelease = DispatchSemaphore(value: 0)
    private var currentReadiness: SampleBufferPresentationBackendReadiness
    private var presentationTimes: [CMTime] = []
    private var imageBufferIdentities: [UInt] = []
    private var imageBufferSizes: [(width: Int, height: Int)] = []
    private var imageBufferColorPrimaries: [String?] = []
    private var immediateFlags: [Bool] = []
    private var flushes: [Bool] = []
    private var shouldBlockFirstEnqueue: Bool
    private var shouldBlockFirstReadiness: Bool
    private var shouldDelayNextFlush = false
    private var pendingFlushes: [@Sendable () -> Void] = []

    var identity: ObjectIdentifier { ObjectIdentifier(self) }

    init(
        readiness: SampleBufferPresentationBackendReadiness = .ready,
        blockFirstEnqueue: Bool = false,
        blockFirstReadiness: Bool = false
    ) {
        currentReadiness = readiness
        shouldBlockFirstEnqueue = blockFirstEnqueue
        shouldBlockFirstReadiness = blockFirstReadiness
    }

    func readiness() -> SampleBufferPresentationBackendReadiness {
        let result = lock.withLock {
            () -> (SampleBufferPresentationBackendReadiness, Bool) in
            let shouldBlock = shouldBlockFirstReadiness
            shouldBlockFirstReadiness = false
            return (currentReadiness, shouldBlock)
        }
        if result.1 {
            firstReadinessStarted.signal()
            _ = firstReadinessRelease.wait(timeout: .now() + 2)
        }
        return result.0
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let shouldBlock = lock.withLock { () -> Bool in
            let value = shouldBlockFirstEnqueue
            shouldBlockFirstEnqueue = false
            return value
        }
        if shouldBlock {
            firstEnqueueStarted.signal()
            _ = firstEnqueueRelease.wait(timeout: .now() + 2)
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let displaysImmediately: Bool
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [NSDictionary], let first = attachments.first {
            displaysImmediately = first[kCMSampleAttachmentKey_DisplayImmediately] as? Bool ?? false
        } else {
            displaysImmediately = false
        }
        // Recorded by value, never retained. Holding presented buffers would
        // starve the presenter's own pixel buffer pool and make this fake the
        // reason the code under test degrades.
        let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        let identity = imageBuffer.map { UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()) }
        let size = imageBuffer.map {
            (width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0))
        }
        let primaries = imageBuffer.flatMap {
            CVBufferCopyAttachment($0, kCVImageBufferColorPrimariesKey, nil) as? String
        }
        lock.withLock {
            presentationTimes.append(presentationTime)
            if let identity { imageBufferIdentities.append(identity) }
            if let size { imageBufferSizes.append(size) }
            if imageBuffer != nil { imageBufferColorPrimaries.append(primaries) }
            immediateFlags.append(displaysImmediately)
        }
    }

    func flush(
        removingDisplayedImage: Bool,
        completion: @escaping @Sendable () -> Void
    ) {
        let shouldComplete = lock.withLock { () -> Bool in
            flushes.append(removingDisplayedImage)
            guard shouldDelayNextFlush else { return true }
            shouldDelayNextFlush = false
            pendingFlushes.append(completion)
            return false
        }
        if shouldComplete { completion() }
    }

    func setReadiness(_ readiness: SampleBufferPresentationBackendReadiness) {
        lock.withLock { currentReadiness = readiness }
    }

    func enqueuedPresentationTimes() -> [CMTime] {
        lock.withLock { presentationTimes }
    }

    /// Identities of the buffers that actually reached the renderer.
    /// Presentation-side work such as upscaling replaces the decoder's buffer,
    /// so identity here is the difference between "the pass ran" and "the pass
    /// was skipped". Compare against a buffer the caller still holds.
    func enqueuedImageBufferIdentities() -> [UInt] {
        lock.withLock { imageBufferIdentities }
    }

    func enqueuedImageBufferSizes() -> [(width: Int, height: Int)] {
        lock.withLock { imageBufferSizes }
    }

    func enqueuedColorPrimaries() -> [String?] {
        lock.withLock { imageBufferColorPrimaries }
    }

    func everySampleDisplaysImmediately() -> Bool {
        lock.withLock { immediateFlags.isEmpty == false && immediateFlags.allSatisfy { $0 } }
    }

    func flushHistory() -> [Bool] {
        lock.withLock { flushes }
    }

    func clearFlushHistory() {
        lock.withLock { flushes.removeAll() }
    }

    func delayNextFlush() {
        lock.withLock { shouldDelayNextFlush = true }
    }

    func pendingFlushCount() -> Int {
        lock.withLock { pendingFlushes.count }
    }

    func completeNextFlush() {
        let completion = lock.withLock { () -> (@Sendable () -> Void)? in
            guard pendingFlushes.isEmpty == false else { return nil }
            return pendingFlushes.removeFirst()
        }
        completion?()
    }

    func waitForFirstEnqueueToStart() -> Bool {
        firstEnqueueStarted.wait(timeout: .now() + 2) == .success
    }

    func releaseFirstEnqueue() {
        firstEnqueueRelease.signal()
    }

    func waitForFirstReadinessToStart() -> Bool {
        firstReadinessStarted.wait(timeout: .now() + 2) == .success
    }

    func releaseFirstReadiness() {
        firstReadinessRelease.signal()
    }
}

private struct RecordedPresentationFailure: Equatable, Sendable {
    let generation: UInt64
    let error: SampleBufferVideoPresentationError
}

private final class LockedPresentationFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RecordedPresentationFailure] = []

    func record(generation: UInt64, error: SampleBufferVideoPresentationError) {
        lock.withLock {
            recorded.append(RecordedPresentationFailure(generation: generation, error: error))
        }
    }

    func values() -> [RecordedPresentationFailure] {
        lock.withLock { recorded }
    }
}

private final class LockedPresentationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func markCompleted() {
        lock.withLock { completed = true }
    }

    func isCompleted() -> Bool {
        lock.withLock { completed }
    }
}

private func presentationFrame(
    generation: UInt64,
    pts: CMTimeValue,
    colorPrimaries: CFString? = nil
) throws -> DecodedVideoFrame {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        4,
        4,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw SampleBufferVideoPresentationError
            .formatDescriptionCreationFailed(status)
    }
    if let colorPrimaries {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            colorPrimaries,
            .shouldPropagate
        )
    }
    return DecodedVideoFrame(
        generation: generation,
        pixelBuffer: pixelBuffer,
        presentationTimeStamp: CMTime(value: pts, timescale: 60),
        duration: CMTime(value: 1, timescale: 60)
    )
}

private func presenterEventually(
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    for _ in 0..<250 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

private func presenterLifecycleEventuallyOccupied(
    _ presenter: BoundedSampleBufferVideoPresenter
) async -> Bool {
    for _ in 0..<250 {
        if await presenter.lifecycleIsOccupiedForTesting() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

@Test
func presenterPacingPrimesReleasesOnePerTickAndAdaptsToBurstsAndStalls() async throws {
    let presenter = BoundedSampleBufferVideoPresenter(usesInternalPacingTimer: false)
    let backend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 1)
    presenter.setPacingEnabled(true)

    // Priming: two frames are below the three-frame target, so a tick holds.
    for pts in 1...2 {
        #expect(presenter.submit(try presentationFrame(generation: 1, pts: CMTimeValue(pts))) == .accepted)
    }
    await presenter.advancePacingForTesting()
    #expect(backend.enqueuedPresentationTimes().isEmpty)
    #expect(presenter.snapshot().pacingQueuedFrames == 2)

    // The third frame reaches the target; each tick releases exactly one.
    #expect(presenter.submit(try presentationFrame(generation: 1, pts: 3)) == .accepted)
    await presenter.advancePacingForTesting()
    #expect(backend.enqueuedPresentationTimes() == [CMTime(value: 1, timescale: 60)])

    // A six-frame burst lands at once: nothing is refused (no worker drops),
    // and the ticks keep releasing one frame per period in order.
    for pts in 4...9 {
        #expect(presenter.submit(try presentationFrame(generation: 1, pts: CMTimeValue(pts))) == .accepted)
    }
    #expect(presenter.snapshot().workerBackpressureDrops == 0)
    for _ in 0..<3 { await presenter.advancePacingForTesting() }
    #expect(backend.enqueuedPresentationTimes().count == 4)
    #expect(backend.enqueuedPresentationTimes().last == CMTime(value: 4, timescale: 60))
    #expect(presenter.snapshot().pacingQueuedFrames == 5)

    // Drain the queue, then one empty tick is a stall: underrun, target 3 -> 5.
    for _ in 0..<5 { await presenter.advancePacingForTesting() }
    #expect(backend.enqueuedPresentationTimes().count == 9)
    await presenter.advancePacingForTesting()
    var snapshot = presenter.snapshot()
    #expect(snapshot.pacingUnderruns == 1)
    #expect(snapshot.pacingTargetFrames == 5)
    #expect(snapshot.pacingQueuedFrames == 0)

    // A twelve-frame burst: priming completes at five, the tick releases one,
    // and the remaining eleven exceed target + slack (9), so the oldest six
    // are skipped to pull latency back to the target.
    for pts in 10...21 {
        #expect(presenter.submit(try presentationFrame(generation: 1, pts: CMTimeValue(pts))) == .accepted)
    }
    await presenter.advancePacingForTesting()
    snapshot = presenter.snapshot()
    #expect(backend.enqueuedPresentationTimes().last == CMTime(value: 10, timescale: 60))
    #expect(snapshot.pacingSkips == 6)
    #expect(snapshot.pacingQueuedFrames == 5)
    await presenter.advancePacingForTesting()
    #expect(backend.enqueuedPresentationTimes().last == CMTime(value: 17, timescale: 60))
    #expect(backend.everySampleDisplaysImmediately())

    // Turning pacing off discards the queue and returns to the immediate path.
    presenter.setPacingEnabled(false)
    #expect(presenter.snapshot().pacingEnabled == false)
    #expect(presenter.snapshot().pacingQueuedFrames == 0)
    #expect(presenter.submit(try presentationFrame(generation: 1, pts: 22)) == .accepted)
    await presenter.waitUntilIdleForTesting()
    #expect(backend.enqueuedPresentationTimes().last == CMTime(value: 22, timescale: 60))
    await presenter.deactivate(generation: 1)
}

@Test
func presenterPacingQueueIsClearedBySuspensionAndFlush() async throws {
    let presenter = BoundedSampleBufferVideoPresenter(usesInternalPacingTimer: false)
    let backend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 1)
    presenter.setPacingEnabled(true)
    for pts in 1...4 {
        #expect(presenter.submit(try presentationFrame(generation: 1, pts: CMTimeValue(pts))) == .accepted)
    }
    presenter.setPresentationSuspended(true)
    #expect(presenter.snapshot().pacingQueuedFrames == 0)
    #expect(presenter.submit(try presentationFrame(generation: 1, pts: 5)) == .suspended)
    await presenter.advancePacingForTesting()
    #expect(presenter.snapshot().pacingUnderruns == 0)
    presenter.setPresentationSuspended(false)

    for pts in 6...8 {
        #expect(presenter.submit(try presentationFrame(generation: 1, pts: CMTimeValue(pts))) == .accepted)
    }
    await presenter.flush()
    #expect(presenter.snapshot().pacingQueuedFrames == 0)
    await presenter.advancePacingForTesting()
    #expect(backend.enqueuedPresentationTimes().isEmpty)
    await presenter.deactivate(generation: 1)
}

/// Primes the queue to the current target, drains it, then ticks once more on
/// an empty queue. Only that last tick is a stall: while priming, an empty
/// queue holds without counting an underrun, which is why a bare tick on a
/// freshly enabled presenter proves nothing.
@discardableResult
private func causePacedUnderrun(
    _ presenter: BoundedSampleBufferVideoPresenter,
    generation: UInt64,
    startingAt firstPTS: CMTimeValue
) async throws -> CMTimeValue {
    let target = presenter.snapshot().pacingTargetFrames
    for offset in 0..<target {
        let pts = firstPTS + CMTimeValue(offset)
        #expect(presenter.submit(try presentationFrame(generation: generation, pts: pts)) == .accepted)
    }
    // The first tick completes priming and releases; the rest drain the queue.
    for _ in 0..<target { await presenter.advancePacingForTesting() }
    await presenter.advancePacingForTesting()
    return firstPTS + CMTimeValue(target)
}

/// Submit one, tick once, repeat: the queue never empties, so every tick
/// releases a frame and none of them stalls.
private func advanceCleanPacedFrames(
    _ presenter: BoundedSampleBufferVideoPresenter,
    generation: UInt64,
    startingAt firstPTS: CMTimeValue,
    count: Int
) async throws {
    for offset in 0..<count {
        let pts = firstPTS + CMTimeValue(offset)
        #expect(presenter.submit(try presentationFrame(generation: generation, pts: pts)) == .accepted)
        await presenter.advancePacingForTesting()
    }
}

/// The paced lead is learned from one network on one evening, and nothing used
/// to give it back. A lead ratcheted to the ceiling therefore outlived the
/// conditions that earned it and survived the one remedy a user would reach
/// for. Turning Smooth motion off and on again now returns it to its start.
@Test
func presenterPacingLeadResetsWhenSmoothMotionIsTurnedBackOn() async throws {
    let presenter = BoundedSampleBufferVideoPresenter(usesInternalPacingTimer: false)
    let backend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 1)
    presenter.setPacingEnabled(true)

    // Three stalls ratchet the lead from 3 to 9 frames, two per stall.
    var pts: CMTimeValue = 1
    for _ in 0..<3 {
        pts = try await causePacedUnderrun(presenter, generation: 1, startingAt: pts)
    }
    #expect(presenter.snapshot().pacingUnderruns == 3)
    #expect(presenter.snapshot().pacingTargetFrames == 9)

    // Off and on again: the lead is back to its documented starting point.
    presenter.setPacingEnabled(false)
    presenter.setPacingEnabled(true)
    #expect(presenter.snapshot().pacingTargetFrames == 3)

    // It still adapts afterwards. The reset clears the lead, not the policy
    // that earns one.
    pts = try await causePacedUnderrun(presenter, generation: 1, startingAt: pts)
    #expect(presenter.snapshot().pacingTargetFrames == 5)
    await presenter.deactivate(generation: 1)
}

/// A new session reads the network fresh rather than inheriting the previous
/// session's worst moment. A mid-session flush is not a new session.
@Test
func presenterPacingLeadResetsOnNewSessionButSurvivesMidSessionFlush() async throws {
    let presenter = BoundedSampleBufferVideoPresenter(usesInternalPacingTimer: false)
    let backend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 1)
    presenter.setPacingEnabled(true)

    var pts: CMTimeValue = 1
    for _ in 0..<2 {
        pts = try await causePacedUnderrun(presenter, generation: 1, startingAt: pts)
    }
    #expect(presenter.snapshot().pacingTargetFrames == 7)

    // The network did not change here, the renderer did, so the lead holds.
    await presenter.flush()
    #expect(presenter.snapshot().pacingTargetFrames == 7)

    try await presenter.activate(generation: 2)
    #expect(presenter.snapshot().pacingTargetFrames == 3)
    await presenter.deactivate(generation: 2)
}

/// Drift detection and the step-down cadence used to share one counter, and a
/// step-down reset it. While the lead was walking down, the counter could never
/// reach the 3,600-frame drift window, so drift was only detectable once the
/// lead had already bottomed out -- 110 s of clean release rather than the 60 s
/// the constant states. Two jobs now use two counters.
///
/// This run is deliberately longer than the drift window and shorter than the
/// old shared-counter path needed, so it fails on the previous implementation
/// instead of passing on both.
@Test
func presenterPacingTreatsALongQuietSpellAsDriftRatherThanJitter() async throws {
    let presenter = BoundedSampleBufferVideoPresenter(usesInternalPacingTimer: false)
    let backend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 1)
    presenter.setPacingEnabled(true)

    // One stall lifts the lead to 5 and starts both counters from zero.
    var pts = try await causePacedUnderrun(presenter, generation: 1, startingAt: 1)
    #expect(presenter.snapshot().pacingTargetFrames == 5)

    // Clean release well past the drift window. Step-downs walk the lead to the
    // two-frame minimum on the way and no longer disturb the drift counter.
    try await advanceCleanPacedFrames(presenter, generation: 1, startingAt: pts, count: 4_000)
    pts += 4_000
    let settled = presenter.snapshot()
    #expect(settled.pacingTargetFrames == 2)
    #expect(settled.pacingUnderruns == 1)

    // Drain what is still queued, then stall. That stall is a full drift window
    // after the previous one, so it re-primes without raising the lead.
    while presenter.snapshot().pacingQueuedFrames > 0 {
        await presenter.advancePacingForTesting()
    }
    await presenter.advancePacingForTesting()
    let afterDrift = presenter.snapshot()
    #expect(afterDrift.pacingUnderruns == 2)
    #expect(afterDrift.pacingTargetFrames == 2)

    // The next stall follows close behind, so it is jitter again and does lift.
    pts = try await causePacedUnderrun(presenter, generation: 1, startingAt: pts)
    #expect(presenter.snapshot().pacingTargetFrames == 4)
    await presenter.deactivate(generation: 1)
}
