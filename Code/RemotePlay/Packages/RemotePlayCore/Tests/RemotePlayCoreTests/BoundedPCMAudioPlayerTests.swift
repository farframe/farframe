import AVFoundation
@testable import AppleMediaCore
import Foundation
import StreamingCore
import Testing

/// Fast jitter configuration for player tests: 20 ms target, 10 ms packets.
private let playerJitterConfiguration = PCMJitterBuffer.Configuration(
    sampleRate: 48_000,
    capacityFrames: 9_600,
    initialTargetFrames: 960,
    minimumTargetFrames: 480,
    maximumTargetFrames: 4_800,
    raiseStepFrames: 480,
    lowerStepFrames: 480,
    skipSlackFrames: 1_920,
    quietWindowFrames: 48_000,
    fadeFrames: 1
)

@Test
func boundedPCMAudioControlsClampMuteAndPreserveTheProvenDefault() async throws {
    let backend = FakePCMAudioPlaybackBackend()
    let player = BoundedPCMAudioPlayer(backend: backend, jitterConfiguration: playerJitterConfiguration)
    let controls = player.makeControls()

    #expect(controls.snapshot().volume == 0.7)
    #expect(controls.snapshot().isMuted == false)

    try await player.activate(generation: 1)
    controls.setVolume(2)
    #expect(await audioEventually { backend.lastVolume() == 1 })
    #expect(controls.snapshot().volume == 1)

    controls.setMuted(true)
    #expect(await audioEventually { backend.lastVolume() == 0 })
    controls.setVolume(0.4)
    #expect(await audioEventually { backend.lastVolume() == 0 })
    #expect(controls.snapshot().volume == 0.4)
    #expect(controls.snapshot().isMuted)

    controls.setMuted(false)
    #expect(await audioEventually { backend.lastVolume() == 0.4 })
    controls.setVolume(.nan)
    #expect(await audioEventually { backend.lastVolume() == 0 })
    #expect(controls.snapshot().volume == 0)

    await player.deactivate(generation: 1)
}

@Test
func boundedPCMAudioConvertsStereoAndDuplicatesMonoIntoFloat32Stereo() async throws {
    let stereoBackend = FakePCMAudioPlaybackBackend()
    let stereoPlayer = BoundedPCMAudioPlayer(
        backend: stereoBackend,
        jitterConfiguration: playerJitterConfiguration
    )
    try await stereoPlayer.activate(generation: 1)
    #expect(stereoPlayer.configure(try stereoFormat(), generation: 1) == .accepted)
    #expect(
        stereoPlayer.admit(
            try pcmBlock(samples: [32_767, -32_768, 16_384, -16_384], frameCount: 2, channels: 2),
            generation: 1
        ) == .accepted
    )
    // Reach the 20 ms target with silence so rendering starts.
    #expect(stereoPlayer.admit(try silentBlock(frameCount: 958), generation: 1) == .accepted)
    let stereo = stereoBackend.pull(frameCount: 2)
    // Frame 0 is the one-frame priming fade from silence; frame 1 is exact.
    #expect(stereo.left[0] == 0)
    #expect(stereo.left[1] == 0.5)
    #expect(stereo.right[1] == -0.5)
    #expect(stereoPlayer.snapshot().queue.acceptedBuffers == 2)
    #expect(stereoPlayer.snapshot().queue.renderedBuffers == 0) // < one 958-frame packet
    await stereoPlayer.deactivate(generation: 1)

    let monoBackend = FakePCMAudioPlaybackBackend()
    let monoPlayer = BoundedPCMAudioPlayer(
        backend: monoBackend,
        jitterConfiguration: playerJitterConfiguration
    )
    try await monoPlayer.activate(generation: 2)
    #expect(monoPlayer.configure(try monoFormat(), generation: 2) == .accepted)
    #expect(
        monoPlayer.admit(
            try pcmBlock(samples: [8_192, -8_192], frameCount: 2, channels: 1),
            generation: 2
        ) == .accepted
    )
    #expect(monoPlayer.admit(try silentBlock(frameCount: 958, channels: 1), generation: 2) == .accepted)
    let mono = monoBackend.pull(frameCount: 2)
    #expect(mono.left == mono.right)
    #expect(mono.left[1] == -0.25)
    await monoPlayer.deactivate(generation: 2)
}

@Test
func boundedPCMAudioRejectsOldMissingMismatchedAndStaleGenerationPackets() async throws {
    let clock = LockedAudioClock(now: 200_000_001)
    let backend = FakePCMAudioPlaybackBackend()
    let player = BoundedPCMAudioPlayer(
        backend: backend,
        jitterConfiguration: playerJitterConfiguration,
        uptimeNanoseconds: { clock.now() }
    )
    try await player.activate(generation: 7)

    let old = try pcmBlock(
        samples: [1, -1],
        frameCount: 1,
        channels: 2,
        receivedUptimeNanoseconds: 50_000_000
    )
    #expect(player.admit(old, generation: 7) == .formatMissing)
    #expect(player.configure(try stereoFormat(), generation: 6) == .staleGeneration)
    #expect(player.configure(try stereoFormat(), generation: 7) == .accepted)
    #expect(player.admit(old, generation: 7) == .stalePacket)
    #expect(
        player.admit(
            try pcmBlock(samples: [1], frameCount: 1, channels: 1),
            generation: 7
        ) == .formatMismatch
    )
    #expect(player.admit(try taggedBlock(1), generation: 8) == .staleGeneration)
    #expect(player.configure(try unsupportedFormat(), generation: 7) == .formatMismatch)

    let snapshot = player.snapshot()
    #expect(snapshot.queue.invalidBuffers == 3)
    #expect(snapshot.queue.droppedBuffers == 1)
    #expect(snapshot.queue.stalePacketDrops == 1)
    #expect(snapshot.queue.acceptedBuffers == 0)
    #expect(player.jitterBufferSnapshotForTesting().writtenFrames == 0)
    await player.deactivate(generation: 7)
}

@Test
func boundedPCMAudioMatchedPaceNeverUnderrunsOrSkips() async throws {
    let backend = FakePCMAudioPlaybackBackend()
    let player = BoundedPCMAudioPlayer(backend: backend, jitterConfiguration: playerJitterConfiguration)
    try await player.activate(generation: 1)
    #expect(player.configure(try stereoFormat(), generation: 1) == .accepted)

    // Prime to the 20 ms target, then keep ingress and hardware pulls matched
    // across the 4,900-packet window used by the physical-run reports.
    for value in 1...2 {
        #expect(player.admit(try taggedBlock(Int16(value)), generation: 1) == .accepted)
    }
    let reportedWindow = 4_900
    for index in 0..<reportedWindow {
        #expect(player.admit(try taggedBlock(Int16(index % 30_000)), generation: 1) == .accepted)
        _ = backend.pull(frameCount: 480)
    }

    let queue = player.snapshot().queue
    #expect(queue.receivedBuffers == reportedWindow + 2)
    #expect(queue.acceptedBuffers == reportedWindow + 2)
    #expect(queue.renderedBuffers == reportedWindow)
    #expect(queue.scheduledBuffers == 2)
    #expect(queue.backlogMilliseconds == 20)
    #expect(queue.droppedBuffers == 0)
    #expect(queue.stalePacketDrops == 0)
    #expect(queue.backpressureDrops == 0)
    #expect(queue.pendingOverflowDrops == 0)
    #expect(queue.underruns == 0)
    #expect(queue.silenceMilliseconds == 0)
    #expect(queue.catchingUp == false)
    // 49 s without an underrun lowered the target from 20 ms to the 10 ms floor.
    #expect(Int(queue.targetLatencyMilliseconds) == 10)
    await player.deactivate(generation: 1)
}

@Test
func boundedPCMAudioReportsUnderrunsSkipsAndTargetThroughTheSharedSnapshot() async throws {
    let backend = FakePCMAudioPlaybackBackend()
    let player = BoundedPCMAudioPlayer(backend: backend, jitterConfiguration: playerJitterConfiguration)
    try await player.activate(generation: 1)
    #expect(player.configure(try stereoFormat(), generation: 1) == .accepted)

    // Prime, then starve the hardware for one pull: an underrun raises the
    // target from 20 ms to 30 ms and is visible on the Stats surface.
    for _ in 0..<2 { _ = player.admit(try taggedBlock(1), generation: 1) }
    for _ in 0..<3 { _ = backend.pull(frameCount: 480) }
    var queue = player.snapshot().queue
    #expect(queue.underruns == 1)
    #expect(queue.silenceMilliseconds == 10)
    #expect(Int(queue.targetLatencyMilliseconds) == 30)
    #expect(queue.catchingUp)
    #expect(queue.lowWaterMark == 3)
    #expect(queue.highWaterMark == 7)

    // A burst far above the ceiling (30 + 40 ms) skips the oldest audio; the
    // skip is reported in the legacy "pressure" slot as whole packets.
    for _ in 0..<8 { _ = player.admit(try taggedBlock(2), generation: 1) }
    queue = player.snapshot().queue
    #expect(queue.backpressureDrops == 5)
    #expect(queue.droppedBuffers == 5)
    #expect(queue.scheduledBuffers == 3)
    #expect(queue.acceptedBuffers == 10)
    await player.deactivate(generation: 1)
}

@Test
func boundedPCMAudioStaleGenerationCannotWriteIntoAReconnectedSession() async throws {
    let backend = FakePCMAudioPlaybackBackend()
    let player = BoundedPCMAudioPlayer(backend: backend, jitterConfiguration: playerJitterConfiguration)

    try await player.activate(generation: 1)
    #expect(player.configure(try stereoFormat(), generation: 1) == .accepted)
    #expect(player.admit(try taggedBlock(1), generation: 1) == .accepted)
    await player.deactivate(generation: 1)
    #expect(player.jitterBufferSnapshotForTesting().fillFrames == 0)

    try await player.activate(generation: 2)
    #expect(player.configure(try stereoFormat(), generation: 2) == .accepted)
    #expect(player.admit(try taggedBlock(1), generation: 1) == .staleGeneration)
    #expect(player.admit(try taggedBlock(2), generation: 2) == .accepted)
    #expect(player.jitterBufferSnapshotForTesting().fillFrames == 480)
    #expect(player.snapshot().queue.receivedBuffers == 1)
    await player.deactivate(generation: 2)
}

@Test
func boundedPCMAudioRecoveryIsSingleFlightKeepsTheLearnedTargetAndReappliesControls() async throws {
    let backend = FakePCMAudioPlaybackBackend()
    let player = BoundedPCMAudioPlayer(backend: backend, jitterConfiguration: playerJitterConfiguration)
    let controls = player.makeControls()
    try await player.activate(generation: 1)
    #expect(player.configure(try stereoFormat(), generation: 1) == .accepted)
    controls.setVolume(0.4)
    controls.setMuted(true)
    #expect(await audioEventually { backend.lastVolume() == 0 })

    // Learn a 30 ms target through one underrun, then queue some audio.
    for _ in 0..<2 { _ = player.admit(try taggedBlock(1), generation: 1) }
    for _ in 0..<3 { _ = backend.pull(frameCount: 480) }
    for _ in 0..<3 { _ = player.admit(try taggedBlock(1), generation: 1) }
    #expect(player.jitterBufferSnapshotForTesting().fillFrames == 1_440)

    backend.blockNextActivation()
    backend.triggerRecovery()
    #expect(await audioEventually { backend.activationIsBlocked() })
    backend.triggerRecovery()
    backend.releaseBlockedActivation()
    #expect(await audioEventually {
        let snapshot = player.snapshot()
        return backend.activationCount() == 2
            && snapshot.state == .playing
            && snapshot.recoveries == 1
    })
    #expect(backend.activationVolumes().last == 0)
    let ring = player.jitterBufferSnapshotForTesting()
    #expect(ring.fillFrames == 0)
    #expect(ring.priming)
    #expect(ring.targetFrames == 1_440)

    // The new engine pulls through the re-installed render handler.
    for _ in 0..<3 { _ = player.admit(try taggedBlock(3), generation: 1) }
    let pulled = backend.pull(frameCount: 480)
    #expect(pulled.left[1] == Float(3) / 32_768)

    controls.setMuted(false)
    #expect(await audioEventually { backend.lastVolume() == 0.4 })
    await player.deactivate(generation: 1)
}

@Test
func boundedPCMAudioActivationFailureClosesTheGeneration() async throws {
    let backend = FakePCMAudioPlaybackBackend(activationFailuresRemaining: 1)
    let player = BoundedPCMAudioPlayer(backend: backend, jitterConfiguration: playerJitterConfiguration)

    await #expect(throws: PCMAudioPlaybackError.backendActivationFailed) {
        try await player.activate(generation: 1)
    }
    #expect(player.snapshot().state == .failed)
    #expect(player.snapshot().activeGeneration == nil)
    #expect(player.snapshot().activationFailures == 1)
    #expect(backend.stopCount() >= 1)
}

@Test
func boundedPCMAudioSupersededActivationCannotStopTheNewGeneration() async throws {
    let backend = FakePCMAudioPlaybackBackend()
    let player = BoundedPCMAudioPlayer(backend: backend, jitterConfiguration: playerJitterConfiguration)
    backend.blockNextActivation()

    let firstActivation = Task { () -> Bool in
        do {
            try await player.activate(generation: 1)
            return true
        } catch {
            return false
        }
    }
    #expect(await audioEventually { backend.activationIsBlocked() })

    let secondActivation = Task {
        try await player.activate(generation: 2)
    }
    #expect(await audioEventually {
        let snapshot = player.snapshot()
        return snapshot.activeGeneration == 2 && snapshot.state == .activating
    })

    // Keep the second backend activation blocked until the first worker job
    // has detected supersession and stopped its own backend instance.
    backend.blockNextActivation()
    backend.releaseBlockedActivation()
    #expect(await audioEventually {
        backend.activationCount() == 2 && backend.activationIsBlocked()
    })
    backend.releaseBlockedActivation()

    #expect(await firstActivation.value == false)
    try await secondActivation.value
    #expect(player.snapshot().activeGeneration == 2)
    #expect(player.snapshot().state == .playing)

    #expect(player.configure(try stereoFormat(), generation: 2) == .accepted)
    #expect(player.admit(try taggedBlock(2), generation: 2) == .accepted)
    #expect(player.jitterBufferSnapshotForTesting().fillFrames == 480)
    await player.deactivate(generation: 2)
}

// MARK: - Fake backend

private struct RenderedAudioSamples: Sendable {
    let left: [Float]
    let right: [Float]
}

private struct FakeAudioBackendError: Error, Sendable {}

private final class FakePCMAudioPlaybackBackend: PCMAudioPlaybackBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let activationRelease = DispatchSemaphore(value: 0)
    private var recoveryHandler: (@Sendable () -> Void)?
    private var activationFailuresRemaining: Int
    private var activations = 0
    private var activationVolumeValues: [Float] = []
    private var volumeValues: [Float] = []
    private var stops = 0
    private var render: PCMAudioRenderHandler?
    private var shouldBlockNextActivation = false
    private var activationBlocked = false

    init(activationFailuresRemaining: Int = 0) {
        self.activationFailuresRemaining = activationFailuresRemaining
    }

    func installRecoveryHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { recoveryHandler = handler }
    }

    func activate(
        outputFormat: AVAudioFormat,
        volume: Float,
        render: @escaping PCMAudioRenderHandler
    ) throws -> PCMAudioRouteMetrics {
        let shouldBlock = lock.withLock { () -> Bool in
            activations += 1
            activationVolumeValues.append(volume)
            volumeValues.append(volume)
            guard shouldBlockNextActivation else { return false }
            shouldBlockNextActivation = false
            activationBlocked = true
            return true
        }
        if shouldBlock {
            activationRelease.wait()
            lock.withLock { activationBlocked = false }
        }

        return try lock.withLock {
            if activationFailuresRemaining > 0 {
                activationFailuresRemaining -= 1
                throw FakeAudioBackendError()
            }
            self.render = render
            return PCMAudioRouteMetrics(
                sampleRate: outputFormat.sampleRate,
                outputLatency: 0.01,
                ioBufferDuration: 0.005,
                presentationLatency: 0.02
            )
        }
    }

    func setVolume(_ volume: Float) {
        lock.withLock { volumeValues.append(volume) }
    }

    func stop() {
        lock.withLock {
            stops += 1
            render = nil
        }
    }

    /// Simulates one hardware pull through the installed render handler.
    func pull(frameCount: Int) -> RenderedAudioSamples {
        guard let render = lock.withLock({ render }) else {
            return RenderedAudioSamples(left: [], right: [])
        }
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        left.withUnsafeMutableBufferPointer { leftPointer in
            right.withUnsafeMutableBufferPointer { rightPointer in
                render(leftPointer.baseAddress!, rightPointer.baseAddress!, frameCount)
            }
        }
        return RenderedAudioSamples(left: left, right: right)
    }

    func blockNextActivation() {
        lock.withLock { shouldBlockNextActivation = true }
    }

    func releaseBlockedActivation() {
        activationRelease.signal()
    }

    func activationIsBlocked() -> Bool {
        lock.withLock { activationBlocked }
    }

    func triggerRecovery() {
        lock.withLock { recoveryHandler }?()
    }

    func activationCount() -> Int {
        lock.withLock { activations }
    }

    func activationVolumes() -> [Float] {
        lock.withLock { activationVolumeValues }
    }

    func lastVolume() -> Float? {
        lock.withLock { volumeValues.last }
    }

    func stopCount() -> Int {
        lock.withLock { stops }
    }
}

private final class LockedAudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(now: UInt64) {
        self.value = now
    }

    func now() -> UInt64 {
        lock.withLock { value }
    }
}

// MARK: - Fixtures

private func stereoFormat() throws -> StreamingAudioFormat {
    try StreamingAudioFormat(channelCount: 2, bitsPerSample: 16, sampleRate: 48_000, frameSize: 4)
}

private func monoFormat() throws -> StreamingAudioFormat {
    try StreamingAudioFormat(channelCount: 1, bitsPerSample: 16, sampleRate: 48_000, frameSize: 2)
}

private func unsupportedFormat() throws -> StreamingAudioFormat {
    try StreamingAudioFormat(channelCount: 2, bitsPerSample: 16, sampleRate: 44_100, frameSize: 4)
}

private func pcmBlock(
    samples: [Int16],
    frameCount: Int,
    channels: Int,
    receivedUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
) throws -> InterleavedS16PCMBlock {
    var data = Data(count: samples.count * MemoryLayout<Int16>.size)
    data.withUnsafeMutableBytes { rawBuffer in
        let pointer = rawBuffer.bindMemory(to: Int16.self)
        for (index, sample) in samples.enumerated() {
            pointer[index] = sample
        }
    }
    return try InterleavedS16PCMBlock(
        data: data,
        frameCount: frameCount,
        channelCount: channels,
        sampleRate: 48_000,
        receivedUptimeNanoseconds: receivedUptimeNanoseconds
    )
}

/// One 10 ms stereo packet whose every sample carries `value`.
private func taggedBlock(_ value: Int16) throws -> InterleavedS16PCMBlock {
    try pcmBlock(samples: Array(repeating: value, count: 960), frameCount: 480, channels: 2)
}

private func silentBlock(frameCount: Int, channels: Int = 2) throws -> InterleavedS16PCMBlock {
    try pcmBlock(samples: Array(repeating: 0, count: frameCount * channels), frameCount: frameCount, channels: channels)
}

private func audioEventually(
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}
