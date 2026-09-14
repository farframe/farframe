import Foundation

/// Standalone deterministic harness; compile with the Foundation-only route
/// source. It needs neither a headset nor a live provider session.
@main
enum VisionArenaPresentationRouteChecks {
    static func main() {
        let session = UUID()
        var route = VisionArenaPresentationRoute()
        let first = route.begin(sessionID: session)!
        precondition(route.begin(sessionID: session) == nil, "Repeated entry must be rejected")
        precondition(!route.flatOwnsLifecycle && route.shouldRenderFlat)
        precondition(!route.rendererAttached(first, activeSessionID: UUID()))
        precondition(route.rendererAttached(first, activeSessionID: session))
        precondition(!route.shouldRenderFlat && !route.flatOwnsLifecycle)
        precondition(!route.rendererAttached(first, activeSessionID: session), "Duplicate completion")
        precondition(route.beginReturn(first, activeSessionID: session))
        let revision = route.flatRevision
        precondition(route.shouldRenderFlat && !route.flatOwnsLifecycle)
        precondition(route.beginReturn(first, activeSessionID: session))
        precondition(route.flatRevision == revision, "System dismissal and Exit must share one return")
        precondition(!route.flatAttached(sessionID: UUID(), revision: revision))
        precondition(!route.flatAttached(sessionID: session, revision: revision &- 1))
        precondition(route.flatAttached(sessionID: session, revision: revision))
        precondition(route.flatOwnsLifecycle && route.ticket == nil)
        precondition(!route.beginReturn(first, activeSessionID: session), "A late dismissal cannot undo completed return")

        let cancelled = route.begin(sessionID: session)!
        precondition(route.beginReturn(cancelled, activeSessionID: session))
        precondition(!route.rendererAttached(cancelled, activeSessionID: session), "Late room load after cancellation")
        precondition(route.flatAttached(sessionID: session, revision: route.flatRevision))
        let newer = route.begin(sessionID: session)!
        precondition(!route.beginReturn(cancelled, activeSessionID: session), "Old attempt cannot affect new attempt")
        precondition(!route.rendererAttached(cancelled, activeSessionID: session))
        precondition(route.rendererAttached(newer, activeSessionID: session))
        precondition(route.beginReturn(newer, activeSessionID: session))
        let failedRevision = route.flatRevision
        precondition(!route.cancelReturn(newer, activeSessionID: UUID()))
        precondition(route.cancelReturn(newer, activeSessionID: session))
        precondition(route.phase == .immersive(newer) && !route.shouldRenderFlat)
        precondition(!route.flatAttached(sessionID: session, revision: failedRevision), "Late readiness cannot close the recovered room")
        precondition(route.beginReturn(newer, activeSessionID: session))
        precondition(route.flatRevision != failedRevision)
        precondition(!route.flatAttached(sessionID: session, revision: failedRevision))
        precondition(route.flatAttached(sessionID: session, revision: route.flatRevision))
        route.invalidate()
        precondition(route.flatOwnsLifecycle && route.shouldRenderFlat)
        precondition(!route.beginReturn(newer, activeSessionID: session))
        precondition(!route.rendererAttached(newer, activeSessionID: session))
        print("PASS: 33 immersive presentation ownership/return/stale-session assertions")
    }
}
