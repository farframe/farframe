import Foundation
import Testing
@testable import ExperienceDomain

struct ReviewRequestPolicyTests {
    private func eligiblePolicy() -> ReviewRequestPolicy {
        var policy = ReviewRequestPolicy()
        for _ in 0..<3 { policy.recordLaunch() }
        for _ in 0..<2 { policy.recordCompletedSession(duration: 300) }
        return policy
    }

    @Test func noFirstLaunchOrBriefSessionRequest() {
        var policy = ReviewRequestPolicy()
        policy.recordLaunch()
        policy.recordCompletedSession(duration: 600)
        #expect(!policy.canRequest(version: "1.2", now: .now))
        for _ in 0..<3 { policy.recordLaunch() }
        for duration in [-1.0, 0, 299, .nan, .infinity] {
            policy.recordCompletedSession(duration: duration)
        }
        #expect(policy.completedSessions == 1)
        #expect(!policy.canRequest(version: "1.2", now: .now))
    }

    @Test func versionAndCooldownBothApply() {
        var policy = eligiblePolicy()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(policy.canRequest(version: "1.2", now: date))
        #expect(!policy.canRequest(version: "", now: date))
        policy.recordRequest(version: "1.2", now: date)
        #expect(!policy.canRequest(version: "1.2", now: date.addingTimeInterval(365 * 86_400)))
        #expect(!policy.canRequest(version: "1.3", now: date.addingTimeInterval(119 * 86_400)))
        #expect(!policy.canRequest(version: "1.3", now: date.addingTimeInterval(-1)))
        #expect(policy.canRequest(version: "1.3", now: date.addingTimeInterval(120 * 86_400)))
    }

    @Test func historySurvivesRelaunch() throws {
        var policy = eligiblePolicy()
        policy.recordRequest(version: "1.2", now: .now)
        let restored = try JSONDecoder().decode(ReviewRequestPolicy.self, from: JSONEncoder().encode(policy))
        #expect(restored == policy)
        #expect(!restored.canRequest(version: "1.2", now: .now))
    }
}
