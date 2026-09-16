import Foundation
import ImageIO
import RealityKit
import SwiftUI
import UIKit

/// Isolated simulator render tool, not linked into any Farframe app target.
/// No account, registration, network, stream or commerce path is present.
@main struct ArenaRenderHarness: App {
    @State private var model = HarnessModel()
    var body: some SwiftUI.Scene {
        WindowGroup {
            HarnessLauncher().frame(width: 380, height: 160)
        }
        ImmersiveSpace(id: "room") { HarnessRoom(model: model) }
            .immersionStyle(selection: .constant(.full), in: .full)
    }
}
private struct HarnessLauncher: View {
    @Environment(\.openImmersiveSpace) private var open
    @Environment(\.dismissWindow) private var dismiss
    var body: some View {
        Text("Farframe renderer verification").task {
            if case .opened = await open(id: "room") { dismiss() }
        }
    }
}
@MainActor @Observable private final class HarnessModel {
    var glow: VisionArenaGlow = .medium
    var coverage: VisionArenaLightCoverage = .screen
    var pillarGlow = true
    var wrap: VisionArenaWrapRig?
    var palette = VisionArenaLiveColorPolicy.EdgeColors(left: [0.02, 0.28, 0.65], right: [0.65, 0.20, 0.025], top: [0.18, 0.025, 0.30], bottom: [0.025, 0.10, 0.15])
    var controlsExpanded = false
    var movable = false
    var partialImmersion = false
    var keepFacing = true
    var placement = VisionArenaScreenPlacement.Preset.cinema.placement
    let exterior: VisionArenaExteriorController
    var ready = false
    var failure: String?
    var root: Entity?
    init() {
        let defaults = UserDefaults(suiteName: "Farframe.ArenaRenderHarness")!
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--wrap") { coverage = .architecturalWrap }
        if args.contains("--off") { glow = .off }
        pillarGlow = args.contains("--pillars")
        if args.contains("--seated") { placement = .init() }
        if args.contains("--small") { placement = .init(scale: 0.35) }
        controlsExpanded = args.contains("--controls-expanded")
        if let i = args.firstIndex(of: "--style"), i + 1 < args.count,
            let style = VisionArenaExteriorStyle(rawValue: args[i + 1])
        {
            defaults.set(style.rawValue, forKey: VisionArenaExteriorController.preferenceKey)
        }
        if args.contains("--cinema") { placement = VisionArenaScreenPlacement.Preset.cinema.placement }
        exterior = VisionArenaExteriorController(defaults: defaults, loader: VisionArenaExteriorFactory.make)
    }
    func load(into root: Entity) async {
        do {
            self.root = root
            let rig = VisionArenaScreenRig.make()
            root.addChild(rig.root)
            _ = await VisionArenaScreenRig.loadTextures(into: root)
            let room = try await Entity(named: "FarframeGlassArena.usdz", in: .main)
            room.name = "FarframeAuthoredArena"
            let glass = ProcessInfo.processInfo.arguments.contains("--probe-glass")
                ? await VisionArenaMaterials.loadOpticalGlass() : nil
            let variation = await VisionArenaMaterials.loadSurfaceVariation()
            VisionArenaMaterials.apply(to: room, opticalGlass: glass, surfaceVariation: variation, includeFloatingTrim: ProcessInfo.processInfo.arguments.contains("--probe-glass"))
            root.addChild(room)
            if !ProcessInfo.processInfo.arguments.contains("--probe-glass") {
                var hiddenTrimBatches = 0
                func checkTrim(_ entity: Entity) {
                    if let model = entity.components[ModelComponent.self], !model.materials.isEmpty,
                       model.materials.allSatisfy({ ($0.name ?? "").hasPrefix("FF_Satin") }) {
                        precondition(!entity.isEnabled, "Floating trim remained visible")
                        hiddenTrimBatches += 1
                    }
                    for child in entity.children { checkTrim(child) }
                }
                checkTrim(room)
                precondition(hiddenTrimBatches > 0, "Expected floating-trim batch was not identified")
            }
            VisionArenaScreenRig.mountHousing(from: room, on: root)
            let floor = root.findEntity(named: "FarframeAuthoredArena")!
            let floorTransform = floor.transform
            let screen = root.findEntity(named: "ArenaStaticScreen")!
            let housing = root.findEntity(named: "ArenaDisplayHousing")!
            precondition(housing.children.count == 1, "Fixed color seams must be removed; housing preserved")
            for value in [VisionArenaScreenPlacement(),
                          VisionArenaScreenPlacement(height: 2, distance: 3.5, horizontal: 1, scale: 0.65, yaw: 20, tilt: 15)] {
                VisionArenaScreenRig.applyPlacement(value, in: root)
                let center = screen.position(relativeTo: root)
                precondition(abs(center.y - value.bounded.height) < 0.001)
                precondition(abs(center.z + value.bounded.distance) < 0.001)
                precondition(root.findEntity(named: "ArenaStaticScreen") === screen)
                precondition(floor.transform == floorTransform, "Screen adjustment moved the room")
            }
            for preset in VisionArenaScreenPlacement.Preset.allCases {
                VisionArenaScreenRig.applyPlacement(preset.placement, in: root)
                precondition(floor.transform == floorTransform)
                precondition(screen.orientation == root.findEntity(named: "ArenaTightHalo")!.orientation)
            }
            VisionArenaScreenRig.setMovable(true, in: root)
            precondition(screen.components[ManipulationComponent.self]?.releaseBehavior == .stay)
            precondition(screen.components[InputTargetComponent.self] != nil)
            var custom = Transform(scale: [1.2, 1.2, 1.2],
                rotation: simd_quatf(angle: .pi / 4, axis: [1, 0, 0]), translation: [1, 3, -3])
            custom = VisionArenaScreenRig.boundedTransform(custom)
            VisionArenaScreenRig.applyDisplayTransform(custom, in: root)
            precondition(screen.transform == custom)
            precondition(floor.transform == floorTransform)
            VisionArenaScreenRig.setMovable(false, in: root)
            precondition(screen.components[ManipulationComponent.self] == nil)
            precondition(screen.components[InputTargetComponent.self] != nil, "Locked screen retains its Controls recall target")
            VisionArenaScreenRig.applyPlacement(placement, in: root)
            let viewer = SIMD3<Float>(0, 1.15, 0)
            let rolled = Transform(scale: [1, 1, 1], rotation: simd_quatf(angle: .pi, axis: [0, 0, 1]), translation: [1, 3, -5])
            let facing = VisionArenaScreenRig.facingViewer(rolled, viewer: viewer)
            let front = facing.rotation.act(SIMD3<Float>(0, 0, 1))
            precondition(simd_dot(front, simd_normalize(viewer - facing.translation)) > 0.999)
            precondition(facing.rotation.act(SIMD3<Float>(1, 0, 0)).y.magnitude < 0.001)
            let distant = VisionArenaScreenRig.withDistance(10, transform: facing, viewer: viewer)
            precondition(abs(simd_length(distant.translation - viewer) - 10) < 0.001)
            for tilt: Float in [0, 30, 60, 90] {
                let adjusted = VisionArenaScreenRig.withTilt(tilt, transform: facing, viewer: viewer)
                precondition(adjusted.translation.y > 0)
                let angle = asin(-adjusted.rotation.act(SIMD3<Float>(0, 0, 1)).y) * 180 / .pi
                precondition(abs(angle - tilt) < 0.05)
            }
            let liveRig = VisionArenaScreenRig.make()
            _ = await VisionArenaScreenRig.loadTextures(into: liveRig.root, includeFixture: false)
            for (rigRoot, haloName, floorName, wallName) in [
                (root, "ArenaFixtureHalo", "ArenaFloorSpill", "ArenaLeftWallWash"),
                (liveRig.root, "ArenaLiveHalo0", "ArenaLiveFloor0", "ArenaLiveWall0")
            ] {
                var lastFloorZ: Float?
                for distance: Float in [4, 8, 12] {
                    var t = facing
                    t.translation = [0.5, 3, -distance]
                    t.scale = [2.1, 2.1, 2.1]
                    t = VisionArenaScreenRig.boundedTransform(t)
                    VisionArenaScreenRig.applyDisplayTransform(t, in: rigRoot)
                    let halo = rigRoot.findEntity(named: haloName)!
                    let expected = t.translation + t.rotation.act(SIMD3<Float>(0, 0, 0.06) * t.scale.x)
                    precondition(simd_distance(halo.position(relativeTo: rigRoot), expected) < 0.001)
                    let floorPatch = rigRoot.findEntity(named: floorName)!
                    precondition(abs(floorPatch.position.y - 0.015) < 0.001)
                    if let lastFloorZ { precondition(floorPatch.position.z < lastFloorZ, "Glow must follow Distance") }
                    lastFloorZ = floorPatch.position.z
                    let wall = rigRoot.findEntity(named: wallName)!
                    precondition(wall.position.x == -5.75, "Wall wash must remain on its wall")
                    precondition(floor.transform == floorTransform, "Glow movement must never move the room")
                }
            }
            VisionArenaScreenRig.applyPlacement(placement, in: root)
            for rigRoot in [root, liveRig.root] {
                let wide = rigRoot.findEntity(named: "ArenaWideHalo")!
                VisionArenaScreenRig.applyPlacement(.init(scale: 0.35), in: rigRoot)
                let smallWidth = wide.visualBounds(relativeTo: rigRoot).extents.x
                VisionArenaScreenRig.applyPlacement(placement, in: rigRoot)
                let largeWidth = wide.visualBounds(relativeTo: rigRoot).extents.x
                precondition(smallWidth < 2.25 && largeWidth >= smallWidth,
                             "Wide glow must shrink with the display")
                VisionArenaScreenRig.applyLiveColors(.black, in: rigRoot)
                for index in 0..<4 {
                    if let edge = rigRoot.findEntity(named: "ArenaLiveWideHalo\(index)") {
                        precondition(!edge.isEnabled, "Black frames must remove wide glow")
                    }
                }
            }
            print("ARENA_GLOW_CHECKS_PASS fixtureAndLive=true followsDistance=true haloAligned=true surfacesFixed=true wideShrinks=true blackClears=true")
            // Exercise direct manipulation, not only the numeric preset clamp.
            for pitch: Float in [-45, 0, 8, 45, 90] {
                for yaw: Float in [-90, -35, 0, 35, 90] {
                    let rotation = simd_quatf(angle: yaw * .pi/180, axis: [0,1,0])
                        * simd_quatf(angle: pitch * .pi/180, axis: [1,0,0])
                    let t = Transform(scale: [2.25,2.25,2.25], rotation: rotation, translation: [0,3,-12])
                    VisionArenaScreenRig.applyDisplayTransform(t, in: root)
                    for x: Float in [-2.1,2.1] { for y: Float in [-1.2,1.2] { for z: Float in [-0.08,0.08] {
                        let corner = screen.transform.translation + screen.orientation.act(SIMD3<Float>(x,y,z) * screen.scale.x)
                        precondition(corner.z >= -VisionArenaScreenPlacement.backClearance - 0.001)
                    } } }
                }
            }
            VisionArenaScreenRig.applyPlacement(placement, in: root)
            print("ARENA_PLACEMENT_CHECKS_PASS housing=1 stableScreen=true stationaryRoom=true")
            if let url = Bundle.main.url(forResource: "FarframeGlassArenaLighting", withExtension: "exr"),
                let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            {
                let environment = try await EnvironmentResource(equirectangular: image)
                _ = VisionArenaLighting.install(on: root, environment: environment)
            }
            let asset = try await Entity(named: "FarframeArenaWrap.usdz", in: .main)
            guard let wrap = VisionArenaWrapRig(asset: asset, room: room) else {
                fatalError("Wrap partition contract did not load")
            }
            self.wrap = wrap
            root.addChild(wrap.root)
            precondition(VisionArenaWrapRig(asset: Entity(), room: room) == nil)
            let frameBatch = room.findEntity(named: "Arena_Graphite_titanium_002")!
            let stripBatch = room.findEntity(named: "Arena_Architectural_cyan_002")!
            for _ in 0..<20 {
                wrap.update(colors: palette, intensity: 0.8, enabled: true)
                precondition(!frameBatch.isEnabled && !stripBatch.isEnabled && wrap.root.isEnabled)
                wrap.update(colors: palette, intensity: 0.8, enabled: true, pillarGlow: false)
                precondition(frameBatch.isEnabled && stripBatch.isEnabled && wrap.root.isEnabled)
                wrap.update(colors: .black, intensity: 0, enabled: false)
                precondition(frameBatch.isEnabled && stripBatch.isEnabled && !wrap.root.isEnabled)
            }
            for zone in ["left", "right", "top"] {
                precondition(wrap.root.findEntity(named: "Wrap_wash_" + zone) == nil,
                             "Fixed backdrop panels must not remain in the scene")
            }
            print("ARENA_WRAP_CHECKS_PASS opaqueParts=8 washParts=0 restorationCycles=20 invalidAssetFallback=true")
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "--palette"), i + 1 < args.count {
                switch args[i+1] {
                case "black": palette = .black
                case "white": palette = palette.map { _ in .init(repeating: 1) }
                case "purple": palette = palette.map { _ in [0.38, 0.035, 0.70] }
                case "split": palette = .init(left: [0.03, 0.35, 0.7], right: [0.8, 0.15, 0.02], top: [0.3, 0.05, 0.6], bottom: [0.04, 0.08, 0.12])
                default: fatalError("Unknown palette")
                }
                for name in ["ArenaTightHalo", "ArenaWideHalo", "ArenaFloorSpill", "ArenaLeftWallWash", "ArenaRightWallWash"] {
                    root.findEntity(named: name)?.removeFromParent()
                }
                _ = await VisionArenaScreenRig.loadTextures(into: root, includeFixture: false)
                VisionArenaScreenRig.applyLiveColors(palette, in: rig.glow)
                let color = palette.top
                func srgb(_ v: Float) -> CGFloat { CGFloat(v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1/2.4) - 0.055) }
                screen.components[ModelComponent.self]?.materials = [UnlitMaterial(color: UIColor(red: srgb(color.x), green: srgb(color.y), blue: srgb(color.z), alpha: 1))]
            }
            exterior.mount(on: root)
            updateGlow()
            if let index = args.firstIndex(of: "--view"), index + 1 < args.count {
                if args[index + 1] == "left" { root.orientation = simd_quatf(angle: -0.50, axis: [0, 1, 0]) }
                if args[index + 1] == "right" { root.orientation = simd_quatf(angle: 0.50, axis: [0, 1, 0]) }
                if args[index + 1] == "rear" { root.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0]) }
                if args[index + 1] == "upper" { root.orientation = simd_quatf(angle: -0.55, axis: [1, 0, 0]) }
                if args[index + 1] == "side" { root.orientation = simd_quatf(angle: -.pi / 2, axis: [0, 1, 0]) }
            }
            ready = true
            saveMetrics()
            print("ARENA_RENDER_READY")
        } catch {
            failure = error.localizedDescription
            print("ARENA_RENDER_FAILED", error)
        }
    }
    func saveMetrics() {
        guard let root, let style = exterior.displayedStyle else { return }
        var models = 0
        var entities = 0
        func visit(_ entity: Entity) {
            entities += 1
            if entity.components[ModelComponent.self] != nil { models += 1 }
            for child in entity.children { visit(child) }
        }
        visit(root)
        let values: [String: Any] = [
            "style": style.rawValue, "entities": entities, "models": models, "coverage": coverage.rawValue,
            "wrapChecksPassed": wrap != nil, "pillarGlow": pillarGlow,
            "screenDistance": placement.distance, "screenScale": placement.scale, "intensity": glow.rawValue,
            "screenCount": root.findEntity(named: "ArenaStaticScreen") == nil ? 0 : 1,
            "fixtureOnly": true, "containsLiveSession": false,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: values, options: [.prettyPrinted, .sortedKeys]),
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        {
            try? data.write(to: url.appendingPathComponent("render-metrics.json"), options: .atomic)
        }
    }
    func updateGlow() {
        guard let glowRoot = root?.findEntity(named: "ArenaScreenGlow") else { return }
        glowRoot.components.set(OpacityComponent(opacity: glow.opacity))
        glowRoot.isEnabled = glow != .off
        VisionArenaBloom.update(in: glowRoot, level: glow, isActive: true)
        let activeCoverage: VisionArenaLightCoverage = glow == .off ? .screen : coverage
        wrap?.update(colors: palette, intensity: glow.opacity, enabled: activeCoverage == .architecturalWrap, pillarGlow: pillarGlow)
        VisionArenaScreenRig.setWideGlowEnabled(activeCoverage == .architecturalWrap, in: glowRoot)
        VisionArenaScreenRig.setWallWashEnabled(activeCoverage == .screen, in: glowRoot)
        if let root { VisionArenaScreenRig.applyPlacement(placement, in: root, coverage: activeCoverage) }
    }
}
private struct HarnessRoom: View {
    @Bindable var model: HarnessModel
    var body: some View {
        RealityView { content, attachments in
            let root = Entity()
            content.add(root)
            if let panel = attachments.entity(for: "controls") {
                panel.position = [2.3, 1.1, -3.5]
                panel.scale = .init(repeating: 1.5)
                panel.components.set(BillboardComponent())
                root.addChild(panel)
            }
            await model.load(into: root)
        } update: { _, attachments in
            if let root = model.root { VisionArenaScreenRig.applyPlacement(model.placement, in: root, coverage: model.glow == .off ? .screen : model.coverage) }
            attachments.entity(for: "controls")?.position = [2.3, 1.1, -3.5]
        } attachments: {
            Attachment(id: "controls") {
                if model.controlsExpanded {
                VisionArenaControlsPanel(movable: $model.movable, partialImmersion: $model.partialImmersion,
                    selectedPreset: nil, size: $model.placement.scale,
                    distance: $model.placement.distance, tilt: $model.placement.tilt,
                    keepFacing: $model.keepFacing,
                    selectPreset: { model.placement = $0.placement },
                    reset: { model.placement = .init() }, exit: {}) {
                    Text("NATIVE RENDER • STATIC FIXTURE").font(.caption)
                    VisionArenaExteriorPicker(exterior: model.exterior)
                    VisionArenaCoveragePicker(selection: $model.coverage, pillarGlow: $model.pillarGlow, available: model.wrap != nil)
                    Picker("Glow", selection: $model.glow) {
                        ForEach(VisionArenaGlow.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    if let failure = model.failure { Text(failure) }
                }.glassBackgroundEffect()
                } else {
                    Text("NATIVE FIXTURE").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.onChange(of: model.glow) { _, _ in model.updateGlow() }
            .onChange(of: model.coverage) { _, _ in model.updateGlow() }
            .onChange(of: model.pillarGlow) { _, _ in model.updateGlow() }
            .onChange(of: model.exterior.displayedStyle) { _, _ in model.saveMetrics() }
            .onDisappear { model.exterior.unmount() }
    }
}
