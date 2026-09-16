#if os(visionOS)
import RealityKit
import UIKit

/// Optional reactive pillar partitions, separate from the exact authored
/// architecture. Screen-following bloom supplies the between-pillar glow.
/// The authored originals remain resident as an immediate, exact fallback.
@MainActor
final class VisionArenaWrapRig {
    private struct Part {
        let entity: Entity
        let surface: VisionArenaWrapPolicy.Surface
        let zone: VisionArenaWrapPolicy.Zone
        let baseline: PhysicallyBasedMaterial
    }
    let root: Entity
    private let originals: [(Entity, Bool)]
    private let parts: [Part]
    private var active = false
    private var previousColors: VisionArenaLiveColorPolicy.EdgeColors?
    private var previousIntensity: Float?
    private var previousPillarGlow: Bool?

    init?(asset: Entity, room: Entity) {
        var batches: [Entity] = []
        func findBatches(_ entity: Entity) {
            if entity.name.hasPrefix("Arena_Graphite_") || entity.name.hasPrefix("Arena_Architectural_") {
                batches.append(entity)
            } else { entity.children.forEach(findBatches) }
        }
        findBatches(room)
        guard batches.count == 2 else { return nil }
        func frameMaterial(_ entity: Entity) -> PhysicallyBasedMaterial? {
            if let material = entity.components[ModelComponent.self]?.materials.first as? PhysicallyBasedMaterial {
                return material
            }
            return entity.children.compactMap(frameMaterial).first
        }
        guard let frame = batches.compactMap(frameMaterial).first else { return nil }
        var found: [Part] = []
        func collect(_ entity: Entity, inheritedName: String = "") {
            let name = entity.name.hasPrefix("Wrap_") ? entity.name : inheritedName
            // Older derived assets contain room-sized wash meshes. Never mount
            // them: their fixed edges remain visible when the screen moves.
            if name.hasPrefix("Wrap_wash_") {
                entity.removeFromParent()
                return
            }
            if var model = entity.components[ModelComponent.self] {
                let fields = name.split(separator: "_").map(String.init)
                guard fields.count == 3,
                      let surface = VisionArenaWrapPolicy.Surface(rawValue: fields[1]),
                      let zone = VisionArenaWrapPolicy.Zone(rawValue: fields[2]) else { return }
                var material = frame
                if surface == .strip {
                    material = PhysicallyBasedMaterial()
                    material.baseColor = .init(tint: UIColor(white: 0.025, alpha: 1))
                    material.roughness = 0.65
                    material.metallic = 0.0
                }
                material.emissiveIntensity = 1
                material.emissiveColor = .init(color: .black)
                material.blending = .opaque
                model.materials = [material]
                entity.components.set(model)
                found.append(Part(entity: entity, surface: surface, zone: zone, baseline: material))
            }
            for child in Array(entity.children) { collect(child, inheritedName: name) }
        }
        collect(asset)
        guard found.count == 8,
              Set(found.map { $0.surface.rawValue + $0.zone.rawValue }).count == 8 else { return nil }
        parts = found
        originals = batches.map { ($0, $0.isEnabled) }
        root = asset
        root.name = "ArenaArchitecturalWrap"
        root.isEnabled = false
    }

    func update(colors: VisionArenaLiveColorPolicy.EdgeColors, intensity: Float, enabled: Bool, pillarGlow: Bool = true) {
        if enabled != active {
            root.isEnabled = enabled
            active = enabled
        }
        // Restore the actual authored materials, not black replacement strips.
        for (entity, wasEnabled) in originals { entity.isEnabled = enabled && pillarGlow ? false : wasEnabled }
        for part in parts { part.entity.isEnabled = enabled && pillarGlow }
        guard enabled, colors != previousColors || intensity != previousIntensity || pillarGlow != previousPillarGlow else { return }
        previousColors = colors; previousIntensity = intensity; previousPillarGlow = pillarGlow
        for part in parts {
            let light = VisionArenaWrapPolicy.radiance(colors, zone: part.zone,
                                                      surface: part.surface, intensity: pillarGlow ? intensity : 0)
            var material = part.baseline
            material.emissiveColor = .init(color: Self.color(light))
            guard var model = part.entity.components[ModelComponent.self] else { continue }
            model.materials = [material]
            part.entity.components.set(model)
        }
    }

    private static func color(_ linear: SIMD3<Float>) -> UIColor {
        func srgb(_ value: Float) -> CGFloat {
            CGFloat(value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055)
        }
        return UIColor(red: srgb(linear.x), green: srgb(linear.y), blue: srgb(linear.z), alpha: 1)
    }
}
#endif
