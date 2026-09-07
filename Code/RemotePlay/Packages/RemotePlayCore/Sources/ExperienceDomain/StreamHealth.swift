import Foundation

public struct VideoTransportStats: Codable, Hashable, Sendable {
    public let samplesReceived: UInt64
    public let decodedFrames: UInt64
    public let bytesReceived: UInt64
    public let framesLost: UInt64
    public let framesRecovered: UInt64
    public let currentBitrateMbps: Double

    public init(
        samplesReceived: UInt64 = 0,
        decodedFrames: UInt64 = 0,
        bytesReceived: UInt64 = 0,
        framesLost: UInt64 = 0,
        framesRecovered: UInt64 = 0,
        currentBitrateMbps: Double = 0
    ) {
        self.samplesReceived = samplesReceived
        self.decodedFrames = decodedFrames
        self.bytesReceived = bytesReceived
        self.framesLost = framesLost
        self.framesRecovered = framesRecovered
        self.currentBitrateMbps = currentBitrateMbps
    }

    public var lossPerThousandSamples: Double {
        guard samplesReceived > 0 else { return 0 }
        return Double(framesLost) / Double(samplesReceived) * 1_000.0
    }
}

public struct DisplayRenderStats: Codable, Hashable, Sendable {
    public let framesReceived: UInt64
    public let framesEnqueued: UInt64
    public let framesDroppedBackpressure: UInt64
    public let flushRecoveries: UInt64

    public init(
        framesReceived: UInt64 = 0,
        framesEnqueued: UInt64 = 0,
        framesDroppedBackpressure: UInt64 = 0,
        flushRecoveries: UInt64 = 0
    ) {
        self.framesReceived = framesReceived
        self.framesEnqueued = framesEnqueued
        self.framesDroppedBackpressure = framesDroppedBackpressure
        self.flushRecoveries = flushRecoveries
    }

    public var droppedPercent: Double {
        guard framesReceived > 0 else { return 0 }
        return Double(framesDroppedBackpressure) / Double(framesReceived) * 100.0
    }
}

public struct AudioQueueSnapshot: Codable, Hashable, Sendable {
    public let scheduledBuffers: Int
    public let scheduledFrames: Int
    public let receivedBuffers: Int
    public let acceptedBuffers: Int
    public let renderedBuffers: Int
    public let droppedBuffers: Int
    public let stalePacketDrops: Int
    public let backpressureDrops: Int
    public let pendingOverflowDrops: Int
    public let schedulingFailureDrops: Int
    public let invalidBuffers: Int
    public let highWaterMark: Int
    public let lowWaterMark: Int
    public let catchingUp: Bool
    public let sampleRate: Double
    public let callbackGapP95Milliseconds: Double
    public let schedulerWaitP95Milliseconds: Double
    public let conversionP95Milliseconds: Double
    public let outputLatencyMilliseconds: Double
    public let ioBufferDurationMilliseconds: Double
    public let presentationLatencyMilliseconds: Double
    /// Times the hardware asked for audio the jitter buffer did not have.
    public let underruns: Int
    /// Adaptive playout latency the jitter buffer is currently holding.
    public let targetLatencyMilliseconds: Double
    /// Total silence inserted while priming or after underruns.
    public let silenceMilliseconds: Double

    public init(
        scheduledBuffers: Int = 0,
        scheduledFrames: Int = 0,
        receivedBuffers: Int = 0,
        acceptedBuffers: Int = 0,
        renderedBuffers: Int = 0,
        droppedBuffers: Int = 0,
        stalePacketDrops: Int = 0,
        backpressureDrops: Int = 0,
        pendingOverflowDrops: Int = 0,
        schedulingFailureDrops: Int = 0,
        invalidBuffers: Int = 0,
        highWaterMark: Int = 0,
        lowWaterMark: Int = 0,
        catchingUp: Bool = false,
        sampleRate: Double = 0,
        callbackGapP95Milliseconds: Double = 0,
        schedulerWaitP95Milliseconds: Double = 0,
        conversionP95Milliseconds: Double = 0,
        outputLatencyMilliseconds: Double = 0,
        ioBufferDurationMilliseconds: Double = 0,
        presentationLatencyMilliseconds: Double = 0,
        underruns: Int = 0,
        targetLatencyMilliseconds: Double = 0,
        silenceMilliseconds: Double = 0
    ) {
        self.scheduledBuffers = scheduledBuffers
        self.scheduledFrames = scheduledFrames
        self.receivedBuffers = receivedBuffers
        self.acceptedBuffers = acceptedBuffers
        self.renderedBuffers = renderedBuffers
        self.droppedBuffers = droppedBuffers
        self.stalePacketDrops = stalePacketDrops
        self.backpressureDrops = backpressureDrops
        self.pendingOverflowDrops = pendingOverflowDrops
        self.schedulingFailureDrops = schedulingFailureDrops
        self.invalidBuffers = invalidBuffers
        self.highWaterMark = highWaterMark
        self.lowWaterMark = lowWaterMark
        self.catchingUp = catchingUp
        self.sampleRate = sampleRate
        self.callbackGapP95Milliseconds = callbackGapP95Milliseconds
        self.schedulerWaitP95Milliseconds = schedulerWaitP95Milliseconds
        self.conversionP95Milliseconds = conversionP95Milliseconds
        self.outputLatencyMilliseconds = outputLatencyMilliseconds
        self.ioBufferDurationMilliseconds = ioBufferDurationMilliseconds
        self.presentationLatencyMilliseconds = presentationLatencyMilliseconds
        self.underruns = underruns
        self.targetLatencyMilliseconds = targetLatencyMilliseconds
        self.silenceMilliseconds = silenceMilliseconds
    }

    public var backlogMilliseconds: Int {
        guard sampleRate > 0 else { return 0 }
        return Int((Double(scheduledFrames) * 1_000.0 / sampleRate).rounded())
    }
}

public struct ControllerSendStats: Codable, Hashable, Sendable {
    public let ticks: UInt64
    public let activeTicks: UInt64
    public let lateTicks: UInt64
    public let immediateSends: UInt64
    public let lastIntervalMs: Double
    public let averageIntervalMs: Double
    public let maxIntervalMs: Double

    public init(
        ticks: UInt64 = 0,
        activeTicks: UInt64 = 0,
        lateTicks: UInt64 = 0,
        immediateSends: UInt64 = 0,
        lastIntervalMs: Double = 0,
        averageIntervalMs: Double = 0,
        maxIntervalMs: Double = 0
    ) {
        self.ticks = ticks
        self.activeTicks = activeTicks
        self.lateTicks = lateTicks
        self.immediateSends = immediateSends
        self.lastIntervalMs = lastIntervalMs
        self.averageIntervalMs = averageIntervalMs
        self.maxIntervalMs = maxIntervalMs
    }
}

public struct StreamHealthSnapshot: Codable, Hashable, Sendable {
    public let measuredAt: Date
    public let videoTransport: VideoTransportStats
    public let videoPresentation: DisplayRenderStats
    public let audioQueue: AudioQueueSnapshot
    public let controllerDelivery: ControllerSendStats

    public init(
        measuredAt: Date = .now,
        videoTransport: VideoTransportStats = .init(),
        videoPresentation: DisplayRenderStats = .init(),
        audioQueue: AudioQueueSnapshot = .init(),
        controllerDelivery: ControllerSendStats = .init()
    ) {
        self.measuredAt = measuredAt
        self.videoTransport = videoTransport
        self.videoPresentation = videoPresentation
        self.audioQueue = audioQueue
        self.controllerDelivery = controllerDelivery
    }
}
