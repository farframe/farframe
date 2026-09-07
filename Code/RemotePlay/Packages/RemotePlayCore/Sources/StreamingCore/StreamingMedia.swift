import Foundation

public enum StreamingMediaPayloadError: Error, Equatable, Sendable {
    case emptyPayload
    case invalidFrameCount
    case invalidChannelCount
    case invalidBitsPerSample
    case invalidSampleRate
    case invalidAudioFrameSize
    case byteCountOverflow
    case inconsistentPCMByteCount(expected: Int, actual: Int)
}

/// An owned encoded-video access unit. Native callback memory must be copied
/// before constructing this value.
public struct EncodedVideoSample: Equatable, Sendable {
    public let data: Data
    public let framesLost: Int32
    public let frameRecovered: Bool
    public let receivedUptimeNanoseconds: UInt64

    public init(
        data: Data,
        framesLost: Int32,
        frameRecovered: Bool,
        receivedUptimeNanoseconds: UInt64
    ) throws {
        guard data.isEmpty == false else {
            throw StreamingMediaPayloadError.emptyPayload
        }
        self.data = data
        self.framesLost = framesLost
        self.frameRecovered = frameRecovered
        self.receivedUptimeNanoseconds = receivedUptimeNanoseconds
    }
}

public struct StreamingAudioFormat: Equatable, Sendable {
    public let channelCount: Int
    public let bitsPerSample: Int
    public let sampleRate: UInt32
    public let frameSize: Int

    public init(
        channelCount: Int,
        bitsPerSample: Int,
        sampleRate: UInt32,
        frameSize: Int
    ) throws {
        guard channelCount > 0 else {
            throw StreamingMediaPayloadError.invalidChannelCount
        }
        guard bitsPerSample > 0 else {
            throw StreamingMediaPayloadError.invalidBitsPerSample
        }
        guard sampleRate > 0 else {
            throw StreamingMediaPayloadError.invalidSampleRate
        }
        guard frameSize > 0 else {
            throw StreamingMediaPayloadError.invalidAudioFrameSize
        }

        self.channelCount = channelCount
        self.bitsPerSample = bitsPerSample
        self.sampleRate = sampleRate
        self.frameSize = frameSize
    }
}

/// Owned, interleaved, signed 16-bit PCM with an exact byte-count invariant.
public struct InterleavedS16PCMBlock: Equatable, Sendable {
    public let data: Data
    public let frameCount: Int
    public let channelCount: Int
    public let sampleRate: UInt32
    public let receivedUptimeNanoseconds: UInt64

    public init(
        data: Data,
        frameCount: Int,
        channelCount: Int,
        sampleRate: UInt32,
        receivedUptimeNanoseconds: UInt64
    ) throws {
        guard frameCount > 0 else {
            throw StreamingMediaPayloadError.invalidFrameCount
        }
        guard channelCount > 0 else {
            throw StreamingMediaPayloadError.invalidChannelCount
        }
        guard sampleRate > 0 else {
            throw StreamingMediaPayloadError.invalidSampleRate
        }

        let (sampleCount, sampleOverflow) = frameCount.multipliedReportingOverflow(
            by: channelCount
        )
        let (expectedByteCount, byteOverflow) = sampleCount.multipliedReportingOverflow(
            by: MemoryLayout<Int16>.size
        )
        guard sampleOverflow == false, byteOverflow == false else {
            throw StreamingMediaPayloadError.byteCountOverflow
        }
        guard data.count == expectedByteCount else {
            throw StreamingMediaPayloadError.inconsistentPCMByteCount(
                expected: expectedByteCount,
                actual: data.count
            )
        }

        self.data = data
        self.frameCount = frameCount
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.receivedUptimeNanoseconds = receivedUptimeNanoseconds
    }
}
