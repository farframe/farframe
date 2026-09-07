import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import RemotePlayMobile

/// Big Screen mode is wired through the Info.plist scene manifest and a class
/// looked up by name at runtime. None of that is checked by the compiler: a
/// renamed class, a dropped key or a typo would build clean, ship, and simply
/// never show anything when someone plugged in a television — with no error
/// anywhere. These tests are the compiler for that seam.
///
/// They run against the built app bundle, so they check what actually shipped
/// rather than what the source says.
@Suite("Big Screen scene wiring")
struct MobileBigScreenSceneWiringTests {
    private var sceneManifest: [String: Any]? {
        Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any]
    }

    @Test("The built app allows only the selected scene scope")
    func supportsSelectedSceneScope() throws {
        let manifest = try #require(sceneManifest, "No scene manifest in the built app")
        #expect(manifest["UIApplicationSupportsMultipleScenes"] as? Bool == FarframeReleaseFeatures.externalDisplay)
    }

    @Test("The built first-release app cannot register an external display")
    func externalDisplayIsNotRegistered() throws {
        let manifest = try #require(sceneManifest)
        let configurations = manifest["UISceneConfigurations"] as? [String: Any]
        #expect(configurations?["UIWindowSceneSessionRoleExternalDisplayNonInteractive"] == nil)
    }

    @Test("The deferred delegate retains its runtime identity for later development")
    func deferredDelegateClassResolves() throws {
        let resolved = try #require(NSClassFromString("FarframeBigScreenSceneDelegate"))
        #expect(resolved is UIWindowSceneDelegate.Type)
        #expect(ObjectIdentifier(resolved) == ObjectIdentifier(MobileBigScreenSceneDelegate.self))
    }

}

@Suite("Big Screen routing")
struct MobileBigScreenRoutingTests {
    @Test("The game only moves to a display that exists, is wanted, and has something to show")
    func destinationRules() {
        var state = MobileBigScreenState()
        #expect(state.destination == .device)

        state.sessionIsLive = true
        #expect(state.destination == .device, "No display connected")

        state.connectedDisplayName = "the connected display"
        #expect(state.destination == .bigScreen)

        state.preferenceIsEnabled = false
        #expect(state.destination == .device, "Turned off by the person")

        state.preferenceIsEnabled = true
        state.sessionIsLive = false
        #expect(state.destination == .device,
                "An idle window on a television must not take the surface from the device")
    }

    @Test("Every combination resolves, and only one surface is ever asked to draw")
    func destinationIsTotal() {
        for connected in [false, true] {
            for preference in [false, true] {
                for live in [false, true] {
                    let state = MobileBigScreenState(
                        connectedDisplayName: connected ? "d" : nil,
                        preferenceIsEnabled: preference,
                        sessionIsLive: live
                    )
                    let expected = connected && preference && live
                    #expect(state.bigScreenIsShowingVideo == expected)
                    #expect((state.destination == .device) == !expected)
                    // The device shows a substitute exactly when it is not
                    // showing the picture on a connected display.
                    #expect((state.deviceSubstituteTitle != nil) == expected)
                }
            }
        }
    }

    @Test("A connected display always says what it is doing")
    func idleMessages() {
        var state = MobileBigScreenState()
        #expect(state.externalIdleMessage == nil, "No display, nothing to say")

        state.connectedDisplayName = "the connected display"
        #expect(state.externalIdleMessage?.contains("Connect to your PS5") == true)

        state.preferenceIsEnabled = false
        #expect(state.externalIdleMessage?.contains("Big Screen is off") == true)

        state.preferenceIsEnabled = true
        state.sessionIsLive = true
        #expect(state.externalIdleMessage == nil, "The game is the message")
    }

    @Test("The device names the display it handed the picture to")
    func substituteTitle() {
        let state = MobileBigScreenState(
            connectedDisplayName: "the connected display",
            displayPointSize: CGSize(width: 1_920, height: 1_080),
            sessionIsLive: true
        )
        #expect(state.deviceSubstituteTitle == "Playing on the connected display")
        #expect(state.displaySizeDescription == "1920 × 1080 points")
    }

    @Test("Release scope ignores external display events and saved opt-in")
    @MainActor
    func releaseScopeKeepsVideoOnDevice() {
        let name = "FarframeReleaseDisplay-" + UUID().uuidString
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        suite.set(true, forKey: "RemotePlayMobile.bigScreenEnabled")
        let routing = MobileBigScreenRouting(defaults: suite)
        routing.setConnectedDisplay(named: "d", pointSize: CGSize(width: 3_840, height: 2_160))
        routing.setSessionIsLive(true)
        routing.preferenceIsEnabled = true
        #expect(!routing.preferenceIsEnabled)
        #expect(!routing.displayIsConnected)
        #expect(routing.state.displayPointSize == nil)
        #expect(routing.destination == .device)
        #expect(!MobileBigScreenRouting(defaults: suite).preferenceIsEnabled)
    }



}

@Suite("One window owns the player")
struct MobileSceneOwnershipTests {
    @Test("A single window never has to ask")
    func singleWindow() {
        var state = MobileSceneOwnershipState()
        let only = UUID()
        state.windowAppeared(only)
        #expect(state.ownsPlayer(only))
    }

    @Test("A second window does not interrupt a stream that is already running")
    func secondWindowDoesNotSteal() {
        var state = MobileSceneOwnershipState()
        let first = UUID()
        let second = UUID()
        state.windowAppeared(first)
        state.windowAppeared(second)
        #expect(state.ownsPlayer(first))
        #expect(!state.ownsPlayer(second))
    }

    @Test("Moving the game to another window is deliberate and complete")
    func takeOwnership() {
        var state = MobileSceneOwnershipState()
        let first = UUID()
        let second = UUID()
        state.windowAppeared(first)
        state.windowAppeared(second)
        state.takeOwnership(second)
        #expect(state.ownsPlayer(second))
        #expect(!state.ownsPlayer(first))
    }

    @Test("Closing the window that held the player leaves the game somewhere to draw")
    func ownerDisappears() {
        var state = MobileSceneOwnershipState()
        let first = UUID()
        let second = UUID()
        state.windowAppeared(first)
        state.windowAppeared(second)
        state.windowDisappeared(first)
        #expect(state.ownsPlayer(second))

        state.windowDisappeared(second)
        // Nothing left to own it, and nothing left to ask.
        #expect(state.ownsPlayer(UUID()))
    }

    @Test("A window that never appeared cannot take the player")
    func unknownWindowCannotTake() {
        var state = MobileSceneOwnershipState()
        let first = UUID()
        let second = UUID()
        state.windowAppeared(first)
        state.windowAppeared(second)
        state.takeOwnership(UUID())
        #expect(state.ownsPlayer(first))
    }

    @Test("Appearing twice does not make one window two")
    func repeatedAppearance() {
        var state = MobileSceneOwnershipState()
        let only = UUID()
        state.windowAppeared(only)
        state.windowAppeared(only)
        state.windowDisappeared(only)
        #expect(state.liveIDs.isEmpty)
    }
}

@Suite("Swipe camera")
struct MobileTouchCameraPadTests {
    private let start = ContinuousClock.now

    @Test("Deflection follows how fast the finger is moving, not where it started")
    func velocityDrivesDeflection() {
        var pad = MobileTouchCameraPad()
        pad.begin(at: CGPoint(x: 500, y: 500), instant: start)
        // Half the speed that means full deflection, over one frame.
        let half = MobileTouchCameraPad.fullDeflectionPointsPerSecond / 2
        let frame = Duration.milliseconds(10)
        pad.move(to: CGPoint(x: 500 + half * 0.01, y: 500), instant: start + frame)

        let vector = pad.vector(at: start + frame, sensitivity: 1)
        #expect(abs(vector.x - 0.5) < 0.02)
        #expect(abs(vector.y) < 0.001)

        // Starting the same gesture a thousand points to the left changes
        // nothing, which is the whole difference from a stick.
        var elsewhere = MobileTouchCameraPad()
        elsewhere.begin(at: CGPoint(x: 20, y: 500), instant: start)
        elsewhere.move(to: CGPoint(x: 20 + half * 0.01, y: 500), instant: start + frame)
        let other = elsewhere.vector(at: start + frame, sensitivity: 1)
        #expect(abs(other.x - vector.x) < 0.001)
    }

    @Test("Up on the screen is up on the stick")
    func verticalSignMatchesTheDrawnStick() {
        var pad = MobileTouchCameraPad()
        pad.begin(at: CGPoint(x: 500, y: 500), instant: start)
        pad.move(to: CGPoint(x: 500, y: 400), instant: start + .milliseconds(10))
        let vector = pad.vector(at: start + .milliseconds(10), sensitivity: 1)
        #expect(vector.y > 0, "Dragging toward the top of the screen looks up")
    }

    @Test("A flick cannot ask for more than a stick can give")
    func magnitudeIsClamped() {
        var pad = MobileTouchCameraPad()
        pad.begin(at: .zero, instant: start)
        pad.move(to: CGPoint(x: 900, y: 900), instant: start + .milliseconds(4))
        let vector = pad.vector(at: start + .milliseconds(4), sensitivity: 1.2)
        let magnitude = (vector.x * vector.x + vector.y * vector.y).squareRoot()
        #expect(magnitude <= 1.0001)
        #expect(magnitude > 0.99, "A hard flick should still saturate")
    }

    @Test("A finger that stops moving stops the camera")
    func idleFingerStopsTheCamera() {
        var pad = MobileTouchCameraPad()
        pad.begin(at: CGPoint(x: 500, y: 500), instant: start)
        let moved = start + .milliseconds(10)
        pad.move(to: CGPoint(x: 600, y: 500), instant: moved)
        #expect(pad.vector(at: moved, sensitivity: 1).x > 0)

        // Still turning one frame later, so a gap between touch samples does
        // not stutter.
        #expect(pad.vector(at: moved + .milliseconds(16), sensitivity: 1).x > 0)

        // Stopped by the time the movement is stale. Without this the last
        // deflection would stay applied and the camera would spin forever
        // under a motionless thumb.
        let stale = moved + MobileTouchCameraPad.idleCutoff + .milliseconds(1)
        let stopped = pad.vector(at: stale, sensitivity: 1)
        #expect(stopped.x == 0 && stopped.y == 0)
    }

    @Test("Lifting the finger releases the camera immediately")
    func endReleases() {
        var pad = MobileTouchCameraPad()
        pad.begin(at: .zero, instant: start)
        pad.move(to: CGPoint(x: 200, y: 0), instant: start + .milliseconds(10))
        pad.end()
        #expect(!pad.isTracking)
        let vector = pad.vector(at: start + .milliseconds(10), sensitivity: 1)
        #expect(vector.x == 0 && vector.y == 0)
    }

    @Test("Sensitivity scales the camera and stays inside the slider's range")
    func sensitivityIsBounded() {
        func deflection(sensitivity: Double) -> Float {
            var pad = MobileTouchCameraPad()
            pad.begin(at: .zero, instant: start)
            pad.move(to: CGPoint(x: 3, y: 0), instant: start + .milliseconds(10))
            return pad.vector(at: start + .milliseconds(10), sensitivity: sensitivity).x
        }
        #expect(deflection(sensitivity: 1.2) > deflection(sensitivity: 0.4))
        // The slider runs 0.4 to 1.2; values outside it clamp rather than
        // producing a camera nobody could aim.
        #expect(deflection(sensitivity: 40) == deflection(sensitivity: 1.2))
        #expect(deflection(sensitivity: 0) == deflection(sensitivity: 0.4))
    }

    @Test("Two samples at the same instant do not divide by zero")
    func simultaneousSamples() {
        var pad = MobileTouchCameraPad()
        pad.begin(at: .zero, instant: start)
        pad.move(to: CGPoint(x: 40, y: 40), instant: start)
        let vector = pad.vector(at: start, sensitivity: 1)
        #expect(vector.x.isFinite && vector.y.isFinite)
    }

    @Test("The swipe surface is only offered where there is picture to swipe on")
    func availability() {
        typealias Overlay = MobileTouchControllerOverlay
        #expect(Overlay.cameraPadIsAvailable(
            cameraControl: .swipe, preset: .play, layout: .expanded, presentation: .standard
        ))
        #expect(Overlay.cameraPadIsAvailable(
            cameraControl: .swipe, preset: .full, layout: .wide, presentation: .standard
        ))
        // Off by default, and off is off.
        #expect(!Overlay.cameraPadIsAvailable(
            cameraControl: .stick, preset: .play, layout: .expanded, presentation: .standard
        ))
        // Menus-only promises a small pad, not a camera.
        #expect(!Overlay.cameraPadIsAvailable(
            cameraControl: .swipe, preset: .navigate, layout: .expanded, presentation: .standard
        ))
        // A bottom strip in portrait is not the picture's to take touches from.
        #expect(!Overlay.cameraPadIsAvailable(
            cameraControl: .swipe, preset: .play, layout: .compact, presentation: .standard
        ))
        #expect(!Overlay.cameraPadIsAvailable(
            cameraControl: .swipe, preset: .play, layout: .wide, presentation: .compactRow
        ))
    }
}
