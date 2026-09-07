import CoreMedia
import Foundation
import StreamingCore
import VideoToolbox

public final class BoundedHEVCDecoder: HEVCVideoDecoding, @unchecked Sendable {
    /// These callbacks execute on the decoder or VideoToolbox callback queue.
    /// Consumers must hand work off promptly and must never block waiting for
    /// `stop()`, which drains asynchronous VideoToolbox output.
    private enum Lifecycle {
        case running
        case stopping
        case stopped
    }

    /// Re-ask the console for a keyframe at most this often while the session
    /// is being rebuilt, so a lost IDR does not stall recovery.
    static let keyframeRequestIntervalNanoseconds: UInt64 = 500_000_000

    private let configuration: HEVCDecodeConfiguration
    private let frameHandler: HEVCDecodedFrameHandler
    private let failureHandler: HEVCDecodeFailureHandler
    private let backend: any HEVCDecoderBackend
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private let lock = NSLock()
    private let decoderQueue = DispatchQueue(
        label: "com.unshackledpursuit.remoteplay.hevc-decoder",
        qos: .userInteractive
    )

    private var lifecycle: Lifecycle = .running
    private var pendingFrameCount = 0
    private var decoderEpoch: UInt64 = 1
    // Set when VideoToolbox invalidates the session (for example after the app
    // was suspended). Cleared once a fresh session is configured.
    private var awaitingKeyframe = false
    private var lastKeyframeRequestUptimeNanoseconds: UInt64 = 0
    private var samplesAdmitted: UInt64 = 0
    private var framesDecoded: UInt64 = 0
    private var backpressureDrops: UInt64 = 0
    private var keyframeRequests: UInt64 = 0
    private var awaitingKeyframeDrops: UInt64 = 0
    private var sessionRecoveries: UInt64 = 0
    private var decodeFailures: UInt64 = 0

    // Decoder-queue confined state.
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var configuredParameterSets: HEVCParameterSets?

    public convenience init(
        configuration: HEVCDecodeConfiguration,
        frameHandler: @escaping HEVCDecodedFrameHandler,
        failureHandler: @escaping HEVCDecodeFailureHandler = { _, _ in }
    ) {
        self.init(
            configuration: configuration,
            backend: VideoToolboxHEVCBackend(),
            frameHandler: frameHandler,
            failureHandler: failureHandler
        )
    }

    init(
        configuration: HEVCDecodeConfiguration,
        backend: any HEVCDecoderBackend,
        frameHandler: @escaping HEVCDecodedFrameHandler,
        failureHandler: @escaping HEVCDecodeFailureHandler = { _, _ in },
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.configuration = configuration
        self.backend = backend
        self.frameHandler = frameHandler
        self.failureHandler = failureHandler
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    public func admit(
        _ sample: EncodedVideoSample,
        generation: UInt64
    ) -> HEVCDecodeAdmission {
        let epoch: UInt64
        lock.lock()
        guard lifecycle == .running else {
            lock.unlock()
            return .notRunning
        }
        guard generation == configuration.generation else {
            lock.unlock()
            return .staleGeneration
        }
        if awaitingKeyframe {
            // Only a sample that can rebuild the session is worth queueing.
            // Everything else is dropped here, and the console is asked for a
            // keyframe on a bounded cadence until one arrives.
            let canRebuild = (try? HEVCAnnexBParser.parse(sample.data)).map {
                $0.containsIDR || $0.vps != nil || $0.sps != nil || $0.pps != nil
            } ?? false
            if canRebuild == false {
                let now = uptimeNanoseconds()
                let shouldRequest = lastKeyframeRequestUptimeNanoseconds == 0
                    || now &- lastKeyframeRequestUptimeNanoseconds
                        >= Self.keyframeRequestIntervalNanoseconds
                if shouldRequest {
                    lastKeyframeRequestUptimeNanoseconds = now
                    keyframeRequests &+= 1
                } else {
                    awaitingKeyframeDrops &+= 1
                }
                lock.unlock()
                return shouldRequest ? .keyframeRequested : .awaitingKeyframe
            }
        }
        guard pendingFrameCount < configuration.maximumPendingFrames else {
            backpressureDrops &+= 1
            lock.unlock()
            return .backpressure
        }
        pendingFrameCount += 1
        samplesAdmitted &+= 1
        epoch = decoderEpoch
        lock.unlock()

        decoderQueue.async { [self] in
            process(sample, generation: generation, epoch: epoch)
        }
        return .accepted
    }

    public func stop() async {
        let shouldStop = lock.withLock { () -> Bool in
            switch lifecycle {
            case .running:
                lifecycle = .stopping
                return true
            case .stopping, .stopped:
                return false
            }
        }
        guard shouldStop else {
            while lock.withLock({ lifecycle == .stopping }) {
                await Task.yield()
            }
            return
        }

        await withCheckedContinuation { continuation in
            decoderQueue.async { [self] in
                backend.waitForAsynchronousFrames()
                backend.invalidate()
                vps = nil
                sps = nil
                pps = nil
                configuredParameterSets = nil
                lock.withLock {
                    decoderEpoch &+= 1
                    pendingFrameCount = 0
                    awaitingKeyframe = false
                    lifecycle = .stopped
                }
                continuation.resume()
            }
        }
    }

    public func diagnostics() -> HEVCDecoderDiagnostics {
        lock.withLock {
            HEVCDecoderDiagnostics(
                samplesAdmitted: samplesAdmitted,
                framesDecoded: framesDecoded,
                backpressureDrops: backpressureDrops,
                keyframeRequests: keyframeRequests,
                awaitingKeyframeDrops: awaitingKeyframeDrops,
                sessionRecoveries: sessionRecoveries,
                decodeFailures: decodeFailures,
                pendingFrames: pendingFrameCount,
                maximumPendingFrames: configuration.maximumPendingFrames,
                awaitingKeyframe: awaitingKeyframe
            )
        }
    }

    func pendingCountForTesting() -> Int {
        lock.withLock { pendingFrameCount }
    }

    func isAwaitingKeyframeForTesting() -> Bool {
        lock.withLock { awaitingKeyframe }
    }

    private func process(
        _ sample: EncodedVideoSample,
        generation: UInt64,
        epoch: UInt64
    ) {
        guard isCurrent(generation: generation, epoch: epoch) else {
            finishPending(generation: generation, epoch: epoch)
            return
        }

        let parsed: ParsedHEVCAccessUnit
        do {
            parsed = try HEVCAnnexBParser.parse(sample.data)
        } catch let failure as HEVCDecodeFailure {
            failureHandler(generation, failure)
            finishPending(generation: generation, epoch: epoch)
            return
        } catch {
            failureHandler(generation, .malformedAnnexB)
            finishPending(generation: generation, epoch: epoch)
            return
        }

        if let parsedVPS = parsed.vps { vps = parsedVPS }
        if let parsedSPS = parsed.sps { sps = parsedSPS }
        if let parsedPPS = parsed.pps { pps = parsedPPS }

        if let vps, let sps, let pps {
            let currentParameterSets = HEVCParameterSets(vps: vps, sps: sps, pps: pps)
            if currentParameterSets != configuredParameterSets {
                // The backend tears down its previous format before configuring
                // the replacement. Clear our marker first so a failed rebuild
                // can never continue decoding against a stale description.
                configuredParameterSets = nil
                do {
                    try backend.configure(parameterSets: currentParameterSets)
                    configuredParameterSets = currentParameterSets
                    lock.withLock { awaitingKeyframe = false }
                } catch let failure as HEVCDecodeFailure {
                    failureHandler(generation, failure)
                    finishPending(generation: generation, epoch: epoch)
                    return
                } catch {
                    failureHandler(generation, .sessionCreationFailed(-1))
                    finishPending(generation: generation, epoch: epoch)
                    return
                }
            }
        }

        guard configuredParameterSets != nil,
              let pictureData = parsed.lengthPrefixedPictureData else {
            finishPending(generation: generation, epoch: epoch)
            return
        }

        let presentationTimeStamp = CMTime(
            value: CMTimeValue(sample.receivedUptimeNanoseconds / 1_000),
            timescale: 1_000_000
        )
        let duration = CMTime(value: 1, timescale: configuration.framesPerSecond)
        do {
            try backend.decode(
                lengthPrefixedAccessUnit: pictureData,
                presentationTimeStamp: presentationTimeStamp,
                duration: duration,
                isIDR: parsed.containsIDR
            ) { [weak self] output in
                self?.receive(
                    output,
                    generation: generation,
                    epoch: epoch
                )
            }
        } catch let failure as HEVCDecodeFailure {
            lock.withLock { decodeFailures &+= 1 }
            handleSessionLossIfNeeded(failure)
            failureHandler(generation, failure)
            finishPending(generation: generation, epoch: epoch)
        } catch {
            lock.withLock { decodeFailures &+= 1 }
            failureHandler(generation, .decodeFailed(-1))
            finishPending(generation: generation, epoch: epoch)
        }
    }

    /// VideoToolbox invalidates hardware sessions when the process is suspended
    /// (headset removed, app backgrounded). Feeding the dead session fails every
    /// frame forever, so tear it down and wait for a sample that can rebuild it.
    /// Runs on the decoder queue or the VideoToolbox callback queue; both only
    /// touch decoder-queue state through the backend's own serialization.
    private func handleSessionLossIfNeeded(_ failure: HEVCDecodeFailure) {
        guard case let .decodeFailed(status) = failure,
              status == kVTInvalidSessionErr else { return }
        let shouldReset = lock.withLock { () -> Bool in
            guard awaitingKeyframe == false else { return false }
            awaitingKeyframe = true
            lastKeyframeRequestUptimeNanoseconds = 0
            sessionRecoveries &+= 1
            return true
        }
        guard shouldReset else { return }
        decoderQueue.async { [self] in
            backend.invalidate()
            configuredParameterSets = nil
        }
    }

    private func receive(
        _ output: HEVCBackendOutput,
        generation: UInt64,
        epoch: UInt64
    ) {
        let shouldDeliver = isCurrent(generation: generation, epoch: epoch)
        defer { finishPending(generation: generation, epoch: epoch) }
        guard shouldDeliver else { return }

        switch output {
        case let .frame(pixelBuffer, presentationTimeStamp, duration):
            lock.withLock { framesDecoded &+= 1 }
            frameHandler(
                DecodedVideoFrame(
                    generation: generation,
                    pixelBuffer: pixelBuffer,
                    presentationTimeStamp: presentationTimeStamp,
                    duration: duration
                )
            )
        case .dropped:
            return
        case let .failed(failure):
            lock.withLock { decodeFailures &+= 1 }
            handleSessionLossIfNeeded(failure)
            failureHandler(generation, failure)
        }
    }

    private func isCurrent(generation: UInt64, epoch: UInt64) -> Bool {
        lock.withLock {
            lifecycle == .running
                && configuration.generation == generation
                && decoderEpoch == epoch
        }
    }

    private func finishPending(generation: UInt64, epoch: UInt64) {
        lock.withLock {
            guard configuration.generation == generation,
                  decoderEpoch == epoch,
                  pendingFrameCount > 0 else {
                return
            }
            pendingFrameCount -= 1
        }
    }
}
