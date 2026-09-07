import SwiftUI
import UIKit

/// The one place UIKit scene plumbing and the SwiftUI app meet.
///
/// An external-display scene is created by UIKit from the Info.plist scene
/// manifest, not by SwiftUI, so its delegate cannot be handed the app's
/// coordinator through the environment, a preference, or an initialiser.
/// A single registered host is the narrowest bridge that works, and it is
/// deliberately the only global in the shell.
///
/// The routing object is created eagerly here rather than by the app, so a
/// display that connects before the first window has laid out still records
/// itself instead of dropping the connection on the floor.
@MainActor
@Observable
final class MobileBigScreenHost {
    static let shared = MobileBigScreenHost()

    let routing = MobileBigScreenRouting()
    private(set) var coordinator: MobileRemotePlayCoordinator?
    private(set) var startGate: MobileSessionStartGate?

    private init() {}

    func register(coordinator: MobileRemotePlayCoordinator, startGate: MobileSessionStartGate) {
        self.coordinator = coordinator
        self.startGate = startGate
    }
}

/// Presents the game full-bleed on a connected display while the device keeps
/// the controls and the telemetry.
///
/// The role is `windowExternalDisplayNonInteractive`, which UIKit documents as
/// the way to "present noninteractive content that supplements the interactive
/// content your app presents on the built-in screen" — Apple's own example for
/// it is a game showing its content on a connected display and its controls on
/// the device. Nothing here is touchable, so nothing here is a control.
@objc(FarframeBigScreenSceneDelegate)
final class MobileBigScreenSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard FarframeReleaseFeatures.externalDisplay,
              let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let host = UIHostingController(rootView: MobileBigScreenRootView())
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.backgroundColor = .black
        self.window = window
        window.makeKeyAndVisible()
        publishGeometry(of: windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        // The device player takes the picture back on the next layout pass.
        // The session itself is untouched: a display going away is a change of
        // where the game is drawn, never a reason to end it.
        MobileBigScreenHost.shared.routing.setConnectedDisplay(named: nil, pointSize: nil)
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        didUpdate previousCoordinateSpace: UICoordinateSpace,
        interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,
        traitCollection previousTraitCollection: UITraitCollection
    ) {
        publishGeometry(of: windowScene)
    }

    /// Reads the scene's own coordinate space rather than a `UIScreen`.
    /// Apple's desktop-class guidance is explicit that a scene, not a screen,
    /// is how an app should ask which display it is on, and `UIWindowScene`'s
    /// screen property is deprecated for exactly that reason.
    private func publishGeometry(of windowScene: UIWindowScene) {
        let size = windowScene.effectiveGeometry.coordinateSpace.bounds.size
        MobileBigScreenHost.shared.routing.setConnectedDisplay(
            named: MobileBigScreenRouting.defaultDisplayName,
            pointSize: size.width > 0 && size.height > 0 ? size : nil
        )
    }
}
