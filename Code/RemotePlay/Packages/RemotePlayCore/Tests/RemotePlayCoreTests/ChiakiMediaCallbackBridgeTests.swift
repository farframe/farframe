import Dispatch
import Foundation
@testable import PlayStationRemotePlay
import StreamingCore
import Testing

@Test
func nativePointerMappingsCopyVideoAndPCMBeforeReturning() throws {
    var videoBytes: [UInt8] = [0x00, 0x00, 0x01, 0x26, 0xaa]
    let videoSample = videoBytes.withUnsafeBufferPointer { buffer in
        ChiakiMediaPayloadMapping.encodedVideo(
            buffer: buffer.baseAddress,
            bufferSize: buffer.count,
            framesLost: 2,
            frameRecovered: true,
            receivedUptimeNanoseconds: 10
        )
    }
    videoBytes[4] = 0xff
    #expect(videoSample?.data == Data([0x00, 0x00, 0x01, 0x26, 0xaa]))
    #expect(videoSample?.framesLost == 2)
    #expect(videoSample?.frameRecovered == true)

    var pcmSamples: [Int16] = [1, -2, 3, -4]
    let expectedPCM = pcmSamples.withUnsafeBytes { Data($0) }
    let pcmBlock = pcmSamples.withUnsafeBufferPointer { buffer in
        ChiakiMediaPayloadMapping.decodedAudio(
            samples: buffer.baseAddress,
            frameCount: 2,
            channels: 2,
            sampleRate: 48_000,
            receivedUptimeNanoseconds: 11
        )
    }
    pcmSamples[0] = 99
    #expect(pcmBlock?.data == expectedPCM)
    #expect(pcmBlock?.frameCount == 2)
    #expect(pcmBlock?.channelCount == 2)
}

@Test
func nativeAudioMappingRejectsUnsupportedFormats() {
    #expect(
        ChiakiMediaPayloadMapping.audioFormat(
            channels: 2,
            bitsPerSample: 16,
            sampleRate: 48_000,
            frameSize: 960
        ) != nil
    )
    #expect(
        ChiakiMediaPayloadMapping.audioFormat(
            channels: 0,
            bitsPerSample: 16,
            sampleRate: 48_000,
            frameSize: 960
        ) == nil
    )
    #expect(
        ChiakiMediaPayloadMapping.audioFormat(
            channels: 2,
            bitsPerSample: 24,
            sampleRate: 48_000,
            frameSize: 960
        ) == nil
    )
    #expect(
        ChiakiMediaPayloadMapping.audioFormat(
            channels: 2,
            bitsPerSample: 16,
            sampleRate: 44_100,
            frameSize: 960
        ) == nil
    )
}

@Test
func clearingCallbackBridgeDrainsInFlightDeliveryAndRejectsQueuedWork() {
    let bridge = ChiakiSessionCallbackBridge()
    let handlerStarted = DispatchSemaphore(value: 0)
    let releaseHandler = DispatchSemaphore(value: 0)
    let clearFinished = DispatchSemaphore(value: 0)
    let recorder = LockedCallbackCount()

    bridge.install(
        eventHandler: { _ in
            recorder.increment()
            handlerStarted.signal()
            releaseHandler.wait()
        },
        mediaHandler: { _ in true }
    )
    bridge.emit(.transportReady)

    #expect(handlerStarted.wait(timeout: .now() + 1) == .success)
    DispatchQueue.global(qos: .userInitiated).async {
        bridge.clear()
        clearFinished.signal()
    }
    #expect(clearFinished.wait(timeout: .now() + .milliseconds(50)) == .timedOut)

    releaseHandler.signal()
    #expect(clearFinished.wait(timeout: .now() + 1) == .success)

    bridge.emit(.transportReady)
    #expect(handlerStarted.wait(timeout: .now() + .milliseconds(50)) == .timedOut)
    releaseHandler.signal()
    #expect(recorder.value() == 1)
}

@Test
func encodedVideoAdmissionReturnsSynchronouslyToTheNativeBridge() throws {
    let bridge = ChiakiSessionCallbackBridge()
    let recorder = LockedCallbackCount()
    bridge.install(
        eventHandler: { _ in },
        mediaHandler: { event in
            guard case .encodedVideo = event else { return true }
            recorder.increment()
            return false
        }
    )
    let sample = try EncodedVideoSample(
        data: Data([0x00, 0x00, 0x01, 0x26, 0xaa]),
        framesLost: 0,
        frameRecovered: false,
        receivedUptimeNanoseconds: 1
    )

    #expect(bridge.emit(.encodedVideo(sample)) == false)
    #expect(recorder.value() == 1)
    bridge.clear()
}

@Test
func decodedAudioAdmissionReturnsSynchronouslyWithoutAnUnboundedDeliveryQueue() throws {
    let bridge = ChiakiSessionCallbackBridge()
    let recorder = LockedCallbackCount()
    bridge.install(
        eventHandler: { _ in },
        mediaHandler: { event in
            guard case .decodedAudio = event else { return true }
            recorder.increment()
            return false
        }
    )
    let block = try InterleavedS16PCMBlock(
        data: Data(repeating: 0, count: 8),
        frameCount: 2,
        channelCount: 2,
        sampleRate: 48_000,
        receivedUptimeNanoseconds: 2
    )

    #expect(bridge.emit(.decodedAudio(block)) == false)
    #expect(recorder.value() == 1)
    bridge.clear()
}

private final class LockedCallbackCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    func value() -> Int {
        lock.withLock { count }
    }
}
