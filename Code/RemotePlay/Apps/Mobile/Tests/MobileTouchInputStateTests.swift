import CoreGraphics
import Foundation
import InputCore
import Testing
@testable import RemotePlayMobile

@Suite("Mobile touch input policies")
struct MobileTouchInputStateTests {
    @Test("Camera response softens center, preserves direction, and bounds invalid inputs")
    func cameraResponse() {
        let center = MobileTouchCameraResponse.apply(x: 0.04, y: 0, sensitivity: 0.8)
        #expect(center.x == 0 && center.y == 0)
        let partial = MobileTouchCameraResponse.apply(x: 0.5, y: 0, sensitivity: 0.8)
        #expect(partial.x > 0 && partial.x < 0.5 && partial.y == 0)
        let full = MobileTouchCameraResponse.apply(x: -1, y: 1, sensitivity: 99)
        #expect(abs(hypot(full.x, full.y) - 1) < 0.0001)
        #expect(full.x < 0 && full.y > 0)
        let invalid = MobileTouchCameraResponse.apply(x: .nan, y: 0, sensitivity: 1)
        #expect(invalid.x == 0 && invalid.y == 0)
    }
    @Test("Short taps retain only the remainder of their minimum duration")
    func shortTapMinimumDuration() {
        let start = ContinuousClock().now
        var press = MobileTouchPressState()
        let didPress = press.press(at: start)
        #expect(didPress)
        #expect(press.releaseDelay(at: start.advanced(by: .milliseconds(12))) == .milliseconds(28))
        #expect(press.releaseDelay(at: start.advanced(by: .milliseconds(40))) == .zero)
        #expect(press.releaseDelay(at: start.advanced(by: .seconds(2))) == .zero)
    }

    @Test("Repeated drag updates do not restart press timing")
    func dragUpdatesDoNotRestartMinimumDuration() {
        let start = ContinuousClock().now
        var press = MobileTouchPressState()
        let didPress = press.press(at: start)
        let didRepeatPress = press.press(at: start.advanced(by: .milliseconds(30)))
        #expect(didPress)
        #expect(didRepeatPress == false)
        #expect(press.releaseDelay(at: start.advanced(by: .milliseconds(45))) == .zero)
    }

    @Test("Cancellation releases immediately and a later press owns fresh timing")
    func cancellationAndNewPress() {
        let start = ContinuousClock().now
        var press = MobileTouchPressState()
        press.press(at: start)
        let didRelease = press.release()
        #expect(didRelease)
        #expect(press.isPressed == false)
        #expect(press.releaseDelay(at: start) == .zero)
        let didReleaseAgain = press.release()
        let didPressAgain = press.press(at: start.advanced(by: .milliseconds(10)))
        #expect(didReleaseAgain == false)
        #expect(didPressAgain)
        #expect(press.releaseDelay(at: start.advanced(by: .milliseconds(20))) == .milliseconds(30))
    }

    @Test("D-pad sweeps through cardinal directions, diagonals, and neutral")
    func continuousDPadSweep() {
        let samples: [(CGPoint, Set<ControllerButton>)] = [
            (CGPoint(x: 50, y: 0), [.dpadUp]),
            (CGPoint(x: 100, y: 0), [.dpadUp, .dpadRight]),
            (CGPoint(x: 100, y: 50), [.dpadRight]),
            (CGPoint(x: 100, y: 100), [.dpadRight, .dpadDown]),
            (CGPoint(x: 50, y: 100), [.dpadDown]),
            (CGPoint(x: 0, y: 100), [.dpadDown, .dpadLeft]),
            (CGPoint(x: 0, y: 50), [.dpadLeft]),
            (CGPoint(x: 0, y: 0), [.dpadLeft, .dpadUp]),
            (CGPoint(x: 50, y: 50), []),
        ]
        for (location, expected) in samples {
            #expect(MobileTouchDPadInput.buttons(at: location, size: 100) == expected)
        }
    }

    @Test("D-pad center and invalid geometry remain neutral")
    func dpadNeutralAndInvalidGeometry() {
        #expect(MobileTouchDPadInput.buttons(at: CGPoint(x: 55, y: 55), size: 100).isEmpty)
        #expect(MobileTouchDPadInput.buttons(at: .zero, size: 0).isEmpty)
        #expect(MobileTouchDPadInput.buttons(at: CGPoint(x: CGFloat.nan, y: 0), size: 100).isEmpty)
        #expect(MobileTouchDPadInput.buttons(at: .zero, size: .infinity).isEmpty)
    }

    @Test("Compact layouts stack before primary controls would be clipped")
    func narrowControlClustersStackWithoutShrinking() {
        for width in [CGFloat(296), 320, 344, 366, 387] {
            let arrangement = MobileTouchClusterArrangement.resolve(availableWidth: width, wide: false)
            #expect(arrangement == .stacked)
            #expect(MobileTouchClusterArrangement.requiredWidth(wide: false, arrangement: arrangement) <= width)
        }
        #expect(MobileTouchClusterArrangement.resolve(availableWidth: 675, wide: false) == .stacked)
        #expect(MobileTouchClusterArrangement.resolve(availableWidth: 676, wide: false) == .sideBySide)
    }

    @Test("Wide layouts also stack when a narrow container cannot fit four columns")
    func wideNarrowContainersStack() {
        #expect(MobileTouchClusterArrangement.resolve(availableWidth: 500, wide: true) == .stacked)
        #expect(MobileTouchClusterArrangement.resolve(availableWidth: 759, wide: true) == .stacked)
        #expect(MobileTouchClusterArrangement.resolve(availableWidth: 760, wide: true) == .sideBySide)
        #expect(MobileTouchClusterArrangement.requiredWidth(wide: true, arrangement: .stacked) == 256)
    }

    @Test("108-point face clusters keep 44-point circular targets separated")
    func faceTargetsDoNotOverlap() {
        let targetDiameter = MobileTouchControlMetrics.target
        let offset = (MobileTouchControlMetrics.cluster - targetDiameter) / 2
        let adjacentCenterDistance = hypot(offset, offset)
        #expect(adjacentCenterDistance >= targetDiameter)
    }

    @Test("All button dimensions reserve at least 44 points")
    func minimumControlBounds() {
        let m = MobileTouchControlMetrics.self
        for width in [m.target, m.shoulderWidth, m.createWidth, m.optionsWidth, m.padSwipeWidth] {
            #expect(width >= 44)
        }
        #expect(m.target >= 44)
        #expect(m.cluster == 108)
        #expect(m.stickClickGap > 0)
        #expect(m.clusterRowGap > 0)
        #expect(m.compactGroupGap > 0)
    }

    @Test("Portrait and square stages keep the standard full-control arrangement")
    func ordinaryStageGeometry() {
        for size in [CGSize(width: 320, height: 600), CGSize(width: 390, height: 650), CGSize(width: 600, height: 600)] {
            let policy = geometry(size: size, wide: false)
            #expect(policy.presentation == .standard)
            let minimum = MobileTouchGeometryPolicy.standardMinimumSize(
                availableWidth: size.width, wide: false, arrangement: policy.arrangement,
                navigationOnly: false, secondaryVisible: true, includesMore: true
            )
            #expect(minimum.width <= size.width)
            #expect(minimum.height <= size.height)
        }
    }

    @Test("Short landscape stages use a separate center tray without shrinking buttons")
    func shortLandscapeGeometry() {
        let minimum = MobileTouchGeometryPolicy.compactRowMinimumSize(navigationOnly: false, secondaryVisible: true)
        #expect(minimum == CGSize(width: 660, height: 205))
        for size in [minimum, CGSize(width: 700, height: 210), CGSize(width: 820, height: 230)] {
            #expect(geometry(size: size, wide: true).presentation == .compactRow)
            #expect(minimum.width <= size.width)
            #expect(minimum.height <= size.height)
        }
    }

    @Test("Center tray and gameplay columns have disjoint reserved bounds")
    func compactRowColumnSeparation() {
        let m = MobileTouchControlMetrics.self
        let padding = m.padding(wide: false)
        let gameplayWidth = m.stick(wide: false) + m.compactGroupGap + m.cluster
        let left = CGRect(x: padding, y: padding, width: gameplayWidth, height: m.gameplayHeight(wide: false, stacked: false, navigationOnly: false))
        let center = CGRect(x: left.maxX + m.compactGroupGap, y: padding, width: m.padRowWidth, height: m.target * 2 + m.trayGap)
        let right = CGRect(x: center.maxX + m.compactGroupGap, y: padding, width: gameplayWidth, height: left.height)
        let minimum = MobileTouchGeometryPolicy.compactRowMinimumSize(navigationOnly: false, secondaryVisible: true)
        #expect(left.intersects(center) == false)
        #expect(center.intersects(right) == false)
        #expect(right.maxX + padding == minimum.width)
        #expect(max(left.maxY, max(center.maxY, right.maxY)) + padding == minimum.height)
    }

    @Test("A deck sized for one layout branch still fits the other",
          arguments: [366.0, 406.0, 810.0, 1_000.0, 1_340.0])
    func deckHeightCoversBothBranches(_ width: CGFloat) {
        let required = MobileTouchGeometryPolicy.deckHeightRequirement(availableWidth: width)
        for wide in [false, true] {
            let policy = MobileTouchGeometryPolicy.resolve(
                size: CGSize(width: width, height: required), wide: wide,
                navigationOnly: false, secondaryVisible: true, includesMore: true
            )
            #expect(policy.presentation == .standard)
        }
        // One point shorter and at least one branch stops fitting, so the
        // requirement is the real minimum rather than a padded guess.
        let short = CGSize(width: width, height: required - 1)
        let fits = [false, true].allSatisfy { wide in
            MobileTouchGeometryPolicy.resolve(
                size: short, wide: wide,
                navigationOnly: false, secondaryVisible: true, includesMore: true
            ).presentation == .standard
        }
        #expect(!fits)
    }

    @Test("Impossible stage sizes remove interactive controls instead of clipping them")
    func impossibleStageGeometry() {
        for size in [CGSize(width: 320, height: 180), CGSize(width: 525, height: 183), CGSize(width: 526, height: 182), .zero] {
            #expect(geometry(size: size, wide: true).presentation == .unavailable)
        }
        #expect(geometry(size: CGSize(width: CGFloat.infinity, height: 600), wide: true).presentation == .unavailable)
    }

    @Test("Opening More rechecks the real tray height before retaining controls")
    func openingMoreRechecksHeight() {
        let size = CGSize(width: 320, height: 382)
        let closed = MobileTouchGeometryPolicy.resolve(
            size: size, wide: false, navigationOnly: false, secondaryVisible: false, includesMore: true
        )
        #expect(closed.presentation == .standard)
        #expect(geometry(size: size, wide: false).presentation == .unavailable)
    }

    private func geometry(size: CGSize, wide: Bool) -> MobileTouchGeometryPolicy {
        MobileTouchGeometryPolicy.resolve(
            size: size, wide: wide, navigationOnly: false, secondaryVisible: true, includesMore: true
        )
    }
}
