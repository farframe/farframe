import CoreImage
import CoreVideo
import Foundation

/// Standalone lab: swiftc -DFARFRAME_COLOR_LAB with the two color sources.
/// Synthetic pixels only. No user frame is read, mirrored, logged or written.
@main enum VisionArenaLiveColorChecks {
    static func expect(_ result: @autoclosure () -> Bool, _ message: String) {
        precondition(result(), message)
    }
    static func near(_ value: Float, _ expected: Float, tolerance: Float = 0.015) -> Bool {
        abs(value - expected) <= tolerance
    }
    static func solid(_ value: SIMD3<Float>) -> VisionArenaLiveColorPolicy.EdgeColors {
        .init(left: value, right: value, top: value, bottom: value)
    }

    @MainActor static func main() async {
        // Exhaust all 32 combinations; each denied condition stops analysis.
        for bits in 0..<32 {
            let allowed = VisionArenaLightingActivity.allowsReactiveLighting(
                accessGranted: bits & 1 != 0, active: bits & 2 != 0, reduceMotion: bits & 4 != 0,
                glowEnabled: bits & 8 != 0, thermalLimited: bits & 16 != 0)
            expect(allowed == (bits == 11), "Access/lifecycle/Reduce Motion/Off/thermal gates")
        }
        let generation = UUID(), later = UUID()
        var policy = VisionArenaLiveColorPolicy()
        expect(policy.snapshot(generation: generation, now: 0).colors == .black, "No frame starts black")
        policy.consume(solid([1, 0, 0]), capturedAt: 1, now: 1)
        let first = policy.snapshot(generation: generation, now: 1)
        expect(first.colors.left.x > 0 && first.colors.left.x < 0.5, "First flash is smoothed")
        let half = policy.snapshot(generation: generation, now: 1.8)
        expect(near(half.freshness, 0.5, tolerance: 0.0001), "Stale fade is clock-based")
        expect(near(half.colors.left.x, first.colors.left.x * 0.5), "Fade scales emitted light")
        expect(policy.snapshot(generation: generation, now: 2.2).colors == .black, "Stale is exactly black")
        policy.consume(nil, capturedAt: 2.3, now: 2.3)
        expect(policy.snapshot(generation: generation, now: 2.3).colors == .black, "Invalid frame clears old color")
        expect(VisionArenaLiveColorPolicy.bound([8, 4, 2]) == SIMD3<Float>(1, 0.5, 0.25), "HDR clamp preserves ratios")
        expect(VisionArenaLiveColorPolicy.bound([.nan, 1, 1]) == .zero, "NaN fails black")
        expect(VisionArenaLiveColorPolicy.bound([.infinity, 1, 1]) == .zero, "Infinity fails black")
        expect(VisionArenaLiveColorPolicy.bound([-2, 0, 0]) == .zero, "Negative colors cannot emit")
        expect(VisionArenaLiveColorPolicy.bound([0.0001, 0.0001, 0.0001]) == .zero, "Black has no brightness lift")
        policy.consume(solid([1, 1, 1]), capturedAt: 3, now: 5)
        expect(policy.snapshot(generation: generation, now: 5).colors == .black, "Slow stale conversion cannot flash")

        var slot = VisionArenaColorSlot<Int>()
        slot.begin(generation)
        for value in 0..<10_000 { slot.submit(value, generation: generation, capturedAt: 1) }
        expect(slot.take(generation: generation)?.frame == 9_999, "Overload retains latest, not a FIFO")
        expect(slot.take(generation: generation) == nil, "Only one pending item exists")
        slot.submit(1, generation: generation, capturedAt: 1)
        slot.begin(later)
        expect(slot.take(generation: later) == nil, "New generation releases pending old input")
        slot.submit(2, generation: generation, capturedAt: 1)
        expect(slot.take(generation: later) == nil, "Old observer cannot populate new slot")
        slot.stop(generation)
        slot.submit(3, generation: later, capturedAt: 1)
        expect(slot.take(generation: later)?.frame == 3, "Old stop cannot stop new generation")
        slot.stop(later)
        slot.submit(4, generation: later, capturedAt: 1)
        expect(slot.take(generation: later) == nil, "Stopped input rejected")

        let sampler = VisionArenaPixelSampler()
        let edges = sampler.sample(makeBGRA(width: 100, height: 100, edges: true))!
        expect(edges.left.x > 0.95 && edges.left.y < 0.03, "Left edge red")
        expect(edges.right.y > 0.95 && edges.right.x < 0.03, "Right edge green")
        expect(edges.top.z > 0.95 && edges.top.x < 0.03, "CV top row maps to top edge")
        expect(edges.bottom.x > 0.95 && edges.bottom.y > 0.95, "Bottom edge yellow")
        let gray = sampler.sample(makeBGRA(width: 32, height: 32, gray: 128))!
        expect(near(gray.left.x, 0.21586), "sRGB gray is averaged in linear light")
        expect(sampler.sample(makeBGRA(width: 8, height: 8)) == nil, "Undersized frame rejected before CI")
        let unsupported = makeBuffer(format: kCVPixelFormatType_OneComponent8, width: 32, height: 32)
        expect(!VisionArenaPixelSampler.validStorage(unsupported), "Unsupported storage fails closed")
        for (format, black, white) in [(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 16, 235),
                                       (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 0, 255)] {
            let blackBuffer = makeNV12(format: format, y: UInt8(black))
            expect(CVPixelBufferGetIOSurface(blackBuffer) != nil, "NV12 fixture is truly IOSurface-backed")
            let blackResult = sampler.sample(blackBuffer)!
            let whiteResult = sampler.sample(makeNV12(format: format, y: UInt8(white)))!
            expect(blackResult.left.x < 0.01 && blackResult.left.y < 0.01, "NV12 range black")
            expect(whiteResult.left.x > 0.95 && whiteResult.left.y > 0.95, "NV12 range white")
        }
        let hdr = sampler.sample(makeHalfLinear())!
        expect(near(hdr.left.x, 4, tolerance: 0.06) && near(hdr.left.y, 2, tolerance: 0.04), "Extended linear HDR not clipped during analysis")
        let p3 = makeBGRA(width: 32, height: 32, gray: 0)
        CVPixelBufferLockBaseAddress(p3, [])
        let p3bytes = CVPixelBufferGetBaseAddress(p3)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<32 { for col in 0..<32 { p3bytes[row * CVPixelBufferGetBytesPerRow(p3) + col * 4 + 2] = 255 } }
        CVPixelBufferUnlockBaseAddress(p3, [])
        CVBufferSetAttachment(p3, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.displayP3)!, .shouldPropagate)
        let p3result = sampler.sample(p3)!
        expect(p3result.left.x > 1.1 && p3result.left.y < 0, "P3 primaries matched into extended linear sRGB before bounding")
        let pqBuffer = makeP010(transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        expect(CVPixelBufferGetIOSurface(pqBuffer) != nil, "P010 fixture is truly IOSurface-backed")
        let pq = sampler.sample(pqBuffer)!
        let hlg = sampler.sample(makeP010(transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG))!
        expect(pq.left.x.isFinite && pq.left.x > 1, "10-bit PQ attachment retains HDR luminance")
        expect(hlg.left.x.isFinite && abs(pq.left.x - hlg.left.x) > 0.1, "PQ and HLG are not interpreted with the same transfer")
        let separated = makeNoncontiguousNV12()
        expect(CVPixelBufferGetDataSize(separated) == 0, "Separate-plane fixture has no aggregate storage")
        expect(VisionArenaPixelSampler.validStorage(separated), "Valid noncontiguous planes accepted")
        expect(sampler.sample(separated)!.left.x > 0.95, "Noncontiguous planes actually converted")
        expect(sampler.sample(pqBuffer, shouldContinue: { false }) == nil, "Retired generation does not begin CI work")
        print("PASS: deterministic smoothing, finite/HDR bounds, fade/stale, 10,000-input overload, generation, BGRA orientation/linear color, NV12 ranges and half-float HDR checks")

        let recorder = Recorder()
        let analyzer = VisionArenaLiveColorAnalyzer { snapshot in
            recorder.events.append((snapshot.generation, ProcessInfo.processInfo.systemUptime))
        }
        analyzer.begin(generation: generation)
        let buffer = makeBGRA(width: 32, height: 32, gray: 128)
        for _ in 0..<1_000 { analyzer.submit(buffer, generation: generation) }
        try? await Task.sleep(for: .milliseconds(300))
        analyzer.stop(generation: generation)
        let stoppedCount = recorder.events.count
        try? await Task.sleep(for: .milliseconds(160))
        expect(recorder.events.count == stoppedCount, "No callback after stop")
        analyzer.begin(generation: later)
        analyzer.submit(buffer, generation: generation)
        analyzer.submit(buffer, generation: later)
        for _ in 0..<60 {
            if recorder.events.contains(where: { $0.0 == later }) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        analyzer.stop(generation: later)
        expect(recorder.events.contains { $0.0 == later }, "Restart delivers current generation")
        expect(zip(recorder.events, recorder.events.dropFirst()).allSatisfy { $1.1 - $0.1 >= 0.12 }, "Main output remains bounded across generations")
        print("PASS: live timer overload, generation restart, stop callback suppression and output-rate smoke checks")
    }

    @MainActor final class Recorder { var events: [(UUID, TimeInterval)] = [] }

    static func makeBuffer(format: OSType, width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        precondition(CVPixelBufferCreate(nil, width, height, format, attributes, &buffer) == kCVReturnSuccess)
        return buffer!
    }

    static func makeBGRA(width: Int, height: Int, edges: Bool = false, gray: UInt8 = 0) -> CVPixelBuffer {
        let buffer = makeBuffer(format: kCVPixelFormatType_32BGRA, width: width, height: height)
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height { for x in 0..<width {
            var rgb: (UInt8, UInt8, UInt8) = (gray, gray, gray)
            if edges {
                if x < width / 10 { rgb = (255, 0, 0) }
                else if x >= width * 9 / 10 { rgb = (0, 255, 0) }
                else if y < height / 10 { rgb = (0, 0, 255) }
                else if y >= height * 9 / 10 { rgb = (255, 255, 0) }
            }
            let i = y * stride + x * 4
            bytes[i] = rgb.2; bytes[i + 1] = rgb.1; bytes[i + 2] = rgb.0; bytes[i + 3] = 255
        } }
        return buffer
    }

    static func makeNV12(format: OSType, y: UInt8) -> CVPixelBuffer {
        let buffer = makeBuffer(format: format, width: 32, height: 32)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 0), Int32(y), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * 32)
        memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * 16)
        return buffer
    }

    static func makeP010(transfer: CFString) -> CVPixelBuffer {
        let buffer = makeBuffer(format: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, width: 32, height: 32)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt16.self)
        let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt16.self)
        for row in 0..<32 { for col in 0..<32 { y[row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2 + col] = 768 << 6 } }
        for row in 0..<16 { for col in 0..<32 { uv[row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2 + col] = 512 << 6 } }
        return buffer
    }

    static func makeNoncontiguousNV12() -> CVPixelBuffer {
        let y = UnsafeMutableRawPointer.allocate(byteCount: 32 * 32, alignment: 64)
        let uv = UnsafeMutableRawPointer.allocate(byteCount: 32 * 16, alignment: 64)
        memset(y, 255, 32 * 32); memset(uv, 128, 32 * 16)
        var addresses: [UnsafeMutableRawPointer?] = [y, uv]
        var widths = [32, 16], heights = [32, 16], strides = [32, 32]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithPlanarBytes(nil, 32, 32, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            nil, 0, 2, &addresses, &widths, &heights, &strides, { _, _, _, count, planes in
                for index in 0..<count { UnsafeMutableRawPointer(mutating: planes?[index])?.deallocate() }
            }, nil, nil, &buffer)
        precondition(status == kCVReturnSuccess)
        CVBufferSetAttachment(buffer!, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer!, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer!, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buffer!
    }

    static func makeHalfLinear() -> CVPixelBuffer {
        let buffer = makeBuffer(format: kCVPixelFormatType_64RGBAHalf, width: 32, height: 32)
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / 2
        for y in 0..<32 { for x in 0..<32 {
            let i = y * stride + x * 4
            bytes[i] = Float16(4).bitPattern; bytes[i + 1] = Float16(2).bitPattern
            bytes[i + 2] = Float16(1).bitPattern; bytes[i + 3] = Float16(1).bitPattern
        } }
        return buffer
    }
}
