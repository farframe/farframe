import CoreMedia
import StreamingCore

/// Callback timestamps are the only common monotonic clock provided for audio
/// and video. Smooth small audio arrival jitter with the sample clock, but
/// preserve a real callback interruption instead of pulling all later sound
/// earlier than the picture. This affects the recording, never live playback.
struct GameplayRecordingAudioClock {
    private var nextTime: CMTime?
    mutating func presentationTime(for block: InterleavedS16PCMBlock) -> CMTime {
        let duration = CMTime(value: Int64(block.frameCount), timescale: Int32(block.sampleRate))
        let arrival = CMTime(value: Int64(block.receivedUptimeNanoseconds / 1_000), timescale: 1_000_000) - duration
        let expected = nextTime ?? arrival
        let time = (arrival - expected).seconds > 0.1 ? arrival : expected
        nextTime = time + duration
        return time
    }
}

/// Select one source frame per 1/30-second interval anchored to recording start.
/// Measuring from the last selected frame drifted under jitter and routinely
/// discarded an extra source frame, reducing 60fps input to about 24–26fps.
struct GameplayRecordingVideoCadence {
    private var lastSlot: Int64?
    func accepts(_ time: CMTime) -> Bool {
        guard time.isNumeric, time >= .zero else { return false }
        let slot = CMTimeConvertScale(time, timescale: 30, method: .roundTowardZero).value
        return lastSlot.map { slot > $0 } ?? true
    }
    mutating func didAppend(_ time: CMTime) {
        lastSlot = CMTimeConvertScale(time, timescale: 30, method: .roundTowardZero).value
    }
}
