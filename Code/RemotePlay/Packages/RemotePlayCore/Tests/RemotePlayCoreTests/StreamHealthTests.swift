import ExperienceDomain
import Foundation
import Testing

@Test
func healthRatiosReturnZeroWithoutSamples() {
    #expect(VideoTransportStats(framesLost: 10).lossPerThousandSamples == 0)
    #expect(DisplayRenderStats(framesDroppedBackpressure: 10).droppedPercent == 0)
    #expect(AudioQueueSnapshot(scheduledFrames: 480).backlogMilliseconds == 0)
}

@Test
func healthRatiosAndBacklogMatchKnownGoodMath() {
    let transport = VideoTransportStats(samplesReceived: 2_000, framesLost: 5)
    let presentation = DisplayRenderStats(framesReceived: 2_000, framesDroppedBackpressure: 4)
    let audio = AudioQueueSnapshot(scheduledFrames: 4_800, sampleRate: 48_000)

    #expect(transport.lossPerThousandSamples == 2.5)
    #expect(presentation.droppedPercent == 0.2)
    #expect(audio.backlogMilliseconds == 100)
}

@Test
func aggregateHealthSnapshotCodableRoundTripPreservesDistinctDomains() throws {
    let snapshot = StreamHealthSnapshot(
        measuredAt: Date(timeIntervalSince1970: 1_784_000_000),
        videoTransport: VideoTransportStats(
            samplesReceived: 1_000,
            decodedFrames: 998,
            bytesReceived: 1_500_000,
            framesLost: 2,
            framesRecovered: 1,
            currentBitrateMbps: 10.4
        ),
        videoPresentation: DisplayRenderStats(
            framesReceived: 998,
            framesEnqueued: 997,
            framesDroppedBackpressure: 1,
            flushRecoveries: 0
        ),
        audioQueue: AudioQueueSnapshot(
            scheduledBuffers: 9,
            scheduledFrames: 4_320,
            receivedBuffers: 1_000,
            acceptedBuffers: 990,
            renderedBuffers: 981,
            droppedBuffers: 10,
            invalidBuffers: 0,
            highWaterMark: 12,
            lowWaterMark: 3,
            catchingUp: false,
            sampleRate: 48_000,
            callbackGapP95Milliseconds: 10.2,
            schedulerWaitP95Milliseconds: 0.4,
            conversionP95Milliseconds: 0.2,
            outputLatencyMilliseconds: 20,
            ioBufferDurationMilliseconds: 5,
            presentationLatencyMilliseconds: 115
        ),
        controllerDelivery: ControllerSendStats(
            ticks: 1_000,
            activeTicks: 800,
            lateTicks: 1,
            immediateSends: 25,
            lastIntervalMs: 8.3,
            averageIntervalMs: 8.3,
            maxIntervalMs: 14
        )
    )

    let encoded = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(StreamHealthSnapshot.self, from: encoded)
    #expect(decoded == snapshot)
    #expect(decoded.videoTransport.decodedFrames == 998)
    #expect(decoded.videoPresentation.framesReceived == 998)
    #expect(decoded.audioQueue.backlogMilliseconds == 90)
}
