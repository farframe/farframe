import Foundation

/// Which window is allowed to present the player.
///
/// Big Screen mode needs `UIApplicationSupportsMultipleScenes`, and UIKit is
/// explicit that setting it to `NO` means "UIKit never creates more than one
/// scene for your app" — so an external-display scene is unreachable without
/// it. Turning it on also lets a person open a second app window on iPadOS,
/// and the app owns exactly one stream coordinator and one video surface.
/// Two players would fight over that surface: whichever attached last would
/// take the picture and the other would go black, while both fed input to the
/// same session.
///
/// So the player is a single-occupancy room. One window holds it, any other
/// window says where it went and offers to take it. Everything else — the
/// console list, Settings, Diagnostics — is safe in as many windows as the
/// person wants, and is left alone.
///
/// Pure value logic, so the rule is testable without scenes or windows.
struct MobileSceneOwnershipState: Equatable, Sendable {
    private(set) var ownerID: UUID?
    private(set) var liveIDs: [UUID] = []

    /// A window appeared. The first one to arrive holds the player; later ones
    /// do not steal it, because a stream that is already running should not be
    /// interrupted by opening a window to look something up.
    mutating func windowAppeared(_ id: UUID) {
        guard liveIDs.contains(id) == false else { return }
        liveIDs.append(id)
        if ownerID == nil { ownerID = id }
    }

    /// A window went away. If it held the player, the oldest surviving window
    /// inherits it rather than leaving the session with nowhere to draw.
    mutating func windowDisappeared(_ id: UUID) {
        liveIDs.removeAll { $0 == id }
        guard ownerID == id else { return }
        ownerID = liveIDs.first
    }

    /// A deliberate "move the game here" from another window.
    mutating func takeOwnership(_ id: UUID) {
        guard liveIDs.contains(id) else { return }
        ownerID = id
    }

    func ownsPlayer(_ id: UUID) -> Bool {
        // A single window never has to ask. Ownership only becomes a question
        // once a second window exists.
        liveIDs.count <= 1 || ownerID == id
    }
}

@MainActor
@Observable
final class MobileSceneOwnership {
    private(set) var state = MobileSceneOwnershipState()

    func windowAppeared(_ id: UUID) { state.windowAppeared(id) }
    func windowDisappeared(_ id: UUID) { state.windowDisappeared(id) }
    func takeOwnership(_ id: UUID) { state.takeOwnership(id) }
    func ownsPlayer(_ id: UUID) -> Bool { state.ownsPlayer(id) }
    var hasMultipleWindows: Bool { state.liveIDs.count > 1 }
}
