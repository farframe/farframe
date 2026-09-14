import Foundation

/// Tracks a view's current activity across initial appearance and later changes.
/// A queued callback from a previous appearance must never reactivate a new one.
struct VisionPlayerLifecycle {
    enum Activity { case active, inactive, background }
    private(set) var activity: Activity = .inactive
    private(set) var isPresented = false
    private(set) var revision = UUID()

    mutating func appeared(_ activity: Activity) -> UUID {
        isPresented = true
        return changed(activity)
    }

    mutating func changed(_ activity: Activity) -> UUID {
        self.activity = activity
        revision = UUID()
        return revision
    }

    mutating func disappeared() {
        isPresented = false
        activity = .inactive
        revision = UUID()
    }

    func canActivate(_ event: UUID) -> Bool {
        isPresented && activity == .active && revision == event
    }

    static func shouldClose(expectedSession: UUID, activeSession: UUID?,
                            replacementWindowIsPresent: Bool) -> Bool {
        expectedSession == activeSession && !replacementWindowIsPresent
    }
}
