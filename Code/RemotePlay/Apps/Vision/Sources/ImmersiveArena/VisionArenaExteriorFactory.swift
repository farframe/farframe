#if os(visionOS)
    import CoreGraphics
    import Foundation
    import RealityKit
    import UIKit

    /// Fixed geometry, original procedural sky and no scene-update subscription.
    /// Exteriors use no additional lights, shadow maps, video or frame analysis.
    @MainActor
    enum VisionArenaExteriorFactory {
        static func make(_ style: VisionArenaExteriorStyle) async throws -> Entity {
            let worker = Task.detached(priority: .utility) { try skyImage(style) }
            let image = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            let texture = try await TextureResource(image: image, options: .init(semantic: .color))
            let root = Entity()
            root.name = "ArenaExterior"
            var skyMaterial = UnlitMaterial()
            skyMaterial.color = .init(tint: .white, texture: .init(texture))
            skyMaterial.faceCulling = .front
            let sky = ModelEntity(mesh: .generateSphere(radius: 140), materials: [skyMaterial])
            sky.name = "ExteriorSky"
            sky.position = [0, 1.7, -4]
            root.addChild(sky)
            switch style {
            case .quietHorizon: try addHorizon(to: root)
            case .orbitalTerrace: try addTerrace(to: root)
            case .lightSculpture: try addSculpture(to: root)
            }
            try Task.checkCancellation()
            return root
        }

        private static func addHorizon(to root: Entity) throws {
            // Closed silhouettes surround the room; all geometry is distant enough
            // to keep the supported deck and the four-metre screen unchanged.
            for layer in 0..<3 {
                let radius: Float = [95, 66, 43][layer]
                let color: UIColor = [
                    rgb(0.095, 0.125, 0.17), rgb(0.055, 0.080, 0.115), rgb(0.027, 0.042, 0.063),
                ][layer]
                var points = [SIMD3<Float>]()
                var indices = [UInt32]()
                let count = 128
                for i in 0...count {
                    let angle = Float(i) / Float(count) * .pi * 2
                    let height =
                        Float(3 - layer) + 2.7 * sin(angle * 7 + Float(layer))
                        + 1.4 * cos(angle * 13 + Float(layer) * 2) + 0.8 * sin(angle * 23)
                    points.append([radius * cos(angle), -9, -4 + radius * sin(angle)])
                    points.append([radius * cos(angle), height, -4 + radius * sin(angle)])
                    if i < count {
                        let n = UInt32(i * 2)
                        indices += [n, n + 1, n + 2, n + 1, n + 3, n + 2]
                    }
                }
                var material = UnlitMaterial(color: color)
                material.faceCulling = .none
                root.addChild(
                    try model("HorizonLayer\(layer)", points: points, indices: indices, material: material))
            }
        }

        private static func addTerrace(to root: Entity) throws {
            let deck = surface(rgb(0.075, 0.085, 0.10), metallic: 0.4, roughness: 0.56)
            root.addChild(try ring("TerraceDeck", radius: 15, width: 9, y: -0.7, material: deck))
            for (index, radius) in [Float(11), 18, 20].enumerated() {
                root.addChild(
                    try ring(
                        "TerraceRail\(index)", radius: radius, width: 0.13, y: -0.10,
                        material: surface(rgb(0.12, 0.14, 0.17))))
                root.addChild(
                    try ring(
                        "TerraceConcealedLight\(index)", radius: radius - 0.05, width: 0.08, y: -0.07,
                        material: UnlitMaterial(color: rgb(0.54, 0.42, 0.28))))
                root.addChild(
                    try ribbon(
                        "TerraceLightRibbon", radius: radius - 0.075, y: -0.23,
                        height: 0.20, material: UnlitMaterial(color: rgb(0.30, 0.23, 0.15))))
            }
            for index in 0..<12 {
                let angle = Float(index) * .pi / 6
                let position: SIMD3<Float> = [19 * cos(angle), 1.2, -4 + 24.7 * sin(angle)]
                let pier = box("TerracePier", size: [0.55, 3.8, 0.75], color: rgb(0.085, 0.105, 0.135))
                pier.look(at: [0, position.y, -4], from: position, relativeTo: nil)
                root.addChild(pier)
                let inset = ModelEntity(
                    mesh: .generateBox(size: [0.055, 1.8, 0.035]),
                    materials: [UnlitMaterial(color: rgb(0.55, 0.43, 0.28))])
                inset.position = [0, 0, -0.39]
                pier.addChild(inset)
            }
            try addStars(to: root)
        }

        private static func addSculpture(to root: Entity) throws {
            root.addChild(
                try ring(
                    "SculptureGround", radius: 18, width: 17, y: -0.8,
                    material: surface(rgb(0.035, 0.042, 0.055), metallic: 0.15, roughness: 0.7)))
            for index in 0..<14 {
                let angle = Float(index) * .pi * 2 / 14 + 0.12
                let height: Float = 5.5 + Float((index * 7) % 5) * 1.1
                let position: SIMD3<Float> = [17 * cos(angle), height / 2 - 0.7, -4 + 22 * sin(angle)]
                let fin = box("LightSculptureFin", size: [0.65, height, 1.1], color: rgb(0.075, 0.092, 0.12))
                fin.look(at: [0, position.y, -4], from: position, relativeTo: nil)
                let strip = ModelEntity(
                    mesh: .generateBox(size: [0.025, height - 0.4, 0.028]),
                    materials: [
                        UnlitMaterial(color: position.x < 0 ? rgb(0.22, 0.44, 0.60) : rgb(0.60, 0.40, 0.21))
                    ])
                strip.name = "SculptureGrazingEdge"
                strip.position = [-0.31, 0, -0.56]
                fin.addChild(strip)
                root.addChild(fin)
            }
        }

        private static func addStars(to root: Entity) throws {
            var points = [SIMD3<Float>]()
            var indices = [UInt32]()
            for i in 0..<110 {
                let angle = Float(i) * 2.3999632
                let elevation = 0.12 + Float((i * 37) % 101) / 101 * 0.75
                let p: SIMD3<Float> = [
                    110 * cos(angle) * cos(elevation), 110 * sin(elevation),
                    -4 + 110 * sin(angle) * cos(elevation),
                ]
                let side = simd_normalize(simd_cross(p - [0, 1.7, -4], SIMD3<Float>(0, 1, 0))) * 0.024
                let up: SIMD3<Float> = [0, 0.024, 0]
                let n = UInt32(points.count)
                points += [p - side - up, p + side - up, p + side + up, p - side + up]
                indices += [n, n + 1, n + 2, n, n + 2, n + 3]
            }
            var m = UnlitMaterial(color: rgb(0.27, 0.32, 0.39))
            m.faceCulling = .none
            root.addChild(try model("StaticStars", points: points, indices: indices, material: m))
        }

        private static func ribbon(
            _ name: String, radius: Float, y: Float, height: Float, material: any Material
        ) throws -> Entity {
            var points = [SIMD3<Float>]()
            var indices = [UInt32]()
            for i in 0...128 {
                let angle = Float(i) * .pi * 2 / 128
                for offset in [-height / 2, height / 2] {
                    points.append([radius * cos(angle), y + offset, -4 + radius * 1.3 * sin(angle)])
                }
                if i < 128 {
                    let n = UInt32(i * 2)
                    indices += [n, n + 1, n + 2, n + 1, n + 3, n + 2]
                }
            }
            var m = material
            if var unlit = material as? UnlitMaterial {
                unlit.faceCulling = .none
                m = unlit
            }
            return try model(name, points: points, indices: indices, material: m)
        }

        private static func ring(
            _ name: String, radius: Float, width: Float, y: Float, material: any Material
        ) throws -> Entity {
            var points = [SIMD3<Float>]()
            var indices = [UInt32]()
            for i in 0...128 {
                let angle = Float(i) * .pi * 2 / 128
                for offset in [-width / 2, width / 2] {
                    points.append([
                        (radius + offset) * cos(angle), y, -4 + (radius + offset) * 1.3 * sin(angle),
                    ])
                }
                if i < 128 {
                    let n = UInt32(i * 2)
                    indices += [n, n + 2, n + 1, n + 1, n + 2, n + 3]
                }
            }
            return try model(name, points: points, indices: indices, material: material)
        }

        private static func model(
            _ name: String, points: [SIMD3<Float>], indices: [UInt32], material: any Material
        ) throws -> ModelEntity {
            var descriptor = MeshDescriptor(name: name)
            descriptor.positions = MeshBuffers.Positions(points)
            descriptor.primitives = .triangles(indices)
            let entity = ModelEntity(
                mesh: try MeshResource.generate(from: [descriptor]), materials: [material])
            entity.name = name
            return entity
        }

        private static func box(_ name: String, size: SIMD3<Float>, color: UIColor) -> ModelEntity {
            let entity = ModelEntity(
                mesh: .generateBox(size: size, cornerRadius: 0.025), materials: [surface(color)])
            entity.name = name
            return entity
        }

        private static func surface(_ color: UIColor, metallic: Float = 0.6, roughness: Float = 0.38)
            -> PhysicallyBasedMaterial
        {
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: color)
            material.metallic = .init(floatLiteral: metallic)
            material.roughness = .init(floatLiteral: roughness)
            // Minimal self-illumination retains silhouette readability outside the
            // local room probe; these surfaces do not cast virtual light.
            material.emissiveColor = .init(color: color)
            material.emissiveIntensity = 0.16
            material.faceCulling = .none
            return material
        }

        private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
            UIColor(red: r, green: g, blue: b, alpha: 1)
        }

        nonisolated private static func skyImage(_ style: VisionArenaExteriorStyle) throws -> CGImage {
            let width = 512
            let height = 256
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                try Task.checkCancellation()
                // Equirectangular horizon at the equator. No artificial sun behind
                // the user or distant motion competes with the game.
                let t = Float(y) / Float(height - 1)
                let band = exp(-pow((t - 0.50) / 0.085, 2))
                for x in 0..<width {
                    let warmth =
                        style == .quietHorizon ? max(0, cos(Float(x) / Float(width) * Float.pi * 2)) : 0
                    let gain: Float = style == .quietHorizon ? 1 : 0.42
                    let color: SIMD3<Float> = [
                        0.008 + band * (0.055 + warmth * 0.040) * gain,
                        0.014 + band * (0.082 - warmth * 0.012) * gain,
                        0.027 + band * (0.135 - warmth * 0.040) * gain,
                    ]
                    let i = (y * width + x) * 4
                    bytes[i] = UInt8(min(255, color.x * 255))
                    bytes[i + 1] = UInt8(min(255, color.y * 255))
                    bytes[i + 2] = UInt8(min(255, color.z * 255))
                }
            }
            let data = Data(bytes) as CFData
            guard let provider = CGDataProvider(data: data),
                let space = CGColorSpace(name: CGColorSpace.sRGB),
                let image = CGImage(
                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { throw CocoaError(.fileReadCorruptFile) }
            return image
        }
    }
#endif
