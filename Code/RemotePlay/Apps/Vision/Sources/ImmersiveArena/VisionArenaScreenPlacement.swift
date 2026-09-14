import Foundation

/// Preset geometry in meters. Direct manipulation uses the same size limits.
struct VisionArenaScreenPlacement: Equatable {
    static let scaleRange: ClosedRange<Float> = 0.35...2.25
    var height: Float = 1.15
    var distance: Float = 4.5
    var horizontal: Float = 0
    var scale: Float = 0.75
    var yaw: Float = 0
    var tilt: Float = 0

    enum Preset: String, CaseIterable, Identifiable {
        case seated = "Seated", cinema = "Cinema", reclined = "Reclined", ceiling = "Ceiling"
        var id: String { rawValue }
        var placement: VisionArenaScreenPlacement {
            switch self {
            case .seated: .init()
            case .cinema: .init(height: 1.15 + 12 * sin(8 * .pi / 180),
                distance: 12 * cos(8 * .pi / 180), scale: 2.1, tilt: 8)
            case .reclined: .init(height: 3.9, distance: 3, scale: 1.1, tilt: 45)
            case .ceiling: .init(height: 4.9, distance: 0.3, scale: 1, tilt: 90)
            }
        }
    }

    var bounded: Self {
        func clamp(_ value: Float, _ range: ClosedRange<Float>, fallback: Float) -> Float {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        var value = self
        value.scale = clamp(scale, Self.scaleRange, fallback: 0.75)
        value.height = clamp(height, 0.6...5.8, fallback: 1.15)
        value.distance = clamp(distance, 0.3...12, fallback: 4.5)
        value.horizontal = clamp(horizontal, -4...4, fallback: 0)
        value.yaw = clamp(yaw, -90...90, fallback: 0)
        value.tilt = clamp(tilt, -45...90, fallback: 0)
        // Tilted screens need less vertical clearance. Never lift an upright
        // seated screen merely to accommodate a hidden oversized housing.
        let extent = (1.2 * abs(cos(value.tilt * .pi / 180)) + 0.08) * value.scale
        value.height = max(value.height, extent + 0.1)
        return value
    }
}
