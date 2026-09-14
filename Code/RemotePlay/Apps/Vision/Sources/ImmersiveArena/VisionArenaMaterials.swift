#if os(visionOS)
import Foundation
import RealityKit
import UIKit

/// The optional graph refracts environment radiance using Apple's glass recipe.
/// It does not refract live scene geometry. PBR remains a local loading fallback.
@MainActor
enum VisionArenaMaterials {
    static let opticalResourceName = "FarframeOpticalGlass"

    static func loadOpticalGlass(in bundle: Bundle = .main) async -> ShaderGraphMaterial? {
        // Development A/B capture, never a shipping preference or account path.
        if ProcessInfo.processInfo.arguments.contains("--farframe-arena-basic-glass") { return nil }
        guard let url = bundle.url(forResource: opticalResourceName, withExtension: "usda") else { return nil }
        do {
            var material = try await ShaderGraphMaterial(named: "/Root/FF_OpticalEnvironmentGlass", from: url)
            try Task.checkCancellation()
            try material.setParameter(name: "eta", value: .float(0.67))
            try material.setParameter(name: "roughness", value: .float(0.085))
            try material.setParameter(name: "opacity", value: .float(0.022))
            try material.setParameter(name: "grazingOpacity", value: .float(0.09))
            material.faceCulling = .none
            material.writesDepth = false
            return material
        } catch {
            return nil
        }
    }

    static func apply(to root: Entity, opticalGlass: ShaderGraphMaterial? = nil, surfaceVariation: TextureResource? = nil, includeFloatingTrim: Bool = false) {
        let optical: any Material = opticalGlass.map { $0 as any Material } ?? fallbackOpticalGlass()
        let obsidian = obsidianFloor(variation: surfaceVariation)
        let graphite = graphiteFrame(variation: surfaceVariation)
        var screenSatin = graphiteFrame(variation: surfaceVariation)
        screenSatin.metallic = 0.25
        screenSatin.roughness = .init(floatLiteral: 0.68)
        screenSatin.specular = 0.12
        screenSatin.clearcoat = .init(floatLiteral: 0)
        var replacements = [0, 0, 0]

        func visit(_ entity: Entity) {
            if var model = entity.components[ModelComponent.self] {
                // The source manifest identifies this batch as two free-floating
                // perimeter rails and four ring suspension stubs. Keep the main
                // ribs, ring, floor and cyan inlays; remove only those stray bars.
                if !includeFloatingTrim, !model.materials.isEmpty,
                   model.materials.allSatisfy({ ($0.name ?? "").hasPrefix("FF_Satin") }) {
                    entity.isEnabled = false
                    return
                }
                model.materials = model.materials.map { material -> any Material in
                    let name = material.name ?? ""
                    if name.hasPrefix("FF_Optical") { replacements[0] += 1; return optical }
                    if name.hasPrefix("FF_Obsidian") { replacements[1] += 1; return obsidian }
                    if name.hasPrefix("FF_Graphite") {
                        replacements[2] += 1
                        return entity.name.hasPrefix("Arena_ScreenAssembly_") ? screenSatin : graphite
                    }
                    if name.hasPrefix("FF_Architectural") { return accent(UIColor(red: 0.18, green: 0.37, blue: 0.46, alpha: 1)) }
                    if name.hasPrefix("FF_Ring") { return accent(UIColor(red: 0.30, green: 0.37, blue: 0.40, alpha: 1)) }
                    if name.hasPrefix("FF_Exit") { return accent(UIColor(red: 0.42, green: 0.29, blue: 0.16, alpha: 1)) }
                    return material
                }
                entity.components.set(model)
            }
            for child in entity.children { visit(child) }
        }
        visit(root)
        if ProcessInfo.processInfo.arguments.contains("--farframe-arena-preview") {
            print("FarframeArena material remap optical=\(replacements[0]) floor=\(replacements[1]) frame=\(replacements[2]) graph=\(opticalGlass != nil)")
        }
    }

    /// One small deterministic roughness map per room load, never per frame.
    /// Optional: failure retains the same material with constant roughness.
    static func loadSurfaceVariation() async -> TextureResource? {
        let worker = Task.detached(priority: .utility) { () throws -> CGImage in
            let width = 256, height = 256
            var pixels = [UInt8](repeating: 240, count: width * height)
            for y in 0..<height {
                try Task.checkCancellation()
                for x in 0..<width {
                    let grain = (x * 37 + y * 11 + (x * y) % 17) % 13
                    let brushed = (y * 23) % 11
                    pixels[y * width + x] = UInt8(229 + grain + brushed)
                }
            }
            guard let data = CGDataProvider(data: Data(pixels) as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                    bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGBitmapInfo(rawValue: 0), provider: data, decode: nil,
                    shouldInterpolate: true, intent: .defaultIntent) else { throw CocoaError(.fileReadCorruptFile) }
            return image
        }
        do {
            let image = try await withTaskCancellationHandler { try await worker.value }
                onCancel: { worker.cancel() }
            try Task.checkCancellation()
            return try await TextureResource(image: image, options: .init(semantic: .scalar))
        } catch { return nil }
    }

    private static func accent(_ color: UIColor) -> UnlitMaterial {
        // Readable architectural seams, deliberately below the video halo.
        UnlitMaterial(color: color)
    }

    private static func fallbackOpticalGlass() -> UnlitMaterial {
        // Clear glazing must show the actual exterior. Sampling the baked room
        // probe through a refractive normal projects unrelated dark silhouettes
        // and strips onto distant scenery. Keep that graph in the lab only.
        var material = UnlitMaterial(color: UIColor(red: 0.3, green: 0.5, blue: 0.57, alpha: 1))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.008))
        material.faceCulling = .none
        material.writesDepth = false
        return material
    }

    private static func obsidianFloor(variation: TextureResource?) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        // UIColor is specified in sRGB; do not copy Blender linear numbers here.
        // A darker neutral deck lets the colored spill dominate broad highlights.
        material.baseColor = .init(tint: UIColor(red: 0.065, green: 0.075, blue: 0.085, alpha: 1))
        material.metallic = 0.12
        material.roughness = .init(scale: 0.72, texture: variation.map { .init($0) })
        material.specular = 0.12
        material.clearcoat = 0.0
        material.clearcoatRoughness = 0.8
        // Keep a grounded opaque floor. The probe supplies broad static room
        // highlights; the screen rig supplies the separate low-detail color wash.
        material.blending = .opaque
        return material
    }

    private static func graphiteFrame(variation: TextureResource?) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        // Authored linear RGB (0.045, 0.065, 0.082), converted to sRGB.
        material.baseColor = .init(tint: UIColor(red: 0.235, green: 0.283, blue: 0.317, alpha: 1))
        material.metallic = 0.66
        material.anisotropyLevel = .init(floatLiteral: 0.28)
        material.roughness = .init(scale: 0.4, texture: variation.map { .init($0) })
        return material
    }
}
#endif
