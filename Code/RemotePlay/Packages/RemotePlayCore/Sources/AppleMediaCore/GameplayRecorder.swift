import AVFoundation
import CoreMedia
import Foundation
import StreamingCore

public struct GameplayRecordingSnapshot: Equatable, Sendable {
    public enum Phase: String, Sendable { case idle, starting, recording, finishing, saved, failed }
    public var phase: Phase = .idle
    public var fileURL: URL?
    public var message: String?
    public var duration: Double = 0
    public var videoFrames = 0
    public var audioFrames = 0
    public var droppedVideoFrames = 0
    public var droppedAudioBlocks = 0
    public var canStop: Bool { phase == .starting || phase == .recording }
    public var isBusy: Bool { canStop || phase == .finishing }
    public init() {}
}

/// Local game-only recording. Provider callbacks make bounded, nonblocking
/// handoffs; all AVAssetWriter operations belong to one utility queue. This
/// does not capture windows, microphone, passthrough, credentials or controls.
public final class GameplayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Farframe.GameplayRecorder", qos: .utility)
    private var state = GameplayRecordingSnapshot()
    private var format: StreamingAudioFormat?
    private var blocked = false
    private var runID = UUID()
    private var pendingVideo = 0
    private var pendingAudio = 0
    private var audioClock = GameplayRecordingAudioClock()
    // Queue-owned writer state. Never read these from a provider callback.
    private var partialURL: URL?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixels: AVAssetWriterInputPixelBufferAdaptor?
    private var baseTime: CMTime?
    private var videoCadence = GameplayRecordingVideoCadence()
    private var writtenAudioEnd: CMTime?
    private var recordingFormat: StreamingAudioFormat?
    private var finishing = false
    private var stopWaiters: [CheckedContinuation<GameplayRecordingSnapshot, Never>] = []

    public init() {}
    public func snapshot() -> GameplayRecordingSnapshot { lock.withLock { state } }

    /// Call before a new transport attempt, once the previous recording has
    /// ended. Reconnection must obtain fresh audio format and content permission.
    public func resetSource() {
        lock.withLock {
            guard !state.isBusy else { return }
            format = nil
            blocked = false
        }
    }

    public func configureAudio(_ format: StreamingAudioFormat) {
        lock.withLock { self.format = format }
    }

    public func setContentBlocked(_ blocked: Bool) {
        let shouldStop = lock.withLock {
            self.blocked = blocked
            return blocked && state.canStop
        }
        if shouldStop { Task { _ = await stop() } }
    }

    /// The adapter chooses a unique app-owned output URL. Starting never
    /// overwrites a file and is independent of Photos/library permissions.
    public func start(to url: URL) throws {
        try lock.withLock {
            guard !state.isBusy else { throw failure("A recording is already in progress.") }
            guard !blocked else { throw failure("This screen cannot be recorded.") }
            guard url.isFileURL, !FileManager.default.fileExists(atPath: url.path) else {
                throw failure("Choose a new recording file.")
            }
            guard let format, format.bitsPerSample == 16,
                  (1...2).contains(format.channelCount),
                  [44_100, 48_000].contains(format.sampleRate) else {
                throw failure("Game audio is not ready to record. Try again once playback starts.")
            }
            runID = UUID()
            state = GameplayRecordingSnapshot()
            state.phase = .starting
            state.fileURL = url
            pendingVideo = 0; pendingAudio = 0
            audioClock = GameplayRecordingAudioClock()
            // Enqueue while holding admission lock so no incoming frame can
            // overtake setup, stop, or a subsequent recording generation.
            queue.async { [self] in
                partialURL = nil
                writer = nil; videoInput = nil; audioInput = nil; pixels = nil
                baseTime = nil; videoCadence = GameplayRecordingVideoCadence(); writtenAudioEnd = nil; recordingFormat = format
                finishing = false
            }
        }
    }

    public func submitVideo(_ frame: DecodedVideoFrame) {
        lock.withLock {
            guard state.canStop, !blocked else { return }
            guard pendingVideo < 3 else { state.droppedVideoFrames += 1; return }
            pendingVideo += 1
            let id = runID
            queue.async { [self] in
                defer { lock.withLock { if runID == id { pendingVideo -= 1 } } }
                guard lock.withLock({ runID == id }), !finishing else { return }
                do { try writeVideo(frame) } catch { failRecording(error.localizedDescription) }
            }
        }
    }

    public func submitAudio(_ block: InterleavedS16PCMBlock) {
        lock.withLock {
            guard state.canStop, !blocked else { return }
            // Advance for every received block, even when our bounded queue
            // drops one. Preserve source interruptions against the video clock.
            let time = audioClock.presentationTime(for: block)
            guard pendingAudio < 24 else { state.droppedAudioBlocks += 1; return }
            pendingAudio += 1
            let id = runID
            queue.async { [self] in
                defer { lock.withLock { if runID == id { pendingAudio -= 1 } } }
                guard lock.withLock({ runID == id }), !finishing else { return }
                do { try writeAudio(block, time: time) } catch { failRecording(error.localizedDescription) }
            }
        }
    }

    /// Handles stop while waiting for the first frame, repeated stop, session
    /// ending, and normal completion. All callers await the same finalization.
    @discardableResult
    public func stop() async -> GameplayRecordingSnapshot {
        await withCheckedContinuation { continuation in
            lock.withLock {
                guard state.isBusy else { continuation.resume(returning: state); return }
                if state.canStop { state.phase = .finishing }
                queue.async { [self] in
                    stopWaiters.append(continuation)
                    guard !finishing else { return }
                    let current = snapshot()
                    guard current.phase == .finishing else { completeWaiters(); return }
                    finishing = true
                    guard let writer, current.videoFrames > 0, current.audioFrames > 0 else {
                        failRecording("No complete game picture and audio were received. Nothing was saved.")
                        completeWaiters()
                        return
                    }
                    videoInput?.markAsFinished(); audioInput?.markAsFinished()
                    let finishingID = lock.withLock { runID }
                    queue.asyncAfter(deadline: .now() + 10) { [self] in
                        guard finishing, lock.withLock({ runID == finishingID }) else { return }
                        failRecording("Saving took too long. The incomplete recording was removed.")
                        completeWaiters()
                    }
                    writer.finishWriting { [self] in
                        queue.async { [self] in
                            guard finishing, lock.withLock({ runID == finishingID }), let output = self.writer else { return }
                            if output.status == .completed {
                                do {
                                    guard let partialURL, let destination = snapshot().fileURL else {
                                        throw failure("Recording output is missing.")
                                    }
                                    try FileManager.default.moveItem(at: partialURL, to: destination)
                                    clearWriter()
                                    lock.withLock { state.phase = .saved }
                                } catch { failRecording(error.localizedDescription) }
                            } else {
                                failRecording(output.error?.localizedDescription ?? "The recording could not be saved.")
                            }
                            completeWaiters()
                        }
                    }
                }
            }
        }
    }

    private func prepareWriter(_ frame: DecodedVideoFrame) throws {
        guard let url = snapshot().fileURL, let format = recordingFormat else {
            throw failure("Recording setup is incomplete.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = url.appendingPathExtension("partial")
        guard !FileManager.default.fileExists(atPath: partial.path) else { throw failure("A recording is already being saved at this location.") }
        partialURL = partial
        let output = try AVAssetWriter(outputURL: partial, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: frame.width, AVVideoHeightKey: frame.height,
            AVVideoCompressionPropertiesKey: [
                // More motion detail at the same source size and 30fps capture target.
                AVVideoAverageBitRateKey: 16_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60
            ]
        ])
        video.expectsMediaDataInRealTime = true
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 128_000
        ])
        audio.expectsMediaDataInRealTime = true
        guard output.canAdd(video), output.canAdd(audio) else { throw failure("This stream format cannot be recorded.") }
        output.add(video); output.add(audio)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        guard output.startWriting() else { throw output.error ?? failure("Recording could not start.") }
        output.startSession(atSourceTime: .zero)
        writer = output; videoInput = video; audioInput = audio; pixels = adaptor
        baseTime = frame.presentationTimeStamp
    }

    private func writeVideo(_ frame: DecodedVideoFrame) throws {
        guard snapshot().phase != .failed else { return }
        guard frame.presentationTimeStamp.isNumeric, frame.width > 0, frame.height > 0 else { return }
        if writer == nil { try prepareWriter(frame) }
        guard let baseTime, let writer, let videoInput, let pixels else { return }
        guard writer.status == .writing else { throw writer.error ?? failure("Recording stopped unexpectedly.") }
        let time = frame.presentationTimeStamp - baseTime
        guard time >= .zero else { return }
        // Target 30fps without cumulative selection drift or changing playback.
        guard videoCadence.accepts(time) else { return }
        guard videoInput.isReadyForMoreMediaData else {
            lock.withLock { state.droppedVideoFrames += 1 }; return
        }
        guard pixels.append(frame.pixelBuffer, withPresentationTime: time) else {
            throw writer.error ?? failure("A video frame could not be recorded.")
        }
        videoCadence.didAppend(time)
        lock.withLock {
            if state.phase == .starting { state.phase = .recording }
            state.videoFrames += 1; state.duration = time.seconds
        }
    }

    private func writeAudio(_ block: InterleavedS16PCMBlock, time: CMTime) throws {
        guard let writer, let audioInput, let baseTime, let format = recordingFormat else { return }
        guard block.sampleRate == format.sampleRate, block.channelCount == format.channelCount else {
            throw failure("Game audio changed format. Start a new recording.")
        }
        guard writer.status == .writing else { throw writer.error ?? failure("Recording stopped unexpectedly.") }
        let presentation = time - baseTime
        guard presentation >= .zero else { return }
        // AAC encoding closes timestamp-only PCM gaps. Write real silence for
        // missing source time so resumed audio stays beside the resumed video.
        // Work and allocations stay on the writer queue, with bounded chunks
        // and backpressure; live audio/video callbacks never wait for padding.
        if let end = writtenAudioEnd {
            var missing = CMTimeConvertScale(presentation - end,
                timescale: Int32(block.sampleRate), method: .roundTowardZero).value
            var chunks = 0
            while missing > 0 {
                guard audioInput.isReadyForMoreMediaData, chunks < 32 else {
                    lock.withLock { state.droppedAudioBlocks += 1 }; return
                }
                let count = Int(min(missing, 4_800))
                let silence = Data(repeating: 0, count: count * block.channelCount * 2)
                try appendAudioPCM(silence, frameCount: count, format: format,
                    at: writtenAudioEnd ?? end, writer: writer, input: audioInput)
                missing -= Int64(count)
                chunks += 1
            }
        }
        guard audioInput.isReadyForMoreMediaData else {
            lock.withLock { state.droppedAudioBlocks += 1 }; return
        }
        try appendAudioPCM(block.data, frameCount: block.frameCount, format: format,
            at: writtenAudioEnd ?? presentation, writer: writer, input: audioInput)
        lock.withLock { state.audioFrames += block.frameCount }
    }

    private func appendAudioPCM(_ data: Data, frameCount: Int,
        format: StreamingAudioFormat, at presentation: CMTime,
        writer: AVAssetWriter, input: AVAssetWriterInput) throws {
        let bytesPerFrame = UInt32(format.channelCount * 2)
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(format.sampleRate),
            mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(format.channelCount), mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        try check(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description))
        var buffer: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &buffer))
        guard let buffer, let description else { throw failure("Audio buffer creation failed.") }
        try data.withUnsafeBytes { bytes in
            try check(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: buffer,
                offsetIntoDestination: 0, dataLength: data.count))
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(format.sampleRate)),
            presentationTimeStamp: presentation, decodeTimeStamp: .invalid)
        var sampleSize = Int(bytesPerFrame)
        var sample: CMSampleBuffer?
        try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: buffer,
            formatDescription: description, sampleCount: frameCount, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample))
        guard let sample, input.append(sample) else {
            throw writer.error ?? failure("An audio block could not be recorded.")
        }
        writtenAudioEnd = presentation + CMTime(value: Int64(frameCount), timescale: Int32(format.sampleRate))
    }

    private func failRecording(_ message: String) {
        writer?.cancelWriting()
        let url = partialURL
        clearWriter()
        if let url { try? FileManager.default.removeItem(at: url) }
        lock.withLock { state.phase = .failed; state.fileURL = nil; state.message = message }
    }
    private func clearWriter() {
        partialURL = nil
        writer = nil; videoInput = nil; audioInput = nil; pixels = nil
        baseTime = nil; videoCadence = GameplayRecordingVideoCadence(); writtenAudioEnd = nil; recordingFormat = nil
    }
    private func completeWaiters() {
        let result = snapshot()
        let waiters = stopWaiters; stopWaiters.removeAll()
        finishing = false
        waiters.forEach { $0.resume(returning: result) }
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "Farframe.GameplayRecorder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw failure("Audio recording failed (\(status)).") }
    }
}
