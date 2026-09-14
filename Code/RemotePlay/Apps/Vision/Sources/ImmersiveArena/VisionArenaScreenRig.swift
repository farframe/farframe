#if os(visionOS)
import CoreGraphics
import AVFoundation
import Foundation
import ImageIO
import RealityKit
import UIKit

/// Fixed meter-space composition; no window padding, frame observation, or timers.
@MainActor
enum VisionArenaScreenRig {
    static let screenWidth: Float = 4
    static let screenHeight: Float = 2.25
    static let screenPosition: SIMD3<Float> = [0, 1.9, -5]

    struct Result {
        let root: Entity
        let glow: Entity
    }

    static func make() -> Result {
        let root = Entity()
        root.name = "ArenaScreenRig"
        let glow = Entity()
        glow.name = "ArenaScreenGlow"
        root.addChild(glow)

        let screen = ModelEntity(
            mesh: .generatePlane(width: screenWidth, height: screenHeight, cornerRadius: 0.045),
            materials: [UnlitMaterial(color: UIColor(white: 0.025, alpha: 1))]
        )
        screen.name = "ArenaStaticScreen"
        screen.position = screenPosition
        root.addChild(screen)
        return Result(root: root, glow: glow)
    }

    static func installVideo(_ renderer: AVSampleBufferVideoRenderer?, in root: Entity) {
        guard let screen = root.findEntity(named: "ArenaStaticScreen") as? ModelEntity else { return }
        // Remove RealityKit's video consumer in background, not just enqueues.
        // Restore the same renderer; never allocate a second session or decoder.
        if let renderer {
            screen.model?.materials = [VideoMaterial(videoRenderer: renderer)]
        } else {
            screen.model?.materials = [UnlitMaterial(color: .black)]
        }
    }

    static func applyPlacement(_ requested: VisionArenaScreenPlacement, in root: Entity) {
        let placement = requested.bounded
        let rotation = simd_quatf(angle: placement.yaw * .pi / 180, axis: [0, 1, 0])
            * simd_quatf(angle: placement.tilt * .pi / 180, axis: [1, 0, 0])
        let center = SIMD3<Float>(placement.horizontal, placement.height, -placement.distance)
        applyDisplayTransform(Transform(scale: .init(repeating: placement.scale), rotation: rotation,
            translation: center), in: root)
    }

    /// System manipulation only owns the screen. Companion meshes follow it;
    /// they never add another video surface or transform the architectural room.
    static func applyDisplayTransform(_ transform: Transform, in root: Entity) {
        let rotation = transform.rotation
        let center = transform.translation
        let scale = transform.scale.x
        // All authored positions are relative to the original display center.
        // The architectural room remains stationary. Surface washes project
        // from the current screen onto the floor and the two side walls.
        let names = ["ArenaStaticScreen", "ArenaTightHalo", "ArenaDisplayHousing"]
        for name in names {
            guard let entity = root.findEntity(named: name) else { continue }
            let offset: SIMD3<Float> = name == "ArenaStaticScreen" ? .zero : -screenPosition
            entity.transform = Transform(scale: .init(repeating: scale), rotation: rotation,
                translation: center + rotation.act(offset * scale))
        }
        applySurfaceGlow(transform, in: root)
    }

    private static func applySurfaceGlow(_ screen: Transform, in root: Entity) {
        let center = screen.translation
        let scale = screen.scale.x
        let forward = screen.rotation.act(SIMD3<Float>(0, 0, 1))
        let yaw = atan2(forward.x, forward.z)
        // Keep the feathered footprint inside the existing room (z -11.8...3.8).
        // At ceiling/reclined angles it stays on the floor; the halo rotates.
        let spread = min(1.4, max(0.5, scale))
        let halfX = (3 * abs(cos(yaw)) + 2.2 * abs(sin(yaw))) * spread
        let halfZ = (2.2 * abs(cos(yaw)) + 3 * abs(sin(yaw))) * spread
        let floorCenter = SIMD3<Float>(
            min(5.7 - halfX, max(-5.7 + halfX, center.x)), 0.015,
            min(3.7 - halfZ, max(-11.7 + halfZ, center.z + 1.4 * spread)))
        for name in ["ArenaFloorSpill", "ArenaLiveFloor0", "ArenaLiveFloor1"] {
            guard let entity = root.findEntity(named: name) else { continue }
            entity.transform = Transform(scale: [spread, 1, spread],
                rotation: simd_quatf(angle: yaw, axis: [0, 1, 0]), translation: floorCenter)
            if name == "ArenaLiveFloor1" { entity.position.y += 0.0005 }
        }
        for (index, names) in [["ArenaLeftWallWash", "ArenaLiveWall0"],
                              ["ArenaRightWallWash", "ArenaLiveWall1"]].enumerated() {
            for name in names {
                guard let entity = root.findEntity(named: name) else { continue }
                entity.transform = Transform(scale: [spread, spread, 1],
                    rotation: simd_quatf(angle: index == 0 ? .pi / 2 : -.pi / 2, axis: [0, 1, 0]),
                    translation: [index == 0 ? -5.75 : 5.75,
                        min(5.9 - 1.1 * spread, max(1.1 * spread, center.y)),
                        min(3.7 - 1.8 * spread, max(-11.7 + 1.8 * spread, center.z))])
            }
        }
    }

    /// The exporter keeps only the housing and two seams outside the room batches.
    static func mountHousing(from room: Entity, on root: Entity) {
        let housing = Entity()
        housing.name = "ArenaDisplayHousing"
        root.addChild(housing)
        func collect(_ parent: Entity) -> [Entity] {
            parent.children.flatMap { child -> [Entity] in
                child.name.hasPrefix("Arena_ScreenAssembly_") ? [child] : collect(child)
            }
        }
        for entity in collect(room) {
            if entity.name.contains("TV_side_seam") {
                // Fixed cyan/amber bars are not derived from the current video.
                entity.removeFromParent()
            } else {
                entity.setParent(housing, preservingWorldTransform: true)
            }
        }
    }

    static func setMovable(_ movable: Bool, in root: Entity) {
        guard let screen = root.findEntity(named: "ArenaStaticScreen") else { return }
        if movable {
            guard screen.components[ManipulationComponent.self] == nil else { return }
            ManipulationComponent.configureEntity(screen, collisionShapes: [
                .generateBox(size: [screenWidth, screenHeight, 0.06])
            ])
            var manipulation = ManipulationComponent()
            manipulation.releaseBehavior = .stay
            manipulation.audioConfiguration = .none
            manipulation.dynamics.scalingBehavior = .unconstrained
            manipulation.dynamics.inertia = .zero
            screen.components.set(manipulation)
            screen.components.remove(HoverEffectComponent.self)
        } else {
            screen.components.remove(ManipulationComponent.self)
            screen.components.set(InputTargetComponent())
            screen.components.set(CollisionComponent(shapes: [
                .generateBox(size: [screenWidth, screenHeight, 0.06])
            ]))
            screen.components.remove(HoverEffectComponent.self)
        }
    }

    static func boundedTransform(_ requested: Transform) -> Transform {
        guard requested.matrix.columns.0.x.isFinite,
              requested.rotation.vector.x.isFinite, requested.rotation.vector.y.isFinite,
              requested.rotation.vector.z.isFinite, requested.rotation.vector.w.isFinite,
              requested.translation.x.isFinite, requested.translation.y.isFinite,
              requested.translation.z.isFinite, requested.scale.x.isFinite,
              simd_length(requested.rotation.vector) > 0.001 else {
            let value = VisionArenaScreenPlacement()
            return Transform(scale: .init(repeating: value.scale),
                translation: [0, value.height, -value.distance])
        }
        var result = requested
        let scale = min(VisionArenaScreenPlacement.scaleRange.upperBound,
                        max(VisionArenaScreenPlacement.scaleRange.lowerBound, requested.scale.x))
        result.scale = .init(repeating: scale)
        result.rotation = simd_normalize(result.rotation)
        // Oriented vertical half-extent keeps the whole screen clear of floor.
        let up = result.rotation.act(SIMD3<Float>(0, 1, 0))
        let right = result.rotation.act(SIMD3<Float>(1, 0, 0))
        let forward = result.rotation.act(SIMD3<Float>(0, 0, 1))
        let extent = scale * (abs(up.y) * 1.2 + abs(right.y) * 2.1 + abs(forward.y) * 0.08)
        result.translation.x = min(4, max(-4, result.translation.x))
        result.translation.y = min(5.8, max(extent + 0.1, result.translation.y))
        result.translation.z = min(-0.3, max(-12, result.translation.z))
        return result
    }

    static func facingViewer(_ requested: Transform, viewer: SIMD3<Float>) -> Transform {
        var result = requested
        let towardViewer = viewer - requested.translation
        guard simd_length_squared(towardViewer) > 0.01 else { return boundedTransform(result) }
        let forward = simd_normalize(towardViewer)
        var right = simd_cross(SIMD3<Float>(0, 1, 0), forward)
        // At the ceiling preserve a stable horizontal direction, never roll.
        if simd_length_squared(right) < 0.0001 { right = [1, 0, 0] }
        right = simd_normalize(right)
        let up = simd_normalize(simd_cross(forward, right))
        result.rotation = simd_quatf(simd_float3x3(columns: (right, up, forward)))
        return boundedTransform(result)
    }

    static func withDistance(_ distance: Float, transform: Transform, viewer: SIMD3<Float>) -> Transform {
        var result = transform
        let delta = transform.translation - viewer
        let direction = simd_length_squared(delta) > 0.01 ? simd_normalize(delta) : SIMD3<Float>(0, 0, -1)
        result.translation = viewer + direction * min(12, max(0.5, distance))
        return boundedTransform(result)
    }

    static func withTilt(_ degrees: Float, transform: Transform, viewer: SIMD3<Float>) -> Transform {
        var result = transform
        let delta = transform.translation - viewer
        let radius = max(0.5, simd_length(delta))
        let yaw = atan2(-delta.x, -delta.z)
        let angle = min(90, max(-30, degrees)) * .pi / 180
        result.rotation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            * simd_quatf(angle: angle, axis: [1, 0, 0])
        result.translation = viewer - result.rotation.act(SIMD3<Float>(0, 0, radius))
        return boundedTransform(result)
    }

    static func loadTextures(into root: Entity, includeFixture: Bool = true) async -> Bool {
        guard let screen = root.findEntity(named: "ArenaStaticScreen") as? ModelEntity,
              let glow = root.findEntity(named: "ArenaScreenGlow") else { return false }
        guard includeFixture else { return await loadLiveMasks(into: glow) }
        do {
            let screenURL = Bundle.main.url(forResource: "FarframeSpectralLandscape", withExtension: "png")
            // Pixel generation never stalls the UI actor or repeats every frame.
            let worker = Task.detached(priority: .userInitiated) {
                try ArenaPreviewTextures.makeImages(screenURL: screenURL)
            }
            let images = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            let fixture = try texture(images.screen)
            var screenMaterial = UnlitMaterial()
            screenMaterial.color = .init(tint: .white, texture: .init(fixture))
            screen.model?.materials = [screenMaterial]

            let halo = ModelEntity(
                mesh: .generatePlane(width: 4.8, height: 3.05),
                materials: [try transparentMaterial(images.halo)]
            )
            halo.name = "ArenaFixtureHalo"
            halo.position = screenPosition + [0, 0, 0.06]
            let haloRoot = Entity()
            haloRoot.name = "ArenaTightHalo"
            haloRoot.addChild(halo)
            glow.addChild(haloRoot)

            let spill = ModelEntity(
                mesh: .generatePlane(width: 6, depth: 4.4),
                materials: [try transparentMaterial(images.floor)]
            )
            spill.name = "ArenaFloorSpill"
            spill.position = [0, 0.015, -3.6]
            glow.addChild(spill)

            // These planes follow the authored vertical side facets. They are
            // deliberately much fainter than the halo and never light real walls.
            let wallTexture = try texture(images.wall)
            for isLeft in [true, false] {
                let tint = isLeft
                    ? UIColor(red: 0.12, green: 0.54, blue: 0.72, alpha: 1)
                    : UIColor(red: 0.72, green: 0.35, blue: 0.13, alpha: 1)
                let wall = ModelEntity(
                    mesh: .generatePlane(width: 3.6, height: 2.2),
                    materials: [transparentMaterial(texture: wallTexture, tint: tint)]
                )
                wall.name = isLeft ? "ArenaLeftWallWash" : "ArenaRightWallWash"
                wall.position = [isLeft ? -5.75 : 5.75, 2.3, -4.7]
                wall.orientation = simd_quatf(angle: isLeft ? .pi / 2 : -.pi / 2, axis: [0, 1, 0])
                glow.addChild(wall)
            }
            return true
        } catch {
            // A missing texture never prevents scene entry or its Exit control.
            glow.children.removeAll()
            return false
        }
    }

    private static func loadLiveMasks(into glow: Entity) async -> Bool {
        do {
            let worker = Task.detached(priority: .utility) { try ArenaPreviewTextures.liveMasks() }
            let masks = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            let halo = Entity()
            halo.name = "ArenaTightHalo"
            glow.addChild(halo)
            for index in 0..<4 {
                let edge = ModelEntity(mesh: .generatePlane(width: 4.8, height: 3.05),
                    materials: [try transparentMaterial(masks.halo[index])])
                edge.name = "ArenaLiveHalo\(index)"
                // Separate feathered masks have no opaque overlapping surfaces.
                edge.position = screenPosition + [0, 0, 0.06 + Float(index) * 0.002]
                edge.isEnabled = false
                halo.addChild(edge)
            }
            for index in 0..<2 {
                let floor = ModelEntity(mesh: .generatePlane(width: 6, depth: 4.4),
                    materials: [try transparentMaterial(masks.floor[index])])
                floor.name = "ArenaLiveFloor\(index)"
                floor.position = [0, 0.015 + Float(index) * 0.0005, -3.6]
                floor.isEnabled = false
                glow.addChild(floor)
                let wall = ModelEntity(mesh: .generatePlane(width: 3.6, height: 2.2),
                    materials: [try transparentMaterial(masks.wall)])
                wall.name = "ArenaLiveWall\(index)"
                wall.position = [index == 0 ? -5.75 : 5.75, 2.3, -4.7]
                wall.orientation = simd_quatf(angle: index == 0 ? .pi / 2 : -.pi / 2, axis: [0, 1, 0])
                wall.isEnabled = false
                glow.addChild(wall)
            }
            return true
        } catch {
            glow.children.removeAll()
            return false
        }
    }

    /// Only four reduced colors cross this boundary. Textures and mesh topology
    /// are created once; gameplay image buffers never become reflection planes.
    static func applyLiveColors(_ colors: VisionArenaLiveColorPolicy.EdgeColors, in root: Entity) {
        let edges = [colors.left, colors.right, colors.top, colors.bottom]
        for index in 0..<4 { tintLiveEntity("ArenaLiveHalo\(index)", color: edges[index], in: root) }
        for index in 0..<2 {
            tintLiveEntity("ArenaLiveFloor\(index)", color: edges[index] * 0.35 + colors.bottom * 0.65, in: root)
            tintLiveEntity("ArenaLiveWall\(index)", color: edges[index], in: root)
        }
    }

    private static func tintLiveEntity(_ name: String, color: SIMD3<Float>, in root: Entity) {
        guard let entity = root.findEntity(named: name) as? ModelEntity,
              var material = entity.model?.materials.first as? UnlitMaterial else { return }
        guard color.x.isFinite, color.y.isFinite, color.z.isFinite else { entity.isEnabled = false; return }
        let peak = min(1, max(0, max(color.x, max(color.y, color.z))))
        entity.isEnabled = peak > 0.001
        guard entity.isEnabled else { return }
        func sRGB(_ channel: Float) -> CGFloat {
            let value = min(1, max(0, channel / peak))
            return CGFloat(value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055)
        }
        material.color.tint = UIColor(red: sRGB(color.x), green: sRGB(color.y), blue: sRGB(color.z), alpha: 1)
        entity.model?.materials = [material]
        // Fade alpha with intensity so a black frame cannot leave a dark halo.
        entity.components.set(OpacityComponent(opacity: peak))
    }

    private static func texture(_ image: CGImage) throws -> TextureResource {
        try TextureResource(image: image, options: .init(semantic: .color))
    }

    private static func transparentMaterial(_ image: CGImage) throws -> UnlitMaterial {
        transparentMaterial(texture: try texture(image), tint: .white)
    }

    private static func transparentMaterial(texture: TextureResource, tint: UIColor) -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(tint: tint, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        material.writesDepth = false
        material.readsDepth = true
        return material
    }
}

/// Small deterministic color masks are created once on scene entry. They contain
/// no captured gameplay or personal images. Alpha reaches zero at every edge.
private enum ArenaPreviewTextures {
    enum TextureError: Error { case creationFailed }

    struct Images: Sendable {
        let screen: CGImage
        let halo: CGImage
        let floor: CGImage
        let wall: CGImage
    }

    struct LiveMasks: Sendable {
        let halo: [CGImage]
        let floor: [CGImage]
        let wall: CGImage
    }

    static func liveMasks() throws -> LiveMasks {
        let halos = try (0..<4).map { edge in
            try image(width: 384, height: 244) { u, v in
                let x = (u - 0.5) * 4.8
                let y = (v - 0.5) * 3.05
                let qx = abs(x) - 1.955
                let qy = abs(y) - 1.08
                let distance = hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - 0.045
                guard distance >= -0.025 else { return .zero }
                let weights = SIMD4<Float>(
                    exp(-pow(u / 0.25, 2)), exp(-pow((1 - u) / 0.25, 2)),
                    exp(-pow(v / 0.25, 2)), exp(-pow((1 - v) / 0.25, 2)))
                let total = max(weights.x + weights.y + weights.z + weights.w, 0.001)
                let border = min(min(u, 1 - u), min(v, 1 - v))
                let alpha = 0.7 * exp(-pow(max(0, distance) / 0.135, 2))
                    * smoothstep(0, 0.035, border) * weights[edge] / total
                return SIMD4(1, 1, 1, alpha)
            }
        }
        let floors = try (0..<2).map { side in
            try image(width: 256, height: 192) { u, v in
                let x = (u - 0.5) * 2
                let z = (v - 0.5) * 2
                let center: Float = side == 0 ? -0.3 : 0.3
                let border = min(min(u, 1 - u), min(v, 1 - v))
                let alpha = 0.15 * exp(-pow((x - center) / 0.55, 2) - pow(z / 0.68, 2))
                    * smoothstep(0, 0.16, border)
                return SIMD4(1, 1, 1, alpha)
            }
        }
        return try LiveMasks(halo: halos, floor: floors, wall: wallSpill())
    }

    static func makeImages(screenURL: URL?) throws -> Images {
        let fixture = bundledScreen(at: screenURL)
        return try Images(screen: fixture ?? screen(), halo: halo(), floor: floorSpill(), wall: wallSpill())
    }

    private static func bundledScreen(at url: URL?) -> CGImage? {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = metadata[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = metadata[kCGImagePropertyPixelHeight] as? NSNumber,
              height.doubleValue > 0,
              abs(width.doubleValue / height.doubleValue - 16.0 / 9.0) < 0.02 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_048,
            kCGImageSourceShouldCacheImmediately: false,
        ] as CFDictionary)
    }

    private static func wallSpill() throws -> CGImage {
        try image(width: 256, height: 160) { u, v in
            let x = (u - 0.5) * 2
            let y = (v - 0.5) * 2
            let border = min(min(u, 1 - u), min(v, 1 - v))
            let alpha = 0.065 * exp(-pow(x / 0.62, 2) - pow(y / 0.65, 2))
                * smoothstep(0, 0.13, border)
            return SIMD4(1, 1, 1, alpha)
        }
    }

    static func halo() throws -> CGImage {
        try image(width: 768, height: 488) { u, v in
            let x = (u - 0.5) * 4.8
            let y = (v - 0.5) * 3.05
            let qx = abs(x) - (2 - 0.045)
            let qy = abs(y) - (1.125 - 0.045)
            let distance = hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - 0.045
            guard distance >= -0.025 else { return .zero }
            let falloff = exp(-pow(max(0, distance) / 0.135, 2))
            let border = min(min(u, 1 - u), min(v, 1 - v))
            let alpha = 0.7 * falloff * smoothstep(0, 0.035, border)
            let color = edgeColor(x: x / 2, y: -y / 1.125)
            return SIMD4(color.x, color.y, color.z, alpha)
        }
    }

    static func floorSpill() throws -> CGImage {
        try image(width: 512, height: 384) { u, v in
            let x = (u - 0.5) * 2
            let z = (v - 0.5) * 2
            let left = exp(-pow((x + 0.3) / 0.55, 2) - pow(z / 0.68, 2))
            let right = exp(-pow((x - 0.32) / 0.5, 2) - pow(z / 0.62, 2))
            let total = max(left + right, 0.001)
            let cyan = SIMD3<Float>(0.12, 0.54, 0.72)
            let amber = SIMD3<Float>(0.72, 0.35, 0.13)
            let color = (cyan * left + amber * right) / total
            let border = min(min(u, 1 - u), min(v, 1 - v))
            let alpha = min(0.27, 0.19 * total) * smoothstep(0, 0.16, border)
            return SIMD4(color.x, color.y, color.z, alpha)
        }
    }

    static func screen() throws -> CGImage {
        // Original abstract still: an explicit fixture, not a fake live session.
        try image(width: 1_024, height: 576) { u, v in
            let cyan = SIMD3<Float>(0.025, 0.3, 0.42)
            let amber = SIMD3<Float>(0.58, 0.25, 0.06)
            let violet = SIMD3<Float>(0.18, 0.065, 0.29)
            let mix = smoothstep(0.2, 0.9, u)
            let horizon = 0.62 + 0.05 * sin(u * 14) + 0.025 * sin(u * 33)
            var color = cyan * (1 - mix) + amber * mix
            color = color * (0.45 + 0.55 * sin(v * .pi)) + violet * (1 - v) * 0.45
            let sun = exp(-pow((u - 0.75) / 0.18, 2) - pow((v - 0.43) / 0.18, 2))
            color += SIMD3<Float>(0.24, 0.18, 0.07) * sun
            if v > horizon {
                color *= 0.25 + 0.28 * exp(-(v - horizon) * 5)
            }
            return SIMD4(color.x, color.y, color.z, 1)
        }
    }

    private static func edgeColor(x: Float, y: Float) -> SIMD3<Float> {
        let left = exp(-pow((x + 1) / 0.7, 2))
        let right = exp(-pow((x - 1) / 0.7, 2))
        let top = exp(-pow((y - 1) / 0.65, 2)) * 0.7
        let bottom = exp(-pow((y + 1) / 0.7, 2)) * 0.45
        let cyan = SIMD3<Float>(0.15, 0.7, 0.88)
        let amber = SIMD3<Float>(0.91, 0.43, 0.16)
        let violet = SIMD3<Float>(0.52, 0.22, 0.76)
        return (cyan * (left + bottom) + amber * right + violet * top)
            / max(left + right + top + bottom, 0.001)
    }

    private static func smoothstep(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let t = min(1, max(0, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }

    private static func image(
        width: Int,
        height: Int,
        pixel: (Float, Float) -> SIMD4<Float>
    ) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            if y.isMultiple(of: 32) { try Task.checkCancellation() }
            for x in 0..<width {
                let rgba = pixel(Float(x) / Float(width - 1), Float(y) / Float(height - 1))
                let alpha = min(1, max(0, rgba.w))
                let index = (y * width + x) * 4
                bytes[index] = UInt8((min(1, max(0, rgba.x)) * alpha * 255).rounded())
                bytes[index + 1] = UInt8((min(1, max(0, rgba.y)) * alpha * 255).rounded())
                bytes[index + 2] = UInt8((min(1, max(0, rgba.z)) * alpha * 255).rounded())
                bytes[index + 3] = UInt8((alpha * 255).rounded())
            }
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                    .union(.byteOrder32Big),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { throw TextureError.creationFailed }
        return image
    }
}
#endif
