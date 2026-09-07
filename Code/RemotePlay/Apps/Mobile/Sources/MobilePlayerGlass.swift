import SwiftUI

/// Farframe's Liquid Glass vocabulary for the player surface, in one file so
/// the rules are visible rather than scattered through five views.
///
/// The material is only ever `.regular`. Apple's three conditions for `.clear`
/// are that the element is over media-rich content, that the content layer can
/// take a dimming layer underneath, and that the content above the glass is
/// bold and bright. Farframe meets the first and fails the other two: dimming
/// the game is the one thing a game-streaming app must never do, and the HUD's
/// content is small text and an eleven-point status dot. `.clear` is not used
/// anywhere in this app, deliberately.
///
/// Two surfaces are deliberately **not** glass and must stay that way:
///
/// - **The on-screen gamepad.** Eighteen small controls, each of which would
///   make its own light/dark decision over a frame that changes sixty times a
///   second, and each of which is a separate GPU compositing pass over a layer
///   that invalidates every frame. It keeps a fixed `.ultraThinMaterial`, which
///   is a *stable* dark blur under `.preferredColorScheme(.dark)`.
/// - **The stream-health overlay.** Dense monospaced numbers are content, not
///   navigation, and Apple is explicit that making content glass muddies the
///   hierarchy. Its solid scrim is the right call and is defended, not upgraded.
///
/// Everything below is the navigation layer floating above the game, which is
/// exactly what Apple reserves the material for.
enum MobilePlayerGlass {
    /// One radius for every floating panel on the player, so panels that appear
    /// in sequence — connecting, then failed, then restricted content — read as
    /// the same object changing its mind rather than three different cards.
    static let panelCornerRadius: CGFloat = 22

    /// Container spacing for the HUD strip. Larger than the strip's own
    /// spacing, so neighbouring buttons blend at rest and morph apart when one
    /// of them leaves.
    static let hudContainerSpacing: CGFloat = 18

    /// The smallest a shortcut may be, in both directions.
    ///
    /// This is Apple's published minimum and it is not advisory here. Before
    /// this number was enforced, the drawn glass was a comfortable pill and the
    /// control inside it answered to about fourteen points of height, so a
    /// player aiming at what they could see missed, the miss landed on the
    /// picture, the picture re-lit the HUD, and every shortcut looked dead.
    /// Measured on an iPad in landscape; the numbers are in the evidence note.
    static let hudTargetSize: CGFloat = 44

    /// Between two shortcuts inside one cluster. They fuse into one capsule at
    /// rest, so this is the seam, not a gap.
    static let hudPillSpacing: CGFloat = 4

    /// Padding inside a shortcut, around its label. The drawn capsule and the
    /// region that answers a finger are the same rectangle because the padding
    /// is applied inside the button, ahead of `contentShape`.
    static let hudPillPadding = EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18)

    /// Below this on its short side, a canvas is a phone.
    ///
    /// The complaint that started this was an iPad complaint: two cramped pills
    /// on a 13-inch screen with a screenful of room around them. A phone in
    /// portrait has the opposite problem and no height to give away, so it gets
    /// the tighter of the two strips. What does *not* change with the canvas is
    /// `hudTargetSize`; the controls are the same size everywhere, and only the
    /// air around them is negotiable.
    static let compactCanvasShortSide: CGFloat = 500

    private static func isCompact(_ size: CGSize) -> Bool {
        min(size.width, size.height) < compactCanvasShortSide
    }

    /// How far the HUD floats below the safe-area top.
    ///
    /// Zero reads as a system bar that has been left switched on. Some daylight
    /// between the shortcuts and the edge is most of what makes them read as a
    /// HUD belonging to the game rather than as furniture belonging to iPadOS,
    /// and it moves the targets away from the screen edge, where a hand
    /// wrapped around a 13-inch iPad cannot easily reach.
    static func hudTopInset(forCanvas size: CGSize) -> CGFloat {
        isCompact(size) ? 6 : 14
    }

    /// The height of the strip the canvas reserves for the HUD. Never less than
    /// a full target plus its seam.
    static func hudStripHeight(forCanvas size: CGSize) -> CGFloat {
        isCompact(size) ? hudTargetSize + 2 * hudPillSpacing : 64
    }

    /// How long the shortcuts stay up untouched before putting themselves away.
    static let hudIdleDelay = Duration.seconds(4)

    /// The put-away HUD's single control. Above the 44-point floor on purpose:
    /// it is unlabelled, it is the only thing on screen, and it is the only way
    /// out of a session.
    static let hudHandleSize: CGFloat = 52

    /// The session strip's two ends. Buttons sharing one of these become a
    /// single continuous piece of glass at rest instead of four separate pills
    /// floating over the game, which is both fewer sampling shapes and a HUD
    /// that reads as one designed object.
    enum HUDCluster: Hashable {
        case leading, trailing
    }
}

/// One identity for every panel that floats in the centre of the player, so a
/// panel that replaces another morphs into it.
enum MobilePlayerPanelID: Hashable {
    case connection
}

extension View {
    /// A large floating panel over the game: connecting, disconnecting, ended,
    /// restricted content, Big Screen.
    ///
    /// Large glass is the case where the material genuinely helps. Apple's own
    /// description is that a larger area simulates a thicker material, with a
    /// deeper shadow and more pronounced lensing, which separates the panel
    /// from whatever is behind it instead of relying on opacity that the
    /// system's Liquid Glass slider can take away.
    func farframePlayerPanel(maximumWidth: CGFloat? = 460) -> some View {
        padding(24)
            .frame(maxWidth: maximumWidth)
            .glassEffect(
                .regular,
                in: .rect(cornerRadius: MobilePlayerGlass.panelCornerRadius, style: .continuous)
            )
    }
}
