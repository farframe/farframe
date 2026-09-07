import XCTest

/// Can a finger reach the session shortcuts?
///
/// This is the one question about the player that no value type can answer.
/// `MobilePlayerCanvasGeometry` can prove the shortcut strip is placed inside
/// the safe area at the top of the canvas, and a test of it will pass happily
/// while every control in that strip is unreachable, because the strip's size
/// and the size of the controls drawn into it are two different numbers.
///
/// That is exactly what happened. The strip was 44 points tall and asserted to
/// be; the buttons inside it answered to about fourteen. A player aiming at the
/// pill he could see missed it, the miss landed on the picture, the picture
/// re-lit the HUD, and all four shortcuts looked dead — including the only way
/// out of a session.
///
/// So the coverage here is never "the control exists". It is how big the
/// control is, and what happened after it was tapped.
final class MobilePlayerChromeUITests: XCTestCase {
    /// Apple's minimum touch target, and the size the shortcuts must never
    /// again fall below.
    private static let minimumTarget: CGFloat = 44

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The player does not run on a bare canvas in the shipping app. It runs
    /// inside the `TabView` whose iPad tab bar occupies the same strip of
    /// screen as these shortcuts, so `hosted` is the configuration that
    /// matters and `hosted: false` is the control.
    private func launchPreview(
        hosted: Bool = true,
        autoHide: Bool = false,
        landscape: Bool = true,
        videoSurface: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--farframe-player-preview"]
        if hosted { app.launchArguments.append("--farframe-preview-hosted") }
        if videoSurface { app.launchArguments.append("--farframe-preview-video-surface") }
        if !autoHide {
            app.launchArguments += ["-farframePreviewAutoHideChrome", "NO"]
        }
        app.launch()
        if landscape { XCUIDevice.shared.orientation = .landscapeLeft }
        return app
    }

    private func shortcut(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let element = app.buttons[name]
        if !element.waitForExistence(timeout: 20) {
            // What is on screen instead is the whole question when a control
            // goes missing, and it is not recoverable after the fact.
            XCTFail("\(name) was never drawn. On screen:\n\(app.debugDescription)")
        }
        settle(element)
        return element
    }

    /// Wait until a control has stopped moving.
    ///
    /// The HUD arrives and leaves with an animation, and a synthetic tap
    /// computed against a frame that is still in flight lands next to the
    /// control rather than on it. A person does not tap a moving target
    /// either, so waiting is the honest thing to measure.
    private func settle(_ element: XCUIElement, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = element.frame
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            let current = element.frame
            if current == previous { return }
            previous = current
        }
    }

    // MARK: - The regression

    /// The bug, as a number.
    ///
    /// Every shortcut is measured in the orientation and on the canvas the
    /// owner plays on. Before the fix, three of the four reported a 14.5-point
    /// height here and the fourth reported 32.
    func testEverySessionShortcutMeetsTheMinimumTouchTarget() {
        let app = launchPreview()
        for name in ["PS Home", "Stream health: Measuring", "End session", "Session"] {
            let frame = shortcut(app, name).frame
            XCTAssertGreaterThanOrEqual(
                frame.height, Self.minimumTarget,
                "\(name) is \(frame.height) points tall; a finger needs \(Self.minimumTarget)"
            )
            XCTAssertGreaterThanOrEqual(
                frame.width, Self.minimumTarget,
                "\(name) is \(frame.width) points wide; a finger needs \(Self.minimumTarget)"
            )
        }
    }

    /// The drawn pill and the control that answers must be the same object.
    ///
    /// A tap eight points off centre used to do nothing at all, because the
    /// glass capsule was larger than the button underneath it. Aiming anywhere
    /// within a 44-point target is aiming at the control.
    func testATapAwayFromTheExactCentreStillCounts() {
        let app = launchPreview()
        let session = shortcut(app, "Session")
        session.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: 14))
            .tap()
        XCTAssertTrue(
            app.navigationBars["Layout preview"].waitForExistence(timeout: 10),
            "A tap inside the drawn pill but away from its centre did nothing"
        )
    }

    /// The other thing that was over the chrome.
    ///
    /// The player asks for the tab bar to be hidden, and on iPad it was not:
    /// `toolbar(.hidden, for: .tabBar)` is silently a no-op against iPadOS 26's
    /// top tab bar, so a Play/Settings bar floated in the same strip of screen
    /// as the shortcuts. Tapping End opened the tab sidebar instead of ending
    /// the session, which is how this was found.
    /// Asserts no overlap rather than no tab UI.
    ///
    /// In landscape the `sidebarAdaptable` style shows a sidebar beside the
    /// player, and no modifier available to the player hides it — that is an
    /// open defect belonging to the tab shell, recorded in the evidence note.
    /// What the player can and must guarantee is that nothing belonging to the
    /// tab UI sits on top of a session shortcut, which is what the old
    /// `toolbar(.hidden, for: .tabBar)` failed to deliver and what a tap on End
    /// used to prove by opening the sidebar instead.
    func testNoTabControlOverlapsTheSessionShortcuts() {
        let app = launchPreview()
        let shortcuts = ["PS Home", "Stream health: Measuring", "End session", "Session"]
            .map { shortcut(app, $0).frame }
        for name in ["ToggleSidebar", "Play", "Settings"] {
            for candidate in [app.buttons[name], app.cells[name]] where candidate.exists {
                let frame = candidate.frame
                for target in shortcuts {
                    XCTAssertFalse(
                        frame.intersects(target),
                        "\(name) at \(frame) is over a session shortcut at \(target)"
                    )
                }
            }
        }
    }

    // MARK: - The shortcuts do something

    private func assertSessionOpens(_ app: XCUIApplication, _ message: String) {
        let session = shortcut(app, "Session")
        XCTAssertTrue(session.isHittable, "\(message): Session is drawn but not hittable")
        session.tap()
        XCTAssertTrue(
            app.navigationBars["Layout preview"].waitForExistence(timeout: 10),
            "\(message): tapping Session did nothing"
        )
    }

    /// End is the way out of a session. Whether it answers is the difference
    /// between a player who can leave and a player who has to force-quit.
    ///
    /// This is also the test that rejected `Menu` for this control. A `Menu`
    /// will not take a `contentShape`, so End kept answering to the size of the
    /// word "End" while measuring 44 points, and a tap on the pill fell through
    /// to the picture and merely put the HUD away.
    private func assertEndOffersAWayOut(_ app: XCUIApplication, _ message: String) {
        let end = shortcut(app, "End session")
        XCTAssertTrue(end.isHittable, "\(message): End is drawn but not hittable")
        end.tap()
        XCTAssertTrue(
            app.buttons["Disconnect, leave PS5 awake"].waitForExistence(timeout: 10),
            "\(message): tapping End did nothing"
        )
    }

    func testShortcutsWorkInsideTheAppShell() {
        let app = launchPreview()
        assertSessionOpens(app, "Inside the tab shell")
    }

    func testEndWorksInsideTheAppShell() {
        let app = launchPreview()
        assertEndOffersAWayOut(app, "Inside the tab shell")
    }

    func testShortcutsWorkOnTheBarePlayerCanvas() {
        let app = launchPreview(hosted: false)
        assertSessionOpens(app, "Bare canvas")
    }

    /// The harness's one meaningful lie, closed. A live session draws into a
    /// real UIKit view, which accepts touches whether or not anything is
    /// listening to them; a SwiftUI `Canvas` does not.
    func testEndWorksOverALiveVideoSurface() {
        let app = launchPreview(videoSurface: true)
        assertEndOffersAWayOut(app, "Over the video surface")
    }

    // MARK: - Showing and hiding, and always having a way out

    /// Tap the picture to put the shortcuts away, tap again to bring them back.
    func testTappingThePictureShowsAndHidesTheShortcuts() {
        let app = launchPreview()
        let end = shortcut(app, "End session")
        let picture = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))

        picture.tap()
        XCTAssertTrue(
            app.buttons["Show session shortcuts"].waitForExistence(timeout: 10),
            "Tapping the picture did not put the shortcuts away"
        )
        XCTAssertFalse(end.exists, "The shortcuts stayed up after being put away")

        picture.tap()
        XCTAssertTrue(
            end.waitForExistence(timeout: 10),
            "Tapping the picture again did not bring the shortcuts back"
        )
    }

    /// The guarantee. However the shortcuts came to be put away — a tap, or the
    /// four-second idle — a player who does not know the gesture must still be
    /// able to reach End. The collapsed HUD is that promise, and this is it
    /// being kept in the layout and orientation the owner was trapped in.
    func testACollapsedHUDStillLeadsToTheWayOutOfASession() {
        let app = launchPreview(autoHide: true)
        let handle = app.buttons["Show session shortcuts"]
        XCTAssertTrue(
            handle.waitForExistence(timeout: 25),
            "Nothing was left on screen after the shortcuts idled away"
        )
        settle(handle)
        XCTAssertGreaterThanOrEqual(handle.frame.height, Self.minimumTarget)
        XCTAssertGreaterThanOrEqual(handle.frame.width, Self.minimumTarget)
        handle.tap()
        assertEndOffersAWayOut(app, "After expanding the collapsed HUD")
    }

    /// The same promise in portrait, where the gamepad deck takes the bottom of
    /// the screen and the picture is only a band across the middle.
    func testACollapsedHUDStillLeadsToTheWayOutInPortrait() {
        let app = launchPreview(autoHide: true, landscape: false)
        let handle = app.buttons["Show session shortcuts"]
        XCTAssertTrue(handle.waitForExistence(timeout: 25))
        settle(handle)
        handle.tap()
        assertEndOffersAWayOut(app, "Portrait, after expanding the collapsed HUD")
    }
}
