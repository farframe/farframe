import CoreVideo
import ExperienceDomain
import Foundation
import Metal
import MetalPerformanceShaders

// MetalFX ships in every device SDK and in NO simulator SDK (verified against
// Xcode 26.6: present in XROS, iPhoneOS and MacOSX; absent from XRSimulator and
// iPhoneSimulator). An unconditional import therefore breaks every simulator
// build, including the Vision simulator leg of `Scripts/verify-integration.sh`.
// MetalPerformanceShaders IS present in the simulators, so the Lanczos tier
// below keeps the feature functional everywhere the scaler cannot exist.
#if canImport(MetalFX)
import MetalFX
#endif

/// Counters for the Stats surfaces. `framesPassedThrough` is the one that
/// explains a quality difference the user can see: those frames reached the
/// display at the source resolution because the GPU pass could not run.
public struct VideoUpscalerDiagnostics: Equatable, Sendable {
    /// `metalfx`, `lanczos`, or `none`.
    public let backendName: String
    public let outputWidth: Int
    public let outputHeight: Int
    public let framesUpscaled: UInt64
    public let framesPassedThrough: UInt64
    public let upscaleFailures: UInt64
    public let lastGPUMilliseconds: Double
    /// The rolling-failure guard tripped and the pass is off for this session.
    public let disabled: Bool

    public init(
        backendName: String = "none",
        outputWidth: Int = 0,
        outputHeight: Int = 0,
        framesUpscaled: UInt64 = 0,
        framesPassedThrough: UInt64 = 0,
        upscaleFailures: UInt64 = 0,
        lastGPUMilliseconds: Double = 0,
        disabled: Bool = false
    ) {
        self.backendName = backendName
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.framesUpscaled = framesUpscaled
        self.framesPassedThrough = framesPassedThrough
        self.upscaleFailures = upscaleFailures
        self.lastGPUMilliseconds = lastGPUMilliseconds
        self.disabled = disabled
    }
}

/// Pass B. MetalFX must write into a `MTLStorageModePrivate` texture, and a
/// texture wrapping an IOSurface-backed `CVPixelBuffer` is never private, so a
/// pass that moves the result into the output buffer is mandatory rather than
/// optional. The current fragment pass only copies the scaled texture. Additional
/// processing is deferred until provenance and hardware checks are complete.
private let videoCompositeShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct FarframeCompositeVertex {
    float4 position [[position]];
    float2 texCoord;
};

struct FarframeCompositeUniforms {
    // Reserved composite controls. Sharpening and dithering are deferred.
    float sharpness;
    // Peak dither amplitude in output code values (1.0 == one 8-bit step).
    float ditherAmplitude;
    // One source texel in normalized coordinates, for the sharpen taps.
    float2 texelSize;
};

vertex FarframeCompositeVertex farframe_composite_vertex(uint vertexID [[vertex_id]]) {
    // Full-screen triangle: no vertex buffer, three vertices, one primitive.
    float2 uv = float2(float((vertexID << 1) & 2), float(vertexID & 2));
    FarframeCompositeVertex out;
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    out.texCoord = uv;
    return out;
}

fragment float4 farframe_composite_fragment(
    FarframeCompositeVertex in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    constant FarframeCompositeUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler sourceSampler(
        filter::linear,
        mip_filter::none,
        address::clamp_to_edge,
        coord::normalized
    );

    float3 color = source.sample(sourceSampler, in.texCoord).rgb;

    return float4(saturate(color), 1.0);
}
"""

private struct VideoCompositeUniforms {
    var sharpness: Float
    var ditherAmplitude: Float
    var texelWidth: Float
    var texelHeight: Float
}

/// A spatial upscaler for decoded video frames, confined by contract to the
/// presenter's serial presentation queue.
///
/// Three properties define the contract and every one of them is load bearing.
///
/// It never blocks the caller. The GPU pass is committed and the caller
/// returns; the completion arrives later on the delivery queue. The pacing
/// timer shares that queue, so waiting on the GPU there would put GPU time
/// inside every pacing tick.
///
/// It never reorders. Completions are delivered through a FIFO keyed on
/// submission order, so a frame can only be presented after every frame
/// submitted before it. The presenter drops non-monotonic timestamps, which
/// would turn any reordering directly into visible stutter.
///
/// It never fails loudly. Every failure path completes with `nil`, and the
/// caller presents the original frame.
final class MetalVideoUpscaler: @unchecked Sendable {
    /// One GPU pass at a time. A second frame arriving while the GPU is still
    /// working is completed as a pass-through rather than dropped or made to
    /// wait: a frame at the source resolution is a far smaller defect than a
    /// missing frame, and it keeps a single intermediate texture correct
    /// without a per-frame allocation.
    private static let maximumFramesInFlight = 1
    /// Consecutive per-frame failures before the pass gives up for the session.
    /// Only a failure that says something about this device counts; see
    /// `countsAsUpscaleFailure(_:)`.
    static let consecutiveFailureLimit = 30
    /// Pool ceiling. At 2560x1440 BGRA each buffer is 14.7 MB, so this caps the
    /// pool at about 74 MB. Three is too tight in practice: one buffer is on
    /// the GPU, and the renderer holds both the frame it is displaying and the
    /// ones queued behind it. Exhausting the pool is safe but it presents a
    /// source-resolution frame, and alternating resolutions is more visible
    /// than the memory is expensive. The pool only grows to what is demanded.
    private static let poolAllocationThreshold = 5
    /// Target output width before the 2.0x clamp. See section 6.1 of the
    /// upscaling report: it matches the default visionOS player window's
    /// backing width and is the ratio Moonlight actually measured.
    private static let preferredOutputWidth = 2_560.0
    /// Below this magnification the upscale is not worth the GPU time.
    static let minimumUsefulScale = 1.15

    private struct Job {
        let sequence: UInt64
        var isComplete: Bool
        var result: DecodedVideoFrame?
        let completion: @Sendable (DecodedVideoFrame?) -> Void
    }

    private struct Dimensions: Equatable {
        let inputWidth: Int
        let inputHeight: Int
        let outputWidth: Int
        let outputHeight: Int
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let pipelineState: any MTLRenderPipelineState
    private let deliveryQueue: DispatchQueue

    // Delivery-queue confined. Rebuilt whenever the frame dimensions change.
    private var dimensions: Dimensions?
    #if canImport(MetalFX)
    private var scaler: (any MTLFXSpatialScaler)?
    #endif
    private var lanczos: MPSImageLanczosScale?
    private var intermediate: (any MTLTexture)?
    private var pixelBufferPool: CVPixelBufferPool?
    private var nextSequence: UInt64 = 1

    // Lock protected: the FIFO and the counters are touched from Metal's
    // completion threads as well as the delivery queue.
    private let lock = NSLock()
    private var pending: [Job] = []
    private var framesUpscaled: UInt64 = 0
    private var framesPassedThrough: UInt64 = 0
    private var upscaleFailures: UInt64 = 0
    private var consecutiveFailures = 0
    private var lastGPUMilliseconds: Double = 0
    private var reportedOutputWidth = 0
    private var reportedOutputHeight = 0
    private var isDisabled = false
    private var activeBackendName = "none"

    /// Builds the device-level objects off the delivery queue and installs the
    /// result on it. Shader compilation and pipeline construction cost tens of
    /// milliseconds, which is a visible stutter if it happens inside a pacing
    /// tick. Returns `nil` to the completion when this device cannot run the
    /// pass at all, which is permanent for the session.
    static func makeAsynchronously(
        deliveryQueue: DispatchQueue,
        completion: @escaping @Sendable (MetalVideoUpscaler?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let upscaler = MetalVideoUpscaler(deliveryQueue: deliveryQueue)
            deliveryQueue.async { completion(upscaler) }
        }
    }

    init?(deliveryQueue: DispatchQueue) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }

        var createdCache: CVMetalTextureCache?
        let textureAttributes: [CFString: Any] = [
            kCVMetalTextureUsage: MTLTextureUsage([.shaderRead, .renderTarget]).rawValue,
        ]
        guard CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            textureAttributes as CFDictionary,
            &createdCache
        ) == kCVReturnSuccess, let textureCache = createdCache else { return nil }

        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(
                source: videoCompositeShaderSource,
                options: nil
            )
        } catch {
            return nil
        }
        guard let vertexFunction = library.makeFunction(name: "farframe_composite_vertex"),
              let fragmentFunction = library.makeFunction(name: "farframe_composite_fragment")
        else { return nil }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        // Decoded frames are Rec.709 gamma encoded. The plain `.bgra8Unorm`
        // target writes the shader's values through unchanged; the `_srgb`
        // variant would apply an encode the frames already carry.
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipelineState = try? device.makeRenderPipelineState(
            descriptor: pipelineDescriptor
        ) else { return nil }

        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = textureCache
        self.pipelineState = pipelineState
        self.deliveryQueue = deliveryQueue
    }

    /// Sharpening stays off until the upscale itself has been characterized on
    /// a headset. The release retains only the ordinary texture-copy composite.
    let sharpness: Float = 0
    /// Reserved. Dithering is deferred along with the enhancement feature.
    let ditherAmplitude: Float = 0

    /// True when no GPU work is outstanding and no completion is owed.
    var isIdle: Bool {
        lock.withLock { pending.isEmpty }
    }

    func diagnostics() -> VideoUpscalerDiagnostics {
        lock.withLock {
            VideoUpscalerDiagnostics(
                backendName: activeBackendName,
                outputWidth: reportedOutputWidth,
                outputHeight: reportedOutputHeight,
                framesUpscaled: framesUpscaled,
                framesPassedThrough: framesPassedThrough,
                upscaleFailures: upscaleFailures,
                lastGPUMilliseconds: lastGPUMilliseconds,
                disabled: isDisabled
            )
        }
    }


    /// Delivery-queue confined. Submits one frame and takes ownership of
    /// delivering exactly one completion, in submission order.
    ///
    /// - Parameter upscale: `false` routes the frame through the same FIFO
    ///   without GPU work. Every frame must travel one ordering domain, so a
    ///   frame that skips the pass still cannot overtake one that did not.
    func submit(
        _ frame: DecodedVideoFrame,
        upscale: Bool,
        completion: @escaping @Sendable (DecodedVideoFrame?) -> Void
    ) {
        let sequence = nextSequence
        nextSequence &+= 1

        let admitted: Bool = lock.withLock {
            pending.append(
                Job(
                    sequence: sequence,
                    isComplete: false,
                    result: nil,
                    completion: completion
                )
            )
            guard upscale, isDisabled == false else { return false }
            // One in flight. `pending` already holds this job, so anything
            // beyond it is a frame that arrived while the GPU was busy.
            return pending.count <= Self.maximumFramesInFlight
        }

        guard admitted else {
            finish(sequence: sequence, result: nil, countedAsFailure: false)
            return
        }

        if encodeUpscale(frame, sequence: sequence) == false {
            finish(sequence: sequence, result: nil, countedAsFailure: true)
        }
    }

    /// Section 9.7 risk 6. The renderer flush and interruption recovery paths
    /// reset presenter queue state; the texture cache must be reset with them
    /// so a post-recovery frame is not composed against a stale mapping.
    func invalidateCaches() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    /// Section 9.7 risk 5. Called when the scene goes inactive. Returns the
    /// pool and any cached texture mappings; buffers still referenced by an
    /// in-flight command buffer or by the renderer survive, because both hold
    /// their own strong references.
    func releaseTransientResources() {
        if let pixelBufferPool {
            CVPixelBufferPoolFlush(pixelBufferPool, .excessBuffers)
        }
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    /// The output size for a given source, or `nil` when magnification would be
    /// too small to be worth the GPU time.
    static func outputSize(
        forInputWidth width: Int,
        inputHeight height: Int
    ) -> (width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        // Never more than 2.0x: larger ratios cost memory without a visible
        // return and take MetalFX outside the range it is tuned for.
        let scale = min(Self.preferredOutputWidth / Double(width), 2.0)
        guard scale > Self.minimumUsefulScale else { return nil }
        let outputWidth = (Int((Double(width) * scale).rounded()) / 8) * 8
        let outputHeight = (Int((Double(height) * scale).rounded()) / 8) * 8
        guard outputWidth > width, outputHeight > height else { return nil }
        return (outputWidth, outputHeight)
    }

    // MARK: - GPU pass

    /// Encodes and commits one frame's GPU work. Returns `false` if anything on
    /// the way there failed, in which case no completion is owed by this call.
    /// Delivery-queue confined.
    private func encodeUpscale(_ frame: DecodedVideoFrame, sequence: UInt64) -> Bool {
        guard let target = Self.outputSize(
            forInputWidth: frame.width,
            inputHeight: frame.height
        ) else { return false }

        let required = Dimensions(
            inputWidth: frame.width,
            inputHeight: frame.height,
            outputWidth: target.width,
            outputHeight: target.height
        )
        guard prepareResources(for: required) else { return false }
        guard let intermediate, let pixelBufferPool else { return false }

        guard let input = makeTexture(
            from: frame.pixelBuffer,
            width: frame.width,
            height: frame.height
        ) else { return false }

        // The allocation threshold makes pool exhaustion a per-frame failure
        // that presents the original, instead of unbounded growth on a headset.
        var createdOutput: CVPixelBuffer?
        let auxiliaryAttributes: [CFString: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey: Self.poolAllocationThreshold,
        ]
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pixelBufferPool,
            auxiliaryAttributes as CFDictionary,
            &createdOutput
        ) == kCVReturnSuccess, let outputBuffer = createdOutput else { return false }

        // Not optional. Without the source colorimetry the display layer reads
        // these frames differently from the originals and the picture shifts
        // the instant the setting is toggled.
        CVBufferPropagateAttachments(frame.pixelBuffer, outputBuffer)

        guard let output = makeTexture(
            from: outputBuffer,
            width: target.width,
            height: target.height
        ) else { return false }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        #if canImport(MetalFX)
        if let scaler {
            scaler.colorTexture = input.texture
            scaler.inputContentWidth = frame.width
            scaler.inputContentHeight = frame.height
            scaler.outputTexture = intermediate
            scaler.encode(commandBuffer: commandBuffer)
        } else if let lanczos {
            lanczos.encode(
                commandBuffer: commandBuffer,
                sourceTexture: input.texture,
                destinationTexture: intermediate
            )
        } else {
            return false
        }
        #else
        guard let lanczos else { return false }
        lanczos.encode(
            commandBuffer: commandBuffer,
            sourceTexture: input.texture,
            destinationTexture: intermediate
        )
        #endif

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = output.texture
        passDescriptor.colorAttachments[0].loadAction = .dontCare
        passDescriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: passDescriptor
        ) else { return false }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(intermediate, index: 0)
        var uniforms = VideoCompositeUniforms(
            sharpness: sharpness,
            ditherAmplitude: ditherAmplitude,
            texelWidth: 1.0 / Float(target.width),
            texelHeight: 1.0 / Float(target.height)
        )
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<VideoCompositeUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        let upscaledFrame = DecodedVideoFrame(
            generation: frame.generation,
            pixelBuffer: outputBuffer,
            presentationTimeStamp: frame.presentationTimeStamp,
            duration: frame.duration
        )

        // The CVMetalTexture wrappers must outlive the command buffer, so the
        // handler captures them. Releasing them earlier is the classic
        // CVMetalTextureCache corruption bug.
        let retainedTextures = RetainedTexturePair(input: input.wrapper, output: output.wrapper)
        commandBuffer.addCompletedHandler { [weak self] buffer in
            // The CVMetalTexture wrappers must outlive the command buffer.
            // Releasing them earlier is the classic CVMetalTextureCache
            // corruption bug, so the handler holds them to completion.
            retainedTextures.keepAlive()
            guard let self else { return }
            if let error = buffer.error {
                finish(
                    sequence: sequence,
                    result: nil,
                    countedAsFailure: Self.countsAsUpscaleFailure(error)
                )
            } else {
                finish(
                    sequence: sequence,
                    result: upscaledFrame,
                    countedAsFailure: false,
                    gpuMilliseconds: (buffer.gpuEndTime - buffer.gpuStartTime) * 1_000
                )
            }
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        commandBuffer.commit()
        return true
    }

    /// Whether a completed command buffer's error should move the rolling
    /// failure guard toward disabling the pass for the session.
    ///
    /// The guard exists for a device that cannot run the pass. Losing GPU
    /// permission is not that: it is an environmental condition that ends the
    /// moment the scene comes back. Counting it would let a few seconds in the
    /// background retire the feature for the rest of the session, silently and
    /// with no way for the user to get it back.
    static func countsAsUpscaleFailure(_ error: (any Error)?) -> Bool {
        guard let error else { return false }
        return isBackgroundExecutionDenial(error) == false
    }

    /// True when the system refused the command buffer because this process is
    /// not currently permitted to use the GPU, which is what happens to work
    /// that reaches the queue after the app moves into the background.
    ///
    /// Apple documents exactly this pair in *Preparing your Metal app to run in
    /// the background*: the buffer's status is `MTLCommandBufferStatus.error`
    /// and its error is `MTLCommandBufferError.Code.notPermitted`. The driver
    /// condition underneath is the one the headset logs as
    /// `kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`.
    ///
    /// `MTLCommandBufferError` bridges from `NSError` and its `Code` raw value
    /// is a `UInt`, hence the domain-and-code comparison rather than a cast.
    private static func isBackgroundExecutionDenial(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == MTLCommandBufferErrorDomain
            && nsError.code == Int(MTLCommandBufferError.Code.notPermitted.rawValue)
    }

    /// Test seam. Drives the rolling-failure guard through exactly the path a
    /// completed command buffer takes, on a machine whose GPU cannot be put
    /// into the denied state on purpose.
    func recordCommandBufferErrorForTesting(_ error: (any Error)?) {
        let sequence = nextSequence
        nextSequence &+= 1
        lock.withLock {
            pending.append(
                Job(
                    sequence: sequence,
                    isComplete: false,
                    result: nil,
                    completion: { _ in }
                )
            )
        }
        finish(
            sequence: sequence,
            result: nil,
            countedAsFailure: Self.countsAsUpscaleFailure(error)
        )
    }

    /// Delivery-queue confined. Rebuilds the scaler, intermediate texture, and
    /// pool when the frame or target dimensions change.
    private func prepareResources(for required: Dimensions) -> Bool {
        #if canImport(MetalFX)
        let backendReady = scaler != nil || lanczos != nil
        #else
        let backendReady = lanczos != nil
        #endif
        if dimensions == required,
           intermediate != nil,
           pixelBufferPool != nil,
           backendReady {
            return true
        }

        #if canImport(MetalFX)
        scaler = nil
        #endif
        lanczos = nil
        intermediate = nil
        pixelBufferPool = nil
        dimensions = nil

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: required.outputWidth,
            height: required.outputHeight,
            mipmapped: false
        )
        // MetalFX requires a private-storage output texture, which is exactly
        // why the composite pass below it exists.
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let newIntermediate = device.makeTexture(
            descriptor: textureDescriptor
        ) else { return false }

        var createdPool: CVPixelBufferPool?
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 2,
            kCVPixelBufferPoolMaximumBufferAgeKey: 1.0,
        ]
        let bufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: required.outputWidth,
            kCVPixelBufferHeightKey: required.outputHeight,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            bufferAttributes as CFDictionary,
            &createdPool
        ) == kCVReturnSuccess, let newPool = createdPool else { return false }

        var backendName = "none"
        #if canImport(MetalFX)
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = required.inputWidth
        descriptor.inputHeight = required.inputHeight
        descriptor.outputWidth = required.outputWidth
        descriptor.outputHeight = required.outputHeight
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        // Apple's guidance for tone-mapped input in the 0-1 range. A decoded
        // Rec.709 frame is definitionally that.
        descriptor.colorProcessingMode = .perceptual

        if MTLFXSpatialScalerDescriptor.supportsDevice(device),
           let newScaler = descriptor.makeSpatialScaler(device: device) {
            scaler = newScaler
            backendName = "metalfx"
        } else {
            // Tier one fallback. Lower quality than MetalFX, still better than
            // handing the compositor an under-sampled surface.
            lanczos = MPSImageLanczosScale(device: device)
            backendName = lanczos == nil ? "none" : "lanczos"
        }
        guard scaler != nil || lanczos != nil else { return false }
        #else
        // Simulator: no MetalFX in the SDK at all, so the Lanczos tier is the
        // only backend. Behaviour is otherwise identical, which keeps the
        // simulator honest about the surrounding plumbing.
        lanczos = MPSImageLanczosScale(device: device)
        backendName = lanczos == nil ? "none" : "lanczos"
        guard lanczos != nil else { return false }
        #endif

        intermediate = newIntermediate
        pixelBufferPool = newPool
        dimensions = required
        lock.withLock {
            activeBackendName = backendName
            reportedOutputWidth = required.outputWidth
            reportedOutputHeight = required.outputHeight
        }
        return true
    }

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) -> (wrapper: CVMetalTexture, texture: any MTLTexture)? {
        var created: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            // Never the `_srgb` variant: the texture unit would linearize on
            // read and double-apply an inverse transfer that `perceptual`
            // already assumes.
            .bgra8Unorm,
            width,
            height,
            0,
            &created
        ) == kCVReturnSuccess, let created,
            let texture = CVMetalTextureGetTexture(created) else { return nil }
        return (created, texture)
    }

    // MARK: - Ordered delivery

    /// Marks one job complete and delivers every job at the front of the FIFO
    /// that is ready. A job can only be delivered once every job submitted
    /// before it has been delivered, which is what makes reordering impossible
    /// regardless of the order Metal invokes completion handlers in.
    private func finish(
        sequence: UInt64,
        result: DecodedVideoFrame?,
        countedAsFailure: Bool,
        gpuMilliseconds: Double? = nil
    ) {
        let ready: [Job] = lock.withLock {
            if let gpuMilliseconds { lastGPUMilliseconds = gpuMilliseconds }
            if countedAsFailure {
                upscaleFailures &+= 1
                consecutiveFailures += 1
                if consecutiveFailures >= Self.consecutiveFailureLimit, isDisabled == false {
                    isDisabled = true
                    activeBackendName = "none"
                }
            } else if result != nil {
                consecutiveFailures = 0
                framesUpscaled &+= 1
            }
            if result == nil {
                framesPassedThrough &+= 1
            }

            if let index = pending.firstIndex(where: { $0.sequence == sequence }) {
                pending[index].isComplete = true
                pending[index].result = result
            }

            var deliverable: [Job] = []
            while let first = pending.first, first.isComplete {
                deliverable.append(pending.removeFirst())
            }
            return deliverable
        }

        guard ready.isEmpty == false else { return }
        deliveryQueue.async {
            for job in ready { job.completion(job.result) }
        }
    }
}

/// Carries the two `CVMetalTexture` wrappers into the command buffer's
/// completion handler, which Metal declares `@Sendable`. The wrappers are only
/// ever read there to keep them alive; nothing mutates them.
private final class RetainedTexturePair: @unchecked Sendable {
    private let input: CVMetalTexture
    private let output: CVMetalTexture

    init(input: CVMetalTexture, output: CVMetalTexture) {
        self.input = input
        self.output = output
    }

    func keepAlive() {
        withExtendedLifetime(input) {}
        withExtendedLifetime(output) {}
    }
}
