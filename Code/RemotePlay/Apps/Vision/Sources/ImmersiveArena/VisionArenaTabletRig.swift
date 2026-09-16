#if os(visionOS)
import RealityKit

/// A room-local recall point beside the screen. The tablet remains a native,
/// independently movable Window; no head anchor can strand this launcher.
@MainActor
final class VisionArenaControlsLauncherRig {
    private var launcher: Entity?
    func mount(launcher: Entity, in root: Entity) {
        unmount()
        launcher.name = "ArenaControlsLauncher"
        launcher.components.set(BillboardComponent())
        root.addChild(launcher)
        self.launcher = launcher
        update(screen: Transform(translation: [0, 1.15, -4.5]))
    }
    func update(screen: Transform) {
        guard let launcher else { return }
        // At a reachable distance, off the right edge's viewing direction.
        let viewer = SIMD3<Float>(0, 1.15, 0)
        let delta = screen.translation - viewer
        let forward = simd_length_squared(delta) > 0.01 ? simd_normalize(delta) : SIMD3<Float>(0, 0, -1)
        var right = simd_cross(forward, SIMD3<Float>(0, 1, 0))
        if simd_length_squared(right) < 0.01 { right = [1, 0, 0] }
        launcher.position = viewer + forward * 1.4 + simd_normalize(right) * 1.1 + [0, -0.15, 0]
    }
    func unmount() { launcher?.removeFromParent(); launcher = nil }
}
#endif
