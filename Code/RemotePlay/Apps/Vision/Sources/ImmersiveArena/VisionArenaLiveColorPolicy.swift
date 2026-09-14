import Foundation

/// Small color-only state. No decoded frame or image is retained here.
struct VisionArenaLiveColorPolicy: Sendable {
    struct EdgeColors: Equatable, Sendable {
        var left: SIMD3<Float>
        var right: SIMD3<Float>
        var top: SIMD3<Float>
        var bottom: SIMD3<Float>

        static let black = Self(left: .zero, right: .zero, top: .zero, bottom: .zero)

        func map(_ transform: (SIMD3<Float>) -> SIMD3<Float>) -> Self {
            Self(left: transform(left), right: transform(right), top: transform(top), bottom: transform(bottom))
        }
    }

    enum State: Sendable { case live, fading, black }

    struct Snapshot: Sendable {
        let generation: UUID
        /// Linear sRGB, 0...1, already smoothed and faded. Not encoded sRGB.
        let colors: EdgeColors
        let freshness: Float
        let state: State
    }

    static let sampleInterval: TimeInterval = 0.125
    static let staleAfter: TimeInterval = 0.5
    static let fadeDuration: TimeInterval = 0.6
    private var filtered = EdgeColors.black
    private var lastSampleAt: TimeInterval?

    mutating func consume(_ measurement: EdgeColors?, capturedAt: TimeInterval, now: TimeInterval) {
        guard let measurement, capturedAt.isFinite, now.isFinite,
              capturedAt <= now, now - capturedAt <= Self.staleAfter else {
            filtered = .black
            lastSampleAt = nil
            return
        }
        let bounded = measurement.map(Self.bound)
        let elapsed = lastSampleAt.map { max(0, capturedAt - $0) } ?? Self.sampleInterval
        let alpha = Float(1 - exp(-min(elapsed, 1) / 0.25))
        filtered = EdgeColors(
            left: filtered.left + (bounded.left - filtered.left) * alpha,
            right: filtered.right + (bounded.right - filtered.right) * alpha,
            top: filtered.top + (bounded.top - filtered.top) * alpha,
            bottom: filtered.bottom + (bounded.bottom - filtered.bottom) * alpha
        )
        lastSampleAt = capturedAt
    }

    func snapshot(generation: UUID, now: TimeInterval) -> Snapshot {
        guard let lastSampleAt, now.isFinite, now >= lastSampleAt else {
            return Snapshot(generation: generation, colors: .black, freshness: 0, state: .black)
        }
        let age = now - lastSampleAt
        let freshness = Float(max(0, min(1, 1 - (age - Self.staleAfter) / Self.fadeDuration)))
        return Snapshot(generation: generation, colors: filtered.map { $0 * freshness }, freshness: freshness,
                        state: freshness == 0 ? .black : age > Self.staleAfter ? .fading : .live)
    }

    /// Hue-preserving HDR bounding after linear-light averaging. Dark frames
    /// stay dark; no automatic brightness lift or saturation boost.
    static func bound(_ color: SIMD3<Float>) -> SIMD3<Float> {
        guard color.x.isFinite, color.y.isFinite, color.z.isFinite else { return .zero }
        let positive = SIMD3<Float>(max(0, color.x), max(0, color.y), max(0, color.z))
        let bounded = positive / max(1, max(positive.x, max(positive.y, positive.z)))
        let luminance = bounded.x * 0.2126 + bounded.y * 0.7152 + bounded.z * 0.0722
        return luminance < 0.002 ? .zero : bounded
    }
}

/// The single pending slot is deliberately replaceable, never a FIFO.
struct VisionArenaColorSlot<Frame> {
    struct Pending {
        let frame: Frame
        let generation: UUID
        let capturedAt: TimeInterval
    }
    private(set) var generation: UUID?
    private var pending: Pending?

    mutating func begin(_ generation: UUID) { self.generation = generation; pending = nil }
    mutating func stop(_ generation: UUID) {
        guard self.generation == generation else { return }
        self.generation = nil
        pending = nil
    }
    mutating func submit(_ frame: Frame, generation: UUID, capturedAt: TimeInterval) {
        guard self.generation == generation else { return }
        pending = Pending(frame: frame, generation: generation, capturedAt: capturedAt)
    }
    mutating func take(generation: UUID) -> Pending? {
        guard self.generation == generation else { return nil }
        defer { pending = nil }
        return pending
    }
}

/// Shared policy for scene and future window lighting. No frame work while
/// access, lifecycle, accessibility, preference or thermal conditions deny it.
enum VisionArenaLightingActivity {
    static func allowsReactiveLighting(accessGranted: Bool, active: Bool, reduceMotion: Bool,
                                       glowEnabled: Bool, thermalLimited: Bool) -> Bool {
        accessGranted && active && !reduceMotion && glowEnabled && !thermalLimited
    }
}
