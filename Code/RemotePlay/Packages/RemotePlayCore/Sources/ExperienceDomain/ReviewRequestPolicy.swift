import Foundation

/// Local pacing for a system review request; never a promise that a prompt appeared.
public struct ReviewRequestPolicy: Codable, Equatable, Sendable {
    public private(set) var launches = 0
    public private(set) var completedSessions = 0
    public private(set) var lastRequestedVersion: String?
    public private(set) var lastRequestedAt: Date?

    public init() {}

    public mutating func recordLaunch() { launches += 1 }

    public mutating func recordCompletedSession(duration: TimeInterval) {
        guard duration.isFinite, duration >= 300 else { return }
        completedSessions += 1
    }

    public func canRequest(version: String, now: Date) -> Bool {
        guard !version.isEmpty, launches >= 3, completedSessions >= 2,
              lastRequestedVersion != version else { return false }
        if let lastRequestedAt, now.timeIntervalSince(lastRequestedAt) < 120 * 86_400 {
            return false
        }
        return true
    }

    public mutating func recordRequest(version: String, now: Date) {
        lastRequestedVersion = version
        lastRequestedAt = now
    }
}
