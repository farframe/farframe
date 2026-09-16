import Foundation

@main enum VisionArenaWrapChecks {
    static func main() {
        typealias P = VisionArenaWrapPolicy
        let split = VisionArenaLiveColorPolicy.EdgeColors(left: [1, 0, 0], right: [0, 0, 1],
                                                         top: [0, 1, 0], bottom: .zero)
        for surface in P.Surface.allCases {
            for zone in P.Zone.allCases {
                precondition(P.radiance(.black, zone: zone, surface: surface, intensity: 1) == .zero)
                precondition(P.radiance(split, zone: zone, surface: surface, intensity: 0) == .zero)
                precondition(P.radiance(split, zone: zone, surface: surface, intensity: .nan) == .zero)
                let radiance = P.radiance(split, zone: zone, surface: surface, intensity: 10)
                precondition(radiance.x >= 0 && radiance.y >= 0 && radiance.z >= 0)
                precondition(max(radiance.x, max(radiance.y, radiance.z)) <= 0.32)
            }
            precondition(P.radiance(split, zone: .left, surface: surface, intensity: 1).z == 0)
            precondition(P.radiance(split, zone: .right, surface: surface, intensity: 1).x == 0)
            precondition(P.radiance(split, zone: .bottom, surface: surface, intensity: 1) == .zero)
        }
        let invalid = split.map { _ in SIMD3<Float>(.nan, .infinity, -1) }
        precondition(P.radiance(invalid, zone: .left, surface: .strip, intensity: 1) == .zero)
        let dark = split.map { _ in SIMD3<Float>(repeating: 0.001) }
        precondition(P.radiance(dark, zone: .top, surface: .frame, intensity: 1) == .zero)
        let frame = P.radiance(split, zone: .left, surface: .frame, intensity: 0.8).x
        let strip = P.radiance(split, zone: .left, surface: .strip, intensity: 0.8).x
        precondition(frame < strip / 4, "Broad metal must not rival strip/screen brightness")
        var prior: Float = 1
        for step in 0...100 {
            let value = P.washFalloff(Float(step)/100)
            precondition(value <= prior && value >= 0)
            prior = value
        }
        precondition(P.washFalloff(1) == 0 && P.washFalloff(2) == 0 && P.washFalloff(.nan) == 0)
        let white = split.map { _ in SIMD3<Float>(repeating: 1) }
        precondition(P.radiance(white, zone: .left, surface: .wash, intensity: 1).x <= 0.14)
        var count = 0
        for coverage in VisionArenaLightCoverage.allCases {
            for scale: Float in [0.1, 0.35, 1, 1.4, 2.25, .nan] {
                for yawDegrees in stride(from: -180, through: 180, by: 5) {
                    for center: SIMD3<Float> in [[-4, 1, -12], [0, 1, -5], [4, 4, -0.3]] {
                        let f = P.floor(center: center, screenScale: scale,
                                        yaw: Float(yawDegrees) * .pi / 180, coverage: coverage)
                        precondition(f.center.x - f.halfX >= -5.701 && f.center.x + f.halfX <= 5.701)
                        precondition(f.center.z - f.halfZ >= -11.701 && f.center.z + f.halfZ <= 3.701)
                        precondition(f.center.y == 0.015 && f.scale.x.isFinite && f.scale.z.isFinite)
                        count += 1
                    }
                }
            }
        }
        let original = P.floor(center: [0, 1.9, -5], screenScale: 1, yaw: 0, coverage: .screen)
        precondition(abs(original.center.z + 3.6) < 0.0001 && original.scale == [1, 1, 1])
        let wrap = P.floor(center: [0, 1.9, -5], screenScale: 1, yaw: 0, coverage: .architecturalWrap)
        precondition(wrap.center.z + wrap.halfZ < 0 && wrap.scale.x > original.scale.x)
        print("Wrap PASS: dark/invalid/HDR bounds, edge mapping, material hierarchy, \(count) floor placements")
    }
}
