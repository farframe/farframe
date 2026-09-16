import Foundation

enum VisionArenaLightCoverage: String, CaseIterable, Identifiable, Sendable {
    case screen = "Screen"
    case architecturalWrap = "Architectural Wrap"
    var id: Self { self }
}

/// Geometry-free policy, fed only the existing smoothed linear-light palette.
enum VisionArenaWrapPolicy {
    enum Zone: String, CaseIterable, Sendable { case left, right, top, bottom }
    enum Surface: String, CaseIterable, Sendable { case frame, strip, wash }

    static func radiance(_ colors: VisionArenaLiveColorPolicy.EdgeColors,
                         zone: Zone, surface: Surface, intensity: Float) -> SIMD3<Float> {
        guard intensity.isFinite else { return .zero }
        let edge: SIMD3<Float>
        switch zone {
        case .left: edge = colors.left
        case .right: edge = colors.right
        case .top: edge = colors.top
        case .bottom: edge = colors.bottom
        }
        // Broad metal stays much quieter than narrow inlays and the screen.
        // Preserve dark edges; no average-white floor or normalized saturation.
        let gain: Float = surface == .frame ? 0.055 : surface == .wash ? 0.14 : 0.32
        let ceiling: Float = zone == .top ? 0.7 : 1
        return VisionArenaLiveColorPolicy.bound(edge) * gain * ceiling * min(1, max(0, intensity))
    }

    /// Zero value and slope at the far edge: no colored tail behind the viewer.
    static func washFalloff(_ distance: Float) -> Float {
        guard distance.isFinite else { return 0 }
        let t = min(1, max(0, distance))
        return 1 - t * t * (3 - 2 * t)
    }

    struct FloorFootprint {
        var center: SIMD3<Float>
        var scale: SIMD3<Float>
        var halfX: Float
        var halfZ: Float
    }

    static func floor(center: SIMD3<Float>, screenScale: Float, yaw: Float,
                      coverage: VisionArenaLightCoverage) -> FloorFootprint {
        let safeCenter = center.x.isFinite && center.z.isFinite ? center : SIMD3<Float>(0, 0, -5)
        let angle = yaw.isFinite ? yaw : 0
        let spread = min(1.4, max(0.5, screenScale.isFinite ? screenScale : 1))
        let wrap = coverage == .architecturalWrap
        var sx = spread * (wrap ? 1.5 : 1)
        var sz = spread * (wrap ? 1.25 : 1)
        var hx = 3 * abs(cos(angle)) * sx + 2.2 * abs(sin(angle)) * sz
        var hz = 2.2 * abs(cos(angle)) * sz + 3 * abs(sin(angle)) * sx
        let fit = min(1, min(5.7 / hx, 7.7 / hz))
        sx *= fit; sz *= fit; hx *= fit; hz *= fit
        return FloorFootprint(center: [min(5.7-hx, max(-5.7+hx, safeCenter.x)), 0.015,
            min(3.7-hz, max(-11.7+hz, safeCenter.z + (wrap ? 2.0 : 1.4) * spread))],
            scale: [sx, 1, sz], halfX: hx, halfZ: hz)
    }
}
