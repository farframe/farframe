import AppleMediaCore
import CoreMedia
import CoreVideo
import ExperienceDomain
import Foundation
import StreamingCore
import Testing

@testable import AppleMediaCore

@Test
func annexBParserAcceptsThreeAndFourByteStartCodesAndBuildsLengthPrefixes() throws {
    let vps = nalUnit(type: 32, payload: [0x01])
    let sps = nalUnit(type: 33, payload: [0x02, 0x03])
    let pps = nalUnit(type: 34, payload: [0x04])
    let idr = nalUnit(type: 19, payload: [0xaa, 0xbb])
    let trail = nalUnit(type: 1, payload: [0xcc])
    let accessUnit = annexB([
        (4, vps),
        (3, sps),
        (4, pps),
        (3, idr),
        (4, trail),
    ])

    let parsed = try HEVCAnnexBParser.parse(accessUnit)
    #expect(parsed.vps == vps)
    #expect(parsed.sps == sps)
    #expect(parsed.pps == pps)
    #expect(parsed.containsIDR)
    #expect(parsed.lengthPrefixedPictureData == lengthPrefixed([idr, trail]))
}

@Test
func annexBParserRejectsMissingStartCode() {
    #expect(throws: HEVCDecodeFailure.malformedAnnexB) {
        try HEVCAnnexBParser.parse(Data([0x26, 0x01, 0xaa]))
    }
}

@Test
func decoderConfigurationRejectsHDRUntilTenBitPresentationExists() {
    #expect(throws: HEVCDecoderConfigurationError.unsupportedDynamicRange) {
        try HEVCDecodeConfiguration(
            generation: 1,
            framesPerSecond: 60,
            dynamicRange: .hdr
        )
    }
}

@Test
func boundedDecoderRejectsStaleGenerationAndSaturation() async throws {
    let backend = FakeHEVCDecoderBackend()
    let decoder = BoundedHEVCDecoder(
        configuration: try HEVCDecodeConfiguration(
            generation: 7,
            maximumPendingFrames: 2,
            framesPerSecond: 60
        ),
        backend: backend,
        frameHandler: { _ in }
    )
    let sample = try encodedSample(data: parameterizedIDR())

    #expect(decoder.admit(sample, generation: 6) == .staleGeneration)
    #expect(decoder.admit(sample, generation: 7) == .accepted)
    #expect(decoder.admit(sample, generation: 7) == .accepted)
    #expect(decoder.admit(sample, generation: 7) == .backpressure)
    #expect(await eventually { backend.decodeCount() == 2 })

    backend.completeFirst(.dropped)
    #expect(await eventually { decoder.pendingCountForTesting() == 1 })
    #expect(decoder.admit(sample, generation: 7) == .accepted)
    await decoder.stop()
    #expect(decoder.admit(sample, generation: 7) == .notRunning)
    #expect(backend.waitCount() == 1)
    #expect(backend.invalidateCount() == 1)
}

@Test
func decoderWaitsForAllParameterSetsBeforeSubmittingPicture() async throws {
    let backend = FakeHEVCDecoderBackend()
    let decoder = BoundedHEVCDecoder(
        configuration: try HEVCDecodeConfiguration(
            generation: 1,
            maximumPendingFrames: 3,
            framesPerSecond: 60
        ),
        backend: backend,
        frameHandler: { _ in }
    )

    let picture = nalUnit(type: 19, payload: [0xaa])
    let vpsOnly = annexB([(4, nalUnit(type: 32, payload: [0x01])), (4, picture)])
    let spsOnly = annexB([(4, nalUnit(type: 33, payload: [0x02])), (4, picture)])
    let ppsAndPicture = annexB([(4, nalUnit(type: 34, payload: [0x03])), (4, picture)])

    #expect(decoder.admit(try encodedSample(data: vpsOnly), generation: 1) == .accepted)
    #expect(await eventually { decoder.pendingCountForTesting() == 0 })
    #expect(backend.decodeCount() == 0)
    #expect(decoder.admit(try encodedSample(data: spsOnly), generation: 1) == .accepted)
    #expect(await eventually { decoder.pendingCountForTesting() == 0 })
    #expect(backend.decodeCount() == 0)
    #expect(decoder.admit(try encodedSample(data: ppsAndPicture), generation: 1) == .accepted)
    #expect(await eventually { backend.decodeCount() == 1 })
    #expect(backend.configureCount() == 1)
    await decoder.stop()
}

@Test
func decoderReconfiguresWhenParameterSetsChange() async throws {
    let backend = FakeHEVCDecoderBackend()
    let decoder = BoundedHEVCDecoder(
        configuration: try HEVCDecodeConfiguration(
            generation: 3,
            maximumPendingFrames: 2,
            framesPerSecond: 60
        ),
        backend: backend,
        frameHandler: { _ in }
    )

    #expect(
        decoder.admit(
            try encodedSample(data: parameterizedIDR(parameterSetSeed: 0x10)),
            generation: 3
        ) == .accepted
    )
    #expect(await eventually { backend.decodeCount() == 1 })
    backend.completeFirst(.dropped)
    #expect(await eventually { decoder.pendingCountForTesting() == 0 })

    #expect(
        decoder.admit(
            try encodedSample(data: parameterizedIDR(parameterSetSeed: 0x20)),
            generation: 3
        ) == .accepted
    )
    #expect(await eventually { backend.configureCount() == 2 })
    #expect(await eventually { backend.decodeCount() == 1 })
    await decoder.stop()
}

@Test
func stoppedDecoderIgnoresLateBackendOutput() async throws {
    let backend = FakeHEVCDecoderBackend()
    let frames = LockedDecodedFrameCount()
    let decoder = BoundedHEVCDecoder(
        configuration: try HEVCDecodeConfiguration(
            generation: 9,
            maximumPendingFrames: 1,
            framesPerSecond: 60
        ),
        backend: backend,
        frameHandler: { _ in frames.increment() }
    )

    #expect(
        decoder.admit(
            try encodedSample(data: parameterizedIDR()),
            generation: 9
        ) == .accepted
    )
    #expect(await eventually { backend.decodeCount() == 1 })
    await decoder.stop()
    backend.completeFirst(.frame(
        pixelBuffer: try makePixelBuffer(),
        presentationTimeStamp: .zero,
        duration: CMTime(value: 1, timescale: 60)
    ))
    #expect(frames.value() == 0)
}

private final class FakeHEVCDecoderBackend: HEVCDecoderBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var configurations: [HEVCParameterSets] = []
    private var completions: [@Sendable (HEVCBackendOutput) -> Void] = []
    private var waits = 0
    private var invalidations = 0

    func configure(parameterSets: HEVCParameterSets) throws {
        lock.withLock { configurations.append(parameterSets) }
    }

    func decode(
        lengthPrefixedAccessUnit: Data,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        isIDR: Bool,
        completion: @escaping @Sendable (HEVCBackendOutput) -> Void
    ) throws {
        _ = lengthPrefixedAccessUnit
        _ = presentationTimeStamp
        _ = duration
        _ = isIDR
        lock.withLock { completions.append(completion) }
    }

    func waitForAsynchronousFrames() {
        lock.withLock { waits += 1 }
    }

    func invalidate() {
        lock.withLock { invalidations += 1 }
    }

    func completeFirst(_ output: HEVCBackendOutput) {
        let completion = lock.withLock { () -> (@Sendable (HEVCBackendOutput) -> Void)? in
            guard completions.isEmpty == false else { return nil }
            return completions.removeFirst()
        }
        completion?(output)
    }

    func configureCount() -> Int {
        lock.withLock { configurations.count }
    }

    func decodeCount() -> Int {
        lock.withLock { completions.count }
    }

    func waitCount() -> Int {
        lock.withLock { waits }
    }

    func invalidateCount() -> Int {
        lock.withLock { invalidations }
    }
}

private final class LockedDecodedFrameCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    func value() -> Int {
        lock.withLock { count }
    }
}

private func encodedSample(data: Data) throws -> EncodedVideoSample {
    try EncodedVideoSample(
        data: data,
        framesLost: 0,
        frameRecovered: false,
        receivedUptimeNanoseconds: 1_000_000
    )
}

private func parameterizedIDR(parameterSetSeed: UInt8 = 0x01) -> Data {
    annexB([
        (4, nalUnit(type: 32, payload: [parameterSetSeed])),
        (4, nalUnit(type: 33, payload: [parameterSetSeed &+ 1])),
        (4, nalUnit(type: 34, payload: [parameterSetSeed &+ 2])),
        (4, nalUnit(type: 19, payload: [0xaa])),
    ])
}

private func nalUnit(type: UInt8, payload: [UInt8]) -> Data {
    Data([(type & 0x3f) << 1, 0x01] + payload)
}

private func annexB(_ units: [(startCodeLength: Int, data: Data)]) -> Data {
    var result = Data()
    for unit in units {
        result.append(contentsOf: unit.startCodeLength == 3
            ? [0x00, 0x00, 0x01]
            : [0x00, 0x00, 0x00, 0x01])
        result.append(unit.data)
    }
    return result
}

private func lengthPrefixed(_ units: [Data]) -> Data {
    var result = Data()
    for unit in units {
        var length = UInt32(unit.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(unit)
    }
    return result
}

private func makePixelBuffer() throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        2,
        2,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw HEVCDecodeFailure.decodeFailed(status)
    }
    return pixelBuffer
}

private func eventually(
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    for _ in 0..<250 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

@Test
func boundedDecoderRebuildsAfterVideoToolboxInvalidatesTheSession() async throws {
    let clock = LockedClock(1_000_000_000)
    let backend = FakeHEVCDecoderBackend()
    let decoder = BoundedHEVCDecoder(
        configuration: try HEVCDecodeConfiguration(
            generation: 3,
            maximumPendingFrames: 4,
            framesPerSecond: 60
        ),
        backend: backend,
        frameHandler: { _ in },
        uptimeNanoseconds: { clock.value() }
    )
    let keyframe = parameterizedIDR()
    let pFrame = annexB([(4, nalUnit(type: 1, payload: [0xcc]))])

    #expect(decoder.admit(try encodedSample(data: keyframe), generation: 3) == .accepted)
    #expect(await eventually { backend.decodeCount() == 1 })
    backend.completeFirst(.dropped)
    #expect(backend.configureCount() == 1)

    // VideoToolbox reports the session as invalidated (the app was suspended).
    // decodeCount() counts in-flight decodes, so it returns to 0 after each completion.
    #expect(decoder.admit(try encodedSample(data: pFrame), generation: 3) == .accepted)
    #expect(await eventually { backend.decodeCount() == 1 })
    backend.completeFirst(.failed(.decodeFailed(-12903)))
    #expect(await eventually { decoder.isAwaitingKeyframeForTesting() })
    #expect(await eventually { backend.invalidateCount() == 1 })
    #expect(await eventually { decoder.pendingCountForTesting() == 0 })

    // Non-keyframes are dropped. The first asks the console for a keyframe;
    // later ones stay silent until the request interval elapses.
    #expect(decoder.admit(try encodedSample(data: pFrame), generation: 3) == .keyframeRequested)
    #expect(decoder.admit(try encodedSample(data: pFrame), generation: 3) == .awaitingKeyframe)
    clock.advance(by: BoundedHEVCDecoder.keyframeRequestIntervalNanoseconds)
    #expect(decoder.admit(try encodedSample(data: pFrame), generation: 3) == .keyframeRequested)
    #expect(backend.decodeCount() == 0)

    // A keyframe carrying parameter sets rebuilds the session; decoding resumes.
    #expect(decoder.admit(try encodedSample(data: keyframe), generation: 3) == .accepted)
    #expect(await eventually { backend.configureCount() == 2 })
    #expect(await eventually { backend.decodeCount() == 1 })
    #expect(decoder.isAwaitingKeyframeForTesting() == false)
    backend.completeFirst(.dropped)
    #expect(decoder.admit(try encodedSample(data: pFrame), generation: 3) == .accepted)
    #expect(await eventually { backend.decodeCount() == 1 })
    backend.completeFirst(.dropped)

    let diagnostics = decoder.diagnostics()
    #expect(diagnostics.samplesAdmitted == 4)
    #expect(diagnostics.sessionRecoveries == 1)
    #expect(diagnostics.keyframeRequests == 2)
    #expect(diagnostics.awaitingKeyframeDrops == 1)
    #expect(diagnostics.decodeFailures == 1)
    #expect(diagnostics.backpressureDrops == 0)
    #expect(diagnostics.awaitingKeyframe == false)
    #expect(diagnostics.maximumPendingFrames == 4)
    await decoder.stop()
}

@Test
func decoderDefaultQueueAbsorbsAWiFiBurstWithoutAskingForAKeyframe() async throws {
    // Jittery Wi-Fi hands over 60 fps video in bursts of ten or more frames.
    // The former three-frame cap dropped most of each burst and, because a
    // dropped P-frame is reported as not consumed, asked the console for a
    // keyframe every time: visible pixelation until the IDR arrived.
    #expect(HEVCDecodeConfiguration.defaultMaximumPendingFrames == 16)
    let backend = FakeHEVCDecoderBackend()
    let decoder = BoundedHEVCDecoder(
        configuration: try HEVCDecodeConfiguration(generation: 1, framesPerSecond: 60),
        backend: backend,
        frameHandler: { _ in }
    )
    #expect(decoder.admit(try encodedSample(data: parameterizedIDR()), generation: 1) == .accepted)
    let pFrame = annexB([(4, nalUnit(type: 1, payload: [0xcc]))])
    for _ in 0..<15 {
        #expect(decoder.admit(try encodedSample(data: pFrame), generation: 1) == .accepted)
    }
    #expect(decoder.admit(try encodedSample(data: pFrame), generation: 1) == .backpressure)
    #expect(await eventually { backend.decodeCount() == 16 })
    let diagnostics = decoder.diagnostics()
    #expect(diagnostics.samplesAdmitted == 16)
    #expect(diagnostics.backpressureDrops == 1)
    #expect(diagnostics.pendingFrames == 16)
    backend.completeFirst(.dropped)
    #expect(await eventually { decoder.pendingCountForTesting() == 15 })
    #expect(decoder.admit(try encodedSample(data: pFrame), generation: 1) == .accepted)
    await decoder.stop()
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64
    init(_ now: UInt64) { self.now = now }
    func value() -> UInt64 { lock.withLock { now } }
    func advance(by delta: UInt64) { lock.withLock { now &+= delta } }
}
