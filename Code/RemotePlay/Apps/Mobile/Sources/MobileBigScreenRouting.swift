import CoreGraphics
import Foundation

/// Where the single decoded video surface is drawn.
///
/// The presenter holds exactly one display backend at a time
/// (`BoundedSampleBufferVideoPresenter.replaceBackend`), so this is a choice,
/// never a mirror. That constraint points at the better design anyway: the
/// external display shows the game and nothing else, and the device keeps the
/// controls, the telemetry and the session actions.
enum MobileVideoDestination: String, Equatable, Sendable {
    /// The video is drawn in the app's own window, as it always has been.
    case device
    /// The video is drawn full-bleed on a connected external display.
    case bigScreen
}

/// The whole Big Screen decision, as a value.
///
/// Deliberately free of SwiftUI, UIKit and any Apple display API so the rule
/// can be exercised without a display, a scene or a simulator, and so a future
/// platform shell can reuse the rule rather than re-deriving it. The observable
/// wrapper below is the only part that knows about scenes.
struct MobileBigScreenState: Equatable, Sendable {
    /// A non-interactive external-display scene is connected, and this is the
    /// name the person would recognise for it.
    var connectedDisplayName: String?
    /// The connected display's size in points, when the scene has reported one.
    var displayPointSize: CGSize?
    /// The person's preference. On by default: plugging a console stream into
    /// a television and then having to go and find a switch is the wrong way
    /// round.
    var preferenceIsEnabled = true
    /// A session is streaming, or is preparing to.
    var sessionIsLive = false

    var displayIsConnected: Bool { connectedDisplayName != nil }

    /// A plain description of the display, for the panel that replaces the
    /// picture on the device. Points, because that is what the scene reports
    /// and what the layout actually uses.
    var displaySizeDescription: String? {
        guard let displayPointSize else { return nil }
        return "\(Int(displayPointSize.width.rounded())) × \(Int(displayPointSize.height.rounded())) points"
    }

    /// Big Screen only claims the video while there is video to claim. Without
    /// this the device player would give up its surface to an idle window on a
    /// television and the person would be looking at two blank screens.
    var destination: MobileVideoDestination {
        displayIsConnected && preferenceIsEnabled && sessionIsLive ? .bigScreen : .device
    }

    var bigScreenIsShowingVideo: Bool { destination == .bigScreen }

    /// What the external window says when it is not showing the game. The
    /// external display is non-interactive, so this is the only way it can
    /// explain itself.
    var externalIdleMessage: String? {
        guard displayIsConnected else { return nil }
        if preferenceIsEnabled == false {
            return "Big Screen is off. Turn it on under Session to move the game here."
        }
        return sessionIsLive ? nil : "Connect to your PS5 to play here."
    }

    /// What the device says in place of the picture while the game is elsewhere.
    var deviceSubstituteTitle: String? {
        guard bigScreenIsShowingVideo, let connectedDisplayName else { return nil }
        return "Playing on \(connectedDisplayName)"
    }
}

/// The live Big Screen state, owned by the app and read by both the in-app
/// player and the external-display window.
@MainActor
@Observable
final class MobileBigScreenRouting {
    private enum PreferenceKey {
        static let bigScreen = "RemotePlayMobile.bigScreenEnabled"
    }

    /// A display has no name an app is allowed to read, so it gets an honest
    /// generic one rather than a guess at "TV" or a model number.
    static let defaultDisplayName = "the connected display"

    private let defaults: UserDefaults
    private(set) var state: MobileBigScreenState

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var state = MobileBigScreenState()
        if defaults.object(forKey: PreferenceKey.bigScreen) != nil {
            state.preferenceIsEnabled = defaults.bool(forKey: PreferenceKey.bigScreen)
        }
        state.preferenceIsEnabled = FarframeReleaseFeatures.externalDisplay && state.preferenceIsEnabled
        self.state = state
    }

    var destination: MobileVideoDestination { state.destination }
    var displayIsConnected: Bool { state.displayIsConnected }
    var connectedDisplayName: String? { state.connectedDisplayName }

    var preferenceIsEnabled: Bool {
        get { state.preferenceIsEnabled }
        set {
            guard state.preferenceIsEnabled != newValue else { return }
            state.preferenceIsEnabled = FarframeReleaseFeatures.externalDisplay && newValue
            defaults.set(newValue, forKey: PreferenceKey.bigScreen)
        }
    }

    /// Called by the external-display scene delegate on connect, on geometry
    /// change, and on disconnect.
    func setConnectedDisplay(named name: String?, pointSize: CGSize?) {
        guard state.connectedDisplayName != name || state.displayPointSize != pointSize else {
            return
        }
        guard FarframeReleaseFeatures.externalDisplay else { return }
        state.connectedDisplayName = name
        state.displayPointSize = name == nil ? nil : pointSize
    }

    /// Called by the player as the session phase changes. "Live" includes
    /// preparing, because the very first surface attachment is what releases a
    /// prepared session, and on a connected display that attachment belongs to
    /// the external window.
    func setSessionIsLive(_ isLive: Bool) {
        guard state.sessionIsLive != isLive else { return }
        state.sessionIsLive = isLive
    }
}
