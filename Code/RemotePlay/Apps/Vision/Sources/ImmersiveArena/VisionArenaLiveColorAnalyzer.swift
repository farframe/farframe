#if os(visionOS) || FARFRAME_COLOR_LAB
import CoreImage
import CoreVideo
import Foundation

/// Samples the existing presenter's accepted immutable buffer. A locked latest
/// slot and serial worker bound ownership to one processing + one pending frame.
/// Only four average colors leave the worker; no image is written or retained.
final class VisionArenaLiveColorAnalyzer: @unchecked Sendable {
    typealias Snapshot = VisionArenaLiveColorPolicy.Snapshot
    typealias EdgeColors = VisionArenaLiveColorPolicy.EdgeColors
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "farframe.arena.color", qos: .utility)
    private let deliver: @MainActor @Sendable (Snapshot) -> Void
    private var slot = VisionArenaColorSlot<CVPixelBuffer>()
    private var latestDelivery: Snapshot?
    private var deliveryScheduled = false
    private var lastDeliveryAt: TimeInterval = -.infinity
    // Worker queue only.
    private var timer: DispatchSourceTimer?
    private var workerGeneration: UUID?
    private var lastTickAt: TimeInterval = -.infinity
    private var policy = VisionArenaLiveColorPolicy()
    private var sampler: VisionArenaPixelSampler?

    init(deliver: @escaping @MainActor @Sendable (Snapshot) -> Void) { self.deliver = deliver }
    deinit { timer?.cancel() }

    @MainActor func begin(generation: UUID) {
        lock.withLock { slot.begin(generation); latestDelivery = nil }
        queue.async { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.timer?.cancel()
            self.policy = VisionArenaLiveColorPolicy()
            self.workerGeneration = generation
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(125), leeway: .milliseconds(15))
            timer.setEventHandler { [weak self] in self?.tick(generation: generation) }
            self.timer = timer
            timer.resume()
        }
    }

    /// Synchronous and inexpensive; safe from the presentation callback queue.
    func submit(_ pixelBuffer: CVPixelBuffer, generation: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock { slot.submit(pixelBuffer, generation: generation, capturedAt: now) }
    }

    /// The scene clears its live glow when stopping. No retired callback fires.
    @MainActor func stop(generation: UUID) {
        lock.withLock {
            slot.stop(generation)
            if latestDelivery?.generation == generation { latestDelivery = nil }
        }
        queue.async { [weak self] in
            guard let self, self.workerGeneration == generation else { return }
            self.timer?.cancel()
            self.timer = nil
            self.workerGeneration = nil
            self.policy = VisionArenaLiveColorPolicy()
            self.sampler?.clearCaches()
        }
    }

    private func isCurrent(_ generation: UUID) -> Bool { lock.withLock { slot.generation == generation } }

    private func tick(generation: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        guard isCurrent(generation), now - lastTickAt >= VisionArenaLiveColorPolicy.sampleInterval else { return }
        lastTickAt = now
        // The buffer and CIImage live only in this autorelease pool.
        autoreleasepool {
            if let pending = lock.withLock({ slot.take(generation: generation) }) {
                if sampler == nil { sampler = VisionArenaPixelSampler() }
                let measured = sampler?.sample(pending.frame, shouldContinue: { self.isCurrent(generation) })
                guard isCurrent(generation) else { return }
                policy.consume(measured, capturedAt: pending.capturedAt, now: ProcessInfo.processInfo.systemUptime)
            }
        }
        guard isCurrent(generation) else { return }
        scheduleDelivery(policy.snapshot(generation: generation, now: ProcessInfo.processInfo.systemUptime))
    }

    private func scheduleDelivery(_ snapshot: Snapshot) {
        let delay: TimeInterval? = lock.withLock {
            guard slot.generation == snapshot.generation else { return nil }
            latestDelivery = snapshot
            guard !deliveryScheduled else { return nil }
            deliveryScheduled = true
            return max(0, VisionArenaLiveColorPolicy.sampleInterval - (ProcessInfo.processInfo.systemUptime - lastDeliveryAt))
        }
        guard let delay else { return }
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            self?.flushDelivery()
        }
    }

    @MainActor private func flushDelivery() {
        let snapshot: Snapshot? = lock.withLock {
            deliveryScheduled = false
            defer { latestDelivery = nil }
            guard let snapshot = latestDelivery, slot.generation == snapshot.generation else { return nil }
            lastDeliveryAt = ProcessInfo.processInfo.systemUptime
            return snapshot
        }
        if let snapshot { deliver(snapshot) }
    }
}

/// Dedicated worker use only. Core Image interprets pixel format, range, YCbCr
/// matrix and color attachments; matching is enabled into extended linear sRGB.
final class VisionArenaPixelSampler {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linear,
        .workingFormat: CIFormat.RGBAf.rawValue,
        .cacheIntermediates: false
    ])

    func clearCaches() { context.clearCaches() }

    func sample(_ buffer: CVPixelBuffer, shouldContinue: () -> Bool = { true }) -> VisionArenaLiveColorPolicy.EdgeColors? {
        guard Self.validStorage(buffer), shouldContinue() else { return nil }
        // Do not replace source color space with sRGB: doing so would misread
        // Display P3, BT.2020, PQ or HLG attachments on the decoder's buffer.
        let image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull,
              extent.minX.isFinite, extent.minY.isFinite, extent.width.isFinite, extent.height.isFinite,
              extent.width >= 16, extent.height >= 16,
              extent.width <= 8192, extent.height <= 8192 else { return nil }
        let w = extent.width, h = extent.height, x = extent.minX, y = extent.minY
        let rectangles = [
            CGRect(x: x, y: y + h * 0.1, width: w * 0.08, height: h * 0.8),
            CGRect(x: x + w * 0.92, y: y + h * 0.1, width: w * 0.08, height: h * 0.8),
            CGRect(x: x + w * 0.1, y: y + h * 0.92, width: w * 0.8, height: h * 0.08),
            CGRect(x: x + w * 0.1, y: y, width: w * 0.8, height: h * 0.08)
        ]
        let outputBounds = CGRect(x: 0, y: 0, width: 4, height: 1)
        var averages = CIImage(color: .clear).cropped(to: outputBounds)
        for (index, rectangle) in rectangles.enumerated() {
            let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rectangle)])
                .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
                .transformed(by: CGAffineTransform(translationX: CGFloat(index), y: 0))
            averages = average.composited(over: averages)
        }
        guard shouldContinue() else { return nil }
        var values = [Float](repeating: 0, count: 16)
        values.withUnsafeMutableBytes { bytes in
            context.render(averages, toBitmap: bytes.baseAddress!, rowBytes: 64,
                           bounds: outputBounds, format: .RGBAf, colorSpace: linear)
        }
        guard values.allSatisfy(\.isFinite) else { return nil }
        func color(_ i: Int) -> SIMD3<Float> { SIMD3(values[i * 4], values[i * 4 + 1], values[i * 4 + 2]) }
        return .init(left: color(0), right: color(1), top: color(2), bottom: color(3))
    }

    static func validStorage(_ buffer: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width >= 16, height >= 16, width <= 8192, height <= 8192 else { return false }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let layoutIsValid: Bool
        switch format {
        case kCVPixelFormatType_32BGRA:
            layoutIsValid = !CVPixelBufferIsPlanar(buffer) && CVPixelBufferGetBytesPerRow(buffer) >= width * 4
        case kCVPixelFormatType_64RGBAHalf:
            layoutIsValid = !CVPixelBufferIsPlanar(buffer) && CVPixelBufferGetBytesPerRow(buffer) >= width * 8
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            let bytes = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 2
            layoutIsValid = width.isMultiple(of: 2) && height.isMultiple(of: 2) && CVPixelBufferGetPlaneCount(buffer) == 2
                && CVPixelBufferGetWidthOfPlane(buffer, 0) == width && CVPixelBufferGetHeightOfPlane(buffer, 0) == height
                && CVPixelBufferGetWidthOfPlane(buffer, 1) == width / 2 && CVPixelBufferGetHeightOfPlane(buffer, 1) == height / 2
                && CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) >= width * bytes
                && CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) >= width * bytes
        default: return false
        }
        guard layoutIsValid, CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        if CVPixelBufferIsPlanar(buffer) {
            // Noncontiguous planes legitimately report a zero aggregate data
            // size. Core Video owns each plane's declared storage separately.
            return CVPixelBufferGetBaseAddressOfPlane(buffer, 0) != nil
                && CVPixelBufferGetBaseAddressOfPlane(buffer, 1) != nil
        }
        return CVPixelBufferGetBaseAddress(buffer) != nil
            && CVPixelBufferGetDataSize(buffer) >= CVPixelBufferGetBytesPerRow(buffer) * height
    }
}
#endif
