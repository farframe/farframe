import AVFoundation
import ExperienceDomain
import Foundation
import OSLog
import StreamingCore

public enum PCMAudioPlaybackError: Error, Equatable, Sendable {
    case invalidGeneration
    case backendActivationFailed
}

public enum PCMAudioPlaybackState: Equatable, Sendable {
    case inactive
    case activating
    case playing
    case recovering
    case failed
}

public enum PCMAudioPlaybackAdmission: Equatable, Sendable {
    case accepted
    case staleGeneration
    case notRunning
    case formatMissing
    case formatMismatch
    case stalePacket
    case backpressure
}

public struct PCMAudioPlaybackSnapshot: Equatable, Sendable {
    public let state: PCMAudioPlaybackState
    public let activeGeneration: UInt64?
    public let negotiatedFormat: StreamingAudioFormat?
    public let volume: Float
    public let isMuted: Bool
    public let queue: AudioQueueSnapshot
    public let recoveries: UInt64
    public let activationFailures: UInt64

    public init(
        state: PCMAudioPlaybackState,
        activeGeneration: UInt64?,
        negotiatedFormat: StreamingAudioFormat?,
        volume: Float,
        isMuted: Bool,
        queue: AudioQueueSnapshot,
        recoveries: UInt64,
        activationFailures: UInt64
    ) {
        self.state = state
        self.activeGeneration = activeGeneration
        self.negotiatedFormat = negotiatedFormat
        self.volume = volume
        self.isMuted = isMuted
        self.queue = queue
        self.recoveries = recoveries
        self.activationFailures = activationFailures
    }
}

/// Session-safe user controls. Stream lifecycle, PCM admission, reset, and
/// recovery remain package-owned so a shell cannot mutate provider authority.
public final class AudioPlaybackControls: @unchecked Sendable {
    private let player: BoundedPCMAudioPlayer

    package init(player: BoundedPCMAudioPlayer) {
        self.player = player
    }

    public func setVolume(_ volume: Float) {
        player.setVolume(volume)
    }

    public func setMuted(_ isMuted: Bool) {
        player.setMuted(isMuted)
    }

    /// Explicit user recovery after a media-services reset or engine failure.
    public func restorePlayback() { player.recoverAfterConfigurationChange(userInitiated: true) }

    /// Reconcile an existing session while its owning player is visible. This
    /// never reconnects the console or changes mute/volume preferences.
    public func reconcilePlayback(isForeground: Bool) {
        player.reconcilePlayback(isForeground: isForeground)
    }

    public func snapshot() -> PCMAudioPlaybackSnapshot {
        player.snapshot()
    }
}

public protocol AudioPlaybackControllableSession: StreamingSession {
    var audioControls: AudioPlaybackControls { get }
}

package struct PCMAudioRouteMetrics: Equatable, Sendable {
    let sampleRate: Double
    let outputLatency: TimeInterval
    let ioBufferDuration: TimeInterval
    let presentationLatency: TimeInterval

    static let unavailable = PCMAudioRouteMetrics(
        sampleRate: 48_000,
        outputLatency: 0,
        ioBufferDuration: 0,
        presentationLatency: 0
    )
}

/// Called on the realtime render thread for every hardware pull. Must fill
/// exactly `frameCount` frames into both non-interleaved Float32 channels.
package typealias PCMAudioRenderHandler = @Sendable (
    _ left: UnsafeMutablePointer<Float>,
    _ right: UnsafeMutablePointer<Float>,
    _ frameCount: Int
) -> Void

package enum PCMAudioRecoveryEvent: Sendable {
    case configurationChanged, mediaServicesReset, interruptionBegan
    case interruptionEnded(shouldResume: Bool)
}

package protocol PCMAudioPlaybackBackend: AnyObject, Sendable {
    func installRecoveryHandler(_ handler: @escaping @Sendable (PCMAudioRecoveryEvent) -> Void)
    func activate(
        outputFormat: AVAudioFormat,
        volume: Float,
        render: @escaping PCMAudioRenderHandler
    ) throws -> PCMAudioRouteMetrics
    func setVolume(_ volume: Float)
    func stop()
}

/// AVAudioEngine backend built on a pull-model `AVAudioSourceNode`. Every
/// method is called on the owning player's serial worker queue; unchecked
/// Sendable documents that confinement explicitly.
private final class AVAudioEnginePCMPlaybackBackend: PCMAudioPlaybackBackend, @unchecked Sendable {
    private let handlerLock = NSLock()
    private var recoveryHandler: (@Sendable (PCMAudioRecoveryEvent) -> Void)?
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var mixer: AVAudioMixerNode?
    private var notificationTokens: [NSObjectProtocol] = []
    private var engineNotificationToken: NSObjectProtocol?

    init() { installSessionNotifications() }

    func installRecoveryHandler(_ handler: @escaping @Sendable (PCMAudioRecoveryEvent) -> Void) {
        handlerLock.withLock { recoveryHandler = handler }
    }

    func activate(
        outputFormat: AVAudioFormat,
        volume: Float,
        render: @escaping PCMAudioRenderHandler
    ) throws -> PCMAudioRouteMetrics {
        stop()

        #if os(iOS) || os(visionOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try audioSession.setPreferredSampleRate(outputFormat.sampleRate)
        try audioSession.setPreferredIOBufferDuration(0.005)
        try audioSession.setActive(true)
        #endif

        let engine = AVAudioEngine()
        let source = AVAudioSourceNode(format: outputFormat) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudioUnitErr_InvalidParameter
            }
            render(left, right, Int(frameCount))
            return noErr
        }
        let mixer = AVAudioMixerNode()
        engine.attach(source)
        engine.attach(mixer)
        engine.connect(source, to: mixer, format: outputFormat)
        engine.connect(mixer, to: engine.mainMixerNode, format: outputFormat)
        mixer.outputVolume = volume

        try engine.start()

        self.engine = engine
        self.source = source
        self.mixer = mixer
        installEngineNotification(for: engine)

        #if os(iOS) || os(visionOS)
        return PCMAudioRouteMetrics(
            sampleRate: audioSession.sampleRate,
            outputLatency: audioSession.outputLatency,
            ioBufferDuration: audioSession.ioBufferDuration,
            presentationLatency: source.outputPresentationLatency
        )
        #else
        return PCMAudioRouteMetrics(
            sampleRate: outputFormat.sampleRate,
            outputLatency: 0,
            ioBufferDuration: 0,
            presentationLatency: source.outputPresentationLatency
        )
        #endif
    }

    func setVolume(_ volume: Float) {
        mixer?.outputVolume = volume
    }

    func stop() {
        if let token = engineNotificationToken { NotificationCenter.default.removeObserver(token) }
        engineNotificationToken = nil
        engine?.stop()
        source = nil
        mixer = nil
        engine = nil

        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
        #endif
    }

    deinit {
        removeNotifications()
    }

    private func installEngineNotification(for engine: AVAudioEngine) {
        let center = NotificationCenter.default
        engineNotificationToken =
            center.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                self?.requestRecovery(.configurationChanged)
            }
    }

    private func installSessionNotifications() {
        let center = NotificationCenter.default
        #if os(iOS) || os(visionOS)
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] notification in
                guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
                    as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
                switch type {
                case .began:
                    self?.requestRecovery(.interruptionBegan)
                case .ended:
                    let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey]
                        as? UInt ?? 0
                    let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                    self?.requestRecovery(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
                @unknown default: break
                }
            }
        )
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(), queue: nil
        ) { [weak self] _ in self?.requestRecovery(.mediaServicesReset) })
        // Engine-configuration notifications do not cover every output route.
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: nil
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  [.newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange].contains(reason) else { return }
            self?.requestRecovery(.configurationChanged)
        })
        #endif
    }

    private func removeNotifications() {
        let center = NotificationCenter.default
        notificationTokens.forEach(center.removeObserver)
        notificationTokens.removeAll(keepingCapacity: true)
        if let token = engineNotificationToken { center.removeObserver(token) }
        engineNotificationToken = nil
    }

    private func requestRecovery(_ event: PCMAudioRecoveryEvent) {
        handlerLock.withLock { recoveryHandler }?(event)
    }
}

private enum PCMAudioActivationResult: Sendable {
    case activated
    case failed
    case superseded
}

/// A jitter-tolerant low-latency PCM player.
///
/// The network callback thread validates the packet, converts it straight into
/// the `PCMJitterBuffer`, and returns. The audio hardware pulls from that
/// buffer on its own clock. There is no per-buffer scheduling, no completion
/// bookkeeping, and no fixed twelve-packet ceiling: bursty delivery is
/// absorbed by an adaptive playout target instead of being dropped.
/// AVAudioEngine lifecycle stays on one user-interactive serial queue.
package final class BoundedPCMAudioPlayer: @unchecked Sendable {
    package static let defaultVolume: Float = 0.7
    package static let maximumPacketAgeNanoseconds: UInt64 = 150_000_000
    /// Frames per Remote Play packet; used to express the ring in packets for
    /// the shared Stats surfaces.
    package static let nominalPacketFrames = 480

    private let lock = NSLock()
    private let workerQueue = DispatchQueue(
        label: "com.unshackledpursuit.remoteplay.pcm-audio",
        qos: .userInteractive
    )
    private let backend: any PCMAudioPlaybackBackend
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private let outputFormat: AVAudioFormat
    private let jitterBuffer: PCMJitterBuffer

    // Lock-protected lifecycle, admission, controls, and metrics.
    private var state: PCMAudioPlaybackState = .inactive
    private var activeGeneration: UInt64?
    private var epoch: UInt64 = 1
    private var negotiatedFormat: StreamingAudioFormat?
    private var volume: Float = BoundedPCMAudioPlayer.defaultVolume
    private var isMuted = false
    private var packetFrames = BoundedPCMAudioPlayer.nominalPacketFrames
    private var receivedBuffers = 0
    private var acceptedBuffers = 0
    private var stalePacketDrops = 0
    private var invalidBuffers = 0
    private var recoveryRequiresUserAction = false
    private var interruptionIsActive = false
    private var automaticRecoveryIsAllowed = true
    private var recoveryIsPending = false
    private var automaticProbeAttempts = 0
    private var lastAutomaticProbeAttempt: UInt64?
    private var lastHealthCheck: UInt64?
    private static let recoveryLog = Logger(subsystem: "com.unshackledpursuit.remoteplay.audio", category: "Recovery")
    private var healthProbe: (time: UInt64, accepted: Int, rendered: Int)?
    private var recoveries: UInt64 = 0
    private var activationFailures: UInt64 = 0
    private var lastCallbackUptimeNanoseconds: UInt64?
    private var callbackGapsMilliseconds: [Double] = []
    private var deliveryWaitsMilliseconds: [Double] = []
    private var conversionTimesMilliseconds: [Double] = []
    private var routeMetrics = PCMAudioRouteMetrics.unavailable
    private let timingWindowCapacity = 512

    package convenience init() {
        self.init(backend: AVAudioEnginePCMPlaybackBackend())
    }

    package init(
        backend: any PCMAudioPlaybackBackend,
        jitterConfiguration: PCMJitterBuffer.Configuration = .remotePlay,
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.backend = backend
        self.uptimeNanoseconds = uptimeNanoseconds
        self.jitterBuffer = PCMJitterBuffer(configuration: jitterConfiguration)
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        backend.installRecoveryHandler { [weak self] event in
            switch event {
            case .configurationChanged: self?.recoverAfterConfigurationChange()
            case .mediaServicesReset: self?.mediaServicesWereReset()
            case .interruptionBegan: self?.interruptionBegan()
            case let .interruptionEnded(shouldResume): self?.interruptionEnded(shouldResume: shouldResume)
            }
        }
    }

    package func makeControls() -> AudioPlaybackControls {
        AudioPlaybackControls(player: self)
    }

    package func activate(generation: UInt64) async throws {
        guard generation > 0 else {
            throw PCMAudioPlaybackError.invalidGeneration
        }

        let activationEpoch = lock.withLock { () -> UInt64 in
            state = .activating
            activeGeneration = generation
            advanceEpochLocked()
            resetGenerationMetricsLocked()
            return epoch
        }
        jitterBuffer.reset(keepTarget: false)

        let activation = await performOnWorkerQueue { [self, backend, outputFormat] in
            guard lock.withLock({
                activeGeneration == generation
                    && epoch == activationEpoch
                    && state == .activating
            }) else {
                return PCMAudioActivationResult.superseded
            }

            let targetVolume = effectiveVolume()
            let metrics: PCMAudioRouteMetrics
            do {
                metrics = try backend.activate(
                    outputFormat: outputFormat,
                    volume: targetVolume,
                    render: makeRenderHandler()
                )
            } catch {
                let isCurrent = lock.withLock { () -> Bool in
                    guard activeGeneration == generation,
                          epoch == activationEpoch,
                          state == .activating else {
                        return false
                    }
                    activationFailures &+= 1
                    state = .failed
                    activeGeneration = nil
                    negotiatedFormat = nil
                    advanceEpochLocked()
                    return true
                }
                backend.stop()
                return isCurrent ? .failed : .superseded
            }

            let committed = lock.withLock { () -> Bool in
                guard activeGeneration == generation,
                      epoch == activationEpoch,
                      state == .activating else {
                    return false
                }
                routeMetrics = metrics
                state = .playing
                return true
            }
            guard committed else {
                // A newer activation can be waiting behind this worker job.
                // Stop the stale backend before that newer job is allowed to
                // activate, so the old task can never stop the new session.
                backend.stop()
                return .superseded
            }
            return .activated
        }

        guard activation == .activated else {
            throw PCMAudioPlaybackError.backendActivationFailed
        }
    }

    package func configure(
        _ format: StreamingAudioFormat,
        generation: UInt64
    ) -> PCMAudioPlaybackAdmission {
        let result = lock.withLock { () -> (PCMAudioPlaybackAdmission, Bool) in
            guard activeGeneration == generation else {
                return (.staleGeneration, false)
            }
            guard state == .playing else { return (.notRunning, false) }
            guard Self.supports(format) else {
                invalidBuffers += 1
                return (.formatMismatch, false)
            }

            let changed = negotiatedFormat.map { $0 != format } ?? false
            negotiatedFormat = format
            return (.accepted, changed)
        }
        if result.1 {
            recoverAfterConfigurationChange()
        }
        return result.0
    }

    /// Validates and converts one decoded packet into the jitter buffer on the
    /// calling thread. Returns synchronously; the transport never waits on a
    /// worker queue for audio.
    package func admit(
        _ block: InterleavedS16PCMBlock,
        generation: UInt64
    ) -> PCMAudioPlaybackAdmission {
        let now = uptimeNanoseconds()
        let admitted = lock.withLock { () -> PCMAudioPlaybackAdmission in
            guard activeGeneration == generation else {
                return .staleGeneration
            }
            guard state == .playing else { return .notRunning }
            receivedBuffers += 1
            recordCallbackGapLocked(block.receivedUptimeNanoseconds)

            guard let negotiatedFormat else {
                invalidBuffers += 1
                return .formatMissing
            }
            guard negotiatedFormat.channelCount == block.channelCount,
                  negotiatedFormat.sampleRate == block.sampleRate,
                  negotiatedFormat.bitsPerSample == 16 else {
                invalidBuffers += 1
                return .formatMismatch
            }
            guard now < block.receivedUptimeNanoseconds
                    || now - block.receivedUptimeNanoseconds
                        <= Self.maximumPacketAgeNanoseconds else {
                stalePacketDrops += 1
                return .stalePacket
            }
            if now >= block.receivedUptimeNanoseconds {
                appendTimingLocked(
                    Double(now - block.receivedUptimeNanoseconds) / 1_000_000,
                    to: &deliveryWaitsMilliseconds
                )
            }
            packetFrames = block.frameCount
            return .accepted
        }
        guard admitted == .accepted else { return admitted }

        let conversionStart = uptimeNanoseconds()
        let outcome = block.data.withUnsafeBytes { rawBytes -> PCMJitterBuffer.WriteOutcome in
            guard let samples = rawBytes.bindMemory(to: Int16.self).baseAddress else {
                return .overflow
            }
            return jitterBuffer.write(
                interleavedInt16: samples,
                frameCount: block.frameCount,
                channelCount: block.channelCount
            )
        }
        let conversionEnd = uptimeNanoseconds()

        return lock.withLock {
            if conversionEnd >= conversionStart {
                appendTimingLocked(
                    Double(conversionEnd - conversionStart) / 1_000_000,
                    to: &conversionTimesMilliseconds
                )
            }
            switch outcome {
            case .accepted, .acceptedAfterSkip:
                acceptedBuffers += 1
                return .accepted
            case .overflow:
                return .backpressure
            }
        }
    }

    package func deactivate(generation: UInt64) async {
        let shouldStop = lock.withLock { () -> Bool in
            guard activeGeneration == generation else { return false }
            state = .inactive
            activeGeneration = nil
            negotiatedFormat = nil
            advanceEpochLocked()
            return true
        }
        guard shouldStop else { return }
        jitterBuffer.reset(keepTarget: false)
        await performOnWorkerQueue { [backend] in backend.stop() }
    }

    package func snapshot() -> PCMAudioPlaybackSnapshot {
        let ring = jitterBuffer.snapshot()
        let configuration = jitterBuffer.configuration
        return lock.withLock {
            let frames: Int = max(1, packetFrames)
            let skippedPackets: Int = ring.skippedFrames / frames
            let overflowPackets: Int = ring.overflowFrames / frames
            let sampleRate = Double(configuration.sampleRate)
            let ceilingFrames: Int = ring.targetFrames + configuration.skipSlackFrames
            let dropped: Int = stalePacketDrops + skippedPackets + overflowPackets
            let targetMilliseconds: Double = Double(ring.targetFrames) * 1_000 / sampleRate
            let silenceMilliseconds: Double = Double(ring.silenceFrames) * 1_000 / sampleRate
            let outputLatencyMilliseconds: Double = routeMetrics.outputLatency * 1_000
            let ioBufferMilliseconds: Double = routeMetrics.ioBufferDuration * 1_000
            let presentationMilliseconds: Double = routeMetrics.presentationLatency * 1_000
            let queue = AudioQueueSnapshot(
                scheduledBuffers: ring.fillFrames / frames,
                scheduledFrames: ring.fillFrames,
                receivedBuffers: receivedBuffers,
                acceptedBuffers: acceptedBuffers,
                renderedBuffers: ring.renderedFrames / frames,
                droppedBuffers: dropped,
                stalePacketDrops: stalePacketDrops,
                backpressureDrops: skippedPackets,
                pendingOverflowDrops: overflowPackets,
                schedulingFailureDrops: 0,
                invalidBuffers: invalidBuffers,
                highWaterMark: ceilingFrames / frames,
                lowWaterMark: ring.targetFrames / frames,
                catchingUp: ring.priming,
                sampleRate: routeMetrics.sampleRate,
                callbackGapP95Milliseconds: percentile95Locked(callbackGapsMilliseconds),
                schedulerWaitP95Milliseconds: percentile95Locked(deliveryWaitsMilliseconds),
                conversionP95Milliseconds: percentile95Locked(conversionTimesMilliseconds),
                outputLatencyMilliseconds: outputLatencyMilliseconds,
                ioBufferDurationMilliseconds: ioBufferMilliseconds,
                presentationLatencyMilliseconds: presentationMilliseconds,
                underruns: ring.underruns,
                targetLatencyMilliseconds: targetMilliseconds,
                silenceMilliseconds: silenceMilliseconds
            )
            return PCMAudioPlaybackSnapshot(
                state: state,
                activeGeneration: activeGeneration,
                negotiatedFormat: negotiatedFormat,
                volume: volume,
                isMuted: isMuted,
                queue: queue,
                recoveries: recoveries,
                activationFailures: activationFailures
            )
        }
    }

    package func jitterBufferSnapshotForTesting() -> PCMJitterBuffer.Snapshot {
        jitterBuffer.snapshot()
    }

    fileprivate func setVolume(_ requestedVolume: Float) {
        let effective = lock.withLock { () -> Float in
            volume = min(1, max(0, requestedVolume.isFinite ? requestedVolume : 0))
            return effectiveVolumeLocked()
        }
        workerQueue.async { [backend] in backend.setVolume(effective) }
    }

    fileprivate func setMuted(_ requestedMuted: Bool) {
        let effective = lock.withLock { () -> Float in
            isMuted = requestedMuted
            return effectiveVolumeLocked()
        }
        workerQueue.async { [backend] in backend.setVolume(effective) }
    }

    private func effectiveVolume() -> Float {
        lock.withLock { effectiveVolumeLocked() }
    }

    private func effectiveVolumeLocked() -> Float {
        isMuted ? 0 : volume
    }

    private func makeRenderHandler() -> PCMAudioRenderHandler {
        let jitterBuffer = self.jitterBuffer
        return { left, right, frameCount in
            jitterBuffer.render(left: left, right: right, frameCount: frameCount)
        }
    }

    fileprivate func recoverAfterConfigurationChange(userInitiated: Bool = false) {
        let recovery: (UInt64, UInt64)? = lock.withLock {
            guard state == .playing || state == .failed,
                  !recoveryRequiresUserAction || userInitiated,
                  let generation = activeGeneration else { return nil }
            if !userInitiated && (!automaticRecoveryIsAllowed || interruptionIsActive) {
                recoveryIsPending = true
                return nil
            }
            if userInitiated {
                interruptionIsActive = false
                automaticProbeAttempts = 0
            }
            recoveryRequiresUserAction = false
            recoveryIsPending = false
            healthProbe = nil
            state = .recovering
            advanceEpochLocked()
            recoveries &+= 1
            return (generation, epoch)
        }
        guard let recovery else { return }
        Self.recoveryLog.notice("Audio recovery requested; userInitiated=\(userInitiated)")
        // A route change (headphones, headset off and on) restarts the engine;
        // the playout target learned for this network is worth keeping.
        jitterBuffer.reset(keepTarget: true)

        workerQueue.async { [weak self, backend, outputFormat] in
            guard let self, lock.withLock({ activeGeneration == recovery.0 && epoch == recovery.1 && state == .recovering }) else { return }
            backend.stop()
            let result: Result<PCMAudioRouteMetrics, PCMAudioPlaybackError>
            do {
                result = .success(
                    try backend.activate(
                        outputFormat: outputFormat,
                        volume: effectiveVolume(),
                        render: makeRenderHandler()
                    )
                )
            } catch {
                result = .failure(.backendActivationFailed)
                backend.stop()
            }
            lock.withLock {
                guard activeGeneration == recovery.0,
                      epoch == recovery.1,
                      state == .recovering else {
                    return
                }
                switch result {
                case let .success(metrics):
                    routeMetrics = metrics
                    state = .playing
                    Self.recoveryLog.notice("Audio output restarted")
                case .failure:
                    activationFailures &+= 1
                    state = .failed
                    Self.recoveryLog.error("Audio output restart failed; preserving the game session")
                }
            }
        }
    }

    /// Called by the owning scene's existing monitor, not a new timer or a
    /// realtime audio callback. Three bounded attempts cover a briefly denied
    /// activation. Healthy output, network silence and muted audio do not
    /// trigger an engine rebuild. A fresh foreground visit permits retry.
    fileprivate func reconcilePlayback(isForeground: Bool) {
        let now = uptimeNanoseconds()
        let shouldInspect = lock.withLock { () -> Bool in
            if automaticRecoveryIsAllowed != isForeground {
                automaticRecoveryIsAllowed = isForeground
                healthProbe = nil
                lastHealthCheck = nil
                if isForeground {
                    automaticProbeAttempts = 0
                    lastAutomaticProbeAttempt = nil
                }
            }
            guard isForeground, activeGeneration != nil,
                  !interruptionIsActive, !recoveryRequiresUserAction else { return false }
            if let lastHealthCheck, now >= lastHealthCheck,
               now - lastHealthCheck < 1_000_000_000 { return false }
            lastHealthCheck = now
            return true
        }
        guard shouldInspect else { return }
        let ring = jitterBuffer.snapshot()
        // Priming/underrun silence still proves that hardware is pulling.
        let hardwareFrames = ring.renderedFrames + ring.silenceFrames
        let shouldRecover = lock.withLock { () -> Bool in
            guard automaticRecoveryIsAllowed, activeGeneration != nil,
                  !interruptionIsActive, !recoveryRequiresUserAction,
                  state == .playing || state == .failed else { return false }
            var needsRecovery = state == .failed || recoveryIsPending
            if state == .playing && !needsRecovery {
                let current = (time: now, accepted: acceptedBuffers, rendered: hardwareFrames)
                guard !isMuted, volume > 0 else { healthProbe = nil; return false }
                guard let previous = healthProbe else { healthProbe = current; return false }
                if hardwareFrames != previous.rendered {
                    healthProbe = current
                    automaticProbeAttempts = 0
                    return false
                }
                guard now >= previous.time, now - previous.time >= 2_000_000_000 else { return false }
                healthProbe = current
                // Look for fresh admitted PCM without corresponding hardware
                // consumption. Never mistake a silent network for a dead engine.
                if let lastCallbackUptimeNanoseconds,
                   now >= lastCallbackUptimeNanoseconds,
                   now - lastCallbackUptimeNanoseconds < 1_000_000_000 {
                    needsRecovery = acceptedBuffers > previous.accepted && ring.fillFrames > 0
                }
            }
            guard needsRecovery, automaticProbeAttempts < 3 else { return false }
            if let lastAutomaticProbeAttempt, now >= lastAutomaticProbeAttempt,
               now - lastAutomaticProbeAttempt < 1_000_000_000 { return false }
            automaticProbeAttempts += 1
            lastAutomaticProbeAttempt = now
            return true
        }
        if shouldRecover { recoverAfterConfigurationChange() }
    }

    private func interruptionBegan() {
        Self.recoveryLog.notice("Audio interruption began")
        suspendForInterruption(requiresUserAction: false)
    }

    private func interruptionEnded(shouldResume: Bool) {
        Self.recoveryLog.notice("Audio interruption ended; shouldResume=\(shouldResume)")
        lock.withLock {
            interruptionIsActive = false
            if !shouldResume { recoveryRequiresUserAction = true }
        }
        if shouldResume { recoverAfterConfigurationChange() }
    }

    private func mediaServicesWereReset() {
        Self.recoveryLog.notice("Audio services reset; waiting for Restore Audio")
        // Apple requires user action after a media-server reset. Foreground
        // reconciliation and ordinary route notifications must not bypass it.
        suspendForInterruption(requiresUserAction: true)
    }

    private func suspendForInterruption(requiresUserAction: Bool) {
        let resetEpoch: UInt64? = lock.withLock {
            guard activeGeneration != nil, state != .inactive else { return nil }
            state = .failed
            if requiresUserAction { recoveryRequiresUserAction = true }
            else { interruptionIsActive = true }
            recoveryIsPending = true
            healthProbe = nil
            advanceEpochLocked()
            return epoch
        }
        guard let resetEpoch else { return }
        jitterBuffer.reset(keepTarget: true)
        workerQueue.async { [weak self, backend] in
            guard let self, lock.withLock({ epoch == resetEpoch && state == .failed }) else { return }
            backend.stop()
        }
    }

    private static func supports(_ format: StreamingAudioFormat) -> Bool {
        (1...2).contains(format.channelCount)
            && format.bitsPerSample == 16
            && format.sampleRate == 48_000
    }

    private func resetGenerationMetricsLocked() {
        recoveryRequiresUserAction = false
        interruptionIsActive = false
        recoveryIsPending = false
        automaticProbeAttempts = 0
        lastAutomaticProbeAttempt = nil
        lastHealthCheck = nil
        healthProbe = nil
        negotiatedFormat = nil
        packetFrames = Self.nominalPacketFrames
        receivedBuffers = 0
        acceptedBuffers = 0
        stalePacketDrops = 0
        invalidBuffers = 0
        lastCallbackUptimeNanoseconds = nil
        callbackGapsMilliseconds.removeAll(keepingCapacity: true)
        deliveryWaitsMilliseconds.removeAll(keepingCapacity: true)
        conversionTimesMilliseconds.removeAll(keepingCapacity: true)
        routeMetrics = .unavailable
    }

    private func advanceEpochLocked() {
        epoch &+= 1
        if epoch == 0 { epoch = 1 }
    }

    private func recordCallbackGapLocked(_ callback: UInt64) {
        if let lastCallbackUptimeNanoseconds,
           callback >= lastCallbackUptimeNanoseconds {
            appendTimingLocked(
                Double(callback - lastCallbackUptimeNanoseconds) / 1_000_000,
                to: &callbackGapsMilliseconds
            )
        }
        lastCallbackUptimeNanoseconds = callback
    }

    private func appendTimingLocked(_ value: Double, to values: inout [Double]) {
        values.append(value)
        if values.count > timingWindowCapacity {
            values.removeFirst(values.count - timingWindowCapacity)
        }
    }

    private func percentile95Locked(_ values: [Double]) -> Double {
        guard values.isEmpty == false else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[max(0, index)]
    }

    private func performOnWorkerQueue<T: Sendable>(
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            workerQueue.async {
                continuation.resume(returning: operation())
            }
        }
    }
}
