#if os(visionOS)
import Foundation
import Metal
import RealityKit
import UIKit

/// Bounded architecture lighting using the screen-off authored room probe.
/// The probe is precalculated environment lighting, not a live screen mirror.
@MainActor
enum VisionArenaLighting {
    private static let rigName = "ArenaArchitecturalLighting"
    private static let supportsLocalLighting = MTLCreateSystemDefaultDevice()?.supportsFamily(.apple6) == true

    static func install(on root: Entity, environment: EnvironmentResource) -> Entity {
        root.findEntity(named: rigName)?.removeFromParent()
        let rig = Entity()
        rig.name = rigName

        let probe = Entity()
        probe.name = "ArenaScreenOffProbe"
        // Blender capture (0, 0, 1.7), converted from Z-up to RealityKit Y-up.
        probe.position = [0, 1.7, 0]
        let source = VirtualEnvironmentProbeComponent.Source.single(
            .init(environment: environment, intensityExponent: -7.0)
        )
        var component = VirtualEnvironmentProbeComponent(source: source)
        #if compiler(>=6.4)
        if #available(visionOS 27.0, *), supportsLocalLighting {
            // Interior bounds in the probe's local coordinate system. The
            // influence extends just beyond the enclosure for a gentle fade.
            component = VirtualEnvironmentProbeComponent(
                source: source,
                influence: .local(
                    parallaxBounds: BoundingBox(min: [-5.8, -1.7, -11.8], max: [5.8, 4.65, 3.8]),
                    influenceBounds: BoundingBox(min: [-6.6, -2.5, -12.6], max: [6.6, 5.45, 4.6]),
                    blendDistance: 0.75
                )
            )
            if let room = root.findEntity(named: "FarframeAuthoredArena") {
                assignStructuralLayer(to: room)
            }
        }
        #endif
        if !ProcessInfo.processInfo.arguments.contains("--farframe-arena-no-probe") {
            probe.components.set(component)
        }
        rig.addChild(probe)

        root.addChild(rig)
        return rig
    }

    /// The room is lit by a dim static probe; no per-frame lights or shadow maps.
    static func update(in root: Entity, isActive: Bool) {
        root.findEntity(named: rigName)?.isEnabled = isActive
    }

    #if compiler(>=6.4)
    @available(visionOS 27.0, *)
    private static func assignStructuralLayer(to entity: Entity, isGlassAncestor: Bool = false) {
        let isGlass = isGlassAncestor || entity.name.contains("Optical")
        if entity.components[ModelComponent.self] != nil {
            // Structural fixtures must not turn nearly invisible glass facets
            // into bright white reflector panels. The probe supplies their
            // environment response independently of this direct-light layer.
            let layer: StaticString = isGlass ? "arena.glass" : "arena.structure"
            entity.components.set(RenderLayerComponent(layer: RenderLayer(layer)))
        }
        for child in entity.children { assignStructuralLayer(to: child, isGlassAncestor: isGlass) }
    }
    #endif
}
#endif
