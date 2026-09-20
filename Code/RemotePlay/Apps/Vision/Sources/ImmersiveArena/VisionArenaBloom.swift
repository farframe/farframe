#if os(visionOS)
import RealityKit

/// Keep the authored feathered glow without optional native bloom. A headset
/// display-service crash reached BloomTileDownsampleNode during Arena entry.
/// This workaround needs sustained device proof before bloom can return.
@MainActor
enum VisionArenaBloom {
    static func update(in glowRoot: Entity, level _: VisionArenaGlow, isActive _: Bool) {
        guard let halo = glowRoot.findEntity(named: "ArenaTightHalo") else { return }
        #if compiler(>=6.4)
        if #available(visionOS 27.0, *) {
            halo.components.remove(BloomComponent.self)
            halo.components.remove(BloomOptionsComponent.self)
        }
        #endif
    }
}
#endif
