import CoreMedia
import Foundation
import StreamingCore
import Testing
@testable import AppleMediaCore

struct GameplayRecordingTimingTests {
    private func block(endingAt seconds: Double) throws -> InterleavedS16PCMBlock {
        try InterleavedS16PCMBlock(data: Data(repeating: 0, count: 1920), frameCount: 480,
            channelCount: 2, sampleRate: 48_000,
            receivedUptimeNanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
    }
    @Test func interruptedAudioKeepsItsPlaceOnVideoTimeline() throws {
        var clock = GameplayRecordingAudioClock()
        #expect(abs(clock.presentationTime(for: try block(endingAt: 100.01)).seconds - 100) < 0.00001)
        #expect(abs(clock.presentationTime(for: try block(endingAt: 100.02)).seconds - 100.01) < 0.00001)
        // A source interruption like the first submitted clip must leave a gap,
        // not place resumed sound 2.7 seconds ahead of the matching video.
        #expect(abs(clock.presentationTime(for: try block(endingAt: 102.73)).seconds - 102.72) < 0.00001)
        #expect(abs(clock.presentationTime(for: try block(endingAt: 102.74)).seconds - 102.73) < 0.00001)
    }
    @Test func smallArrivalJitterAndBoundedDropsDoNotShiftSound() throws {
        var clock = GameplayRecordingAudioClock()
        _ = clock.presentationTime(for: try block(endingAt: 100.01))
        // The writer may drop this block; the admission clock still advances.
        _ = clock.presentationTime(for: try block(endingAt: 100.024))
        #expect(abs(clock.presentationTime(for: try block(endingAt: 100.029)).seconds - 100.02) < 0.00001)
    }
    @Test func jitteredSixtyFPSInputKeepsThirtyFPSSelection() {
        var cadence = GameplayRecordingVideoCadence()
        var accepted: [Double] = []
        for n in 0..<600 {
            let jitter = n == 0 ? 0 : (n.isMultiple(of: 2) ? -0.004 : 0.004)
            let time = CMTime(seconds: Double(n) / 60 + jitter, preferredTimescale: 1_000_000)
            if cadence.accepts(time) { cadence.didAppend(time); accepted.append(time.seconds) }
        }
        #expect(accepted.count == 300)
        #expect(zip(accepted, accepted.dropFirst()).allSatisfy { $0 < $1 })
    }
    @Test func videoDiscontinuityDoesNotDuplicateOrBackfillFrames() {
        var cadence = GameplayRecordingVideoCadence()
        let first = CMTime.zero
        #expect(cadence.accepts(first)); cadence.didAppend(first)
        #expect(!cadence.accepts(first))
        #expect(!cadence.accepts(CMTime(value: -1, timescale: 30)))
        #expect(!cadence.accepts(.invalid))
        let resumed = CMTime(seconds: 2.7, preferredTimescale: 1_000_000)
        #expect(cadence.accepts(resumed)); cadence.didAppend(resumed)
        #expect(!cadence.accepts(CMTime(seconds: 1, preferredTimescale: 1_000_000)))
    }
}
