import FarframeStorefront
import Foundation

/// The last boundary before native transport starts.
///
/// A prepared session is released by the *first* display surface that queues an
/// attachment, and entitlement is revalidated at that exact moment to close the
/// trial-expiry and refund race that can open while asynchronous preparation is
/// building its media surface.
///
/// This used to live inside the root view, which was fine while the app had one
/// window and one place to draw. Big Screen mode means the first surface to
/// queue can belong to an external-display window that the root view does not
/// own and cannot reach. The rule moved here rather than being written a second
/// time, so there is still exactly one revalidation path.
///
/// A denial is published rather than presented: the paywall belongs to the
/// in-app window, and this object has no view of its own.
@MainActor
@Observable
final class MobileSessionStartGate {
    private let coordinator: MobileRemotePlayCoordinator
    private let accessStore: FarframeAccessStore

    /// Set when revalidation refused a prepared session, so the window that
    /// owns the paywall can offer the purchase. Cleared by `acknowledgeDenial`.
    private(set) var deniedConsoleID: UUID?

    init(coordinator: MobileRemotePlayCoordinator, accessStore: FarframeAccessStore) {
        self.coordinator = coordinator
        self.accessStore = accessStore
    }

    /// A display host calls this only after it has synchronously queued its
    /// surface attachment, whichever screen that host draws on.
    func surfaceQueued(sessionID: UUID) {
        Task {
            guard let authorization = coordinator.surfaceWasQueued(sessionID: sessionID) else {
                return
            }
            await resolve(authorization)
        }
    }

    /// Foreground handling: a session whose start was deferred while the app
    /// was not active resolves here instead of silently staying prepared.
    func applicationDidBecomeActive() async {
        if let authorization = await coordinator.applicationDidBecomeActive() {
            await resolve(authorization)
        } else {
            await accessStore.refresh()
        }
    }

    func acknowledgeDenial() { deniedConsoleID = nil }

    private func resolve(_ authorization: MobilePreparedSessionStartAuthorization) async {
        let isAuthorized = await accessStore.revalidateConnectionStart()
        let resolution = await coordinator.resolvePreparedSessionStart(
            authorization,
            isAuthorized: isAuthorized
        )
        guard case let .denied(consoleID) = resolution else { return }
        deniedConsoleID = consoleID
    }
}
