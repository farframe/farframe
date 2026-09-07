import Foundation

/// Queues one post-pairing connection until the pairing presentation has
/// fully dismissed. This prevents native session startup underneath a sheet.
struct MobilePairingConnectHandoff: Equatable {
    private(set) var pendingConsoleID: UUID?

    mutating func pairingCompleted(consoleID: UUID) {
        pendingConsoleID = consoleID
    }

    mutating func pairingSheetDismissed() -> UUID? {
        defer { pendingConsoleID = nil }
        return pendingConsoleID
    }
}
