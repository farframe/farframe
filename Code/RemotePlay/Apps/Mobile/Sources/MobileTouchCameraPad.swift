import CoreGraphics
import Foundation

/// How the camera is aimed with touch.
enum MobileTouchCameraControl: String, CaseIterable, Identifiable {
    case stick
    case swipe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stick: "Right stick"
        case .swipe: "Swipe anywhere"
        }
    }

    var detail: String {
        switch self {
        case .stick:
            "Aim with the drawn right stick only."
        case .swipe:
            "Also aim by swiping the empty right-hand side of the picture, the way a trackpad works. The stick keeps working, and the buttons on top of it still take your taps."
        }
    }
}

/// Turns finger movement into a right-stick deflection.
///
/// Apple's handheld-games guidance is blunt about why this exists: a thumbstick
/// over-rotates and feels sluggish, while a touchpad moves the camera "exactly
/// as far as their finger moves, with no latency or drift". Remote Play can
/// only send stick positions to the console, so a swipe has to be *expressed*
/// as a stick — the deflection is proportional to how fast the finger is
/// currently moving, not to where it started.
///
/// The important consequence, and the one this type exists to get right: a
/// finger resting motionless on the screen must stop the camera. A gesture
/// recogniser stops calling back the moment movement stops, so a naive
/// implementation leaves the last deflection applied and the camera spins
/// forever. `vector(at:)` therefore takes the current instant and reports
/// neutral once the last movement is older than `idleCutoff`, which makes the
/// stopping behaviour a property of the value rather than of a timer.
///
/// Pure geometry and time. No SwiftUI, no gestures, no touchscreen needed to
/// exercise any of it.
struct MobileTouchCameraPad: Equatable {
    /// Finger speed, in points per second, that means full deflection at
    /// sensitivity 1. Chosen so an unhurried swipe across a phone's width is
    /// roughly a half-deflection and a fast flick saturates.
    static let fullDeflectionPointsPerSecond: Double = 900

    /// How long a movement stays meaningful. Two frames at 60 Hz: long enough
    /// that a momentary gap between touch samples does not stutter the camera,
    /// short enough that lifting a thumb or holding still stops it at once.
    static let idleCutoff: Duration = .milliseconds(120)

    private var lastLocation: CGPoint?
    private var lastInstant: ContinuousClock.Instant?
    private var lastMovementInstant: ContinuousClock.Instant?
    /// Points per second, in view coordinates.
    private var velocity: CGSize = .zero

    init() {}

    var isTracking: Bool { lastLocation != nil }

    mutating func begin(at location: CGPoint, instant: ContinuousClock.Instant) {
        lastLocation = location
        lastInstant = instant
        lastMovementInstant = instant
        velocity = .zero
    }

    mutating func move(to location: CGPoint, instant: ContinuousClock.Instant) {
        guard let lastLocation, let lastInstant else {
            begin(at: location, instant: instant)
            return
        }
        let seconds = Self.seconds(lastInstant.duration(to: instant))
        self.lastLocation = location
        self.lastInstant = instant
        // Two samples at the same instant carry no speed. Keeping the previous
        // velocity is better than dividing by zero or reporting a stop.
        guard seconds > 0 else { return }
        velocity = CGSize(
            width: (location.x - lastLocation.x) / seconds,
            height: (location.y - lastLocation.y) / seconds
        )
        lastMovementInstant = instant
    }

    mutating func end() {
        self = MobileTouchCameraPad()
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// The right-stick vector this pad is currently asking for.
    ///
    /// `y` is negated because view coordinates grow downward and a stick's
    /// positive Y is up, which is the same convention the drawn stick uses.
    func vector(
        at instant: ContinuousClock.Instant,
        sensitivity: Double
    ) -> (x: Float, y: Float) {
        guard let lastMovementInstant, lastLocation != nil,
              lastMovementInstant.duration(to: instant) <= Self.idleCutoff else {
            return (0, 0)
        }
        let scale = max(0.4, min(1.2, sensitivity)) / Self.fullDeflectionPointsPerSecond
        var x = velocity.width * scale
        var y = -velocity.height * scale
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude.isFinite, magnitude > 0 else { return (0, 0) }
        if magnitude > 1 {
            x /= magnitude
            y /= magnitude
        }
        return (Float(x), Float(y))
    }
}
