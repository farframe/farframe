import InputCore
import SwiftUI

enum MobileTouchStick {
    case left
    case right
}

enum MobileTouchControlPreset: String, CaseIterable, Identifiable {
    case navigate
    case play
    case full

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .navigate: "Menus only"
        case .play: "Game — clean"
        case .full: "Game — expanded"
        }
    }

    var detail: String {
        switch self {
        case .navigate: "A small D-pad, Cross and Circle layout for browsing PS5 menus. It is not a complete game controller."
        case .play: "The complete gameplay controls stay visible. On a large screen the controller tray stays out beside them; on a small one, reveal it when you need Create, Options or the touchpad."
        case .full: "Starts with the controller tray open, but you can collapse it at any time."
        }
    }
}

enum MobileTouchControllerLayout: Equatable {
    case compact
    case wide
    /// A canvas with room for the controller tray to stay open beside the
    /// thumb clusters instead of behind the chevron. Renders as `wide`.
    case expanded

    /// Wide and expanded share every control size and spacing. Only the tray's
    /// resting state differs, so the geometry policy sees one answer.
    var usesWideMetrics: Bool { self != .compact }

    static func resolve(
        playerMode: MobilePlayerLayoutMode,
        size: CGSize
    ) -> MobileTouchControllerLayout {
        if playerMode == .expanded { return .expanded }
        if playerMode == .wide { return .wide }
        return widePresentationFits(size) ? .wide : .compact
    }

    /// Whether the full-size controls actually fit.
    ///
    /// This used to be `width / height >= 1.35`. An aspect ratio is a proxy for
    /// available space, and a proxy is exactly what WWDC26 tells developers to
    /// stop using: a near-square canvas — a large phone opened out, a resized
    /// window — has plenty of room for full-size controls and was being handed
    /// a small phone's cramped metrics purely because its shape looked wrong.
    ///
    /// Measured against the resting layout, with the controller tray closed,
    /// which is the state this choice is made in. Opening the tray is still
    /// free to fall back the way it always could.
    static func widePresentationFits(_ size: CGSize) -> Bool {
        let minimum = MobileTouchGeometryPolicy.standardMinimumSize(
            availableWidth: size.width,
            wide: true,
            arrangement: .sideBySide,
            navigationOnly: false,
            secondaryVisible: false,
            includesMore: true
        )
        return size.width >= minimum.width && size.height >= minimum.height
    }
}

struct MobileTouchControllerOverlay: View {
    let mode: MobilePlayerLayoutMode
    let preset: MobileTouchControlPreset
    let hapticsAreEnabled: Bool
    var thumbLayout: MobileTouchThumbLayout = .edgeSticks
    var chromeVisible = true
    var cameraControl: MobileTouchCameraControl = .stick
    var cameraSensitivity: Double = 0.8
    let onButtonChange: (ControllerButton, Bool) -> Void
    let onStickChange: (MobileTouchStick, Float, Float) -> Void
    let onTriggerChange: (ControllerButton, Float) -> Void
    let onTouchpadChange: (Float, Float, Bool) -> Void
    /// Already a stick vector, and already sensitivity-scaled. It bypasses the
    /// drawn stick's response curve on purpose: that curve shapes a *position*,
    /// with a dead zone at the centre, and running a velocity through it would
    /// swallow exactly the small, slow camera adjustments this control exists
    /// to make good.
    var onCameraPadChange: (Float, Float) -> Void = { _, _ in }

    /// `nil` means the layout's own resting state, so a canvas that gains or
    /// loses the room for a permanent tray is not fighting a stored answer.
    /// Toggling the chevron records a deliberate choice that then wins.
    @State private var secondaryControlsAreVisible: Bool?
    @State private var haptics = MobileTouchHapticEngine()

    var body: some View {
        GeometryReader { proxy in
            let layout = MobileTouchControllerLayout.resolve(
                playerMode: mode,
                size: proxy.size
            )
            let secondaryIsShown = secondaryControlsAreShown(layout: layout)
            let geometry = MobileTouchGeometryPolicy.resolve(
                size: proxy.size,
                wide: layout.usesWideMetrics,
                navigationOnly: preset == .navigate,
                secondaryVisible: secondaryIsShown,
                includesMore: true
            )

            Group {
                switch geometry.presentation {
                case .standard:
                    if layout.usesWideMetrics {
                        wideLayout(arrangement: geometry.arrangement, secondaryIsShown: secondaryIsShown)
                    } else {
                        compactLayout(arrangement: geometry.arrangement, secondaryIsShown: secondaryIsShown)
                    }
                case .compactRow:
                    shortHeightLayout(secondaryIsShown: secondaryIsShown)
                case .unavailable:
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Text("Rotate or enlarge this view to use touch controls.")
                            .multilineTextAlignment(.center)
                        if secondaryIsShown {
                            Button("Hide extra controls") {
                                releaseAllInputs()
                                secondaryControlsAreVisible = false
                            }
                            .frame(minHeight: MobileTouchControlMetrics.target)
                            .buttonStyle(.glass)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .id(geometry)
            .padding(MobileTouchControlMetrics.padding(
                wide: geometry.presentation == .standard && layout.usesWideMetrics
            ))
            // Behind every drawn control, so a button that sits inside the
            // swipe region still takes the touch. Apple's guidance is to make
            // the camera's input area far larger than any drawn control; the
            // exclusion the face-button cluster needs comes free from hit
            // testing rather than from geometry that would have to be kept in
            // step with the layout.
            .background(alignment: .trailing) {
                if Self.cameraPadIsAvailable(
                    cameraControl: cameraControl, preset: preset,
                    layout: layout, presentation: geometry.presentation
                ) {
                    MobileTouchCameraPadSurface(
                        sensitivity: cameraSensitivity,
                        onChange: onCameraPadChange
                    )
                    .frame(width: proxy.size.width * MobileTouchCameraPadSurface.widthFraction)
                }
            }
            .onChange(of: geometry) { _, _ in releaseAllInputs() }
            .onAppear {
                if geometry.presentation == .unavailable { releaseAllInputs() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("On-screen PlayStation controller")
        .onAppear {
            if hapticsAreEnabled { haptics.prepare() }
        }
        .onChange(of: preset) { _, _ in
            releaseAllInputs()
            secondaryControlsAreVisible = nil
        }
        .onChange(of: hapticsAreEnabled) { _, enabled in
            if enabled {
                haptics.prepare()
            } else {
                haptics.stop()
            }
        }
        .onDisappear {
            releaseAllInputs()
            haptics.stop()
        }
        .onChange(of: thumbLayout) { _, _ in releaseAllInputs() }
    }

    private func wideLayout(
        arrangement: MobileTouchClusterArrangement,
        secondaryIsShown: Bool
    ) -> some View {
        HStack(alignment: .bottom, spacing: arrangement == .stacked ? 4 : 18) {
            if thumbLayout.pullsClustersInward { Spacer(minLength: 0) }
            leftGameplayCluster(wide: true, arrangement: arrangement)
            clusterGap(arrangement: arrangement)
            rightGameplayCluster(wide: true, arrangement: arrangement)
            if thumbLayout.pullsClustersInward { Spacer(minLength: 0) }
        }
        .overlay(alignment: .bottom) {
            secondaryControls(isShown: secondaryIsShown)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func compactLayout(
        arrangement: MobileTouchClusterArrangement,
        secondaryIsShown: Bool
    ) -> some View {
        HStack(alignment: .bottom, spacing: 4) {
            if thumbLayout.pullsClustersInward { Spacer(minLength: 0) }
            leftGameplayCluster(wide: false, arrangement: arrangement)
            clusterGap(arrangement: arrangement)
            rightGameplayCluster(wide: false, arrangement: arrangement)
            if thumbLayout.pullsClustersInward { Spacer(minLength: 0) }
        }
        .overlay(alignment: .bottom) {
            secondaryControls(isShown: secondaryIsShown)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// The space between the two thumb clusters.
    ///
    /// `MobileTouchControlMetrics.centredClusterGap` is not a taste value: it
    /// is the width of the controller tray plus its margin, and the tray is an
    /// overlay across the bottom centre. Any smaller and a centred cluster
    /// would sit on top of Create, the touchpad or Options. It is the same
    /// number the edge-anchored layout uses as its *minimum*, so the geometry
    /// policy's fit calculation stays correct without knowing about any of this.
    @ViewBuilder
    private func clusterGap(arrangement: MobileTouchClusterArrangement) -> some View {
        if arrangement == .stacked {
            Spacer(minLength: 4)
        } else if thumbLayout.pullsClustersInward {
            Spacer().frame(width: MobileTouchControlMetrics.centredClusterGap)
        } else {
            Spacer(minLength: MobileTouchControlMetrics.centredClusterGap)
        }
    }

    /// Reuses the compact thumb clusters and places the secondary controls in
    /// their own center column, saving a row without overlapping hit regions.
    private func shortHeightLayout(secondaryIsShown: Bool) -> some View {
        HStack(alignment: .bottom, spacing: MobileTouchControlMetrics.compactGroupGap) {
            leftGameplayCluster(wide: false, arrangement: .sideBySide)
            secondaryControls(isShown: secondaryIsShown)
            .frame(width: MobileTouchControlMetrics.padRowWidth)
            rightGameplayCluster(wide: false, arrangement: .sideBySide)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// A canvas wide enough for the expanded layout has room to keep Create,
    /// the touchpad and Options out where they can be reached, in the dead
    /// space between two corner-anchored thumb clusters. The menus-only preset
    /// is excluded: it promises a small pad, not a complete controller.
    func secondaryControlsAreShown(layout: MobileTouchControllerLayout) -> Bool {
        secondaryControlsAreVisible ?? Self.secondaryControlsRestingState(
            layout: layout, preset: preset
        )
    }

    /// The swipe camera needs a picture to swipe on. It is offered only where
    /// the controls float over the whole canvas: in the portrait deck layout
    /// the overlay is a strip at the bottom and the picture above it is not the
    /// overlay's to take touches from, and the menus-only preset promises a
    /// small pad rather than a camera at all.
    static func cameraPadIsAvailable(
        cameraControl: MobileTouchCameraControl,
        preset: MobileTouchControlPreset,
        layout: MobileTouchControllerLayout,
        presentation: MobileTouchGeometryPolicy.Presentation
    ) -> Bool {
        cameraControl == .swipe
            && preset != .navigate
            && presentation == .standard
            && layout.usesWideMetrics
    }

    /// Pure logic on two enums, and the canvas geometry needs it while deciding
    /// how much of the deck the picture may sit above. `nonisolated` so that
    /// decision does not have to pretend to be on the main actor.
    nonisolated static func secondaryControlsRestingState(
        layout: MobileTouchControllerLayout,
        preset: MobileTouchControlPreset
    ) -> Bool {
        guard preset != .navigate else { return false }
        return preset == .full || layout == .expanded
    }

    @ViewBuilder
    private func leftGameplayCluster(
        wide: Bool,
        arrangement: MobileTouchClusterArrangement
    ) -> some View {
        switch preset {
        case .navigate:
            dpad(size: MobileTouchControlMetrics.cluster)
        case .play, .full:
            VStack(alignment: .leading, spacing: MobileTouchControlMetrics.clusterRowGap) {
                HStack(spacing: 8) {
                    triggerButton("L2", button: .leftTrigger)
                    digitalButton("L1", button: .leftShoulder, width: MobileTouchControlMetrics.shoulderWidth)
                }
                if arrangement == .stacked {
                    if thumbLayout.sticksAreInside {
                        dpad(size: MobileTouchControlMetrics.cluster)
                        stick(.left, label: "L3", size: MobileTouchControlMetrics.stick(wide: wide))
                    } else {
                        stick(.left, label: "L3", size: MobileTouchControlMetrics.stick(wide: wide))
                        dpad(size: MobileTouchControlMetrics.cluster)
                    }
                } else {
                    HStack(alignment: thumbLayout.sticksAreInside ? .top : .bottom, spacing: wide ? 12 : 4) {
                        if thumbLayout.sticksAreInside {
                            dpad(size: MobileTouchControlMetrics.cluster)
                            stick(.left, label: "L3", size: MobileTouchControlMetrics.stick(wide: wide))
                        } else {
                            stick(.left, label: "L3", size: MobileTouchControlMetrics.stick(wide: wide))
                            dpad(size: MobileTouchControlMetrics.cluster)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rightGameplayCluster(
        wide: Bool,
        arrangement: MobileTouchClusterArrangement
    ) -> some View {
        switch preset {
        case .navigate:
            HStack(spacing: 12) {
                digitalButton("×", accessibilityLabel: "Cross", button: .cross, tint: .blue)
                digitalButton("○", accessibilityLabel: "Circle", button: .circle, tint: .red)
            }
        case .play, .full:
            VStack(alignment: .trailing, spacing: MobileTouchControlMetrics.clusterRowGap) {
                HStack(spacing: 8) {
                    digitalButton("R1", button: .rightShoulder, width: MobileTouchControlMetrics.shoulderWidth)
                    triggerButton("R2", button: .rightTrigger)
                }
                if arrangement == .stacked {
                    if thumbLayout.sticksAreInside {
                        faceButtons(size: MobileTouchControlMetrics.cluster)
                        stick(.right, label: "R3", size: MobileTouchControlMetrics.stick(wide: wide))
                    } else {
                        stick(.right, label: "R3", size: MobileTouchControlMetrics.stick(wide: wide))
                        faceButtons(size: MobileTouchControlMetrics.cluster)
                    }
                } else {
                    HStack(alignment: thumbLayout.sticksAreInside ? .top : .bottom, spacing: wide ? 12 : 4) {
                        if thumbLayout.sticksAreInside {
                            stick(.right, label: "R3", size: MobileTouchControlMetrics.stick(wide: wide))
                            faceButtons(size: MobileTouchControlMetrics.cluster)
                        } else {
                            faceButtons(size: MobileTouchControlMetrics.cluster)
                            stick(.right, label: "R3", size: MobileTouchControlMetrics.stick(wide: wide))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func secondaryControls(isShown: Bool) -> some View {
        if isShown {
            VStack(spacing: MobileTouchControlMetrics.trayGap) {
                HStack(spacing: MobileTouchControlMetrics.trayGap) {
                    digitalButton("Create", button: .create, width: MobileTouchControlMetrics.createWidth)
                    touchpadControls
                    digitalButton("Options", button: .options, width: MobileTouchControlMetrics.optionsWidth)
                }
                moreControlsButton(isShown: isShown)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.94)))
        } else {
            moreControlsButton(isShown: isShown)
        }
    }

    private var touchpadControls: some View {
        MobileTouchpadControl(
            onChange: onTouchpadChange,
            onClickChange: { onButtonChange(.touchpad, $0) },
            onPressFeedback: { playHaptic(.button) }
        )
    }

    private func moreControlsButton(isShown: Bool) -> some View {
        Button {
            releaseAllInputs()
            withAnimation(.snappy(duration: 0.2)) {
                secondaryControlsAreVisible = !isShown
            }
            playHaptic(.tray)
        } label: {
            Image(systemName: isShown ? "chevron.down" : "gamecontroller.fill")
                .font(.caption.weight(.bold))
                .frame(width: MobileTouchControlMetrics.target, height: MobileTouchControlMetrics.target)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.24), lineWidth: 1)
        }
        // The only control here a pointer user plausibly reaches for. The 18
        // gameplay buttons deliberately get no hover treatment: a trackpad is
        // not how anyone drives them, and the effect would only add noise.
        .hoverEffect(.highlight)
        .accessibilityLabel(isShown ? "Hide more controls" : "Show more controls")
        // Keep the layout and gameplay hit regions stable as shortcuts fade.
        // An opened utility tray keeps its close control until deliberately closed.
        .opacity(chromeVisible || isShown ? 1 : 0)
        .allowsHitTesting(chromeVisible || isShown)
        .accessibilityHidden(!chromeVisible && !isShown)
    }

    private func dpad(size: CGFloat) -> some View {
        MobileTouchDPadControl(
            size: size,
            onPressFeedback: { playHaptic(.button) },
            onButtonChange: onButtonChange
        )
    }

    private func faceButtons(size: CGFloat) -> some View {
        let offset = (size - MobileTouchControlMetrics.target) / 2
        return ZStack {
            digitalButton("△", accessibilityLabel: "Triangle", button: .triangle, tint: .green)
                .offset(y: -offset)
            digitalButton("×", accessibilityLabel: "Cross", button: .cross, tint: .blue)
                .offset(y: offset)
            digitalButton("□", accessibilityLabel: "Square", button: .square, tint: .pink)
                .offset(x: -offset)
            digitalButton("○", accessibilityLabel: "Circle", button: .circle, tint: .red)
                .offset(x: offset)
        }
        .frame(width: size, height: size)
    }

    private func stick(
        _ stick: MobileTouchStick,
        label: String,
        size: CGFloat = 82
    ) -> some View {
        VStack(spacing: MobileTouchControlMetrics.stickClickGap) {
            if thumbLayout.sticksAreInside { stickClick(stick, label: label) }
            MobileTouchStickControl(
                label: stick == .left ? "Left stick" : "Right stick",
                size: size,
                onPressFeedback: { playHaptic(.stick) },
                onChange: { x, y in onStickChange(stick, x, y) }
            )
            if !thumbLayout.sticksAreInside { stickClick(stick, label: label) }
        }
    }

    private func stickClick(_ stick: MobileTouchStick, label: String) -> some View {
        digitalButton(label, accessibilityLabel: stick == .left ? "L3" : "R3",
                      button: stick == .left ? .leftStick : .rightStick)
    }

    private func triggerButton(
        _ label: String,
        button: ControllerButton
    ) -> some View {
        MobileTouchPressControl(
            label: label,
            accessibilityLabel: label,
            width: MobileTouchControlMetrics.shoulderWidth,
            tint: .white,
            onPressFeedback: { playHaptic(.trigger) },
            onPressChange: { pressed in
                onTriggerChange(button, pressed ? 1 : 0)
            }
        )
    }

    private func digitalButton(
        _ label: String,
        accessibilityLabel: String? = nil,
        button: ControllerButton,
        tint: Color = .white,
        width: CGFloat = MobileTouchControlMetrics.target
    ) -> some View {
        MobileTouchPressControl(
            label: label,
            accessibilityLabel: accessibilityLabel ?? label,
            width: width,
            tint: tint,
            onPressFeedback: { playHaptic(.button) },
            onPressChange: { pressed in
                onButtonChange(button, pressed)
            }
        )
    }

    private func playHaptic(_ event: MobileTouchHapticEvent) {
        haptics.play(event, enabled: hapticsAreEnabled)
    }

    private func releaseAllInputs() {
        for button in ControllerButton.allCases { onButtonChange(button, false) }
        onStickChange(.left, 0, 0)
        onStickChange(.right, 0, 0)
        onTriggerChange(.leftTrigger, 0)
        onTriggerChange(.rightTrigger, 0)
        onTouchpadChange(0, 0, false)
    }
}

/// The invisible camera surface.
///
/// It draws nothing, which is the point: Apple's handheld-games guidance is to
/// make a camera control's input area far larger than anything drawn, because
/// a player cannot feel where their finger is relative to a control they are
/// not looking at.
///
/// Two behaviours make it safe to lay over part of the picture. It sits behind
/// every drawn control, so buttons keep their touches. And a contact that never
/// really moves is treated as a tap on the picture and works the session
/// shortcuts, exactly as tapping the picture anywhere else does — without that,
/// an invisible layer would silently swallow the gesture the player has for
/// showing and hiding the HUD.
private struct MobileTouchCameraPadSurface: View {
    /// The right-hand side, per Apple's rule that controls used at the same
    /// time should share a side: the face buttons are already there, and they
    /// stay on top of this.
    static let widthFraction: CGFloat = 0.5
    /// Below this a contact was a tap, not a swipe. Matches the touchpad
    /// control's own threshold so the two feel like the same app.
    static let tapDistance: CGFloat = 12

    let sensitivity: Double
    let onChange: (Float, Float) -> Void

    @Environment(\.farframeTogglePlayerChrome) private var toggleChrome
    @State private var pad = MobileTouchCameraPad()
    @State private var tick: Task<Void, Never>?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let now = ContinuousClock.now
                        if pad.isTracking {
                            pad.move(to: value.location, instant: now)
                        } else {
                            pad.begin(at: value.location, instant: now)
                            startTicking()
                        }
                        emit()
                    }
                    .onEnded { value in
                        let distance = hypot(value.translation.width, value.translation.height)
                        stop()
                        if distance <= Self.tapDistance { toggleChrome() }
                    }
            )
            // The drawn stick is the accessible way to aim. An invisible
            // velocity surface is not usable by VoiceOver and should not
            // clutter its rotor pretending otherwise.
            .accessibilityHidden(true)
            .onDisappear { stop() }
    }

    /// A gesture recogniser stops reporting the moment the finger stops moving,
    /// so without this the last deflection would stay applied and the camera
    /// would keep turning under a motionless thumb. The tick runs only while a
    /// finger is down.
    private func startTicking() {
        tick?.cancel()
        tick = Task { @MainActor in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(16))
                guard Task.isCancelled == false, pad.isTracking else { return }
                emit()
            }
        }
    }

    private func emit() {
        let vector = pad.vector(at: .now, sensitivity: sensitivity)
        onChange(vector.x, vector.y)
    }

    private func stop() {
        tick?.cancel()
        tick = nil
        pad.end()
        onChange(0, 0)
    }
}

private struct MobileTouchPressControl: View {
    let label: String
    let accessibilityLabel: String
    let width: CGFloat
    let tint: Color
    let onPressFeedback: () -> Void
    let onPressChange: (Bool) -> Void

    @GestureState private var gestureIsActive = false
    @State private var pressState = MobileTouchPressState()
    @State private var releaseWasRequested = false
    @State private var releaseTask: Task<Void, Never>?

    private var isPressed: Bool { pressState.isPressed }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .minimumScaleFactor(0.7)
            .frame(width: max(width, MobileTouchControlMetrics.target), height: MobileTouchControlMetrics.target)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(isPressed ? 0.62 : 0.24), lineWidth: 1)
            }
            .opacity(isPressed ? 1 : 0.82)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($gestureIsActive) { _, state, _ in state = true }
                    .onChanged { _ in setPressed(true) }
                    .onEnded { _ in setPressed(false) }
            )
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { pulseForAccessibility() }
            .onChange(of: gestureIsActive) { _, active in
                // onEnded is not called when a recognizer is cancelled. A
                // completed gesture may still be finishing its minimum pulse;
                // cancellation must instead release held input immediately.
                if active == false, releaseWasRequested == false {
                    releaseImmediately()
                }
            }
            .onDisappear { releaseImmediately() }
    }

    private func setPressed(_ pressed: Bool) {
        if pressed {
            // This is a fresh contact after an earlier finger-up. Release the
            // old logical press before beginning it; a sampled provider may
            // still coalesce sub-40ms taps, but the UI never silently treats a
            // fresh contact as another update of the old gesture.
            if releaseWasRequested { releaseImmediately() }
            releaseTask?.cancel()
            releaseTask = nil
            releaseWasRequested = false
            guard pressState.press() else { return }
            onPressFeedback()
            onPressChange(true)
            return
        }

        guard isPressed else { return }
        releaseWasRequested = true
        let delay = pressState.releaseDelay()
        guard delay > .zero else {
            releaseImmediately()
            return
        }
        scheduleRelease(after: delay)
    }

    private func scheduleRelease(after delay: Duration) {
        releaseTask?.cancel()
        releaseTask = Task { @MainActor in
            // Retain only the time still needed since finger-down, never an
            // additional 40 ms after releasing an already-held button.
            try? await Task.sleep(for: delay)
            guard Task.isCancelled == false else { return }
            releaseImmediately()
        }
    }

    private func releaseImmediately() {
        releaseTask?.cancel()
        releaseTask = nil
        guard pressState.release() else { return }
        onPressChange(false)
    }

    private func pulseForAccessibility() {
        setPressed(true)
        releaseWasRequested = true
        scheduleRelease(after: .milliseconds(90))
    }
}

private struct MobileTouchDPadControl: View {
    let size: CGFloat
    let onPressFeedback: () -> Void
    let onButtonChange: (ControllerButton, Bool) -> Void

    @GestureState private var gestureIsActive = false
    @State private var pressedButtons: Set<ControllerButton> = []
    @State private var pressState = MobileTouchPressState()
    @State private var releaseWasRequested = false
    @State private var pulseTask: Task<Void, Never>?

    private let directions: [ControllerButton] = [
        .dpadUp, .dpadDown, .dpadLeft, .dpadRight,
    ]

    var body: some View {
        let offset = (size - MobileTouchControlMetrics.target) / 2
        ZStack {
            arrow("▲", button: .dpadUp).offset(y: -offset)
            arrow("▼", button: .dpadDown).offset(y: offset)
            arrow("◀", button: .dpadLeft).offset(x: -offset)
            arrow("▶", button: .dpadRight).offset(x: offset)
        }
        .frame(width: size, height: size)
        .contentShape(RoundedRectangle(cornerRadius: size * 0.2))
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($gestureIsActive) { _, state, _ in state = true }
                .onChanged { value in
                    if releaseWasRequested { cancelInteraction() }
                    pulseTask?.cancel()
                    pulseTask = nil
                    releaseWasRequested = false
                    update(MobileTouchDPadInput.buttons(at: value.location, size: size))
                }
                .onEnded { _ in finishInteraction() }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Directional pad")
        .accessibilityHint("Drag to change direction, including diagonals")
        .accessibilityValue(accessibilityValue)
        .accessibilityAction(named: Text("Up")) { pulse([.dpadUp]) }
        .accessibilityAction(named: Text("Down")) { pulse([.dpadDown]) }
        .accessibilityAction(named: Text("Left")) { pulse([.dpadLeft]) }
        .accessibilityAction(named: Text("Right")) { pulse([.dpadRight]) }
        .accessibilityAction(named: Text("Up left")) { pulse([.dpadUp, .dpadLeft]) }
        .accessibilityAction(named: Text("Up right")) { pulse([.dpadUp, .dpadRight]) }
        .accessibilityAction(named: Text("Down left")) { pulse([.dpadDown, .dpadLeft]) }
        .accessibilityAction(named: Text("Down right")) { pulse([.dpadDown, .dpadRight]) }
        .onChange(of: gestureIsActive) { _, active in
            if active == false, releaseWasRequested == false { cancelInteraction() }
        }
        .onDisappear { cancelInteraction() }
    }

    private func arrow(_ label: String, button: ControllerButton) -> some View {
        let isPressed = pressedButtons.contains(button)
        return Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: MobileTouchControlMetrics.target, height: MobileTouchControlMetrics.target)
            .background(.ultraThinMaterial, in: Circle())
            .overlay {
                Circle().strokeBorder(.white.opacity(isPressed ? 0.62 : 0.24), lineWidth: 1)
            }
            .scaleEffect(isPressed ? 0.9 : 1)
            .opacity(isPressed ? 1 : 0.82)
            .allowsHitTesting(false)
    }

    private var accessibilityValue: String {
        let names: [(ControllerButton, String)] = [
            (.dpadUp, "Up"), (.dpadDown, "Down"),
            (.dpadLeft, "Left"), (.dpadRight, "Right"),
        ]
        let active = names.filter { pressedButtons.contains($0.0) }.map { $0.1 }
        return active.isEmpty ? "Centered" : active.joined(separator: " ")
    }

    private func update(_ next: Set<ControllerButton>) {
        guard next != pressedButtons else { return }
        if pressedButtons.isEmpty, next.isEmpty == false {
            pressState.press()
            onPressFeedback()
        }
        if next.isEmpty { pressState.release() }
        let previous = pressedButtons
        pressedButtons = next
        // Release old directions first, so an asynchronous input sample can
        // never see both opposing directions during a sweep across the pad.
        for direction in directions where previous.contains(direction) && next.contains(direction) == false {
            onButtonChange(direction, false)
        }
        for direction in directions where previous.contains(direction) == false && next.contains(direction) {
            onButtonChange(direction, true)
        }
    }

    private func cancelInteraction() {
        pulseTask?.cancel()
        pulseTask = nil
        releaseWasRequested = false
        update([])
    }

    private func finishInteraction() {
        releaseWasRequested = true
        let delay = pressState.releaseDelay()
        guard delay > .zero else {
            update([])
            return
        }
        pulseTask?.cancel()
        pulseTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard Task.isCancelled == false else { return }
            update([])
        }
    }

    private func pulse(_ buttons: Set<ControllerButton>) {
        cancelInteraction()
        releaseWasRequested = true
        update(buttons)
        pulseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard Task.isCancelled == false else { return }
            update([])
        }
    }
}

private struct MobileTouchStickControl: View {
    let label: String
    let size: CGFloat
    let onPressFeedback: () -> Void
    let onChange: (Float, Float) -> Void

    @GestureState private var gestureIsActive = false
    @State private var displacement = CGSize.zero
    @State private var isEngaged = false
    @State private var pulseTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
            Circle()
                .strokeBorder(.white.opacity(0.26), lineWidth: 1)
            Circle()
                .fill(.white.opacity(0.32))
                .frame(width: size * 0.46, height: size * 0.46)
                .offset(displacement)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($gestureIsActive) { _, state, _ in state = true }
                .onChanged { value in update(location: value.location) }
                .onEnded { _ in cancelInteraction() }
        )
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityHint("Drag in any direction")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                pulse(x: 0, y: 1)
            case .decrement:
                pulse(x: 0, y: -1)
            @unknown default:
                reset()
            }
        }
        .accessibilityAction(named: Text("Left")) { pulse(x: -1, y: 0) }
        .accessibilityAction(named: Text("Right")) { pulse(x: 1, y: 0) }
        .accessibilityAction(named: Text("Up")) { pulse(x: 0, y: 1) }
        .accessibilityAction(named: Text("Down")) { pulse(x: 0, y: -1) }
        .onChange(of: gestureIsActive) { _, active in
            if active == false { cancelInteraction() }
        }
        .onDisappear { cancelInteraction() }
    }

    private var accessibilityValue: String {
        guard displacement != .zero else { return "Centered" }
        return "X \(Int(displacement.width)), Y \(Int(-displacement.height))"
    }

    private func update(location: CGPoint) {
        pulseTask?.cancel()
        pulseTask = nil
        if isEngaged == false {
            isEngaged = true
            onPressFeedback()
        }
        let radius = size * 0.36
        var x = location.x - size / 2
        var y = location.y - size / 2
        let distance = hypot(x, y)
        if distance > radius, distance > 0 {
            let scale = radius / distance
            x *= scale
            y *= scale
        }
        displacement = CGSize(width: x, height: y)
        onChange(Float(x / radius), Float(-y / radius))
    }

    private func reset() {
        displacement = .zero
        onChange(0, 0)
    }

    private func cancelInteraction() {
        pulseTask?.cancel()
        pulseTask = nil
        isEngaged = false
        reset()
    }

    private func pulse(x: Float, y: Float) {
        pulseTask?.cancel()
        displacement = CGSize(
            width: CGFloat(x) * size * 0.28,
            height: CGFloat(-y) * size * 0.28
        )
        onChange(x, y)
        pulseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard Task.isCancelled == false else { return }
            reset()
        }
    }
}

private struct MobileTouchpadControl: View {
    let onChange: (Float, Float, Bool) -> Void
    let onClickChange: (Bool) -> Void
    let onPressFeedback: () -> Void

    @GestureState private var gestureIsActive = false
    @State private var isPressed = false
    @State private var clickReleaseTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 2) {
                Image(systemName: "rectangle.inset.filled")
                    .font(.caption2)
                Text("Touchpad")
                    .font(.caption2.weight(.bold))
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.white.opacity(isPressed ? 0.62 : 0.24), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($gestureIsActive) { _, state, _ in state = true }
                        .onChanged { value in
                            if isPressed == false {
                                onPressFeedback()
                            }
                            isPressed = true
                            let width = max(proxy.size.width, 1)
                            let height = max(proxy.size.height, 1)
                            let x = min(1, max(-1, Float(value.location.x / width * 2 - 1)))
                            let y = min(1, max(-1, Float(1 - value.location.y / height * 2)))
                            // A drag owns touch coordinates. A short stationary
                            // gesture becomes the touchpad's digital click.
                            onChange(x, y, true)
                        }
                        .onEnded { value in
                            let distance = hypot(value.translation.width, value.translation.height)
                            releaseImmediately()
                            if distance <= 12 { click() }
                        }
                )
        }
        .frame(width: MobileTouchControlMetrics.padSwipeWidth, height: MobileTouchControlMetrics.target)
        .opacity(isPressed ? 1 : 0.82)
        .accessibilityElement()
        .accessibilityLabel("Touchpad")
        .accessibilityHint("Drag to swipe. Tap to click.")
        .onChange(of: gestureIsActive) { _, active in
            if active == false { releaseImmediately() }
        }
        .onDisappear {
            clickReleaseTask?.cancel()
            clickReleaseTask = nil
            onClickChange(false)
            releaseImmediately()
        }
    }

    private func releaseImmediately() {
        isPressed = false
        onChange(0, 0, false)
    }

    private func click() {
        clickReleaseTask?.cancel()
        onPressFeedback()
        onClickChange(true)
        clickReleaseTask = Task { @MainActor in
            try? await Task.sleep(for: MobileTouchPressState.minimumDuration)
            guard Task.isCancelled == false else { return }
            onClickChange(false)
        }
    }
}
