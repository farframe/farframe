#if os(visionOS)
import Foundation
import RealityKit
import UIKit

/// Runs in the isolated tablet fixture against the actual application state.
@MainActor enum VisionArenaWrapStateChecks {
    static func run(_ state: VisionArenaPreviewState) async {
        let initial = VisionArenaPreviewState(defaults: UserDefaults(suiteName: "FarframeWrapDefaultsFixture")!)
        precondition(initial.selectedPreset == .cinema && !initial.pillarGlow)
        precondition(initial.placement == VisionArenaScreenPlacement.Preset.cinema.placement)
        func firstModel(_ entity: Entity) -> Entity? {
            if entity.components[ModelComponent.self] != nil { return entity }
            return entity.children.compactMap(firstModel).first
        }
        func emission(_ entity: Entity) -> CGFloat {
            let material = entity.components[ModelComponent.self]!.materials[0] as! PhysicallyBasedMaterial
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            precondition(material.emissiveColor.color.getRed(&r, green: &g, blue: &b, alpha: &a))
            return max(r, max(g, b))
        }
        for _ in 0..<2 {
            state.accessGranted = true
            state.isActive = true
            state.reduceMotion = false
            state.glow = .medium
            await state.prewarmRoom(forLiveSession: false)
            precondition(state.wrapAvailable)
            let root = state.prepareScene().root
            let room = root.findEntity(named: "FarframeAuthoredArena")!
            let frame = room.findEntity(named: "Arena_Graphite_titanium_002")!
            let wrap = root.findEntity(named: "ArenaArchitecturalWrap")!
            let screen = root.findEntity(named: "ArenaStaticScreen")!
            let originalTransform = screen.transform
            state.pillarGlow = true
            state.lightCoverage = .architecturalWrap
            state.applyGlow()
            precondition(wrap.isEnabled && !frame.isEnabled)
            precondition(wrap.findEntity(named: "Wrap_wash_left") == nil)
            let wash = root.findEntity(named: "ArenaWideHalo")!
            let strip = firstModel(wrap.findEntity(named: "Wrap_strip_left")!)!
            precondition(wash.isEnabled && emission(strip) > 0)
            state.pillarGlow = false; state.applyGlow()
            precondition(frame.isEnabled && !strip.isEnabled, "Pillar Glow off must restore authored batches and hide replacements")
            precondition(wash.isEnabled,
                         "Pillar Glow must not turn off or dim between-pillar lighting")
            precondition(screen.transform == originalTransform)
            state.pillarGlow = true; state.applyGlow(); precondition(emission(strip) > 0)
            let floor = root.findEntity(named: "ArenaFloorSpill")!
            let wide = floor.scale
            for i in 0..<20 {
                state.lightCoverage = i.isMultiple(of: 2) ? .screen : .architecturalWrap
                state.applyGlow()
                precondition(wrap.isEnabled == !i.isMultiple(of: 2))
                precondition(frame.isEnabled == i.isMultiple(of: 2))
                precondition(screen.transform == originalTransform)
            }
            state.glow = .off; state.applyGlow()
            precondition(!wrap.isEnabled && frame.isEnabled && floor.scale.x < wide.x)
            state.glow = .medium; state.applyGlow(); precondition(wrap.isEnabled)
            state.reduceMotion = true; state.applyGlow(); precondition(!wrap.isEnabled)
            state.reduceMotion = false; state.applyGlow(); precondition(wrap.isEnabled)
            state.isActive = false; state.applyGlow(); precondition(!wrap.isEnabled)
            state.isActive = true; state.applyGlow(); precondition(wrap.isEnabled)
            state.updateAccess(false); precondition(!wrap.isEnabled)
            state.updateAccess(true); precondition(wrap.isEnabled)
            state.tearDown()
            precondition(!state.wrapAvailable && state.phase == .closed)
        }
        // Re-entering must retain an explicit user-selected position.
        state.selectPreset(.reclined)
        let selected = state.currentScreenTransform
        state.accessGranted = true
        await state.prewarmRoom(forLiveSession: false)
        precondition(state.selectedPreset == .reclined && state.currentScreenTransform == selected)
        state.selectPreset(.cinema)
        precondition(state.selectedPreset == .cinema && abs(state.screenSize - VisionArenaScreenPlacement.Preset.cinema.placement.scale) < 0.001)
        state.lightCoverage = .screen
        state.applyGlow()
        print("WRAP_STATE_PASS cinemaDefault=true pillarIndependent=true customPositionRetained=true entryExit=2 restoration=40 reduceMotion=true inactive=true accessRevoked=true off=true")
    }
}
#endif
