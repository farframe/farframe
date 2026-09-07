import ChiakiNative
import Dispatch
import Foundation
import InputCore
import StreamingCore

public enum ChiakiPlayStationNativeSessionError: Error, Equatable, Sendable, LocalizedError {
    case allocationFailed
    case sessionAlreadyStarted
    case invalidHost
    case invalidRegistrationKeyLength(Int)
    case invalidRemotePlayKeyLength(Int)
    case invalidVideoProfile
    case initializeFailed(code: Int32)
    case startFailed(code: Int32)
    case controllerStateFailed(code: Int32)
    case goHomeFailed(code: Int32)
    case goToBedFailed(code: Int32)
    case stopFailed(code: Int32)
    case joinFailed(code: Int32)
    case destroyFailed(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .allocationFailed:
            "The native PlayStation session could not be allocated."
        case .sessionAlreadyStarted:
            "This PlayStation session has already been started."
        case .invalidHost:
            "The saved PlayStation address is invalid."
        case .invalidRegistrationKeyLength, .invalidRemotePlayKeyLength:
            "The saved PlayStation registration is invalid. Re-register the console."
        case .invalidVideoProfile:
            "The selected PlayStation stream quality is invalid."
        case .initializeFailed:
            "The native PlayStation session could not be initialized."
        case .startFailed:
            "The native PlayStation session could not be started."
        case .controllerStateFailed:
            "The controller state could not be sent to the PlayStation."
        case .goHomeFailed:
            "The PlayStation Home command could not be sent."
        case .goToBedFailed:
            "The PlayStation Rest command could not be sent."
        case .stopFailed:
            "The native PlayStation session could not be stopped."
        case .joinFailed:
            "The native PlayStation session could not finish shutting down."
        case .destroyFailed:
            "The native PlayStation session could not release its resources."
        }
    }
}

/// Production adapter for the opaque ABI-6 Chiaki session boundary. A private
/// serial queue keeps every native lifecycle call ordered without blocking a
/// Swift cooperative executor. Native callbacks synchronously copy borrowed
/// payloads, enqueue owned values, and return without actor or teardown work.
public final class ChiakiPlayStationNativeSession: PlayStationNativeSession, @unchecked Sendable {
    private enum Lifecycle {
        case ready
        case started
        case stopRequested
        case closed
    }

    private let queue = DispatchQueue(
        label: "com.unshackledpursuit.remoteplay.chiaki-session",
        qos: .userInitiated
    )
    private let callbackBridge = ChiakiSessionCallbackBridge()
    private var handle: ChiakiSessionHandleBox?
    private var retainedCallbackContext: UnsafeMutableRawPointer?
    private var lifecycle: Lifecycle = .ready

    public init() throws {
        guard let handle = ChiakiSessionHandleBox() else {
            throw ChiakiPlayStationNativeSessionError.allocationFailed
        }
        self.handle = handle
    }

    public func start(
        configuration: PlayStationConnectConfiguration,
        eventHandler: @escaping PlayStationNativeSessionEventHandler,
        mediaHandler: @escaping PlayStationNativeMediaEventHandler
    ) async throws {
        try Self.validate(configuration)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard lifecycle == .ready, let handlePointer = handle?.pointer else {
                    continuation.resume(
                        throwing: ChiakiPlayStationNativeSessionError.sessionAlreadyStarted
                    )
                    return
                }

                callbackBridge.install(
                    eventHandler: eventHandler,
                    mediaHandler: mediaHandler
                )
                let callbackContext = Unmanaged.passRetained(callbackBridge).toOpaque()
                retainedCallbackContext = callbackContext
                let initializeResult = Self.initialize(
                    handle: handlePointer,
                    configuration: configuration,
                    callbackContext: callbackContext
                )
                guard initializeResult == RP_CHIAKI_BRIDGE_SUCCESS.rawValue else {
                    callbackBridge.clear()
                    releaseCallbackContext()
                    continuation.resume(
                        throwing: ChiakiPlayStationNativeSessionError.initializeFailed(
                            code: initializeResult
                        )
                    )
                    return
                }

                let startResult = rp_chiaki_session_start(handlePointer)
                guard startResult == RP_CHIAKI_BRIDGE_SUCCESS.rawValue else {
                    callbackBridge.clear()
                    releaseCallbackContext()
                    continuation.resume(
                        throwing: ChiakiPlayStationNativeSessionError.startFailed(code: startResult)
                    )
                    return
                }

                lifecycle = .started
                continuation.resume()
            }
        }
    }

    public func stop() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard lifecycle == .started, let handlePointer = handle?.pointer else {
                    continuation.resume()
                    return
                }

                let stopResult = rp_chiaki_session_request_stop(handlePointer)
                guard stopResult == RP_CHIAKI_BRIDGE_SUCCESS.rawValue else {
                    continuation.resume(
                        throwing: ChiakiPlayStationNativeSessionError.stopFailed(code: stopResult)
                    )
                    return
                }
                lifecycle = .stopRequested
                continuation.resume()
            }
        }
    }

    public func sendControllerSnapshot(_ snapshot: ControllerSnapshot) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard lifecycle == .started, let handlePointer = handle?.pointer else {
                    continuation.resume(
                        throwing: ChiakiPlayStationNativeSessionError.controllerStateFailed(
                            code: RP_CHIAKI_BRIDGE_INVALID_STATE.rawValue
                        )
                    )
                    return
                }

                var nativeState = ChiakiControllerStateMapping.map(snapshot)
                let result = rp_chiaki_session_set_controller_state(
                    handlePointer,
                    &nativeState
                )
                guard result == RP_CHIAKI_BRIDGE_SUCCESS.rawValue else {
                    continuation.resume(
                        throwing: ChiakiPlayStationNativeSessionError.controllerStateFailed(
                            code: result
                        )
                    )
                    return
                }
                continuation.resume()
            }
        }
    }

    public func goHome() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard lifecycle == .started, let handlePointer = handle?.pointer else {
                    continuation.resume(
                        throwing: ChiakiPlayStationNativeSessionError.goHomeFailed(
                            code: RP_CHIAKI_BRIDGE_INVALID_STATE.rawValue
                        )
                    )
                    return
                }

                let result = rp_chiaki_session_go_home(handlePointer)
                guard result == RP_CHIAKI_BRIDGE_SUCCESS.rawValue else {
                    continuation.resume(
                        throwing: ChiakiPlayStationNativeSessionError.goHomeFailed(code: result)
                    )
                    return
                }
                continuation.resume()
            }
        }
    }

    public func goToBed() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard lifecycle == .started, let handlePointer = handle?.pointer else {
                    continuation.resume(
                        throwing: ChiakiPlayStationNativeSessionError.goToBedFailed(
                            code: RP_CHIAKI_BRIDGE_INVALID_STATE.rawValue
                        )
                    )
                    return
                }

                let result = rp_chiaki_session_go_to_bed(handlePointer)
                guard result == RP_CHIAKI_BRIDGE_SUCCESS.rawValue else {
                    continuation.resume(
                        throwing: ChiakiPlayStationNativeSessionError.goToBedFailed(code: result)
                    )
                    return
                }
                continuation.resume()
            }
        }
    }

    public func join() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard lifecycle != .closed, let handle else {
                    continuation.resume()
                    return
                }

                let joinResult = rp_chiaki_session_join(handle.pointer)
                guard joinResult == RP_CHIAKI_BRIDGE_SUCCESS.rawValue else {
                    continuation.resume(
                        throwing: ChiakiPlayStationNativeSessionError.joinFailed(code: joinResult)
                    )
                    return
                }

                callbackBridge.clear()
                let destroyResult = handle.destroy()
                guard destroyResult == RP_CHIAKI_BRIDGE_SUCCESS.rawValue else {
                    continuation.resume(
                        throwing: ChiakiPlayStationNativeSessionError.destroyFailed(
                            code: destroyResult
                        )
                    )
                    return
                }
                releaseCallbackContext()
                self.handle = nil
                lifecycle = .closed
                continuation.resume()
            }
        }
    }

    private static func validate(_ configuration: PlayStationConnectConfiguration) throws {
        guard configuration.host.isEmpty == false,
              configuration.host.utf8.contains(0) == false else {
            throw ChiakiPlayStationNativeSessionError.invalidHost
        }
        guard configuration.registrationKey.count
                == Int(RP_CHIAKI_REGISTRATION_KEY_SIZE) else {
            throw ChiakiPlayStationNativeSessionError.invalidRegistrationKeyLength(
                configuration.registrationKey.count
            )
        }
        guard configuration.remotePlayKey.count
                == Int(RP_CHIAKI_REMOTE_PLAY_KEY_SIZE) else {
            throw ChiakiPlayStationNativeSessionError.invalidRemotePlayKeyLength(
                configuration.remotePlayKey.count
            )
        }
        guard configuration.videoProfile.width > 0,
              configuration.videoProfile.height > 0,
              configuration.videoProfile.maximumFramesPerSecond == 30
                || configuration.videoProfile.maximumFramesPerSecond == 60,
              configuration.videoProfile.bitrateKbps > 0,
              configuration.videoProfile.automaticDowngrade else {
            throw ChiakiPlayStationNativeSessionError.invalidVideoProfile
        }
    }

    private static func initialize(
        handle: OpaquePointer,
        configuration: PlayStationConnectConfiguration,
        callbackContext: UnsafeMutableRawPointer
    ) -> Int32 {
        configuration.host.withCString { hostPointer in
            configuration.registrationKey.withUnsafeBytes { registrationBytes in
                configuration.remotePlayKey.withUnsafeBytes { remotePlayBytes in
                    var nativeConfiguration = RPChiakiConnectConfiguration(
                        host: hostPointer,
                        registration_key: registrationBytes.bindMemory(to: UInt8.self).baseAddress,
                        registration_key_size: registrationBytes.count,
                        remote_play_key: remotePlayBytes.bindMemory(to: UInt8.self).baseAddress,
                        remote_play_key_size: remotePlayBytes.count,
                        width: configuration.videoProfile.width,
                        height: configuration.videoProfile.height,
                        maximum_frames_per_second: configuration.videoProfile.maximumFramesPerSecond,
                        bitrate_kbps: configuration.videoProfile.bitrateKbps,
                        codec: configuration.videoProfile.codec == .hevcHDR
                            ? RP_CHIAKI_VIDEO_CODEC_HEVC_HDR
                            : RP_CHIAKI_VIDEO_CODEC_HEVC
                    )
                    var callbacks = RPChiakiSessionCallbacks(
                        user: callbackContext,
                        event: receiveChiakiSessionEvent,
                        encoded_video: receiveChiakiEncodedVideo,
                        audio_format: receiveChiakiAudioFormat,
                        decoded_audio: receiveChiakiDecodedAudio,
                        display_state: receiveChiakiDisplayState,
                        controller_feedback: receiveChiakiControllerFeedback
                    )
                    return rp_chiaki_session_initialize(handle, &nativeConfiguration, &callbacks)
                }
            }
        }
    }

    private func releaseCallbackContext() {
        guard let retainedCallbackContext else { return }
        Unmanaged<ChiakiSessionCallbackBridge>.fromOpaque(retainedCallbackContext).release()
        self.retainedCallbackContext = nil
    }
}

enum ChiakiControllerStateMapping {
    static func map(_ snapshot: ControllerSnapshot) -> RPChiakiControllerState {
        RPChiakiControllerState(
            buttons: snapshot.pressedButtons.reduce(into: UInt32(0)) { buttons, button in
                buttons |= nativeButton(for: button)
            },
            l2_state: trigger(snapshot.leftTrigger),
            r2_state: trigger(snapshot.rightTrigger),
            left_x: stick(snapshot.leftX),
            left_y: stick(-snapshot.leftY),
            right_x: stick(snapshot.rightX),
            right_y: stick(-snapshot.rightY),
            touch_active: snapshot.touchpadActive ? 1 : 0,
            reserved: 0,
            touch_x: touch(
                snapshot.touchpadX,
                maximum: UInt16(RP_CHIAKI_TOUCHPAD_WIDTH)
            ),
            touch_y: touch(
                snapshot.touchpadY,
                maximum: UInt16(RP_CHIAKI_TOUCHPAD_HEIGHT)
            )
        )
    }

    private static func nativeButton(for button: ControllerButton) -> UInt32 {
        switch button {
        case .cross: UInt32(RP_CHIAKI_CONTROLLER_BUTTON_CROSS)
        case .circle: UInt32(RP_CHIAKI_CONTROLLER_BUTTON_CIRCLE)
        case .square: UInt32(RP_CHIAKI_CONTROLLER_BUTTON_SQUARE)
        case .triangle: UInt32(RP_CHIAKI_CONTROLLER_BUTTON_TRIANGLE)
        case .dpadUp: UInt32(RP_CHIAKI_CONTROLLER_BUTTON_DPAD_UP)
        case .dpadDown: UInt32(RP_CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN)
        case .dpadLeft: UInt32(RP_CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT)
        case .dpadRight: UInt32(RP_CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT)
        case .leftShoulder: UInt32(RP_CHIAKI_CONTROLLER_BUTTON_L1)
        case .rightShoulder: UInt32(RP_CHIAKI_CONTROLLER_BUTTON_R1)
        case .leftTrigger: UInt32(RP_CHIAKI_CONTROLLER_BUTTON_L2)
        case .rightTrigger: UInt32(RP_CHIAKI_CONTROLLER_BUTTON_R2)
        case .leftStick: UInt32(RP_CHIAKI_CONTROLLER_BUTTON_L3)
        case .rightStick: UInt32(RP_CHIAKI_CONTROLLER_BUTTON_R3)
        case .options: UInt32(RP_CHIAKI_CONTROLLER_BUTTON_OPTIONS)
        case .create: UInt32(RP_CHIAKI_CONTROLLER_BUTTON_CREATE)
        case .playStation: UInt32(RP_CHIAKI_CONTROLLER_BUTTON_PS)
        case .touchpad: UInt32(RP_CHIAKI_CONTROLLER_BUTTON_TOUCHPAD)
        }
    }

    private static func trigger(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8(clamping: Int(min(1, max(0, value)) * 255))
    }

    private static func stick(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16(clamping: Int(min(1, max(-1, value)) * 32_767))
    }

    private static func touch(_ value: Float, maximum: UInt16) -> UInt16 {
        guard value.isFinite else { return 0 }
        return UInt16(clamping: Int(min(1, max(0, value)) * Float(maximum)))
    }
}

public struct ChiakiPlayStationNativeSessionFactory: PlayStationNativeSessionFactory {
    public init() {}

    public func makeSession() async throws -> any PlayStationNativeSession {
        try ChiakiPlayStationNativeSession()
    }
}

enum ChiakiSessionEventMapping {
    // Stable values from ChiakiQuitReason in the source-locked native runtime.
    private static let stopped: Int32 = 1
    private static let remoteDisconnected: Int32 = 11
    private static let remoteShutdown: Int32 = 12

    static func map(eventType: Int32, detailCode: Int32) -> PlayStationNativeSessionEvent? {
        if eventType == Int32(RP_CHIAKI_SESSION_EVENT_TRANSPORT_READY.rawValue) {
            return .transportReady
        }
        guard eventType == Int32(RP_CHIAKI_SESSION_EVENT_QUIT.rawValue) else {
            return nil
        }

        switch detailCode {
        case stopped:
            return .quit(.normal)
        case remoteDisconnected, remoteShutdown:
            return .quit(.remoteDisconnected)
        default:
            return .quit(.nativeFailure(code: detailCode))
        }
    }
}

private func receiveChiakiSessionEvent(
    _ user: UnsafeMutableRawPointer?,
    _ eventType: RPChiakiSessionEventType,
    _ detailCode: Int32
) {
    guard let user,
          let event = ChiakiSessionEventMapping.map(
              eventType: Int32(eventType.rawValue),
              detailCode: detailCode
    ) else {
        return
    }
    Unmanaged<ChiakiSessionCallbackBridge>.fromOpaque(user)
        .takeUnretainedValue()
        .emit(event)
}

private func receiveChiakiEncodedVideo(
    _ user: UnsafeMutableRawPointer?,
    _ buffer: UnsafePointer<UInt8>?,
    _ bufferSize: Int,
    _ framesLost: Int32,
    _ frameRecovered: Bool
) -> Bool {
    guard let user else { return false }
    guard bufferSize > 0 else { return true }
    guard let sample = ChiakiMediaPayloadMapping.encodedVideo(
        buffer: buffer,
        bufferSize: bufferSize,
        framesLost: framesLost,
        frameRecovered: frameRecovered,
        receivedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
    ) else {
        return false
    }

    return Unmanaged<ChiakiSessionCallbackBridge>.fromOpaque(user)
        .takeUnretainedValue()
        .emit(.encodedVideo(sample))
}

private func receiveChiakiAudioFormat(
    _ user: UnsafeMutableRawPointer?,
    _ channels: UInt32,
    _ bitsPerSample: UInt32,
    _ sampleRate: UInt32,
    _ frameSize: UInt32
) {
    guard let user,
          let format = ChiakiMediaPayloadMapping.audioFormat(
        channels: channels,
        bitsPerSample: bitsPerSample,
        sampleRate: sampleRate,
        frameSize: frameSize
    ) else { return }
    _ = Unmanaged<ChiakiSessionCallbackBridge>.fromOpaque(user)
        .takeUnretainedValue()
        .emit(.audioFormat(format))
}

private func receiveChiakiDecodedAudio(
    _ user: UnsafeMutableRawPointer?,
    _ samples: UnsafePointer<Int16>?,
    _ frameCount: Int,
    _ channels: UInt32,
    _ sampleRate: UInt32
) {
    guard let user,
          let block = ChiakiMediaPayloadMapping.decodedAudio(
        samples: samples,
        frameCount: frameCount,
        channels: channels,
        sampleRate: sampleRate,
        receivedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
    ) else { return }
    _ = Unmanaged<ChiakiSessionCallbackBridge>.fromOpaque(user)
        .takeUnretainedValue()
        .emit(.decodedAudio(block))
}

private func receiveChiakiDisplayState(
    _ user: UnsafeMutableRawPointer?,
    _ cannotDisplay: Bool
) {
    guard let user else { return }
    _ = Unmanaged<ChiakiSessionCallbackBridge>.fromOpaque(user)
        .takeUnretainedValue()
        .emit(.displayBlocked(cannotDisplay))
}

private func receiveChiakiControllerFeedback(
    _ user: UnsafeMutableRawPointer?,
    _ feedback: UnsafePointer<RPChiakiControllerFeedback>?
) {
    guard let user, let feedback,
          let event = ChiakiControllerFeedbackMapping.map(feedback.pointee) else {
        return
    }
    Unmanaged<ChiakiSessionCallbackBridge>.fromOpaque(user)
        .takeUnretainedValue()
        .emit(.controllerFeedback(event))
}

enum ChiakiControllerFeedbackMapping {
    static func map(
        _ feedback: RPChiakiControllerFeedback
    ) -> ControllerFeedbackEvent? {
        switch feedback.type {
        case UInt32(RP_CHIAKI_CONTROLLER_FEEDBACK_RUMBLE.rawValue):
            return .rumble(
                ControllerRumble(
                    lowFrequencyByte: feedback.rumble_left,
                    highFrequencyByte: feedback.rumble_right
                )
            )

        case UInt32(RP_CHIAKI_CONTROLLER_FEEDBACK_LIGHT_BAR.rawValue):
            return .lightBar(
                ControllerLightBarColor(
                    redByte: feedback.light_bar_red,
                    greenByte: feedback.light_bar_green,
                    blueByte: feedback.light_bar_blue
                )
            )

        case UInt32(RP_CHIAKI_CONTROLLER_FEEDBACK_TRIGGER_EFFECTS.rawValue):
            var left = feedback.trigger_effect_left
            var right = feedback.trigger_effect_right
            return .triggerEffects(
                ControllerTriggerEffects(
                    left: ControllerTriggerEffectDecoder.decode(
                        type: feedback.trigger_effect_type_left,
                        parameters: parameterBytes(&left)
                    ),
                    right: ControllerTriggerEffectDecoder.decode(
                        type: feedback.trigger_effect_type_right,
                        parameters: parameterBytes(&right)
                    )
                )
            )

        case UInt32(RP_CHIAKI_CONTROLLER_FEEDBACK_HAPTIC_INTENSITY.rawValue):
            guard let intensity = ControllerEffectIntensity(
                wireValue: feedback.intensity
            ) else { return nil }
            return .rumbleIntensity(intensity)

        case UInt32(RP_CHIAKI_CONTROLLER_FEEDBACK_TRIGGER_INTENSITY.rawValue):
            guard let intensity = ControllerEffectIntensity(
                wireValue: feedback.intensity
            ) else { return nil }
            return .triggerIntensity(intensity)

        case UInt32(RP_CHIAKI_CONTROLLER_FEEDBACK_PLAYER_INDEX.rawValue):
            return .playerIndex(Int(feedback.player_index))

        default:
            return nil
        }
    }

    /// The trigger parameter block arrives as a fixed-size C array, which Swift
    /// imports as a tuple; this reads it back out as bytes.
    private static func parameterBytes(
        _ parameters: inout (
            UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8
        )
    ) -> [UInt8] {
        withUnsafeBytes(of: &parameters) { Array($0) }
    }
}

enum ChiakiMediaPayloadMapping {
    static func encodedVideo(
        buffer: UnsafePointer<UInt8>?,
        bufferSize: Int,
        framesLost: Int32,
        frameRecovered: Bool,
        receivedUptimeNanoseconds: UInt64
    ) -> EncodedVideoSample? {
        guard let buffer, bufferSize > 0 else { return nil }
        return try? EncodedVideoSample(
            data: Data(bytes: buffer, count: bufferSize),
            framesLost: framesLost,
            frameRecovered: frameRecovered,
            receivedUptimeNanoseconds: receivedUptimeNanoseconds
        )
    }

    static func audioFormat(
        channels: UInt32,
        bitsPerSample: UInt32,
        sampleRate: UInt32,
        frameSize: UInt32
    ) -> StreamingAudioFormat? {
        guard (1...2).contains(channels),
              bitsPerSample == 16,
              sampleRate == 48_000,
              frameSize > 0 else {
            return nil
        }
        return try? StreamingAudioFormat(
            channelCount: Int(channels),
            bitsPerSample: Int(bitsPerSample),
            sampleRate: sampleRate,
            frameSize: Int(frameSize)
        )
    }

    static func decodedAudio(
        samples: UnsafePointer<Int16>?,
        frameCount: Int,
        channels: UInt32,
        sampleRate: UInt32,
        receivedUptimeNanoseconds: UInt64
    ) -> InterleavedS16PCMBlock? {
        guard let samples,
              (1...2).contains(channels),
              sampleRate == 48_000,
              (1...4_800).contains(frameCount) else {
            return nil
        }

        let (sampleCount, sampleOverflow) = frameCount.multipliedReportingOverflow(
            by: Int(channels)
        )
        let (byteCount, byteOverflow) = sampleCount.multipliedReportingOverflow(
            by: MemoryLayout<Int16>.size
        )
        guard sampleOverflow == false, byteOverflow == false else { return nil }

        return try? InterleavedS16PCMBlock(
            data: Data(bytes: samples, count: byteCount),
            frameCount: frameCount,
            channelCount: Int(channels),
            sampleRate: sampleRate,
            receivedUptimeNanoseconds: receivedUptimeNanoseconds
        )
    }
}

final class ChiakiSessionCallbackBridge: @unchecked Sendable {
    private let condition = NSCondition()
    private let eventDeliveryQueue = DispatchQueue(
        label: "com.unshackledpursuit.remoteplay.chiaki-events",
        qos: .userInitiated
    )
    private let mediaStateDeliveryQueue = DispatchQueue(
        label: "com.unshackledpursuit.remoteplay.chiaki-media-state",
        qos: .userInitiated
    )
    private var eventHandler: PlayStationNativeSessionEventHandler?
    private var mediaHandler: PlayStationNativeMediaEventHandler?
    private var generation: UInt64 = 0
    private var inFlightDeliveries = 0

    func install(
        eventHandler: @escaping PlayStationNativeSessionEventHandler,
        mediaHandler: @escaping PlayStationNativeMediaEventHandler
    ) {
        condition.lock()
        generation &+= 1
        self.eventHandler = eventHandler
        self.mediaHandler = mediaHandler
        condition.unlock()
    }

    func clear() {
        condition.lock()
        generation &+= 1
        eventHandler = nil
        mediaHandler = nil
        while inFlightDeliveries > 0 {
            condition.wait()
        }
        condition.unlock()
    }

    func emit(_ event: PlayStationNativeSessionEvent) {
        let queuedGeneration = currentGeneration()
        eventDeliveryQueue.async { [self] in
            guard let handler = beginEventDelivery(generation: queuedGeneration) else {
                return
            }
            defer { finishDelivery() }
            handler(event)
        }
    }

    /// Video and audio are offered synchronously so bounded decoder/player
    /// admission flows back through Chiaki's callback. Display state remains a
    /// low-rate asynchronous notification on its independent queue.
    @discardableResult
    func emit(_ event: PlayStationNativeMediaEvent) -> Bool {
        let queuedGeneration = currentGeneration()
        switch event {
        case .encodedVideo, .audioFormat, .decodedAudio:
            guard let handler = beginMediaDelivery(generation: queuedGeneration) else {
                return false
            }
            defer { finishDelivery() }
            return handler(event)
        case .displayBlocked:
            enqueue(event, generation: queuedGeneration, on: mediaStateDeliveryQueue)
            return true
        }
    }

    private func enqueue(
        _ event: PlayStationNativeMediaEvent,
        generation queuedGeneration: UInt64,
        on deliveryQueue: DispatchQueue
    ) {
        deliveryQueue.async { [self] in
            guard let handler = beginMediaDelivery(generation: queuedGeneration) else {
                return
            }
            defer { finishDelivery() }
            _ = handler(event)
        }
    }

    private func currentGeneration() -> UInt64 {
        condition.lock()
        defer { condition.unlock() }
        return generation
    }

    private func beginEventDelivery(
        generation queuedGeneration: UInt64
    ) -> PlayStationNativeSessionEventHandler? {
        condition.lock()
        defer { condition.unlock() }
        guard generation == queuedGeneration, let eventHandler else { return nil }
        inFlightDeliveries += 1
        return eventHandler
    }

    private func beginMediaDelivery(
        generation queuedGeneration: UInt64
    ) -> PlayStationNativeMediaEventHandler? {
        condition.lock()
        defer { condition.unlock() }
        guard generation == queuedGeneration, let mediaHandler else { return nil }
        inFlightDeliveries += 1
        return mediaHandler
    }

    private func finishDelivery() {
        condition.lock()
        inFlightDeliveries -= 1
        if inFlightDeliveries == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }
}

private final class ChiakiSessionHandleBox: @unchecked Sendable {
    private(set) var pointer: OpaquePointer?

    init?() {
        guard let pointer = rp_chiaki_session_handle_create() else { return nil }
        self.pointer = pointer
    }

    func destroy() -> Int32 {
        guard let pointer else { return RP_CHIAKI_BRIDGE_SUCCESS.rawValue }
        let result = rp_chiaki_session_handle_destroy(pointer)
        if result == RP_CHIAKI_BRIDGE_SUCCESS.rawValue {
            self.pointer = nil
        }
        return result
    }

    deinit {
        // An active handle deliberately refuses destruction; this avoids a
        // use-after-free if a consumer violates the required stop/join contract.
        _ = destroy()
    }
}
