import AVFoundation
import CoreMedia
import CoreVideo
import ExperienceDomain
import Foundation
import Metal
import Testing

@testable import AppleMediaCore

// The GPU pass is deliberately untestable in the sense that matters: whether
// MetalFX runs at all depends on the machine. These tests therefore assert the
// properties that must hold either way. A frame reaches the renderer, it keeps
// its identity, and it keeps its place in line, whether the pass ran, silently
// fell back, or never built at all.

@Test
func upscaleTargetIsCappedAndSkippedWhenMagnificationWouldBeTrivial() {
    // The shipping case: 1080p to the default visionOS window's backing width.
    let hd = MetalVideoUpscaler.outputSize(forInputWidth: 1_920, inputHeight: 1_080)
    #expect(hd?.width == 2_560)
    #expect(hd?.height == 1_440)

    // Lower profiles clamp at 2.0x rather than stretching to the preferred
    // width, which keeps MetalFX inside the ratio range it is tuned for.
    let lower = MetalVideoUpscaler.outputSize(forInputWidth: 1_280, inputHeight: 720)
    #expect(lower?.width == 2_560)
    #expect(lower?.height == 1_440)
    let lowest = MetalVideoUpscaler.outputSize(forInputWidth: 640, inputHeight: 360)
    #expect(lowest?.width == 1_280)
    #expect(lowest?.height == 720)

    // Already at or above the target: the pass would cost GPU time for nothing.
    #expect(MetalVideoUpscaler.outputSize(forInputWidth: 2_560, inputHeight: 1_440) == nil)
    #expect(MetalVideoUpscaler.outputSize(forInputWidth: 3_840, inputHeight: 2_160) == nil)
    #expect(MetalVideoUpscaler.outputSize(forInputWidth: 0, inputHeight: 0) == nil)

    // Every output stays a multiple of eight.
    for width in [640, 960, 1_280, 1_920] {
        guard let size = MetalVideoUpscaler.outputSize(
            forInputWidth: width,
            inputHeight: width * 9 / 16
        ) else { continue }
        #expect(size.width % 8 == 0)
        #expect(size.height % 8 == 0)
    }
}

@Test
func upscalingIsOffByDefaultAndPresentsTheDecodedBufferUntouched() async throws {
    let presenter = BoundedSampleBufferVideoPresenter(usesInternalPacingTimer: false)
    let backend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 1)

    #expect(presenter.snapshot().upscaling == .off)

    let frame = try streamSizedFrame(generation: 1, pts: 1)
    #expect(presenter.submit(frame) == .accepted)
    await presenter.waitUntilIdleForTesting()

    // Off is not "an upscale that does nothing", it is the untouched path: the
    // renderer receives the decoder's own buffer.
    let untouchedIdentity = UInt(
        bitPattern: Unmanaged.passUnretained(frame.pixelBuffer).toOpaque()
    )
    #expect(backend.enqueuedImageBufferIdentities() == [untouchedIdentity])
    #expect(backend.enqueuedImageBufferSizes().map(\.width) == [1_920])
    let snapshot = presenter.snapshot()
    #expect(snapshot.upscaler.framesUpscaled == 0)
    #expect(snapshot.upscaler.backendName == "none")
    #expect(snapshot.invalidTimingDrops == 0)
    await presenter.deactivate(generation: 1)
}

@Test
func enabledUpscalingPreservesFrameIdentityAndDeliversEveryFrameInOrder() async throws {
    let presenter = BoundedSampleBufferVideoPresenter(usesInternalPacingTimer: false)
    let backend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 1)

    presenter.setUpscaling(.enhanced)
    presenter.setDisplayPixelSize(width: 3_840, height: 2_160)
    let installed = await presenter.waitForUpscalerInstallationForTesting()

    var submitted: [DecodedVideoFrame] = []
    for pts in 1...12 {
        let frame = try streamSizedFrame(generation: 1, pts: CMTimeValue(pts))
        submitted.append(frame)
        #expect(presenter.submit(frame) == .accepted)
        await presenter.waitUntilIdleForTesting()
    }

    // The GPU pass completes off the presentation queue, so drain on the
    // observable outcome rather than on queue emptiness.
    #expect(await upscalingEventually { backend.enqueuedPresentationTimes().count == 12 })

    // Not one frame lost, and every timestamp strictly ascending: the presenter
    // drops non-monotonic frames, so any reordering would show up as a gap.
    #expect(backend.enqueuedPresentationTimes() == submitted.map(\.presentationTimeStamp))
    let snapshot = presenter.snapshot()
    #expect(snapshot.invalidTimingDrops == 0)
    #expect(snapshot.framesEnqueued == 12)
    #expect(snapshot.upscaling == .enhanced)

    // Whether the pass ran, silently fell back to Lanczos, or failed per
    // frame, every frame is accounted for exactly once. A machine with no
    // usable Metal device installs nothing and simply presents originals.
    let upscaler = snapshot.upscaler
    if installed {
        #expect(upscaler.framesUpscaled + upscaler.framesPassedThrough == 12)
        #expect(upscaler.backendName != "none")
    } else {
        #expect(upscaler.framesUpscaled == 0)
    }

    // Colorimetry survives the swap. An upscaled buffer that lost its Rec.709
    // attachments is read differently by the display layer, and the picture
    // visibly shifts the moment the setting is toggled.
    let expectedPrimaries = kCVImageBufferColorPrimaries_ITU_R_709_2 as String
    #expect(backend.enqueuedColorPrimaries().count == 12)
    #expect(backend.enqueuedColorPrimaries().allSatisfy { $0 == expectedPrimaries })

    // When the pass ran, the renderer really did receive a larger buffer.
    if installed, upscaler.framesUpscaled > 0 {
        #expect(backend.enqueuedImageBufferSizes().contains { $0.width == 2_560 })
    }
    await presenter.deactivate(generation: 1)
}

@Test
func togglingUpscalingMidStreamNeverBreaksTimingOrLosesFrames() async throws {
    let presenter = BoundedSampleBufferVideoPresenter(usesInternalPacingTimer: false)
    let backend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 1)
    presenter.setDisplayPixelSize(width: 3_840, height: 2_160)

    let modes: [StreamUpscaling] = [.enhanced, .off, .automatic, .enhanced, .off]
    var pts: CMTimeValue = 0
    var expected: [CMTime] = []
    for mode in modes {
        presenter.setUpscaling(mode)
        for _ in 0..<5 {
            pts += 1
            let frame = try streamSizedFrame(generation: 1, pts: pts)
            expected.append(frame.presentationTimeStamp)
            #expect(presenter.submit(frame) == .accepted)
            await presenter.waitUntilIdleForTesting()
        }
    }

    let expectedTimes = expected
    #expect(await upscalingEventually {
        backend.enqueuedPresentationTimes().count == expectedTimes.count
    })
    #expect(backend.enqueuedPresentationTimes() == expectedTimes)
    #expect(presenter.snapshot().invalidTimingDrops == 0)
    #expect(presenter.snapshot().upscaling == .off)
    await presenter.deactivate(generation: 1)
}

@Test
func automaticSkipsTheGPUPassWhenTheVideoIsNotBeingMagnified() async throws {
    let presenter = BoundedSampleBufferVideoPresenter(usesInternalPacingTimer: false)
    let backend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 1)

    // A window showing the 1080p stream at its own size. Reconstruction here
    // would burn GPU and battery for a magnification the eye cannot see.
    presenter.setUpscaling(.automatic)
    presenter.setDisplayPixelSize(width: 1_920, height: 1_080)

    for pts in 1...8 {
        let frame = try streamSizedFrame(generation: 1, pts: CMTimeValue(pts))
        #expect(presenter.submit(frame) == .accepted)
        await presenter.waitUntilIdleForTesting()
    }
    #expect(await upscalingEventually { backend.enqueuedPresentationTimes().count == 8 })

    let snapshot = presenter.snapshot()
    #expect(snapshot.upscaler.framesUpscaled == 0)
    #expect(snapshot.invalidTimingDrops == 0)
    await presenter.deactivate(generation: 1)
}

@Test
func suspensionAndRecoveryAreSafeWhileUpscalingIsEnabled() async throws {
    let presenter = BoundedSampleBufferVideoPresenter(usesInternalPacingTimer: false)
    let backend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 1)
    presenter.setUpscaling(.enhanced)
    presenter.setDisplayPixelSize(width: 3_840, height: 2_160)

    #expect(presenter.submit(try streamSizedFrame(generation: 1, pts: 1)) == .accepted)
    await presenter.waitUntilIdleForTesting()

    // The headset comes off: the pool is returned and admission stops.
    presenter.setPresentationSuspended(true)
    #expect(presenter.submit(try streamSizedFrame(generation: 1, pts: 2)) == .suspended)
    presenter.setPresentationSuspended(false)

    // Renderer recovery resets queue state, including the upscaler's caches.
    #expect(await presenter.recoverAfterInterruption() == .recovered)

    #expect(presenter.submit(try streamSizedFrame(generation: 1, pts: 3)) == .accepted)
    await presenter.waitUntilIdleForTesting()
    #expect(await upscalingEventually {
        backend.enqueuedPresentationTimes().last == CMTime(value: 3, timescale: 60)
    })
    #expect(presenter.snapshot().invalidTimingDrops == 0)
    await presenter.deactivate(generation: 1)
}

@Test
func aFrameProcessedAfterSuspensionSubmitsNoGPUWorkAndPresentsTheOriginal() async throws {
    let presenter = BoundedSampleBufferVideoPresenter(usesInternalPacingTimer: false)
    let backend = FakeSampleBufferPresentationBackend()
    await presenter.attach(backend: backend)
    try await presenter.activate(generation: 1)
    presenter.setUpscaling(.enhanced)
    presenter.setDisplayPixelSize(width: 3_840, height: 2_160)
    let installed = await presenter.waitForUpscalerInstallationForTesting()

    // One live frame first, so the comparison below is between a pass that
    // demonstrably works on this machine and one deliberately skipped.
    #expect(presenter.submit(try streamSizedFrame(generation: 1, pts: 1)) == .accepted)
    await presenter.waitUntilIdleForTesting()
    #expect(await upscalingEventually { backend.enqueuedPresentationTimes().count == 1 })
    let upscaledBefore = presenter.snapshot().upscaler.framesUpscaled

    // The scene goes away between admission and the hop onto the presentation
    // queue. `submit` refuses suspended frames, but this one was already past
    // it, and it is the frame that used to reach the GPU from the background
    // and come back as `MTLCommandBufferError.Code.notPermitted`.
    let strandedFrame = try streamSizedFrame(generation: 1, pts: 2)
    presenter.setPresentationSuspended(true)
    await presenter.processAdmittedFrameForTesting(strandedFrame)
    #expect(await upscalingEventually { backend.enqueuedPresentationTimes().count == 2 })

    // No GPU pass ran for it, and the renderer received the decoder's own
    // buffer. An upscale would have handed over a pool buffer instead, so this
    // identity is what distinguishes a skip from a completed pass.
    #expect(presenter.snapshot().upscaler.framesUpscaled == upscaledBefore)
    let untouchedIdentity = UInt(
        bitPattern: Unmanaged.passUnretained(strandedFrame.pixelBuffer).toOpaque()
    )
    #expect(backend.enqueuedImageBufferIdentities().last == untouchedIdentity)
    #expect(backend.enqueuedImageBufferSizes().last?.width == 1_920)

    // The frame still went through, in order, at the source resolution: the
    // load-bearing safety property survives the skip.
    #expect(backend.enqueuedPresentationTimes() == [
        CMTime(value: 1, timescale: 60),
        CMTime(value: 2, timescale: 60),
    ])

    // And it is a skip, not a latch. The pass works again the moment the scene
    // comes back, which is the whole point of not counting it as a failure.
    presenter.setPresentationSuspended(false)
    #expect(presenter.snapshot().upscaler.disabled == false)
    #expect(presenter.submit(try streamSizedFrame(generation: 1, pts: 3)) == .accepted)
    await presenter.waitUntilIdleForTesting()
    #expect(await upscalingEventually { backend.enqueuedPresentationTimes().count == 3 })
    if installed, upscaledBefore > 0 {
        #expect(presenter.snapshot().upscaler.framesUpscaled > upscaledBefore)
    }
    #expect(presenter.snapshot().invalidTimingDrops == 0)
    await presenter.deactivate(generation: 1)
}

@Test
func aBackgroundGPUDenialIsASkipWhileEveryOtherCommandBufferErrorIsAFailure() {
    // Apple documents this exact pair for a command buffer that reaches the
    // queue after the app moves into the background, in "Preparing your Metal
    // app to run in the background": status `.error`, code `.notPermitted`.
    // The headset logs the driver condition underneath it as
    // `kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`.
    let backgroundDenial = NSError(
        domain: MTLCommandBufferErrorDomain,
        code: Int(MTLCommandBufferError.Code.notPermitted.rawValue),
        userInfo: [
            NSLocalizedDescriptionKey:
                "Insufficient Permission (to submit GPU work from background)",
        ]
    )
    #expect(MetalVideoUpscaler.countsAsUpscaleFailure(backgroundDenial) == false)
    #expect(MetalVideoUpscaler.countsAsUpscaleFailure(nil) == false)

    // Every error that really does say something about this device still
    // counts, so the guard keeps doing the job it was written for.
    let deviceFailures: [MTLCommandBufferError.Code] = [
        .internal, .timeout, .pageFault, .accessRevoked,
        .outOfMemory, .invalidResource, .memoryless, .stackOverflow,
    ]
    for code in deviceFailures {
        let error = NSError(
            domain: MTLCommandBufferErrorDomain,
            code: Int(code.rawValue)
        )
        #expect(MetalVideoUpscaler.countsAsUpscaleFailure(error))
    }

    // The same number in another domain is an unrelated condition.
    let foreign = NSError(
        domain: "com.unshackledpursuit.remoteplay.not-metal",
        code: Int(MTLCommandBufferError.Code.notPermitted.rawValue)
    )
    #expect(MetalVideoUpscaler.countsAsUpscaleFailure(foreign))
}

@Test
func repeatedBackgroundDenialsNeverBurnTheSessionDisableLatch() throws {
    let queue = DispatchQueue(label: "com.unshackledpursuit.remoteplay.upscaler-latch-test")
    guard let upscaler = MetalVideoUpscaler(deliveryQueue: queue) else {
        // No usable Metal device here, so there is no latch to protect.
        return
    }

    let backgroundDenial = NSError(
        domain: MTLCommandBufferErrorDomain,
        code: Int(MTLCommandBufferError.Code.notPermitted.rawValue)
    )
    // Twice the limit. Taking the headset off repeatedly across a long session
    // must never cost the user the feature for the rest of that session.
    let denials = MetalVideoUpscaler.consecutiveFailureLimit * 2
    for _ in 0..<denials {
        upscaler.recordCommandBufferErrorForTesting(backgroundDenial)
    }
    let afterDenials = upscaler.diagnostics()
    #expect(afterDenials.disabled == false)
    #expect(afterDenials.upscaleFailures == 0)
    // They are still counted honestly as frames that reached the display at
    // the source resolution, which is what the Stats surface reports.
    #expect(afterDenials.framesPassedThrough == UInt64(denials))

    // The latch is intact for the condition it exists for: device incapability.
    let deviceFailure = NSError(
        domain: MTLCommandBufferErrorDomain,
        code: Int(MTLCommandBufferError.Code.outOfMemory.rawValue)
    )
    for _ in 0..<MetalVideoUpscaler.consecutiveFailureLimit {
        upscaler.recordCommandBufferErrorForTesting(deviceFailure)
    }
    let afterDeviceFailures = upscaler.diagnostics()
    #expect(afterDeviceFailures.disabled)
    #expect(
        afterDeviceFailures.upscaleFailures
            == UInt64(MetalVideoUpscaler.consecutiveFailureLimit)
    )
}

/// Polls a condition that a GPU completion resolves off the presentation queue.
private func upscalingEventually(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

/// A frame at the resolution the console actually sends. The upscaler declines
/// anything already at or above its target, so the 4x4 buffers the other
/// presenter tests use would never exercise the pass.
private func streamSizedFrame(
    generation: UInt64,
    pts: CMTimeValue
) throws -> DecodedVideoFrame {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:],
    ]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        1_920,
        1_080,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw SampleBufferVideoPresentationError
            .formatDescriptionCreationFailed(status)
    }
    CVBufferSetAttachment(
        pixelBuffer,
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferColorPrimaries_ITU_R_709_2,
        .shouldPropagate
    )
    CVBufferSetAttachment(
        pixelBuffer,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferTransferFunction_ITU_R_709_2,
        .shouldPropagate
    )
    return DecodedVideoFrame(
        generation: generation,
        pixelBuffer: pixelBuffer,
        presentationTimeStamp: CMTime(value: pts, timescale: 60),
        duration: CMTime(value: 1, timescale: 60)
    )
}
