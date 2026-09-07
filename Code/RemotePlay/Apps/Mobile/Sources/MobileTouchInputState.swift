import CoreGraphics
import Foundation
import InputCore

enum MobileTouchThumbLayout: String, CaseIterable, Identifiable {
    case edgeSticks, classic, centred
    var id: String { rawValue }

    var title: String {
        switch self {
        case .edgeSticks: "Sticks outside"
        case .classic: "Classic — sticks inside"
        case .centred: "Centred — for a device lying flat"
        }
    }

    var sticksAreInside: Bool { self != .edgeSticks }

    /// An iPad is often put down rather than held. Held, your thumbs are at the
    /// extreme bottom corners and corner-anchored clusters are exactly right;
    /// flat on a table, your hands come from above and land wherever they land,
    /// and clusters a screen apart are a reach in both directions.
    ///
    /// This pulls the two clusters in until they just clear the controller
    /// tray, which is the tightest they can go without colliding with it. On a
    /// canvas with no spare width the clusters are already that close, so the
    /// choice costs a phone nothing — it only does something where there is
    /// something to do.
    var pullsClustersInward: Bool { self == .centred }
}

/// Softer response near center with independently bounded camera speed. Does
/// not affect the left movement stick or any physical game controller.
enum MobileTouchCameraResponse {
    static func apply(x: Float, y: Float, sensitivity: Float) -> (x: Float, y: Float) {
        guard x.isFinite, y.isFinite, sensitivity.isFinite else { return (0, 0) }
        let distance = hypot(x, y)
        guard distance > 0.08 else { return (0, 0) }
        let normalized = min(1, (distance - 0.08) / 0.92)
        let magnitude = min(1, pow(normalized, 1.35) * min(1.2, max(0.4, sensitivity)))
        return (x / distance * magnitude, y / distance * magnitude)
    }
}

/// Input-only policy, kept independent of SwiftUI gesture lifetime so timing
/// and directional behavior can be verified without a physical touchscreen.
struct MobileTouchPressState {
    static let minimumDuration: Duration = .milliseconds(40)

    private(set) var isPressed = false
    private var pressedAt: ContinuousClock.Instant?

    @discardableResult
    mutating func press(at instant: ContinuousClock.Instant = ContinuousClock().now) -> Bool {
        guard isPressed == false else { return false }
        isPressed = true
        pressedAt = instant
        return true
    }

    func releaseDelay(at instant: ContinuousClock.Instant = ContinuousClock().now) -> Duration {
        guard let pressedAt else { return .zero }
        return max(.zero, Self.minimumDuration - pressedAt.duration(to: instant))
    }

    @discardableResult
    mutating func release() -> Bool {
        let wasPressed = isPressed
        isPressed = false
        pressedAt = nil
        return wasPressed
    }
}

enum MobileTouchDPadInput {
    /// An eight-way pad owns one continuous touch. Its center is neutral, and
    /// each 45-degree sector maps to a cardinal direction or a diagonal.
    static func buttons(at location: CGPoint, size: CGFloat) -> Set<ControllerButton> {
        guard size.isFinite, size > 0,
              location.x.isFinite, location.y.isFinite else { return [] }
        let x = location.x - size / 2
        let y = location.y - size / 2
        guard hypot(x, y) > size * 0.12 else { return [] }

        let cardinalBoundary = CGFloat(0.4142135623730951) // tan(22.5 degrees)
        if abs(y) <= abs(x) * cardinalBoundary {
            return [x < 0 ? .dpadLeft : .dpadRight]
        }
        if abs(x) <= abs(y) * cardinalBoundary {
            return [y < 0 ? .dpadUp : .dpadDown]
        }
        return [
            x < 0 ? .dpadLeft : .dpadRight,
            y < 0 ? .dpadUp : .dpadDown,
        ]
    }
}

enum MobileTouchClusterArrangement: Hashable {
    case sideBySide
    case stacked

    static func resolve(availableWidth: CGFloat, wide: Bool) -> Self {
        availableWidth >= requiredWidth(wide: wide, arrangement: .sideBySide)
            ? .sideBySide : .stacked
    }

    /// Matches the fixed control sizes, spacing, and outer padding in the
    /// overlay. Narrow layouts rearrange controls instead of shrinking targets.
    static func requiredWidth(wide: Bool, arrangement: Self) -> CGFloat {
        let padding = MobileTouchControlMetrics.padding(wide: wide) * 2
        let cluster = MobileTouchControlMetrics.cluster
        if arrangement == .stacked {
            return cluster * 2 + 4 * 2 + 4 + padding
        }
        let stick = MobileTouchControlMetrics.stick(wide: wide)
        let clusterGap: CGFloat = wide ? 12 : 4
        let groupGap: CGFloat = wide ? 18 : 4
        let centerGap = MobileTouchControlMetrics.padRowWidth + 16
        return (stick + clusterGap + cluster) * 2 + groupGap * 2 + centerGap + padding
    }
}

/// Real layout bounds, not invisible hit-area expansion. The overlay consumes
/// these same sizes so geometry tests cannot pass against a separate model.
enum MobileTouchControlMetrics {
    static let target: CGFloat = 44
    static let cluster: CGFloat = 108
    static let shoulderWidth: CGFloat = 46
    static let createWidth: CGFloat = 52
    static let optionsWidth: CGFloat = 56
    static let padSwipeWidth: CGFloat = 112
    static let trayGap: CGFloat = 6
    static let rowGap: CGFloat = 8
    static let clusterRowGap: CGFloat = 6
    static let stickClickGap: CGFloat = 3
    static let compactGroupGap: CGFloat = 4

    static func padding(wide: Bool) -> CGFloat { wide ? 14 : 10 }
    static func stick(wide: Bool) -> CGFloat { wide ? 104 : 88 }
    static var padRowWidth: CGFloat {
        createWidth + trayGap + padSwipeWidth + trayGap + optionsWidth
    }

    /// The tray sits across the bottom centre as an overlay, so this is the
    /// closest two thumb clusters can be without landing on it. Used as a fixed
    /// gap by the centred arrangement and as the minimum by every other one.
    static var centredClusterGap: CGFloat { padRowWidth + 16 }

    static func systemRowWidth(includesMore: Bool) -> CGFloat {
        createWidth + target + optionsWidth + trayGap * 2
            + (includesMore ? target + trayGap : 0)
    }

    static func gameplayHeight(wide: Bool, stacked: Bool, navigationOnly: Bool) -> CGFloat {
        guard navigationOnly == false else { return cluster }
        let stickHeight = stick(wide: wide) + stickClickGap + target
        return stacked
            ? cluster + clusterRowGap + target + clusterRowGap + stickHeight
            : target + clusterRowGap + max(cluster, stickHeight)
    }
}

struct MobileTouchGeometryPolicy: Hashable {
    enum Presentation: Hashable {
        case standard
        case compactRow
        case unavailable
    }

    let presentation: Presentation
    let arrangement: MobileTouchClusterArrangement

    static func resolve(
        size: CGSize,
        wide: Bool,
        navigationOnly: Bool,
        secondaryVisible: Bool,
        includesMore: Bool
    ) -> Self {
        let arrangement = MobileTouchClusterArrangement.resolve(availableWidth: size.width, wide: wide)
        let normal = standardMinimumSize(
            availableWidth: size.width,
            wide: wide,
            arrangement: arrangement,
            navigationOnly: navigationOnly,
            secondaryVisible: secondaryVisible,
            includesMore: includesMore
        )
        let compact = compactRowMinimumSize(navigationOnly: navigationOnly, secondaryVisible: secondaryVisible)
        let presentation: Presentation
        if fits(normal, in: size) {
            presentation = .standard
        } else if fits(compact, in: size) {
            presentation = .compactRow
        } else {
            presentation = .unavailable
        }
        return Self(presentation: presentation, arrangement: arrangement)
    }

    static func standardMinimumSize(
        availableWidth: CGFloat,
        wide: Bool,
        arrangement: MobileTouchClusterArrangement,
        navigationOnly: Bool,
        secondaryVisible: Bool,
        includesMore: Bool
    ) -> CGSize {
        let m = MobileTouchControlMetrics.self
        let padding = m.padding(wide: wide) * 2
        let groupGap: CGFloat = wide && arrangement == .sideBySide ? 18 : 4
        let centerGap: CGFloat = arrangement == .sideBySide ? m.padRowWidth + 16 : 4
        let gameplayWidth = navigationOnly
            ? m.cluster + m.target * 2 + 12 + groupGap * 2 + centerGap + padding
            : MobileTouchClusterArrangement.requiredWidth(wide: wide, arrangement: arrangement)
        let trayWidth = secondaryVisible ? m.padRowWidth : m.target
        let trayHeight = secondaryVisible ? m.target * 2 + m.trayGap : m.target
        return CGSize(
            width: max(gameplayWidth, trayWidth + padding),
            height: m.gameplayHeight(
                wide: wide, stacked: arrangement == .stacked, navigationOnly: navigationOnly
            ) + m.rowGap + trayHeight + padding
        )
    }

    /// The tallest standard deck the overlay can ask for at this width, with
    /// the controller tray open.
    ///
    /// A portrait deck is sized before the overlay exists, and the overlay then
    /// picks wide or compact from the deck's own aspect ratio. Sizing the deck
    /// for only one of those choices can make the other stop fitting the moment
    /// the deck is applied, which would drop the controls into their fallback
    /// presentation. Taking the taller of the two keeps that decision free.
    static func deckHeightRequirement(availableWidth: CGFloat) -> CGFloat {
        deckHeightRequirement(availableWidth: availableWidth, secondaryVisible: true)
    }

    /// The same measurement for a stated tray state.
    ///
    /// The deck is always *reserved* at the open-tray height, so opening the
    /// tray can never drop the controls into their fallback presentation. But
    /// while the tray is closed that reserve is empty, and it sits directly
    /// between the picture and the thumb controls, where it compounds with the
    /// picture's own margin into one large void. The picture's region is
    /// therefore measured against the resting height instead, so the two gaps
    /// stop adding up; a tray opened later draws over the picture's lower edge,
    /// which is exactly what the controls already do in landscape.
    static func deckHeightRequirement(
        availableWidth: CGFloat,
        secondaryVisible: Bool
    ) -> CGFloat {
        [false, true].reduce(0) { tallest, wide in
            let arrangement = MobileTouchClusterArrangement.resolve(
                availableWidth: availableWidth, wide: wide
            )
            let minimum = standardMinimumSize(
                availableWidth: availableWidth,
                wide: wide,
                arrangement: arrangement,
                navigationOnly: false,
                secondaryVisible: secondaryVisible,
                includesMore: true
            )
            return max(tallest, minimum.height)
        }
    }

    static func compactRowMinimumSize(navigationOnly: Bool, secondaryVisible: Bool) -> CGSize {
        let m = MobileTouchControlMetrics.self
        let gameplayWidth = navigationOnly
            ? m.cluster + m.target * 2 + 12
            : (m.stick(wide: false) + m.compactGroupGap + m.cluster) * 2
        let trayHeight = secondaryVisible ? m.target * 2 + m.trayGap : m.target
        let padding = m.padding(wide: false) * 2
        return CGSize(
            width: gameplayWidth + m.compactGroupGap * 2 + m.padRowWidth + padding,
            height: max(
                m.gameplayHeight(wide: false, stacked: false, navigationOnly: navigationOnly),
                trayHeight
            ) + padding
        )
    }

    private static func fits(_ minimum: CGSize, in available: CGSize) -> Bool {
        available.width.isFinite && available.height.isFinite
            && available.width >= minimum.width && available.height >= minimum.height
    }
}
