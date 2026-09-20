import Foundation

/// Bounded photometric output for real surroundings, separate from the screen
/// halo and native bloom. Inputs are the existing smoothed linear edge colors.
enum VisionMixedWallLightPolicy {
    struct Output {
        let tint: SIMD3<Float>
        let lumens: Float
        let radius: Float
        static let off = Output(tint: .zero, lumens: 0, radius: 0)
    }

    static func output(color: SIMD3<Float>, low: Bool, boost: Float,
                       thermalState: ProcessInfo.ThermalState) -> Output {
        guard boost.isFinite, boost > 1.05,
              thermalState != .serious, thermalState != .critical else { return .off }
        let bounded = VisionArenaLiveColorPolicy.bound(color)
        let peak = max(bounded.x, max(bounded.y, bounded.z))
        guard peak > 0 else { return .off }
        let amount = min(1, max(0, boost - 1))
        // Lift dark-but-visible colors into useful room-light levels without
        // inventing a constant white floor. Black/stale frames still turn off.
        let brightness = sqrt(peak)
        let thermalGain: Float = thermalState == .fair ? 0.75 : 1
        let radius = min(thermalState == .fair ? 4 : 5.5, 3.5 + amount * 2)
        return Output(tint: bounded / peak,
                      lumens: (low ? 900 : 1_800) * amount * brightness * thermalGain,
                      radius: radius)
    }
}
