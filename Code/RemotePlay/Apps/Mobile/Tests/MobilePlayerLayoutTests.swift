import SwiftUI
import Testing
@testable import RemotePlayMobile

@Suite("Mobile video-first canvas")
struct MobilePlayerLayoutTests {
    @Test("Idle chrome hides, tap reveals, and accessibility can keep it available")
    func chromeVisibility() {
        var chrome = MobilePlayerChromeState()
        #expect(chrome.isVisible)
        chrome.idleElapsed(autoHide: true, voiceOver: false)
        #expect(!chrome.isVisible)
        chrome.toggle(voiceOver: false)
        #expect(chrome.isVisible)
        chrome.idleElapsed(autoHide: false, voiceOver: false)
        #expect(chrome.isVisible)
        chrome.idleElapsed(autoHide: true, voiceOver: true)
        #expect(chrome.isVisible)
    }

    @Test("Tapping the picture shows the shortcuts and tapping again puts them away")
    func chromeToggles() {
        var chrome = MobilePlayerChromeState()
        chrome.toggle(voiceOver: false)
        #expect(!chrome.isVisible)
        chrome.toggle(voiceOver: false)
        #expect(chrome.isVisible)
        // A control that is not drawn is not in the accessibility tree, so the
        // gesture that would remove the only exit from a session is refused.
        chrome.toggle(voiceOver: true)
        #expect(chrome.isVisible)
    }

    @Test("Fit preserves, Fill crops, and Stretch uses both full screen dimensions")
    func pictureModes() {
        let bounds = CGSize(width: 932, height: 430)
        let fit = MobileVideoContentMode.fit.pictureSize(in: bounds)
        let fill = MobileVideoContentMode.fill.pictureSize(in: bounds)
        #expect(abs(fit.width / fit.height - 16.0 / 9) < 0.001)
        #expect(fit.width < bounds.width && fit.height == bounds.height)
        #expect(fill.width == bounds.width && fill.height > bounds.height)
        #expect(MobileVideoContentMode.stretch.pictureSize(in: bounds) == bounds)
        #expect(MobileVideoContentMode.fit.videoGravity == .resizeAspect)
        #expect(MobileVideoContentMode.fill.videoGravity == .resizeAspectFill)
        #expect(MobileVideoContentMode.stretch.videoGravity == .resize)
    }

    @Test("Classic arrangement is optional and keeps the established control sizes")
    func classicArrangement() {
        #expect(!MobileTouchThumbLayout.edgeSticks.sticksAreInside)
        #expect(MobileTouchThumbLayout.classic.sticksAreInside)
        #expect(MobileTouchControlMetrics.target >= 44)
        #expect(MobileTouchControlMetrics.stick(wide: true) == 104)
    }

    @Test("Accessibility actions keep 44-point targets without shrinking video")
    @MainActor
    func accessibilityActions() {
        for size in [DynamicTypeSize.accessibility1, .accessibility2, .accessibility3,
                     .accessibility4, .accessibility5] {
            #expect(MobilePlayerQuickActions.usesSymbolsOnly(for: size))
        }
        for size in [DynamicTypeSize.small, .large, .xxxLarge] {
            #expect(!MobilePlayerQuickActions.usesSymbolsOnly(for: size))
        }
        let canvas = CGSize(width: 844, height: 390)
        let geometry = MobilePlayerCanvasGeometry.resolve(size: canvas,
            insets: EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59), touchVisible: true)
        #expect(MobilePlayerQuickActions.accessibleTargetSize >= 44)
        #expect(geometry.actions.height >= MobilePlayerQuickActions.accessibleTargetSize)
        #expect(geometry.actions.width >= 2 * MobilePlayerQuickActions.accessibleTargetSize + 8)
        #expect(geometry.video == CGRect(origin: .zero, size: canvas))
    }

    @Test("Landscape uses the whole canvas, independent of controller visibility",
          arguments: [CGSize(width: 932, height: 430), CGSize(width: 844, height: 390), CGSize(width: 1194, height: 834)])
    func landscapeVideo(_ size: CGSize) {
        for visible in [true, false] {
            let geometry = MobilePlayerCanvasGeometry.resolve(size: size,
                insets: EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59), touchVisible: visible)
            #expect(geometry.video == CGRect(origin: .zero, size: size))
            #expect(geometry.actions.minX >= 59)
            #expect(geometry.actions.maxX <= size.width - 59)
            #expect(geometry.controls.minY > geometry.actions.maxY)
            #expect(geometry.controls.maxY <= size.height - 21)
        }
    }

    /// What a person actually sees in the default picture mode: the frame is
    /// the whole region, and Fit letterboxes a 16:9 picture inside it.
    private func visiblePicture(_ geometry: MobilePlayerCanvasGeometry) -> CGSize {
        MobileVideoContentMode.fit.pictureSize(in: geometry.video.size)
    }

    @Test("Portrait keeps game above a separate reachable control deck",
          arguments: [CGSize(width: 390, height: 844), CGSize(width: 430, height: 932), CGSize(width: 834, height: 1194)])
    func portraitDeck(_ size: CGSize) {
        let geometry = MobilePlayerCanvasGeometry.resolve(size: size,
            insets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0), touchVisible: true)
        // The frame may extend into the deck's reserve for the controller
        // tray, which is empty while the tray is closed. It must never reach
        // the controls as they actually rest.
        #expect(geometry.video.maxY <= geometry.restingControlsTop + 0.001)
        #expect(geometry.video.minY > geometry.actions.maxY)
        #expect(geometry.controls.maxY <= size.height - 34)
        // Full-bleed: the picture is the one thing allowed under the insets.
        #expect(geometry.video.width == size.width)
        let policy = MobileTouchGeometryPolicy.resolve(size: geometry.controls.size,
            wide: false, navigationOnly: false, secondaryVisible: false, includesMore: true)
        #expect(policy.presentation != .unavailable)
    }

    @Test("Portrait hands its unavoidable surplus to the picture mode instead of leaving a void",
          arguments: [CGSize(width: 430, height: 932), CGSize(width: 390, height: 844),
                      CGSize(width: 440, height: 956)])
    func portraitSurplusIsUsable(_ size: CGSize) {
        let geometry = MobilePlayerCanvasGeometry.resolve(
            size: size, insets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
            touchVisible: true
        )
        // A 16:9 stream in a tall window cannot be made taller than its width
        // allows, so Fit is exactly a full-width band and nothing can change
        // that. It is the default and it is unchanged in kind.
        let fit = visiblePicture(geometry)
        #expect(abs(fit.width - size.width) < 0.001)
        #expect(abs(fit.height - size.width * 9 / 16) < 0.001)

        // The surplus is real, and it now belongs to the frame rather than to
        // black bars the person cannot do anything about. Fill uses all of it.
        #expect(geometry.video.height > fit.height)
        let fill = MobileVideoContentMode.fill.pictureSize(in: geometry.video.size)
        #expect(abs(fill.height - geometry.video.height) < 0.001)
        #expect(fill.height > fit.height * 1.2, "Filling portrait is worth doing")

        // Whichever mode is chosen, the frame stops at the resting controls.
        #expect(geometry.video.maxY <= geometry.restingControlsTop + 0.001)
    }

    @Test("Square windows and hidden touch controls keep a full video canvas")
    func squareAndControllerMode() {
        for size in [CGSize(width: 720, height: 720), CGSize(width: 390, height: 844)] {
            let g = MobilePlayerCanvasGeometry.resolve(size: size, touchVisible: false)
            #expect(g.video == CGRect(origin: .zero, size: size))
        }
    }

    @Test("Degenerate windows cannot create negative video or controller extents")
    func zeroGeometry() {
        let g = MobilePlayerCanvasGeometry.resolve(size: .zero, touchVisible: true)
        #expect(g.video.size == .zero)
        #expect(g.controls.width == 0 && g.controls.height == 0)
    }

    @Test("End-session confirmations distinguish awake from Rest")
    func endSessionMeaning() {
        #expect(MobileSessionEndAction.disconnect.detail.contains("stays awake"))
        #expect(MobileSessionEndAction.rest.detail.contains("Rest Mode"))
        #expect(MobileSessionEndAction.disconnect.confirmTitle != MobileSessionEndAction.rest.confirmTitle)
    }

    @Test("The session strip stays one cluster instead of spanning a large canvas",
          arguments: [CGSize(width: 1_366, height: 1_024), CGSize(width: 1_032, height: 1_376),
                      CGSize(width: 932, height: 430), CGSize(width: 390, height: 844)])
    func actionsStripIsBounded(_ size: CGSize) {
        let insets = EdgeInsets(top: 24, leading: 20, bottom: 20, trailing: 20)
        let geometry = MobilePlayerCanvasGeometry.resolve(size: size, insets: insets, touchVisible: true)
        let safe = CGRect(x: 20, y: 24, width: size.width - 40, height: size.height - 44)
        #expect(geometry.actions.width <= MobilePlayerCanvasGeometry.maximumActionsWidth)
        #expect(geometry.actions.minX >= safe.minX)
        #expect(geometry.actions.maxX <= safe.maxX)
        // Centred, so the two ends of the HUD stay a readable distance apart.
        #expect(abs(geometry.actions.midX - size.width / 2) < 0.001)
        #expect(geometry.actions.width >= 2 * MobilePlayerQuickActions.accessibleTargetSize + 8)
    }

    /// The owner's complaint about how these looked, as an assertion.
    ///
    /// Two pills jammed against the top edge of a 13-inch game is what he saw.
    /// The strip now floats below the safe area and reserves enough height for
    /// a 44-point control with air around it, which is also what moves the
    /// targets away from a screen edge a hand is wrapped around.
    @Test("The session strip floats clear of the top edge with room around its controls",
          arguments: [CGSize(width: 1_366, height: 1_024), CGSize(width: 1_032, height: 1_376),
                      CGSize(width: 932, height: 430), CGSize(width: 390, height: 844)])
    func actionsStripBreathes(_ size: CGSize) {
        let insets = EdgeInsets(top: 24, leading: 20, bottom: 20, trailing: 20)
        let geometry = MobilePlayerCanvasGeometry.resolve(size: size, insets: insets, touchVisible: true)
        #expect(geometry.actions.minY
                >= 24 + MobilePlayerGlass.hudTopInset(forCanvas: size) - 0.001)
        #expect(geometry.actions.minY > 24, "The strip sits on the safe-area edge")
        #expect(geometry.actions.height
                >= MobilePlayerGlass.hudTargetSize + 2 * MobilePlayerGlass.hudPillSpacing)
        // The gamepad is pushed down by whatever the strip takes, so growing
        // the strip can never put a shortcut on top of a gameplay control.
        #expect(geometry.controls.minY >= geometry.actions.maxY)
    }

    @Test("A narrow canvas still gives the session strip the whole safe width")
    func actionsStripUsesNarrowWidth() {
        let geometry = MobilePlayerCanvasGeometry.resolve(
            size: CGSize(width: 390, height: 844),
            insets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0), touchVisible: true
        )
        #expect(geometry.actions.width == CGFloat(390 - 24))
        #expect(geometry.actions.minX == CGFloat(12))
    }

    @Test("A large portrait canvas gives its spare height to the picture, not to an empty band",
          arguments: [CGSize(width: 1_024, height: 1_366), CGSize(width: 1_032, height: 1_376)])
    func portraitDeckOnALargeCanvas(_ size: CGSize) {
        let insets = EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
        let geometry = MobilePlayerCanvasGeometry.resolve(size: size, insets: insets, touchVisible: true)
        let required = MobileTouchGeometryPolicy.deckHeightRequirement(
            availableWidth: geometry.controls.width
        )
        // The deck claims what its controls occupy and no more, and stays
        // anchored to the bottom edge where thumbs are.
        #expect(abs(geometry.controls.height - required) < 0.001)
        #expect(abs(geometry.controls.maxY - (size.height - 20)) < 0.001)
        #expect(geometry.video.maxY <= geometry.restingControlsTop + 0.001)
        // The picture is 16:9 across the full width, which neither the old 42%
        // ceiling nor the old safe-width inset could reach on a canvas this tall.
        let fit = visiblePicture(geometry)
        #expect(abs(fit.width - size.width) < 0.001)
        #expect(abs(fit.width * 9 / 16 - fit.height) < 0.001)
        #expect(fit.height > geometry.controls.height * 1.5)
        // Whichever branch the overlay picks from the deck's own aspect ratio,
        // the deck it was given still fits the controls.
        for wide in [false, true] {
            let policy = MobileTouchGeometryPolicy.resolve(
                size: geometry.controls.size, wide: wide,
                navigationOnly: false, secondaryVisible: true, includesMore: true
            )
            #expect(policy.presentation == .standard)
        }
    }

    @Test("Shrinking the deck never shrinks the picture on a phone",
          arguments: [CGSize(width: 390, height: 844), CGSize(width: 430, height: 932)])
    func portraitDeckKeepsPhonePicture(_ size: CGSize) {
        let insets = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        let geometry = MobilePlayerCanvasGeometry.resolve(size: size, insets: insets, touchVisible: true)
        let controlsTop = 59.0 + MobilePlayerGlass.hudTopInset(forCanvas: size)
            + MobilePlayerGlass.hudStripHeight(forCanvas: size) + 8
        let availableHeight = size.height - 34 - controlsTop
        let previousVideoHeight = min((size.width - 24) * 9 / 16, availableHeight * 0.42)
        #expect(visiblePicture(geometry).height >= previousVideoHeight - 0.001)
        #expect(geometry.video.minY >= controlsTop - 0.001)
        let policy = MobileTouchGeometryPolicy.resolve(
            size: geometry.controls.size, wide: false,
            navigationOnly: false, secondaryVisible: true, includesMore: true
        )
        #expect(policy.presentation == .standard)
    }

    @Test("Only an expanded canvas resolves the expanded touch layout")
    func expandedTouchLayout() {
        let wideDeck = CGSize(width: 1_200, height: 700)
        #expect(MobileTouchControllerLayout.resolve(playerMode: .expanded, size: wideDeck) == .expanded)
        #expect(MobileTouchControllerLayout.resolve(playerMode: .wide, size: wideDeck) == .wide)
        #expect(MobileTouchControllerLayout.resolve(playerMode: .compact, size: CGSize(width: 390, height: 500)) == .compact)
        // Expanded and wide share every control size; only the tray differs.
        #expect(MobileTouchControllerLayout.expanded.usesWideMetrics)
        #expect(MobileTouchControllerLayout.wide.usesWideMetrics)
        #expect(!MobileTouchControllerLayout.compact.usesWideMetrics)
    }

    @Test("The controller tray rests open only where there is room and a full controller")
    func secondaryControlsRestingState() {
        typealias Overlay = MobileTouchControllerOverlay
        #expect(Overlay.secondaryControlsRestingState(layout: .expanded, preset: .play))
        #expect(Overlay.secondaryControlsRestingState(layout: .expanded, preset: .full))
        // Menus-only promises a small pad, not a complete controller.
        #expect(!Overlay.secondaryControlsRestingState(layout: .expanded, preset: .navigate))
        #expect(!Overlay.secondaryControlsRestingState(layout: .wide, preset: .play))
        #expect(!Overlay.secondaryControlsRestingState(layout: .compact, preset: .play))
        #expect(Overlay.secondaryControlsRestingState(layout: .compact, preset: .full))
    }

    /// Fold readiness. A phone that opens out produces canvases no current
    /// Apple device does: near-square, and tall-narrow when closed. Nothing in
    /// this layout asks what device it is on, so the way to prove it is to run
    /// the real geometry across a grid of sizes and assert the invariants hold
    /// everywhere, rather than to add the two aspect ratios someone guessed at.
    @Test("Every canvas produces a sane layout, including shapes no device ships yet")
    func geometryHoldsAcrossEveryCanvas() {
        let insetProfiles = [
            EdgeInsets(),
            EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
            EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59),
            EdgeInsets(top: 24, leading: 20, bottom: 20, trailing: 20),
        ]
        var widths = Array(stride(from: CGFloat(240), through: 1_400, by: 53))
        // Shapes a folding phone would actually produce: closed and narrow,
        // half-open, and opened out to nearly square in both orientations.
        let foldSizes = [
            CGSize(width: 320, height: 748), CGSize(width: 375, height: 812),
            CGSize(width: 734, height: 768), CGSize(width: 768, height: 806),
            CGSize(width: 768, height: 734), CGSize(width: 806, height: 768),
            CGSize(width: 384, height: 768), CGSize(width: 1_024, height: 1_024),
        ]
        widths.append(contentsOf: [0, 1])

        var canvases = foldSizes
        for width in widths {
            for height in stride(from: CGFloat(240), through: 1_400, by: 149) {
                canvases.append(CGSize(width: width, height: height))
            }
        }

        for size in canvases {
            for insets in insetProfiles {
                for touchVisible in [true, false] {
                    let g = MobilePlayerCanvasGeometry.resolve(
                        size: size, insets: insets, touchVisible: touchVisible
                    )
                    for rect in [g.video, g.controls, g.actions] {
                        #expect(rect.width >= 0 && rect.height >= 0)
                        #expect(rect.origin.x.isFinite && rect.origin.y.isFinite)
                        #expect(rect.width.isFinite && rect.height.isFinite)
                    }
                    let left = max(12, insets.leading)
                    let right = max(12, insets.trailing)
                    let top = max(12, insets.top)
                    let bottom = max(12, insets.bottom)
                    let safeWidth = max(0, size.width - left - right)
                    #expect(g.actions.width <= MobilePlayerCanvasGeometry.maximumActionsWidth)
                    #expect(g.actions.width <= safeWidth + 0.001)
                    // Below this a canvas has no room for a session strip and a
                    // control region at all, and only the finiteness checks
                    // above are meaningful.
                    guard safeWidth > 0, size.height > top + g.actions.height + 8 + bottom else {
                        continue
                    }
                    // The session strip stays one readable cluster inside the
                    // safe area at every size, and centred in it.
                    #expect(g.actions.minX >= left - 0.001)
                    #expect(g.actions.maxX <= size.width - right + 0.001)
                    #expect(abs(g.actions.midX - size.width / 2) < 0.001)
                    #expect(g.actions.minY >= top - 0.001)
                    // Controls never climb into the strip or past the bottom.
                    #expect(g.controls.minY >= g.actions.maxY - 0.001)
                    #expect(g.controls.maxY <= size.height - bottom + 0.001)
                    #expect(g.controls.minX >= left - 0.001)
                    #expect(g.controls.maxX <= size.width - right + 0.001)
                    // The picture never reaches the controls as they rest,
                    // except in the full-bleed layout where the controls are
                    // deliberately drawn over the game.
                    #expect(g.video.maxY <= g.restingControlsTop + 0.001
                            || g.video == CGRect(origin: .zero, size: size))
                    #expect(g.restingControlsTop >= g.controls.minY - 0.001)
                    #expect(g.restingControlsTop <= g.controls.maxY + 0.001)
                }
            }
        }
    }

    @Test("A near-square canvas keeps a full-bleed picture instead of a phone's split deck",
          arguments: [CGSize(width: 768, height: 806), CGSize(width: 806, height: 768),
                      CGSize(width: 1_024, height: 1_024), CGSize(width: 734, height: 768)])
    func nearSquareCanvasIsNotTreatedAsAPhonePortrait(_ size: CGSize) {
        let g = MobilePlayerCanvasGeometry.resolve(size: size, touchVisible: true)
        // The portrait deck exists because a tall narrow phone cannot show a
        // picture and reachable thumb controls in the same rectangle. A canvas
        // that is nearly as wide as it is tall can, and splitting it would
        // throw away most of the extra room a folding phone just gained.
        #expect(g.video == CGRect(origin: .zero, size: size))
        #expect(g.mode != .compact)
    }

    @Test("Full-size controls are chosen by whether they fit, not by the canvas's shape")
    func wideMetricsFollowRoomNotShape() {
        typealias Layout = MobileTouchControllerLayout
        // A near-square landscape canvas with real width: an opened-out phone.
        // The old aspect-ratio rule called this compact and handed it a small
        // phone's control sizes despite having room for full-size ones.
        let openedOut = CGSize(width: 782, height: 692)
        #expect(Layout.widePresentationFits(openedOut))
        #expect(Layout.resolve(playerMode: .balanced, size: openedOut) == .wide)

        // A phone in portrait still has no room, and still gets compact.
        let phonePortraitDeck = CGSize(width: 366, height: 445)
        #expect(!Layout.widePresentationFits(phonePortraitDeck))
        #expect(Layout.resolve(playerMode: .compact, size: phonePortraitDeck) == .compact)

        // Established behaviour is unchanged where it was already right.
        #expect(Layout.resolve(playerMode: .wide, size: CGSize(width: 814, height: 345)) == .wide)
        #expect(Layout.resolve(playerMode: .expanded, size: CGSize(width: 1_200, height: 700)) == .expanded)
    }

    @Test("The centred arrangement pulls the clusters in only as far as the tray allows")
    func centredThumbLayout() {
        #expect(MobileTouchThumbLayout.centred.pullsClustersInward)
        #expect(!MobileTouchThumbLayout.classic.pullsClustersInward)
        #expect(!MobileTouchThumbLayout.edgeSticks.pullsClustersInward)
        // Hands coming from above a flat device want the sticks inboard, the
        // same way the classic arrangement does.
        #expect(MobileTouchThumbLayout.centred.sticksAreInside)
        // The gap it uses is the tray's own width plus its margin, so a centred
        // cluster can never land on Create, the touchpad or Options — and it is
        // the same number every other arrangement uses as its minimum, which is
        // what keeps the geometry policy's fit calculation honest.
        #expect(MobileTouchControlMetrics.centredClusterGap
                == MobileTouchControlMetrics.padRowWidth + 16)
        #expect(MobileTouchThumbLayout.allCases.count == 3)
    }

    @Test("Menu-only controls cannot be mistaken for full gameplay")
    func presetNames() {
        #expect(MobileTouchControlPreset.navigate.displayName == "Menus only")
        #expect(MobileTouchControlPreset.navigate.detail.contains("not a complete"))
        #expect(MobileVideoContentMode.fill.title.contains("crop"))
    }
}
