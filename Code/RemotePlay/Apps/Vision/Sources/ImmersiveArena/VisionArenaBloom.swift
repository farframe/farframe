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
        #if compiler(>=6.4)
        if #available(visionOS 27.0, *) {
            // Limit the search footprint to the halo. The screen, HUD, floor
            // and side washes are not bloom descendants.
            guard let halo = glowRoot.findEntity(named: "ArenaTightHalo") else { return }
            let thermal = ProcessInfo.processInfo.thermalState
            guard supportsBloom, isActive, level != .off,
                  thermal != .serious, thermal != .critical else {
                halo.components.remove(BloomComponent.self)
                halo.components.remove(BloomOptionsComponent.self)
                return
            }
            var options = BloomOptionsComponent()
            options.strength = level == .low ? 0.12 : 0.2
            options.threshold = 0.15
            options.blurRadius = 3
            halo.components.set(BloomComponent(scope: .hierarchical))
            halo.components.set(options)
        }
        #endif
    }
}
#endif
