import CoreHaptics
import Foundation
import GameController

/// Applies console-driven feedback to a real Apple game controller.
///
/// Everything here is best effort by construction. A missing controller, a
/// controller without haptics, a light bar that does not exist, a non-DualSense
/// gamepad, or a Core Haptics engine that refuses to start all end in the same
/// place: the feedback is dropped and the stream is untouched. No path throws,
/// logs, or reaches the video, audio, or pacing code.
///
/// Rumble is delivered through Core Haptics rather than a rumble API because
/// Apple exposes no direct amplitude control. One infinite continuous event per
/// handle is started on demand, then steered with dynamic intensity parameters,
/// which is the lowest-latency way to track a console rumble stream.
public final class AppleControllerFeedbackSink: @unchecked Sendable {
    private struct Actuator {
        let engine: CHHapticEngine
        var player: (any CHHapticAdvancedPatternPlayer)?
        var isPlaying = false
    }

    /// The Core Haptics event that rumble intensity is applied to. The
    /// PlayStation's two actuators differ in weight, so the heavier
    /// low-frequency side gets a duller sharpness than the light one.
    private enum Handle {
        case low
        case high

        var locality: GCHapticsLocality {
            switch self {
            case .low: .leftHandle
            case .high: .rightHandle
            }
        }

        var sharpness: Float {
            switch self {
            case .low: 0.2
            case .high: 0.8
            }
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "com.unshackledpursuit.remoteplay.controller-feedback",
        qos: .userInitiated
    )

    private var controller: GCController?
    private var actuators: [GCHapticsLocality: Actuator] = [:]
    private var isEnabled = true
    private var rumbleScale: Float = 1
    private var triggerScale: Float = 1
    private var lastRumble = ControllerRumble.silent
    private var installedLightBar: ControllerLightBarColor?

    public init() {}

    // MARK: - Lifecycle

    /// Adopts a controller. Passing nil releases the previous one and returns
    /// it to rest.
    public func setController(_ controller: GCController?) {
        let previous: GCController? = lock.withLock {
            let previous = self.controller
            guard previous !== controller else { return nil }
            self.controller = controller
            return previous
        }

        guard previous != nil || controller != nil else { return }
        let previousBox = previous.map(SendableGameController.init(value:))
        queue.async { [self] in
            if let previousBox {
                quiesce(previousBox.value)
            }
            teardownActuators()
        }
    }

    /// Turns the whole feedback path on or off. Disabling immediately returns
    /// the controller to rest so a held rumble cannot survive the setting.
    public func setEnabled(_ enabled: Bool) {
        let changed: Bool = lock.withLock {
            guard isEnabled != enabled else { return false }
            isEnabled = enabled
            return true
        }
        guard changed else { return }
        if !enabled {
            stopAll()
        }
    }

    public var isFeedbackEnabled: Bool {
        lock.withLock { isEnabled }
    }

    /// Returns the controller to rest without releasing it. Used when a session
    /// ends, the app is backgrounded, or feedback is switched off.
    public func stopAll() {
        let controllerBox: SendableGameController? = lock.withLock {
            lastRumble = .silent
            installedLightBar = nil
            return controller.map(SendableGameController.init(value:))
        }
        queue.async { [self] in
            if let controllerBox {
                quiesce(controllerBox.value)
            }
            teardownActuators()
        }
    }

    // MARK: - Delivery

    public func apply(_ event: ControllerFeedbackEvent) {
        let shouldApply: Bool = lock.withLock { isEnabled && controller != nil }
        guard shouldApply else { return }
        queue.async { [self] in
            applyOnQueue(event)
        }
    }

    private func applyOnQueue(_ event: ControllerFeedbackEvent) {
        let (controller, enabled, rumbleScale, triggerScale) = lock.withLock {
            (self.controller, isEnabled, self.rumbleScale, self.triggerScale)
        }
        guard enabled, let controller else { return }

        switch event {
        case let .rumble(rumble):
            let scaled = rumble.scaled(by: rumbleScale)
            lock.withLock { lastRumble = scaled }
            applyRumble(scaled, to: controller)

        case let .lightBar(color):
            lock.withLock { installedLightBar = color }
            controller.light?.color = GCColor(
                red: color.red,
                green: color.green,
                blue: color.blue
            )

        case let .triggerEffects(effects):
            applyTriggerEffects(effects, scale: triggerScale, to: controller)

        case let .rumbleIntensity(intensity):
            let scale = intensity.scale
            let rescaled: ControllerRumble = lock.withLock {
                self.rumbleScale = scale
                return lastRumble
            }
            // The console changed the global scale, not the effect. Re-apply
            // the current rumble so the change is audible immediately.
            applyRumble(rescaled, to: controller)

        case let .triggerIntensity(intensity):
            lock.withLock { self.triggerScale = intensity.scale }

        case let .playerIndex(index):
            if let playerIndex = GCControllerPlayerIndex(rawValue: index) {
                controller.playerIndex = playerIndex
            }
        }
    }

    // MARK: - Rumble

    private func applyRumble(_ rumble: ControllerRumble, to controller: GCController) {
        setLevel(rumble.lowFrequency, handle: .low, controller: controller)
        setLevel(rumble.highFrequency, handle: .high, controller: controller)
    }

    private func setLevel(_ level: Float, handle: Handle, controller: GCController) {
        guard let locality = resolvedLocality(handle, controller: controller) else {
            return
        }

        if level <= 0 {
            stopActuator(at: locality)
            return
        }
        guard var actuator = actuator(at: locality, controller: controller) else {
            return
        }

        if actuator.player == nil {
            actuator.player = makePlayer(engine: actuator.engine, handle: handle)
        }
        guard let player = actuator.player else {
            actuators[locality] = actuator
            return
        }

        if !actuator.isPlaying {
            do {
                try player.start(atTime: CHHapticTimeImmediate)
                actuator.isPlaying = true
            } catch {
                // A refused start leaves the actuator idle; the next rumble
                // event retries. Nothing else is affected.
                actuator.isPlaying = false
            }
        }
        actuators[locality] = actuator
        guard actuator.isPlaying else { return }

        let parameter = CHHapticDynamicParameter(
            parameterID: .hapticIntensityControl,
            value: level,
            relativeTime: 0
        )
        try? player.sendParameters([parameter], atTime: CHHapticTimeImmediate)
    }

    /// Prefers per-handle localities so the two actuators stay independent, and
    /// falls back to whatever the controller does support.
    private func resolvedLocality(
        _ handle: Handle,
        controller: GCController
    ) -> GCHapticsLocality? {
        guard let haptics = controller.haptics else { return nil }
        let supported = haptics.supportedLocalities
        if supported.contains(handle.locality) {
            return handle.locality
        }
        // Without independent handles a single engine has to carry both
        // actuators, so only the heavier one drives it and the light one is
        // dropped rather than fighting it for the same engine.
        guard handle == .low else { return nil }
        if supported.contains(.default) {
            return .default
        }
        return supported.first
    }

    private func actuator(
        at locality: GCHapticsLocality,
        controller: GCController
    ) -> Actuator? {
        if let existing = actuators[locality] {
            return existing
        }
        guard let haptics = controller.haptics,
              let engine = haptics.createEngine(withLocality: locality) else {
            return nil
        }

        // An infinite pattern must outlive idle periods, and a reset has to
        // rebuild the player rather than leave a dead one installed.
        engine.isAutoShutdownEnabled = false
        engine.resetHandler = { [weak self] in
            self?.handleEngineReset(at: locality)
        }
        engine.stoppedHandler = { [weak self] _ in
            self?.handleEngineStopped(at: locality)
        }
        guard (try? engine.start()) != nil else { return nil }

        let actuator = Actuator(engine: engine)
        actuators[locality] = actuator
        return actuator
    }

    private func makePlayer(
        engine: CHHapticEngine,
        handle: Handle
    ) -> (any CHHapticAdvancedPatternPlayer)? {
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(
                    parameterID: .hapticSharpness,
                    value: handle.sharpness
                ),
            ],
            relativeTime: 0,
            duration: TimeInterval(GCHapticDurationInfinite)
        )
        guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
              let player = try? engine.makeAdvancedPlayer(with: pattern) else {
            return nil
        }
        return player
    }

    private func stopActuator(at locality: GCHapticsLocality) {
        guard var actuator = actuators[locality], actuator.isPlaying else { return }
        try? actuator.player?.stop(atTime: CHHapticTimeImmediate)
        actuator.isPlaying = false
        actuators[locality] = actuator
    }

    private func handleEngineReset(at locality: GCHapticsLocality) {
        queue.async { [self] in
            guard var actuator = actuators[locality] else { return }
            actuator.player = nil
            actuator.isPlaying = false
            actuators[locality] = actuator
            try? actuator.engine.start()
        }
    }

    private func handleEngineStopped(at locality: GCHapticsLocality) {
        queue.async { [self] in
            guard var actuator = actuators[locality] else { return }
            actuator.player = nil
            actuator.isPlaying = false
            actuators[locality] = actuator
        }
    }

    private func teardownActuators() {
        for (_, actuator) in actuators {
            try? actuator.player?.stop(atTime: CHHapticTimeImmediate)
            actuator.engine.stop()
        }
        actuators.removeAll()
    }

    // MARK: - Adaptive triggers

    private func applyTriggerEffects(
        _ effects: ControllerTriggerEffects,
        scale: Float,
        to controller: GCController
    ) {
        guard let dualSense = controller.extendedGamepad as? GCDualSenseGamepad else {
            return
        }
        apply(effects.left, scale: scale, to: dualSense.leftTrigger)
        apply(effects.right, scale: scale, to: dualSense.rightTrigger)
    }

    private func apply(
        _ effect: ControllerTriggerEffect,
        scale: Float,
        to trigger: GCDualSenseAdaptiveTrigger
    ) {
        // A zero global scale means the console asked for no trigger force at
        // all, so every effect collapses to off.
        guard scale > 0 else {
            trigger.setModeOff()
            return
        }

        switch effect {
        case .off:
            trigger.setModeOff()

        // The single-position setters carry no `NS_SWIFT_NAME`, so they import
        // under their full Objective-C spelling; the positional ones are
        // renamed. Both spellings below are what GameController actually
        // exposes to Swift.
        case let .feedback(startPosition, resistiveStrength):
            trigger.setModeFeedbackWithStartPosition(
                startPosition,
                resistiveStrength: resistiveStrength * scale
            )

        case let .positionalFeedback(resistiveStrengths):
            var strengths = GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths()
            withUnsafeMutableBytes(of: &strengths.values) { buffer in
                let values = buffer.bindMemory(to: Float.self)
                for index in values.indices where index < resistiveStrengths.count {
                    values[index] = resistiveStrengths[index] * scale
                }
            }
            trigger.setModeFeedback(resistiveStrengths: strengths)

        case let .weapon(startPosition, endPosition, resistiveStrength):
            trigger.setModeWeaponWithStartPosition(
                startPosition,
                endPosition: endPosition,
                resistiveStrength: resistiveStrength * scale
            )

        case let .vibration(startPosition, amplitude, frequency):
            trigger.setModeVibrationWithStartPosition(
                startPosition,
                amplitude: amplitude * scale,
                frequency: frequency
            )

        case let .positionalVibration(amplitudes, frequency):
            var positional = GCDualSenseAdaptiveTrigger.PositionalAmplitudes()
            withUnsafeMutableBytes(of: &positional.values) { buffer in
                let values = buffer.bindMemory(to: Float.self)
                for index in values.indices where index < amplitudes.count {
                    values[index] = amplitudes[index] * scale
                }
            }
            trigger.setModeVibration(amplitudes: positional, frequency: frequency)
        }
    }

    // MARK: - Rest

    /// Returns a controller to a neutral state: no rumble, no trigger force,
    /// and the light bar released back to the system.
    private func quiesce(_ controller: GCController) {
        for (_, actuator) in actuators where actuator.isPlaying {
            try? actuator.player?.stop(atTime: CHHapticTimeImmediate)
        }
        if let dualSense = controller.extendedGamepad as? GCDualSenseGamepad {
            dualSense.leftTrigger.setModeOff()
            dualSense.rightTrigger.setModeOff()
        }
    }
}
