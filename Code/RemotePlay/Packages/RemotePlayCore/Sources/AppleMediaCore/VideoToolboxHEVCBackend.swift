import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum HEVCBackendOutput: @unchecked Sendable {
    case frame(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime, duration: CMTime)
    case dropped
    case failed(HEVCDecodeFailure)
}

protocol HEVCDecoderBackend: AnyObject, Sendable {
    func configure(parameterSets: HEVCParameterSets) throws

    func decode(
        lengthPrefixedAccessUnit: Data,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        isIDR: Bool,
        completion: @escaping @Sendable (HEVCBackendOutput) -> Void
    ) throws

    func waitForAsynchronousFrames()
    func invalidate()
}

final class VideoToolboxHEVCBackend: HEVCDecoderBackend, @unchecked Sendable {
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?

    func configure(parameterSets: HEVCParameterSets) throws {
        waitForAsynchronousFrames()
        invalidate()

        var createdFormatDescription: CMVideoFormatDescription?
        let formatStatus = parameterSets.vps.withUnsafeBytes { vpsBytes in
            parameterSets.sps.withUnsafeBytes { spsBytes in
                parameterSets.pps.withUnsafeBytes { ppsBytes -> OSStatus in
                    guard let vps = vpsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let sps = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let pps = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return kCMFormatDescriptionError_InvalidParameter
                    }
                    var pointers: [UnsafePointer<UInt8>] = [vps, sps, pps]
                    var sizes = [
                        parameterSets.vps.count,
                        parameterSets.sps.count,
                        parameterSets.pps.count,
                    ]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count,
                        parameterSetPointers: &pointers,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &createdFormatDescription
                    )
                }
            }
        }
        guard formatStatus == noErr, let createdFormatDescription else {
            throw HEVCDecodeFailure.formatDescriptionCreationFailed(formatStatus)
        }

        let decoderSpecification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        // This checkpoint intentionally preserves only the proven SDR path.
        // HEVCDecodeConfiguration rejects HDR until a separately verified
        // 10-bit destination and presentation path exists.
        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: remotePlayDecompressionOutputCallback,
            decompressionOutputRefCon: nil
        )
        var createdSession: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: createdFormatDescription,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &createdSession
        )
        guard sessionStatus == noErr, let createdSession else {
            throw HEVCDecodeFailure.sessionCreationFailed(sessionStatus)
        }

        VTSessionSetProperty(
            createdSession,
            key: kVTDecompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
        formatDescription = createdFormatDescription
        decompressionSession = createdSession
    }

    func decode(
        lengthPrefixedAccessUnit: Data,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        isIDR: Bool,
        completion: @escaping @Sendable (HEVCBackendOutput) -> Void
    ) throws {
        guard let decompressionSession, let formatDescription else {
            throw HEVCDecodeFailure.missingDecoderSession
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: lengthPrefixedAccessUnit.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: lengthPrefixedAccessUnit.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw HEVCDecodeFailure.blockBufferCreationFailed(blockStatus)
        }

        let copyStatus = lengthPrefixedAccessUnit.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: lengthPrefixedAccessUnit.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw HEVCDecodeFailure.blockBufferCopyFailed(copyStatus)
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = lengthPrefixedAccessUnit.count
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw HEVCDecodeFailure.sampleBufferCreationFailed(sampleStatus)
        }

        let callbackContext = Unmanaged.passRetained(
            VideoToolboxFrameCallbackContext(completion: completion)
        )
        var infoFlags: VTDecodeInfoFlags = []
        let decodeFlags: VTDecodeFrameFlags = isIDR
            ? []
            : [._EnableAsynchronousDecompression]
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: decodeFlags,
            frameRefcon: callbackContext.toOpaque(),
            infoFlagsOut: &infoFlags
        )
        guard decodeStatus == noErr else {
            callbackContext.release()
            throw HEVCDecodeFailure.decodeFailed(decodeStatus)
        }
    }

    func waitForAsynchronousFrames() {
        guard let decompressionSession else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
    }

    func invalidate() {
        guard let decompressionSession else {
            formatDescription = nil
            return
        }
        VTDecompressionSessionInvalidate(decompressionSession)
        self.decompressionSession = nil
        formatDescription = nil
    }

    deinit {
        waitForAsynchronousFrames()
        invalidate()
    }
}

private final class VideoToolboxFrameCallbackContext: @unchecked Sendable {
    let completion: @Sendable (HEVCBackendOutput) -> Void

    init(completion: @escaping @Sendable (HEVCBackendOutput) -> Void) {
        self.completion = completion
    }
}

private func remotePlayDecompressionOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    _ = decompressionOutputRefCon
    _ = infoFlags
    guard let sourceFrameRefCon else { return }
    let context = Unmanaged<VideoToolboxFrameCallbackContext>
        .fromOpaque(sourceFrameRefCon)
        .takeRetainedValue()

    guard status == noErr else {
        context.completion(.failed(.decodeFailed(status)))
        return
    }
    guard let imageBuffer else {
        context.completion(.dropped)
        return
    }
    context.completion(
        .frame(
            pixelBuffer: imageBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: presentationDuration
        )
    )
}
