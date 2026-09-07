import CoreMedia
import CoreVideo
import ExperienceDomain
import Foundation
import StreamingCore

public enum HEVCDecoderConfigurationError: Error, Equatable, Sendable {
    case invalidGeneration
    case invalidPendingFrameCapacity
    case invalidFrameRate
    case unsupportedDynamicRange
}

public struct HEVCDecodeConfiguration: Equatable, Sendable {
    public let generation: UInt64
    public let maximumPendingFrames: Int
    public let framesPerSecond: Int32
    public let dynamicRange: StreamDynamicRange

    /// Frames handed to VideoToolbox and not yet returned. Jittery Wi-Fi
    /// delivers 60 fps video in bursts of ten or more frames; hardware decode
    /// clears a burst in a few tens of milliseconds, so queueing it is cheap,
    /// while dropping a P-frame breaks the reference chain until the next
    /// keyframe (visible pixelation). The former cap of 3 did exactly that.
    public static let defaultMaximumPendingFrames = 16

    public init(
        generation: UInt64,
        maximumPendingFrames: Int = HEVCDecodeConfiguration.defaultMaximumPendingFrames,
        framesPerSecond: Int32,
        dynamicRange: StreamDynamicRange = .sdr
    ) throws {
        guard generation > 0 else {
            throw HEVCDecoderConfigurationError.invalidGeneration
        }
        guard maximumPendingFrames > 0 else {
            throw HEVCDecoderConfigurationError.invalidPendingFrameCapacity
        }
        guard framesPerSecond == 30 || framesPerSecond == 60 else {
            throw HEVCDecoderConfigurationError.invalidFrameRate
        }
        guard dynamicRange == .sdr else {
            throw HEVCDecoderConfigurationError.unsupportedDynamicRange
        }
        self.generation = generation
        self.maximumPendingFrames = maximumPendingFrames
        self.framesPerSecond = framesPerSecond
        self.dynamicRange = dynamicRange
    }
}

public enum HEVCDecodeAdmission: Equatable, Sendable {
    case accepted
    case staleGeneration
    case notRunning
    case backpressure
    /// The decoder lost its session and this sample cannot start a new one.
    /// The frame is dropped silently; the transport should treat it as handled.
    case awaitingKeyframe
    /// Same as `awaitingKeyframe`, but the caller should report the frame as
    /// not processed so the console is asked for a fresh keyframe.
    case keyframeRequested
}

public enum HEVCDecodeFailure: Error, Equatable, Sendable {
    case malformedAnnexB
    case formatDescriptionCreationFailed(OSStatus)
    case sessionCreationFailed(OSStatus)
    case blockBufferCreationFailed(OSStatus)
    case blockBufferCopyFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case decodeFailed(OSStatus)
    case missingDecoderSession
}

/// Retains one VideoToolbox output buffer. Core Video objects are immutable for
/// this pipeline but are not declared Sendable by the SDK, so queue ownership
/// remains the decoder/presenter's responsibility.
public struct DecodedVideoFrame: @unchecked Sendable {
    public let generation: UInt64
    public let pixelBuffer: CVPixelBuffer
    public let width: Int
    public let height: Int
    public let presentationTimeStamp: CMTime
    public let duration: CMTime

    public init(
        generation: UInt64,
        pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        duration: CMTime
    ) {
        self.generation = generation
        self.pixelBuffer = pixelBuffer
        width = CVPixelBufferGetWidth(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        self.presentationTimeStamp = presentationTimeStamp
        self.duration = duration
    }
}

/// Counters for the Stats surfaces. `backpressureDrops` and `keyframeRequests`
/// are the ones that explain visible artifacts: each is a frame the console was
/// told we did not consume.
public struct HEVCDecoderDiagnostics: Equatable, Sendable {
    public let samplesAdmitted: UInt64
    public let framesDecoded: UInt64
    public let backpressureDrops: UInt64
    public let keyframeRequests: UInt64
    public let awaitingKeyframeDrops: UInt64
    public let sessionRecoveries: UInt64
    public let decodeFailures: UInt64
    public let pendingFrames: Int
    public let maximumPendingFrames: Int
    public let awaitingKeyframe: Bool

    public init(
        samplesAdmitted: UInt64 = 0,
        framesDecoded: UInt64 = 0,
        backpressureDrops: UInt64 = 0,
        keyframeRequests: UInt64 = 0,
        awaitingKeyframeDrops: UInt64 = 0,
        sessionRecoveries: UInt64 = 0,
        decodeFailures: UInt64 = 0,
        pendingFrames: Int = 0,
        maximumPendingFrames: Int = 0,
        awaitingKeyframe: Bool = false
    ) {
        self.samplesAdmitted = samplesAdmitted
        self.framesDecoded = framesDecoded
        self.backpressureDrops = backpressureDrops
        self.keyframeRequests = keyframeRequests
        self.awaitingKeyframeDrops = awaitingKeyframeDrops
        self.sessionRecoveries = sessionRecoveries
        self.decodeFailures = decodeFailures
        self.pendingFrames = pendingFrames
        self.maximumPendingFrames = maximumPendingFrames
        self.awaitingKeyframe = awaitingKeyframe
    }
}

/// Synchronous, shell-safe read of the current session's decoder counters.
/// The session owner attaches each new decoder and detaches on teardown.
public final class VideoDecoderDiagnosticsProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder: (any HEVCVideoDecoding)?

    public init() {}

    public func attach(_ decoder: any HEVCVideoDecoding) {
        lock.withLock { self.decoder = decoder }
    }

    public func detach() {
        lock.withLock { decoder = nil }
    }

    public func snapshot() -> HEVCDecoderDiagnostics? {
        lock.withLock { decoder }?.diagnostics()
    }
}

public typealias HEVCDecodedFrameHandler = @Sendable (DecodedVideoFrame) -> Void
public typealias HEVCDecodeFailureHandler = @Sendable (UInt64, HEVCDecodeFailure) -> Void

public protocol HEVCVideoDecoding: Sendable {
    func admit(
        _ sample: EncodedVideoSample,
        generation: UInt64
    ) -> HEVCDecodeAdmission

    func stop() async

    func diagnostics() -> HEVCDecoderDiagnostics
}

extension HEVCVideoDecoding {
    public func diagnostics() -> HEVCDecoderDiagnostics { HEVCDecoderDiagnostics() }
}

public protocol HEVCVideoDecoderBuilding: Sendable {
    func makeDecoder(
        configuration: HEVCDecodeConfiguration,
        frameHandler: @escaping HEVCDecodedFrameHandler,
        failureHandler: @escaping HEVCDecodeFailureHandler
    ) -> any HEVCVideoDecoding
}

public struct VideoToolboxHEVCDecoderFactory: HEVCVideoDecoderBuilding {
    public init() {}

    public func makeDecoder(
        configuration: HEVCDecodeConfiguration,
        frameHandler: @escaping HEVCDecodedFrameHandler,
        failureHandler: @escaping HEVCDecodeFailureHandler
    ) -> any HEVCVideoDecoding {
        BoundedHEVCDecoder(
            configuration: configuration,
            frameHandler: frameHandler,
            failureHandler: failureHandler
        )
    }
}
