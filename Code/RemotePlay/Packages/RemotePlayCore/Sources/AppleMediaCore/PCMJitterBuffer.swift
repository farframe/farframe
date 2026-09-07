import Foundation
import os

/// A realtime-safe PCM ring buffer with an adaptive playout target.
///
/// Remote Play delivers 10 ms audio packets, but a jittery Wi-Fi path hands
/// them to the app in bursts: nothing for 100 to 150 ms, then a dozen packets at
/// once. A fixed queue of scheduled buffers cannot survive that pattern. It
/// starves during the stall (silence, hitches) and overflows when the burst
/// lands (dropped packets, crackle). Both apps that preceded this one showed
/// exactly those two counters on the same network.
///
/// This buffer decouples the two clocks. The network thread writes converted
/// samples; the audio hardware pulls exactly what it needs from the render
/// thread. Playback waits until `targetFrames` of audio are queued, so a stall
/// shorter than the target is invisible. Each underrun raises the target so
/// the next stall of that size is absorbed; long quiet stretches lower it
/// again so latency does not stay high forever. When a burst leaves far more
/// than the target queued, the oldest audio is skipped once, with a short
/// crossfade, so latency never drifts upward permanently.
///
/// The render path never allocates. Both sides take one unfair lock for a few
/// microseconds around a memcpy-sized copy.
package final class PCMJitterBuffer: @unchecked Sendable {
    package struct Configuration: Equatable, Sendable {
        package var sampleRate: Int
        /// Total ring capacity. Larger than any burst we expect to absorb.
        package var capacityFrames: Int
        /// Playout latency requested before the first frame plays.
        package var initialTargetFrames: Int
        package var minimumTargetFrames: Int
        package var maximumTargetFrames: Int
        /// Added to the target after every underrun.
        package var raiseStepFrames: Int
        /// Removed from the target after a quiet window with no underrun.
        package var lowerStepFrames: Int
        /// Frames above the target tolerated before the oldest audio is skipped.
        package var skipSlackFrames: Int
        /// Rendered frames without an underrun before the target is lowered.
        package var quietWindowFrames: Int
        /// Crossfade length applied after any discontinuity.
        package var fadeFrames: Int

        package init(
            sampleRate: Int = 48_000,
            capacityFrames: Int = 28_800,
            initialTargetFrames: Int = 3_840,
            minimumTargetFrames: Int = 1_920,
            maximumTargetFrames: Int = 11_520,
            raiseStepFrames: Int = 1_440,
            lowerStepFrames: Int = 480,
            skipSlackFrames: Int = 4_800,
            quietWindowFrames: Int = 48_000 * 5,
            fadeFrames: Int = 96
        ) {
            self.sampleRate = sampleRate
            self.capacityFrames = capacityFrames
            self.initialTargetFrames = initialTargetFrames
            self.minimumTargetFrames = minimumTargetFrames
            self.maximumTargetFrames = maximumTargetFrames
            self.raiseStepFrames = raiseStepFrames
            self.lowerStepFrames = lowerStepFrames
            self.skipSlackFrames = skipSlackFrames
            self.quietWindowFrames = quietWindowFrames
            self.fadeFrames = fadeFrames
        }

        /// 48 kHz stereo Remote Play: 600 ms ring, 80 ms initial target, 40 to
        /// 240 ms adaptive range, one 30 ms raise per underrun, 100 ms skip
        /// slack, 5 s quiet window, 2 ms crossfade.
        ///
        /// The quiet window is short on purpose. Raising costs 30 ms and is
        /// instant; lowering returns 10 ms. With a 20 s window a burst of
        /// underruns pinned the target near its 240 ms ceiling for the rest of
        /// the session. Five seconds of clean render is enough evidence to
        /// start walking it back.
        package static let remotePlay = Configuration()
    }

    package enum WriteOutcome: Equatable, Sendable {
        case accepted
        /// Accepted, but the oldest `frames` were skipped to pull latency back.
        case acceptedAfterSkip(frames: Int)
        /// The ring had no room; the incoming block was dropped.
        case overflow
    }

    package struct Snapshot: Equatable, Sendable {
        package let fillFrames: Int
        package let targetFrames: Int
        package let priming: Bool
        package let writtenFrames: Int
        package let renderedFrames: Int
        package let skippedFrames: Int
        package let overflowFrames: Int
        package let silenceFrames: Int
        package let underruns: Int
    }

    package let configuration: Configuration

    private let lock = OSAllocatedUnfairLock()
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>

    // Lock-protected state.
    private var readIndex = 0
    private var fill = 0
    private var targetFrames: Int
    private var priming = true
    private var pendingFadeFrames = 0
    private var lastLeft: Float = 0
    private var lastRight: Float = 0
    private var framesSinceUnderrun = 0
    private var writtenFrames = 0
    private var renderedFrames = 0
    private var skippedFrames = 0
    private var overflowFrames = 0
    private var silenceFrames = 0
    private var underruns = 0

    package init(configuration: Configuration = .remotePlay) {
        precondition(configuration.capacityFrames > 0)
        precondition(configuration.minimumTargetFrames <= configuration.initialTargetFrames)
        precondition(configuration.initialTargetFrames <= configuration.maximumTargetFrames)
        precondition(
            configuration.maximumTargetFrames + configuration.skipSlackFrames
                <= configuration.capacityFrames
        )
        self.configuration = configuration
        self.targetFrames = configuration.initialTargetFrames
        left = .allocate(capacity: configuration.capacityFrames)
        right = .allocate(capacity: configuration.capacityFrames)
        left.initialize(repeating: 0, count: configuration.capacityFrames)
        right.initialize(repeating: 0, count: configuration.capacityFrames)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// Clears queued audio and returns to priming. The learned target is kept
    /// when `keepTarget` is true (route change mid-session) and reset otherwise
    /// (new session).
    package func reset(keepTarget: Bool = false) {
        lock.withLockUnchecked {
            readIndex = 0
            fill = 0
            priming = true
            pendingFadeFrames = 0
            lastLeft = 0
            lastRight = 0
            framesSinceUnderrun = 0
            writtenFrames = 0
            renderedFrames = 0
            skippedFrames = 0
            overflowFrames = 0
            silenceFrames = 0
            underruns = 0
            if keepTarget == false {
                targetFrames = configuration.initialTargetFrames
            }
        }
    }

    /// Converts interleaved signed 16-bit PCM into the ring. Mono is duplicated
    /// to both channels; channels beyond the second are ignored.
    package func write(
        interleavedInt16 samples: UnsafePointer<Int16>,
        frameCount: Int,
        channelCount: Int
    ) -> WriteOutcome {
        guard frameCount > 0, channelCount > 0 else { return .accepted }
        let capacity = configuration.capacityFrames
        return lock.withLockUnchecked { () -> WriteOutcome in
            guard fill + frameCount <= capacity else {
                overflowFrames += frameCount
                return .overflow
            }

            var writeIndex = (readIndex + fill) % capacity
            let rightOffset = min(1, channelCount - 1)
            let scale: Float = 1 / 32_768
            for frame in 0..<frameCount {
                let base = frame * channelCount
                left[writeIndex] = Float(samples[base]) * scale
                right[writeIndex] = Float(samples[base + rightOffset]) * scale
                writeIndex += 1
                if writeIndex == capacity { writeIndex = 0 }
            }
            fill += frameCount
            writtenFrames += frameCount

            let ceiling = targetFrames + configuration.skipSlackFrames
            guard fill > ceiling else { return .accepted }
            // A burst left far more queued than the target. Skip the oldest
            // audio once so latency snaps back; the render side crossfades.
            let skipped = fill - targetFrames
            readIndex = (readIndex + skipped) % capacity
            fill = targetFrames
            skippedFrames += skipped
            pendingFadeFrames = configuration.fadeFrames
            return .acceptedAfterSkip(frames: skipped)
        }
    }

    /// Fills `frameCount` frames for the hardware. Called from the realtime
    /// render thread; never allocates. Returns the number of real audio frames
    /// delivered (the remainder was silence).
    @discardableResult
    package func render(
        left output: UnsafeMutablePointer<Float>,
        right outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) -> Int {
        guard frameCount > 0 else { return 0 }
        let capacity = configuration.capacityFrames
        return lock.withLockUnchecked { () -> Int in
            if priming {
                guard fill >= targetFrames else {
                    output.update(repeating: 0, count: frameCount)
                    outputRight.update(repeating: 0, count: frameCount)
                    // Silence before the first packet is the stream starting,
                    // not a buffering event.
                    if writtenFrames > 0 { silenceFrames += frameCount }
                    return 0
                }
                priming = false
                pendingFadeFrames = configuration.fadeFrames
                lastLeft = 0
                lastRight = 0
            }

            let available = min(fill, frameCount)
            var index = readIndex
            for frame in 0..<available {
                var l = left[index]
                var r = right[index]
                if pendingFadeFrames > 0 {
                    let total = Float(configuration.fadeFrames)
                    let progress = 1 - Float(pendingFadeFrames) / total
                    l = lastLeft * (1 - progress) + l * progress
                    r = lastRight * (1 - progress) + r * progress
                    pendingFadeFrames -= 1
                }
                output[frame] = l
                outputRight[frame] = r
                index += 1
                if index == capacity { index = 0 }
            }
            if available > 0 {
                // A later skip or underrun fades from the last sample heard.
                lastLeft = output[available - 1]
                lastRight = outputRight[available - 1]
            }
            readIndex = index
            fill -= available
            renderedFrames += available
            framesSinceUnderrun += available

            if available < frameCount {
                let missing = frameCount - available
                (output + available).update(repeating: 0, count: missing)
                (outputRight + available).update(repeating: 0, count: missing)
                silenceFrames += missing
                underruns += 1
                priming = true
                framesSinceUnderrun = 0
                lastLeft = 0
                lastRight = 0
                targetFrames = min(
                    configuration.maximumTargetFrames,
                    targetFrames + configuration.raiseStepFrames
                )
            } else if framesSinceUnderrun >= configuration.quietWindowFrames,
                      targetFrames > configuration.minimumTargetFrames {
                framesSinceUnderrun = 0
                targetFrames = max(
                    configuration.minimumTargetFrames,
                    targetFrames - configuration.lowerStepFrames
                )
            }
            return available
        }
    }

    package func snapshot() -> Snapshot {
        lock.withLockUnchecked {
            Snapshot(
                fillFrames: fill,
                targetFrames: targetFrames,
                priming: priming,
                writtenFrames: writtenFrames,
                renderedFrames: renderedFrames,
                skippedFrames: skippedFrames,
                overflowFrames: overflowFrames,
                silenceFrames: silenceFrames,
                underruns: underruns
            )
        }
    }
}
