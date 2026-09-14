import Foundation

/// Pure transition state; UI tasks and renderer callbacks carry the exact
/// session plus attempt token. It has no transport or entitlement authority.
struct VisionArenaPresentationRoute: Equatable {
    struct Ticket: Equatable, Sendable {
        let sessionID: UUID
        let attemptID: UUID
    }

    enum Phase: Equatable {
        case flat
        case entering(Ticket)
        case immersive(Ticket)
        case returning(Ticket)
    }

    private(set) var phase: Phase = .flat
    private(set) var flatRevision: UInt64 = 0

    var flatOwnsLifecycle: Bool { phase == .flat }
    var shouldRenderFlat: Bool {
        if case .immersive = phase { return false }
        return true
    }
    var ticket: Ticket? {
        switch phase {
        case .flat: nil
        case .entering(let ticket), .immersive(let ticket), .returning(let ticket): ticket
        }
    }

    mutating func begin(sessionID: UUID) -> Ticket? {
        guard phase == .flat else { return nil }
        let ticket = Ticket(sessionID: sessionID, attemptID: UUID())
        phase = .entering(ticket)
        return ticket
    }

    mutating func rendererAttached(_ ticket: Ticket, activeSessionID: UUID?) -> Bool {
        guard activeSessionID == ticket.sessionID, phase == .entering(ticket) else { return false }
        phase = .immersive(ticket)
        return true
    }

    /// Recreate the flat layer even after failed entry: an attachment may have
    /// completed while the system was cancelling the space opening.
    mutating func beginReturn(_ ticket: Ticket, activeSessionID: UUID?) -> Bool {
        guard activeSessionID == ticket.sessionID, self.ticket == ticket else { return false }
        if phase != .returning(ticket) {
            flatRevision &+= 1
            phase = .returning(ticket)
        }
        return true
    }

    mutating func flatAttached(sessionID: UUID, revision: UInt64) -> Bool {
        guard case .returning(let ticket) = phase,
              ticket.sessionID == sessionID, revision == flatRevision else { return false }
        phase = .flat
        return true
    }

    /// If a replacement cannot show an image, the existing room is still a
    /// safe destination. A late ready callback from that window must be ignored.
    mutating func cancelReturn(_ ticket: Ticket, activeSessionID: UUID?) -> Bool {
        guard activeSessionID == ticket.sessionID, phase == .returning(ticket) else { return false }
        phase = .immersive(ticket)
        return true
    }

    mutating func invalidate() {
        phase = .flat
        flatRevision &+= 1
    }
}
