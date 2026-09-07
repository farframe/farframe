import Foundation
import StreamingCore
import Testing

@Test
func encodedVideoPayloadOwnsItsDataValue() throws {
    var source = Data([0x00, 0x00, 0x01, 0x26, 0xaa])
    let sample = try EncodedVideoSample(
        data: source,
        framesLost: 1,
        frameRecovered: true,
        receivedUptimeNanoseconds: 42
    )

    source[4] = 0xff
    #expect(sample.data == Data([0x00, 0x00, 0x01, 0x26, 0xaa]))
    #expect(sample.framesLost == 1)
    #expect(sample.frameRecovered)
    #expect(sample.receivedUptimeNanoseconds == 42)
}

@Test
func encodedVideoRejectsAnEmptyAccessUnit() {
    #expect(throws: StreamingMediaPayloadError.emptyPayload) {
        try EncodedVideoSample(
            data: Data(),
            framesLost: 0,
            frameRecovered: false,
            receivedUptimeNanoseconds: 0
        )
    }
}

@Test
func audioFormatRejectsInvalidShape() throws {
    let valid = try StreamingAudioFormat(
        channelCount: 2,
        bitsPerSample: 16,
        sampleRate: 48_000,
        frameSize: 960
    )
    #expect(valid.channelCount == 2)
    #expect(valid.bitsPerSample == 16)
    #expect(valid.sampleRate == 48_000)
    #expect(valid.frameSize == 960)

    #expect(throws: StreamingMediaPayloadError.invalidChannelCount) {
        try StreamingAudioFormat(
            channelCount: 0,
            bitsPerSample: 16,
            sampleRate: 48_000,
            frameSize: 960
        )
    }
    #expect(throws: StreamingMediaPayloadError.invalidBitsPerSample) {
        try StreamingAudioFormat(
            channelCount: 2,
            bitsPerSample: 0,
            sampleRate: 48_000,
            frameSize: 960
        )
    }
    #expect(throws: StreamingMediaPayloadError.invalidSampleRate) {
        try StreamingAudioFormat(
            channelCount: 2,
            bitsPerSample: 16,
            sampleRate: 0,
            frameSize: 960
        )
    }
    #expect(throws: StreamingMediaPayloadError.invalidAudioFrameSize) {
        try StreamingAudioFormat(
            channelCount: 2,
            bitsPerSample: 16,
            sampleRate: 48_000,
            frameSize: 0
        )
    }
}

@Test
func interleavedPCMRequiresAnExactByteCount() throws {
    let valid = Data(count: 4 * 2 * MemoryLayout<Int16>.size)
    let block = try InterleavedS16PCMBlock(
        data: valid,
        frameCount: 4,
        channelCount: 2,
        sampleRate: 48_000,
        receivedUptimeNanoseconds: 99
    )
    #expect(block.data.count == 16)
    #expect(block.frameCount == 4)
    #expect(block.channelCount == 2)
    #expect(block.sampleRate == 48_000)

    #expect(throws: StreamingMediaPayloadError.inconsistentPCMByteCount(
        expected: 16,
        actual: 15
    )) {
        try InterleavedS16PCMBlock(
            data: Data(count: 15),
            frameCount: 4,
            channelCount: 2,
            sampleRate: 48_000,
            receivedUptimeNanoseconds: 0
        )
    }
}

@Test
func interleavedPCMRejectsInvalidShapeAndOverflow() {
    #expect(throws: StreamingMediaPayloadError.invalidFrameCount) {
        try InterleavedS16PCMBlock(
            data: Data(),
            frameCount: 0,
            channelCount: 2,
            sampleRate: 48_000,
            receivedUptimeNanoseconds: 0
        )
    }
    #expect(throws: StreamingMediaPayloadError.invalidChannelCount) {
        try InterleavedS16PCMBlock(
            data: Data(),
            frameCount: 1,
            channelCount: 0,
            sampleRate: 48_000,
            receivedUptimeNanoseconds: 0
        )
    }
    #expect(throws: StreamingMediaPayloadError.invalidSampleRate) {
        try InterleavedS16PCMBlock(
            data: Data(count: 4),
            frameCount: 1,
            channelCount: 2,
            sampleRate: 0,
            receivedUptimeNanoseconds: 0
        )
    }
    #expect(throws: StreamingMediaPayloadError.byteCountOverflow) {
        try InterleavedS16PCMBlock(
            data: Data(),
            frameCount: Int.max,
            channelCount: Int.max,
            sampleRate: 48_000,
            receivedUptimeNanoseconds: 0
        )
    }
}
