#if os(visionOS)
import Foundation
import RealityKit
#if compiler(>=6.4)
import Metal
#endif

/// Optional enhancement for the paired Xcode27/visionOS27 preview toolchain.
/// Stable26.6 compiles the same file with this enhancement absent.
@MainActor
enum VisionArenaBloom {
    #if compiler(>=6.4)
    private static let supportsBloom = MTLCreateSystemDefaultDevice()?.supportsFamily(.apple7) == true
    #endif

    static func update(in glowRoot: Entity, level: VisionArenaGlow, isActive: Bool) {
        guard let halo = glowRoot.findEntity(named: "ArenaTightHalo") else { return }
        apply(on: halo, level: level, isActive: isActive, intensity: 1, blurRadius: 3)
    }

    static func apply(
        on halo: Entity,
        level: VisionArenaGlow,
        isActive: Bool,
        intensity: Float = 1,
        blurRadius: Float = 3
    ) {
        #if compiler(>=6.4)
        if #available(visionOS 27.0, *) {
            let thermal = ProcessInfo.processInfo.thermalState
            guard supportsBloom, isActive, level != .off,
                  thermal != .serious, thermal != .critical else {
                halo.components.remove(BloomComponent.self)
                halo.components.remove(BloomOptionsComponent.self)
                return
            }
            var options = BloomOptionsComponent()
            let gain = min(2.5, max(0.4, intensity))
            options.strength = (level == .low ? 0.14 : 0.26) * gain
            options.threshold = 0.12
            options.blurRadius = min(12, max(1, blurRadius))
            halo.components.set(BloomComponent(scope: .hierarchical))
            halo.components.set(options)
        }
        #endif
    }
}
#endif
