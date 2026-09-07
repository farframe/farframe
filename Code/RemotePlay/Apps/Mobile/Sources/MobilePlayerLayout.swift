import SwiftUI

extension EnvironmentValues {
    /// Shows the session shortcuts, or puts them away again.
    ///
    /// Tapping empty picture is how a player works them, and the canvas owns
    /// that gesture. Any control that covers part of the picture — the swipe
    /// camera surface is the first — has to be able to honour the same tap
    /// instead of quietly eating it, so the action travels through the
    /// environment rather than through five view signatures.
    @Entry var farframeTogglePlayerChrome: () -> Void = {}
}

enum MobilePlayerLayoutMode: String, Equatable, Sendable {
    case compact, wide, balanced, expanded
}

enum MobileVideoContentMode: String, CaseIterable, Identifiable {
    case fit, fill, stretch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fit: "Fit entire picture"
        case .fill: "Fill / zoom (crop)"
        case .stretch: "Stretch to screen"
        }
    }

    func pictureSize(in bounds: CGSize) -> CGSize {
        if self == .stretch { return bounds }
        let scale = self == .fill ? max(bounds.width / 16, bounds.height / 9)
            : min(bounds.width / 16, bounds.height / 9)
        return CGSize(width: scale * 16, height: scale * 9)
    }
}

struct MobilePlayerChromeState {
    private(set) var isVisible = true

    /// Tap to show, tap again to put away.
    ///
    /// VoiceOver is the one case that cannot toggle: a control that is not
    /// drawn is not in the accessibility tree, and a gesture that removes the
    /// only route out of a session is not one to offer someone who navigates
    /// by that tree. For them the tap can only ever mean "show".
    mutating func toggle(voiceOver: Bool) {
        isVisible = voiceOver ? true : !isVisible
    }

    mutating func idleElapsed(autoHide: Bool, voiceOver: Bool) {
        isVisible = !autoHide || voiceOver
    }
}

/// One geometry contract for the real player and its disconnected design preview.
/// Only the video can extend under system insets; every control stays inside them.
struct MobilePlayerCanvasGeometry: Equatable {
    let video: CGRect
    let controls: CGRect
    let actions: CGRect
    let mode: MobilePlayerLayoutMode

    /// The session strip is a floating HUD, not a full-width bar. Beyond this
    /// it stops reading as one cluster and throws its two ends to opposite
    /// edges of a large canvas with a screen of nothing between them.
    ///
    /// Raised from 560 when the shortcuts grew to full 44-point targets: at the
    /// old cap the two ends of the HUD were touching on a 13-inch canvas, which
    /// is the cramped look the owner objected to.
    static let maximumActionsWidth: CGFloat = 680

    /// The top of the controls as they rest, which in portrait is lower than
    /// the top of `controls`.
    ///
    /// `controls` is the frame the overlay is given, and it reserves room for
    /// the controller tray so that opening the tray can never drop the pad into
    /// its fallback presentation. While the tray is closed that reserve is
    /// empty, so the picture is allowed to extend into it and a tray opened
    /// later simply draws over the picture's lower edge — which is exactly what
    /// the controls already do in landscape. Anything asking "is the picture
    /// clear of the controls" wants this, not `controls.minY`.
    var restingControlsTop: CGFloat

    static func resolve(
        size: CGSize,
        insets: EdgeInsets = EdgeInsets(),
        touchVisible: Bool,
        preset: MobileTouchControlPreset = .play
    ) -> Self {
        let width = max(0, size.width)
        let height = max(0, size.height)
        let left = max(12, insets.leading)
        let right = max(12, insets.trailing)
        let top = max(12, insets.top)
        let bottom = max(12, insets.bottom)
        let safeWidth = max(0, width - left - right)
        let actionsWidth = min(safeWidth, maximumActionsWidth)
        // The strip floats below the safe-area top rather than sitting on it,
        // and it is tall enough to hold a 44-point control with room around it.
        // Both numbers exist so the shortcuts read as a HUD over the game
        // instead of a system bar, and so a hand wrapped around the device is
        // not reaching for the screen edge.
        let canvas = CGSize(width: width, height: height)
        let actions = CGRect(x: left + (safeWidth - actionsWidth) / 2,
                             y: top + MobilePlayerGlass.hudTopInset(forCanvas: canvas),
                             width: actionsWidth,
                             height: MobilePlayerGlass.hudStripHeight(forCanvas: canvas))
        let controlsTop = actions.maxY + 8
        let available = CGRect(x: left, y: controlsTop, width: safeWidth,
                               height: max(0, height - bottom - controlsTop))
        let portraitDeck = touchVisible && height > width * 1.15
        let mode: MobilePlayerLayoutMode = width >= 1_000 ? .expanded
            : width > height ? .wide : height > width * 1.15 ? .compact : .balanced
        if portraitDeck {
            // The deck is bottom-anchored and only claims the height its own
            // controls occupy. On a phone that is nearly all of it; on a large
            // portrait canvas the surplus used to sit as an empty band between
            // the picture and the thumb clusters.
            //
            // The picture is full-bleed. This layout used to inset it to the
            // safe width, which contradicts this type's own contract — only the
            // video may extend under system insets, and every control stays
            // inside them — and it cost real picture: a 16:9 frame is as tall as
            // its width allows, so twenty-four points of side margin is
            // thirteen points of height thrown away on a screen that has none
            // to spare. It also read as a small rectangle floating in black
            // rather than as a band across the device.
            let ceiling = min(width * 9 / 16, available.height * 0.42)
            let deckHeight = min(
                max(0, available.height - 12 - ceiling),
                MobileTouchGeometryPolicy.deckHeightRequirement(availableWidth: safeWidth)
            )
            // The tray's resting state is a property of the preset and the
            // canvas, not of the chevron, so this cannot change while someone
            // is playing — only when they choose a different control layout,
            // which already rebuilds the overlay.
            let trayRestsOpen = MobileTouchControllerOverlay.secondaryControlsRestingState(
                layout: mode == .expanded ? .expanded : .wide, preset: preset
            )
            let pictureDeckHeight = trayRestsOpen ? deckHeight : min(
                deckHeight,
                MobileTouchGeometryPolicy.deckHeightRequirement(
                    availableWidth: safeWidth, secondaryVisible: false
                )
            )
            // The picture frame takes the whole region rather than a 16:9 slice
            // of it. A 16:9 stream cannot be made taller than its width allows,
            // so portrait always has surplus; giving the frame the surplus
            // hands it to the person instead of guessing. Fit letterboxes
            // inside the frame and looks exactly like a centred picture, which
            // is the default and stays the default. Fill and Stretch — controls
            // that already exist and are already explained in Session — now do
            // something in portrait, where before all three looked identical
            // because the frame was 16:9 to begin with.
            let videoRegion = max(0, available.height - 12 - pictureDeckHeight)
            let video = CGRect(x: 0, y: controlsTop, width: width, height: videoRegion)
            return Self(video: video,
                        controls: CGRect(x: left, y: height - bottom - deckHeight,
                                         width: safeWidth, height: deckHeight),
                        actions: actions, mode: mode,
                        restingControlsTop: height - bottom - pictureDeckHeight)
        }
        return Self(video: CGRect(x: 0, y: 0, width: width, height: height),
                    controls: available, actions: actions, mode: mode,
                    restingControlsTop: available.minY)
    }
}

/// Menus never move the display into another branch or replace its session host.
struct MobilePlayerCanvas<Video: View, Controls: View, Actions: View>: View {
    let touchVisible: Bool
    var autoHideChrome = true
    /// Only used to know whether the controller tray rests open, which changes
    /// how much of the deck the picture may sit above.
    var preset = MobileTouchControlPreset.play
    @ViewBuilder let video: () -> Video
    @ViewBuilder let controls: (MobilePlayerLayoutMode, Bool) -> Controls
    /// Handed the chrome's own state rather than being faded out by the canvas.
    ///
    /// The canvas used to hold the shortcuts at zero opacity with hit testing
    /// switched off, which made "idle" and "gone" the same thing and left a
    /// session whose only exit was a gesture nobody had been told about. The
    /// HUD now decides what it looks like when it is not wanted, and it never
    /// decides on nothing.
    @ViewBuilder let actions: (Bool) -> Actions
    let onResize: () -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chrome = MobilePlayerChromeState()
    @State private var revealGeneration = 0

    var body: some View {
        // Read insets before expanding the child. A GeometryReader that itself
        // ignores safe areas reports zero and would put R2 under the camera cutout.
        GeometryReader { safeProxy in
            GeometryReader { proxy in
                let geometry = MobilePlayerCanvasGeometry.resolve(
                    size: proxy.size, insets: safeProxy.safeAreaInsets,
                    touchVisible: touchVisible, preset: preset
                )
                ZStack(alignment: .topLeading) {
                    Color.black
                    video()
                        .frame(width: geometry.video.width, height: geometry.video.height)
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture(perform: toggleChrome)
                        .position(x: geometry.video.midX, y: geometry.video.midY)
                    controls(geometry.mode, chrome.isVisible)
                        .frame(width: geometry.controls.width, height: geometry.controls.height)
                        .position(x: geometry.controls.midX, y: geometry.controls.midY)
                    actions(chrome.isVisible)
                        .frame(width: geometry.actions.width, height: geometry.actions.height,
                               alignment: .trailing)
                        .position(x: geometry.actions.midX, y: geometry.actions.midY)
                }
                .environment(\.farframeTogglePlayerChrome, toggleChrome)
                .onChange(of: proxy.size) { _, _ in onResize() }
            }
            .ignoresSafeArea()
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .task(id: "\(revealGeneration)-\(chrome.isVisible)-\(autoHideChrome)-\(voiceOver)") {
            // Only a HUD that is up can idle away. This used to open by
            // revealing, which meant a deliberate tap-to-hide was undone by the
            // timer it restarted.
            guard chrome.isVisible, autoHideChrome, !voiceOver else { return }
            do { try await Task.sleep(for: MobilePlayerGlass.hudIdleDelay) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(chromeAnimation) {
                chrome.idleElapsed(autoHide: autoHideChrome, voiceOver: voiceOver)
            }
        }
    }

    private var chromeAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.32)
    }

    private func toggleChrome() {
        withAnimation(chromeAnimation) { chrome.toggle(voiceOver: voiceOver) }
        revealGeneration &+= 1
    }
}
