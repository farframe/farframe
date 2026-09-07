import SwiftUI

/// The Farframe hero backdrop: a quiet field of brand colour with two soft
/// lights in it, drawn once and reused by the Home hero and by the external
/// display's idle card.
///
/// It exists because `backgroundExtensionEffect()` has nothing to work with
/// unless there is something worth extending. The effect mirrors and blurs a
/// view's edges into the surrounding safe area; run it on a flat material card
/// and it produces a flat material card with slightly blurrier edges. Run it on
/// a gradient and the colour genuinely appears to continue under the navigation
/// bar and the status bar.
///
/// Deliberately built from tints over the system grouped background rather than
/// fixed colours, so it is correct in light and in dark without a second
/// palette, and so it never fights the system's own contrast settings.
struct FarframeBrandBackdrop: View {
    /// Scales the two soft lights with the panel, so the same art reads on a
    /// phone-width hero and on a television.
    var intensity: Double = 1

    /// Whether the art carries its own opaque plate.
    ///
    /// A connected display is showing nothing else, so it wants the plate: the
    /// art has to cover the screen. The Home hero is the opposite case. An
    /// opaque plate is exactly what made that hero read as a banner stuck onto
    /// the page, because a plate has to stop somewhere and wherever it stops is
    /// a visible line. Without it, the same tints sit directly on the page's own
    /// background and can be faded to nothing.
    var fillsBackground: Bool = true

    var body: some View {
        ZStack {
            if fillsBackground {
                Color(uiColor: .secondarySystemGroupedBackground)
            }
            LinearGradient(
                colors: [
                    Color.blue.opacity(0.30 * intensity),
                    Color.indigo.opacity(0.16 * intensity),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            GeometryReader { proxy in
                let unit = max(proxy.size.width, proxy.size.height)
                Ellipse()
                    .fill(Color.cyan.opacity(0.22 * intensity))
                    .frame(width: unit * 0.8, height: unit * 0.5)
                    .blur(radius: unit * 0.16)
                    .offset(x: -unit * 0.18, y: -unit * 0.22)
                Ellipse()
                    .fill(Color.purple.opacity(0.18 * intensity))
                    .frame(width: unit * 0.7, height: unit * 0.45)
                    .blur(radius: unit * 0.18)
                    .offset(x: proxy.size.width - unit * 0.35, y: proxy.size.height - unit * 0.25)
            }
            .allowsHitTesting(false)
        }
        // Art, not information. Nothing here is announced or focusable.
        .accessibilityHidden(true)
    }
}
