import Foundation

@main
enum VisionPlayerLifecycleChecks {
    static func main() {
        var lifecycle = VisionPlayerLifecycle()
        let first = lifecycle.appeared(.active)
        precondition(lifecycle.canActivate(first))

        // The old player backgrounds/closes. A new window is ALREADY active:
        // no phase-change event is required to authorize its initial start.
        let background = lifecycle.changed(.background)
        precondition(!lifecycle.canActivate(first))
        precondition(!lifecycle.canActivate(background))
        lifecycle.disappeared()
        let reopened = lifecycle.appeared(.active)
        precondition(lifecycle.canActivate(reopened))
        precondition(!lifecycle.canActivate(first))

        // A system interruption supersedes a queued activation.
        let inactive = lifecycle.changed(.inactive)
        precondition(!lifecycle.canActivate(reopened))
        precondition(!lifecycle.canActivate(inactive))
        let resumed = lifecycle.changed(.active)
        precondition(lifecycle.canActivate(resumed))
        lifecycle.disappeared()
        precondition(!lifecycle.canActivate(resumed))
        let inactiveAppearance = lifecycle.appeared(.inactive)
        precondition(!lifecycle.canActivate(inactiveAppearance))

        let oldSession = UUID(), replacementSession = UUID()
        precondition(VisionPlayerLifecycle.shouldClose(expectedSession: oldSession,
            activeSession: oldSession, replacementWindowIsPresent: false))
        precondition(!VisionPlayerLifecycle.shouldClose(expectedSession: oldSession,
            activeSession: replacementSession, replacementWindowIsPresent: false))
        precondition(!VisionPlayerLifecycle.shouldClose(expectedSession: oldSession,
            activeSession: oldSession, replacementWindowIsPresent: true))
        precondition(!VisionPlayerLifecycle.shouldClose(expectedSession: oldSession,
            activeSession: nil, replacementWindowIsPresent: false))
        print("PASS: 14 player appearance/interruption/stale-close assertions")
    }
}
