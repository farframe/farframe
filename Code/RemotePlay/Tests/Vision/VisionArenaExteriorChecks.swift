import Foundation
import RealityKit

@MainActor private final class Gate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        continuation?.resume()
        continuation = nil
    }
}
private enum SyntheticFailure: Error { case load }

@MainActor private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return predicate()
}

@MainActor private func expectEventually(_ predicate: @MainActor () -> Bool) async {
    let passed = await eventually(predicate)
    precondition(passed, "Timed out waiting for exterior state")
}

@main struct ExteriorChecks {
    @MainActor static func main() async {
        let suite = "Farframe.ExteriorChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("removed-style", forKey: VisionArenaExteriorController.preferenceKey)
        var calls = 0
        var fail = false
        let controller = VisionArenaExteriorController(defaults: defaults) { style in
            calls += 1
            if fail { throw SyntheticFailure.load }
            let root = Entity()
            root.name = style.rawValue
            return root
        }
        precondition(controller.selection == .quietHorizon)
        controller.select(.orbitalTerrace)
        precondition(calls == 0 && controller.selection == .orbitalTerrace)
        controller.select(.quietHorizon)
        let parent = Entity()
        let screen = Entity()
        screen.name = "ScreenSentinel"
        parent.addChild(screen)
        controller.mount(on: parent)
        await expectEventually { controller.displayedStyle == .quietHorizon }
        precondition(parent.children.count == 2 && screen.parent === parent)
        controller.select(.quietHorizon)
        precondition(calls == 1, "Repeated selection must not rebuild")
        let old = parent.findEntity(named: "ArenaExterior")!
        fail = true
        controller.select(.orbitalTerrace)
        await expectEventually { !controller.isLoading }
        precondition(controller.displayedStyle == .quietHorizon && controller.selection == .quietHorizon)
        precondition(parent.findEntity(named: "ArenaExterior") === old && controller.message != nil)
        precondition(defaults.string(forKey: VisionArenaExteriorController.preferenceKey) == "quietHorizon")
        fail = false
        for i in 0..<30 {
            let style = VisionArenaExteriorStyle.allCases[(i + 1) % 3]
            controller.select(style)
            await expectEventually { !controller.isLoading && controller.displayedStyle == style }
            precondition(parent.children.count == 2 && screen.parent === parent)
        }
        controller.unmount()
        precondition(parent.children.count == 1 && controller.displayedStyle == nil && !controller.isLoading)
        let before = calls
        controller.select(.lightSculpture)
        precondition(calls == before, "Unmounted/denied room cannot load")

        for lateFailure in [false, true] {
            defaults.set("lightSculpture", forKey: VisionArenaExteriorController.preferenceKey)
            let gate = Gate()
            let c = VisionArenaExteriorController(defaults: defaults) { style in
                if style == .quietHorizon {
                    await gate.wait()
                    if lateFailure { throw SyntheticFailure.load }
                }
                return Entity()
            }
            let p = Entity()
            p.addChild(screen)
            c.mount(on: p)
            await expectEventually { c.displayedStyle == .lightSculpture }
            c.select(.quietHorizon)
            await expectEventually { gate.entered }
            c.select(.orbitalTerrace)
            await expectEventually { c.displayedStyle == .orbitalTerrace }
            let current = p.findEntity(named: "ArenaExterior")!
            gate.open()
            for _ in 0..<20 { await Task.yield() }
            precondition(c.displayedStyle == .orbitalTerrace && c.message == nil)
            precondition(p.findEntity(named: "ArenaExterior") === current && screen.parent === p)
            c.unmount()
        }
        defaults.set("quietHorizon", forKey: VisionArenaExteriorController.preferenceKey)
        let gate = Gate()
        let cancelled = VisionArenaExteriorController(defaults: defaults) { _ in
            await gate.wait()
            return Entity()
        }
        let p = Entity()
        cancelled.mount(on: p)
        await expectEventually { gate.entered }
        cancelled.unmount()
        gate.open()
        for _ in 0..<20 { await Task.yield() }
        precondition(p.children.isEmpty && cancelled.displayedStyle == nil && cancelled.message == nil)
        print(
            "PASS: exterior fallback, atomic replacement, 30 switches, failed load, late success/failure, unmount/cancellation, preference and screen identity"
        )
    }
}
