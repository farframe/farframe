import CoreHaptics
import Foundation

enum MobileTouchHapticEvent {
    case button
    case trigger
    case stick
    case tray

    fileprivate var intensity: Float {
        switch self {
        case .button: 0.52
        case .trigger: 0.72
        case .stick: 0.28
        case .tray: 0.4
        }
    }

    fileprivate var sharpness: Float {
        switch self {
        case .button: 0.7
        case .trigger: 0.42
        case .stick: 0.32
        case .tray: 0.58
        }
    }
}

/// Whether this device can produce haptics at all.
///
/// No iPad has ever shipped a Taptic Engine, so on every iPad this is false and
/// the touch-haptics setting is an inert promise. The UI reads the hardware
/// rather than the device family: it stays honest without asking what kind of
/// device it is running on, and a future iPad with haptics would need no change.
///
/// Cached because the answer cannot change while the app runs, and the alternative
/// is querying Core Haptics on every button press of a gameplay surface.
enum MobileTouchHapticsCapability {
    static let deviceSupportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
}

/// Local tactile confirmation for the glass controller. This is intentionally
/// separate from future PS5 rumble/adaptive-trigger output: the current native
/// bridge carries controller input but does not expose console feedback events.
@MainActor
final class MobileTouchHapticEngine {
    private var engine: CHHapticEngine?
    private var supportsHaptics = false
    private var lastInitializationAttempt: ContinuousClock.Instant?

    func prepare() {
        guard engine == nil else { return }
        supportsHaptics = MobileTouchHapticsCapability.deviceSupportsHaptics
        guard supportsHaptics else { return }
        let now = ContinuousClock.now
        if let lastInitializationAttempt,
           lastInitializationAttempt.duration(to: now) < .seconds(2) { return }
        lastInitializationAttempt = now

        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            engine.resetHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    try? self?.engine?.start()
                }
            }
            try engine.start()
            self.engine = engine
        } catch {
            // A transient engine/audio-service failure does not mean the
            // hardware lacks haptics. A later interaction may retry, bounded
            // to one initialization attempt every two seconds.
            engine = nil
        }
    }

    func play(_ event: MobileTouchHapticEvent, enabled: Bool) {
        guard enabled, MobileTouchHapticsCapability.deviceSupportsHaptics else { return }
        if engine == nil { prepare() }
        guard supportsHaptics, let engine else { return }
        let haptic = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(
                    parameterID: .hapticIntensity,
                    value: event.intensity
                ),
                CHHapticEventParameter(
                    parameterID: .hapticSharpness,
                    value: event.sharpness
                ),
            ],
            relativeTime: 0
        )

        do {
            // Auto-shutdown and audio interruptions may stop an otherwise
            // valid engine. Starting an already-running engine is harmless.
            try engine.start()
            let pattern = try CHHapticPattern(events: [haptic], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Haptics are feedback, never a gameplay dependency. The engine's
            // reset handler recovers external interruption when possible.
        }
    }

    func stop() {
        engine?.stop(completionHandler: nil)
        engine = nil
        lastInitializationAttempt = nil
    }
}
