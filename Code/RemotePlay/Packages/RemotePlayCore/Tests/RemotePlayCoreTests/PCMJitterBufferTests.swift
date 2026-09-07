@testable import AppleMediaCore
import Foundation
import Testing

/// 48 kHz, 10 ms packets. Small target/slack values keep the tests fast while
/// exercising the same rules as the Remote Play configuration.
private let testConfiguration = PCMJitterBuffer.Configuration(
    sampleRate: 48_000,
    capacityFrames: 9_600,          // 200 ms
    initialTargetFrames: 1_440,     // 30 ms
    minimumTargetFrames: 960,       // 20 ms
    maximumTargetFrames: 4_800,     // 100 ms
    raiseStepFrames: 960,           // 20 ms
    lowerStepFrames: 480,           // 10 ms
    skipSlackFrames: 1_920,         // 40 ms
    quietWindowFrames: 48_000,      // 1 s
    fadeFrames: 48
)

private let packetFrames = 480

@Test
func jitterBufferPrimesToTargetThenPlaysContinuously() {
    let buffer = PCMJitterBuffer(configuration: testConfiguration)
    var output = RenderScratch(frames: packetFrames)

    // Two packets queued is below the 30 ms target: silence, nothing consumed.
    #expect(buffer.write(packet(value: 1_000)) == .accepted)
    #expect(buffer.write(packet(value: 1_000)) == .accepted)
    #expect(output.pull(from: buffer) == 0)
    #expect(buffer.snapshot().fillFrames == 2 * packetFrames)
    #expect(buffer.snapshot().priming)

    // The third packet reaches the target; playback starts and stays steady.
    #expect(buffer.write(packet(value: 1_000)) == .accepted)
    #expect(output.pull(from: buffer) == packetFrames)
    #expect(buffer.snapshot().priming == false)
    for _ in 0..<200 {
        #expect(buffer.write(packet(value: 1_000)) == .accepted)
        #expect(output.pull(from: buffer) == packetFrames)
    }
    let snapshot = buffer.snapshot()
    #expect(snapshot.underruns == 0)
    #expect(snapshot.skippedFrames == 0)
    #expect(snapshot.overflowFrames == 0)
    #expect(snapshot.fillFrames == 2 * packetFrames)
    #expect(abs(output.left.last! - Float(1_000) / 32_768) < 0.000_01)
}

@Test
func jitterBufferUnderrunRaisesTargetAndRePrimes() {
    let buffer = PCMJitterBuffer(configuration: testConfiguration)
    var output = RenderScratch(frames: packetFrames)
    for _ in 0..<3 { _ = buffer.write(packet(value: 4_000)) }
    #expect(output.pull(from: buffer) == packetFrames)

    // Drain the remaining 20 ms and then ask for more: one underrun.
    #expect(output.pull(from: buffer) == packetFrames)
    #expect(output.pull(from: buffer) == packetFrames)
    #expect(output.pull(from: buffer) == 0)
    var snapshot = buffer.snapshot()
    #expect(snapshot.underruns == 1)
    #expect(snapshot.priming)
    #expect(snapshot.targetFrames == 1_440 + 960)
    #expect(snapshot.silenceFrames == packetFrames)

    // Playback waits for the raised 50 ms target before resuming.
    for _ in 0..<4 { _ = buffer.write(packet(value: 4_000)) }
    #expect(output.pull(from: buffer) == 0)
    _ = buffer.write(packet(value: 4_000))
    #expect(output.pull(from: buffer) == packetFrames)
    snapshot = buffer.snapshot()
    #expect(snapshot.priming == false)
    #expect(snapshot.underruns == 1)

    // A partial pull counts as an underrun too and zero-fills the remainder.
    for _ in 0..<4 { #expect(output.pull(from: buffer) == packetFrames) }
    _ = buffer.write(halfPacket(value: 4_000))
    #expect(output.pull(from: buffer) == packetFrames / 2)
    #expect(output.left[packetFrames - 1] == 0)
    #expect(buffer.snapshot().underruns == 2)
    #expect(buffer.snapshot().targetFrames == 1_440 + 2 * 960)
}

@Test
func jitterBufferTargetClampsAtMaximumAndLowersAfterQuietWindow() {
    let buffer = PCMJitterBuffer(configuration: testConfiguration)
    var output = RenderScratch(frames: packetFrames)
    // Force many underruns: alternate one packet and one pull.
    for _ in 0..<12 {
        for _ in 0..<(testConfiguration.maximumTargetFrames / packetFrames) {
            _ = buffer.write(packet(value: 100))
        }
        while output.pull(from: buffer) == packetFrames {}
    }
    #expect(buffer.snapshot().targetFrames == testConfiguration.maximumTargetFrames)

    // One quiet second of matched pace lowers the target by one step.
    for _ in 0..<(testConfiguration.maximumTargetFrames / packetFrames) {
        _ = buffer.write(packet(value: 100))
    }
    for _ in 0..<(48_000 / packetFrames + 2) {
        _ = buffer.write(packet(value: 100))
        #expect(output.pull(from: buffer) == packetFrames)
    }
    #expect(buffer.snapshot().targetFrames == testConfiguration.maximumTargetFrames - 480)
}

@Test
func jitterBufferSkipsOldestAudioWhenABurstOvershootsAndFadesTheSeam() {
    let buffer = PCMJitterBuffer(configuration: testConfiguration)
    var output = RenderScratch(frames: packetFrames)
    for _ in 0..<3 { _ = buffer.write(packet(value: 8_000)) }
    #expect(output.pull(from: buffer) == packetFrames)
    // 20 ms queued. Target 30 + slack 40 = 70 ms ceiling. Write 12 packets of a
    // different value: fill reaches 140 ms on the 12th write and snaps to 30.
    var skipped = 0
    for index in 0..<12 {
        let outcome = buffer.write(packet(value: -8_000))
        if case let .acceptedAfterSkip(frames) = outcome {
            skipped += frames
            #expect(index >= 5)
        }
    }
    // Skips land on the 6th and 11th writes (fill 3840 > 3360 both times),
    // each pulling fill back to the 30 ms target; one more write follows.
    let snapshot = buffer.snapshot()
    #expect(skipped == 2 * 2_400)
    #expect(snapshot.skippedFrames == skipped)
    #expect(snapshot.fillFrames == testConfiguration.initialTargetFrames + packetFrames)
    #expect(snapshot.underruns == 0)

    // The next render blends from the last heard sample (+8000) into the
    // skipped-to audio (-8000) over the fade window, then holds steady.
    #expect(output.pull(from: buffer) == packetFrames)
    let target = Float(-8_000) / 32_768
    let start = Float(8_000) / 32_768
    #expect(output.left[0] > target)
    #expect(output.left[0] <= start)
    for frame in 1..<testConfiguration.fadeFrames {
        #expect(output.left[frame] <= output.left[frame - 1] + 0.000_01)
    }
    #expect(abs(output.left[testConfiguration.fadeFrames] - target) < 0.000_01)
    #expect(abs(output.left[packetFrames - 1] - target) < 0.000_01)
}

@Test
func jitterBufferDropsIncomingAudioOnlyWhenTheRingIsFull() {
    let buffer = PCMJitterBuffer(configuration: PCMJitterBuffer.Configuration(
        sampleRate: 48_000,
        capacityFrames: 2_400,
        initialTargetFrames: 480,
        minimumTargetFrames: 480,
        maximumTargetFrames: 960,
        raiseStepFrames: 480,
        lowerStepFrames: 480,
        skipSlackFrames: 1_440,
        quietWindowFrames: 48_000,
        fadeFrames: 48
    ))
    // Ceiling is 480 + 1440 = 1920 frames. Capacity 2400. Write four packets
    // (1920, no skip), then a fifth (2400 fits, then skips down to 480).
    for _ in 0..<4 { #expect(buffer.write(packet(value: 1)) == .accepted) }
    #expect(buffer.write(packet(value: 1)) == .acceptedAfterSkip(frames: 1_920))
    for _ in 0..<3 { #expect(buffer.write(packet(value: 1)) == .accepted) }
    #expect(buffer.snapshot().fillFrames == 1_920)
    // A ring whose ceiling equals its capacity refuses the frame that would
    // not fit instead of skipping.
    let wide = PCMJitterBuffer(configuration: PCMJitterBuffer.Configuration(
        sampleRate: 48_000,
        capacityFrames: 960,
        initialTargetFrames: 480,
        minimumTargetFrames: 480,
        maximumTargetFrames: 480,
        raiseStepFrames: 480,
        lowerStepFrames: 480,
        skipSlackFrames: 480,
        quietWindowFrames: 48_000,
        fadeFrames: 48
    ))
    #expect(wide.write(packet(value: 1)) == .accepted)
    #expect(wide.write(packet(value: 1)) == .accepted)
    #expect(wide.write(packet(value: 1)) == .overflow)
    #expect(wide.snapshot().overflowFrames == 480)
}

@Test
func jitterBufferAbsorbsBurstyDeliveryAfterAdapting() {
    // The owner's network: the PS5 emits one 10 ms packet every 10 ms, but the
    // Wi-Fi path delays them by anywhere from 10 to 160 ms, changing every
    // half second. Packets therefore land in bursts after long stalls while the
    // hardware keeps pulling 10 ms every 10 ms.
    let buffer = PCMJitterBuffer(configuration: .remotePlay)
    var output = RenderScratch(frames: packetFrames)
    let delaysMilliseconds = [20, 150, 40, 120, 10, 160, 30, 140]
    let totalTicks = 3_000 // 30 s
    var nextPacket = 0
    var snapshots: [PCMJitterBuffer.Snapshot] = []
    for tick in 0..<totalTicks {
        // Deliver, in order, every packet whose delayed arrival is due.
        while nextPacket < totalTicks {
            let delay = delaysMilliseconds[(nextPacket / 50) % delaysMilliseconds.count]
            let arrivalTick = nextPacket + (delay + 9) / 10
            guard arrivalTick <= tick else { break }
            _ = buffer.write(packet(value: 2_000))
            nextPacket += 1
        }
        _ = output.pull(from: buffer)
        if tick % 500 == 499 { snapshots.append(buffer.snapshot()) }
    }
    let first = snapshots[snapshots.count / 2 - 1]
    let last = snapshots[snapshots.count - 1]
    // The first half may underrun and skip while the target climbs. The
    // second half must be clean: no new underruns, no new skips, no overflow.
    #expect(last.underruns == first.underruns)
    #expect(last.skippedFrames == first.skippedFrames)
    #expect(last.overflowFrames == 0)
    #expect(first.underruns > 0)
    // The target climbed from the 80 ms start to whatever this path needed
    // (priming phase decides the exact value) and stayed under the cap.
    #expect(last.targetFrames > PCMJitterBuffer.Configuration.remotePlay.initialTargetFrames)
    #expect(last.targetFrames <= PCMJitterBuffer.Configuration.remotePlay.maximumTargetFrames)
}

@Test
func jitterBufferConvertsMonoAndStereoAndResetsCounters() {
    let buffer = PCMJitterBuffer(configuration: testConfiguration)
    var output = RenderScratch(frames: 2)
    let stereo: [Int16] = [32_767, -32_768, 16_384, -16_384]
    stereo.withUnsafeBufferPointer { pointer in
        _ = buffer.write(interleavedInt16: pointer.baseAddress!, frameCount: 2, channelCount: 2)
    }
    // Fill to the target with silence packets so rendering starts.
    for _ in 0..<3 { _ = buffer.write(packet(value: 0)) }
    #expect(output.pull(from: buffer) == 2)
    // The first two frames are the priming crossfade from silence; check
    // the shape rather than exact values.
    #expect(output.left[0] >= 0)
    #expect(output.right[0] <= 0)
    #expect(output.left[1] > output.left[0])

    buffer.reset(keepTarget: true)
    let snapshot = buffer.snapshot()
    #expect(snapshot.fillFrames == 0)
    #expect(snapshot.renderedFrames == 0)
    #expect(snapshot.priming)

    let mono = PCMJitterBuffer(configuration: PCMJitterBuffer.Configuration(
        sampleRate: 48_000,
        capacityFrames: 480,
        initialTargetFrames: 2,
        minimumTargetFrames: 2,
        maximumTargetFrames: 2,
        raiseStepFrames: 0,
        lowerStepFrames: 0,
        skipSlackFrames: 400,
        quietWindowFrames: 48_000,
        fadeFrames: 1
    ))
    let monoSamples: [Int16] = [8_192, -8_192]
    monoSamples.withUnsafeBufferPointer { pointer in
        _ = mono.write(interleavedInt16: pointer.baseAddress!, frameCount: 2, channelCount: 1)
    }
    var monoOutput = RenderScratch(frames: 2)
    #expect(monoOutput.pull(from: mono) == 2)
    #expect(monoOutput.left == monoOutput.right)
    #expect(monoOutput.left[1] == -0.25)
}

// MARK: - Helpers

private func packet(value: Int16) -> [Int16] {
    Array(repeating: value, count: packetFrames * 2)
}

private func halfPacket(value: Int16) -> [Int16] {
    Array(repeating: value, count: packetFrames)
}

private extension PCMJitterBuffer {
    func write(_ interleavedStereo: [Int16]) -> WriteOutcome {
        interleavedStereo.withUnsafeBufferPointer { pointer in
            write(
                interleavedInt16: pointer.baseAddress!,
                frameCount: interleavedStereo.count / 2,
                channelCount: 2
            )
        }
    }
}

private struct RenderScratch {
    var left: [Float]
    var right: [Float]

    init(frames: Int) {
        left = Array(repeating: 0, count: frames)
        right = Array(repeating: 0, count: frames)
    }

    mutating func pull(from buffer: PCMJitterBuffer) -> Int {
        let frames = left.count
        return left.withUnsafeMutableBufferPointer { leftPointer in
            right.withUnsafeMutableBufferPointer { rightPointer in
                buffer.render(
                    left: leftPointer.baseAddress!,
                    right: rightPointer.baseAddress!,
                    frameCount: frames
                )
            }
        }
    }
}
