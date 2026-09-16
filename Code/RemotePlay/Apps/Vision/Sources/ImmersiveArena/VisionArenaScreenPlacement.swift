import Foundation

/// Preset geometry in meters. Direct manipulation uses the same size limits.
struct VisionArenaScreenPlacement: Equatable {
    static let backClearance: Float = 11.5
    // Cinema distances match the radial Distance control, rather than Z depth.
    static let cinemaDistance: Float = 11.0
    static let scaleRange: ClosedRange<Float> = 0.35...2.25
    var height: Float = 1.15
    var distance: Float = 4.5
    var horizontal: Float = 0
    var scale: Float = 0.75
    var yaw: Float = 0
    var tilt: Float = 0

    enum Preset: String, CaseIterable, Identifiable {
        case cinema = "Cinema 1", cinema2 = "Cinema 2"
        case seated = "Seated", reclined = "Reclined", ceiling = "Ceiling"
        var id: String { rawValue }
        var viewingDistance: Float? {
            switch self {
            case .cinema: VisionArenaScreenPlacement.cinemaDistance
            case .cinema2: 9.1
            default: nil
            }
        }

        private func cinemaPlacement(scale: Float, distance: Float, tilt: Float = 8) -> VisionArenaScreenPlacement {
            var p = VisionArenaScreenPlacement(height: 2.3, scale: scale, tilt: tilt).bounded
            let rise = p.height - 1.15
            p.distance = sqrt(max(0.09, distance * distance - rise * rise))
            return p.bounded
        }
        var placement: VisionArenaScreenPlacement {
            switch self {
            case .seated: .init()
            case .cinema: cinemaPlacement(scale: 2.04, distance: VisionArenaScreenPlacement.cinemaDistance, tilt: 9)
            case .cinema2: cinemaPlacement(scale: 2.25, distance: 9.1)
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
        let extent = (1.2 * abs(cos(value.tilt * .pi / 180)) + 0.08 * abs(sin(value.tilt * .pi / 180))) * value.scale
        value.height = max(value.height, extent + 0.1)
        let yaw = value.yaw * .pi / 180, tilt = value.tilt * .pi / 180
        let depth = value.scale * (2.1 * abs(sin(yaw))
            + 1.2 * abs(cos(yaw) * sin(tilt)) + 0.08 * abs(cos(yaw) * cos(tilt)))
        value.distance = min(value.distance, Self.backClearance - depth)
        return value
    }
}
