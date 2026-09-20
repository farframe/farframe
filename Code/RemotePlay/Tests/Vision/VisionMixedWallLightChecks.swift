import Foundation

@main enum VisionMixedWallLightChecks {
    static func main() {
        func output(_ color: SIMD3<Float>, boost: Float = 2, low: Bool = false,
                    thermal: ProcessInfo.ThermalState = .nominal) -> VisionMixedWallLightPolicy.Output {
            VisionMixedWallLightPolicy.output(color: color, low: low, boost: boost, thermalState: thermal)
        }
        precondition(output(.zero).lumens == 0, "Black must not become a fabricated white wall wash")
        precondition(output(.init(repeating: 0.0001)).lumens == 0, "Near-black noise stays dark")
        for invalid: SIMD3<Float> in [[.nan, 1, 1], [1, .infinity, 1], [-1, -1, -1]] {
            precondition(output(invalid).lumens == 0, "Invalid colors cannot illuminate surroundings")
        }
        for boost: Float in [.nan, .infinity, -1, 1] {
            precondition(output(.one, boost: boost).lumens == 0, "Off/invalid boost stays off")
        }
        let darkScene = output(.init(repeating: 0.04))
        precondition((250...500).contains(darkScene.lumens), "Dark visible content should produce useful room-light output")
        let colored = output([0.4, 0.2, 0.1])
        precondition(colored.tint == [1, 0.5, 0.25], "Brightness lift preserves the sampled hue")
        precondition(output(.one, low: true).lumens < output(.one).lumens, "Low remains gentler than Medium")
        precondition(output(.one, boost: 1.5).lumens < output(.one).lumens, "Boost remains effective")
        let fair = output(.one, thermal: .fair)
        precondition(fair.lumens < output(.one).lumens && fair.radius < output(.one).radius,
                     "Fair thermal state reduces intensity and footprint")
        for thermal in [ProcessInfo.ThermalState.serious, .critical] {
            precondition(output(.one, thermal: thermal).lumens == 0, "High heat stops optional wall lighting")
        }
        // Sweep valid, out-of-range and HDR input; neither intensity nor GPU
        // footprint can exceed the four-light budget's per-emitter limits.
        for peak in stride(from: Float(0), through: 8, by: 0.05) {
            for boost in stride(from: Float(0), through: 3, by: 0.05) {
                let value = output(.init(repeating: peak), boost: boost)
                precondition(value.lumens.isFinite && (0...1_800).contains(value.lumens))
                precondition(value.radius.isFinite && (0...5.5).contains(value.radius))
            }
        }
        print("PASS: wall-light black/noise, invalid inputs, dark-scene output, hue, controls, thermal and bounded HDR/boost sweep")
    }
}
