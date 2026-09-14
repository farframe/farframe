import ExperienceDomain
import StoreKit
import SwiftUI

/// Tracks an ordinary stream -> disconnect -> Home transition. Failed connection
/// attempts and background teardown never trigger a request on a later launch.
enum FarframeReviewSessionPhase: Equatable {
    case home, streaming, ending, other
}

@MainActor
private final class FarframeReviewHistory {
    static let shared = FarframeReviewHistory()
    private let key = "Farframe.reviewHistory.v1"
    private let store = UserDefaults.standard
    private var policy: ReviewRequestPolicy

    private init() {
        policy = store.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(ReviewRequestPolicy.self, from: $0) }
            ?? ReviewRequestPolicy()
        policy.recordLaunch()
        save()
    }

    func recordCompletion(duration: TimeInterval) {
        policy.recordCompletedSession(duration: duration)
        save()
    }

    func claimRequest() -> Bool {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let now = Date()
        guard policy.canRequest(version: version, now: now) else { return false }
        policy.recordRequest(version: version, now: now)
        save()
        return true
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(policy) else { return }
        store.set(data, forKey: key)
    }
}

private struct FarframeReviewPromptModifier: ViewModifier {
    let phase: FarframeReviewSessionPhase
    let unobstructed: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @State private var startedAt: ContinuousClock.Instant?
    @State private var endedDuration: Duration?
    @State private var pending = false

    private var ready: Bool {
        pending && phase == .home && unobstructed && scenePhase == .active
    }

    func body(content: Content) -> some View {
        content
            .task { _ = FarframeReviewHistory.shared }
            .onChange(of: phase) { previous, current in
                switch current {
                case .streaming:
                    startedAt = .now
                    endedDuration = nil
                    pending = false
                case .ending:
                    if previous == .streaming, let startedAt {
                        endedDuration = startedAt.duration(to: .now)
                    } else {
                        endedDuration = nil
                    }
                    startedAt = nil
                case .home:
                    if previous == .ending, let endedDuration {
                        let parts = endedDuration.components
                        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                        FarframeReviewHistory.shared.recordCompletion(duration: seconds)
                        pending = seconds >= 300 && scenePhase == .active && unobstructed
                    }
                    endedDuration = nil
                    startedAt = nil
                case .other:
                    startedAt = nil
                    endedDuration = nil
                    pending = false
                }
            }
            .onChange(of: scenePhase) { _, current in
                if current != .active { pending = false }
            }
            .task(id: ready) {
                guard ready else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard !Task.isCancelled, ready else { return }
                pending = false
                if FarframeReviewHistory.shared.claimRequest() { requestReview() }
            }
    }
}

extension View {
    func farframeReviewPrompt(phase: FarframeReviewSessionPhase, unobstructed: Bool) -> some View {
        modifier(FarframeReviewPromptModifier(phase: phase, unobstructed: unobstructed))
    }
}
