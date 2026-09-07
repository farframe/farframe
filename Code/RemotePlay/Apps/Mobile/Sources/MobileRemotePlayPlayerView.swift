import AppleMediaCore
import ExperienceDomain
import InputCore
import SwiftUI
import UIKit

/// Player state the iPadOS menu bar and the Command-key shortcut overlay have
/// to be able to reach. The player view is created and destroyed with the
/// session, and a menu command outlives it, so what a command presses is held
/// one level above the view.
@MainActor
@Observable
final class MobilePlayerMenuState {
    /// `nil` keeps the established default: on-screen controls appear unless a
    /// physical controller is connected.
    var touchControlsPreference: Bool?
    var diagnosticsOverlayIsPresented = false
}

struct MobileRemotePlayPlayerView: View {
    @Bindable var coordinator: MobileRemotePlayCoordinator
    @Bindable var menuState: MobilePlayerMenuState
    @Bindable var routing: MobileBigScreenRouting
    let onSurfaceQueued: (UUID) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var sessionIsPresented = false
    @State private var diagnosticsReportError: String?
    @State private var touchSnapshot = ControllerSnapshot.neutral
    @State private var touchLayoutGeneration = 0
    @State private var endAction: MobileSessionEndAction?
    /// The player's own way out: End offers both endings and then confirms.
    @State private var endPromptIsPresented = false
    @Namespace private var panelNamespace
    @AppStorage("RemotePlayMobile.touchControlPreset")
    private var touchControlPresetRaw = MobileTouchControlPreset.play.rawValue
    @AppStorage("RemotePlayMobile.touchHapticsEnabled") private var touchHapticsAreEnabled = true
    @AppStorage("RemotePlayMobile.videoContentMode") private var videoModeRaw = MobileVideoContentMode.fit.rawValue
    @AppStorage("RemotePlayMobile.touchOpacity") private var touchOpacity = 0.72
    @AppStorage("RemotePlayMobile.cameraSensitivity") private var cameraSensitivity = 0.8
    @AppStorage("RemotePlayMobile.autoHideSessionControls") private var autoHideChrome = true
    @AppStorage("RemotePlayMobile.thumbLayout") private var thumbLayoutRaw = MobileTouchThumbLayout.classic.rawValue
    @AppStorage("RemotePlayMobile.cameraControl") private var cameraControlRaw = MobileTouchCameraControl.stick.rawValue

    var body: some View {
        MobilePlayerCanvas(touchVisible: touchControlsAreVisible,
                           autoHideChrome: autoHideChrome,
                           preset: touchControlPreset) {
            video
        } controls: { mode, chromeVisible in
            if touchControlsAreActive {
                MobileTouchControllerOverlay(
                    mode: mode, preset: touchControlPreset,
                    hapticsAreEnabled: touchHapticsAreEnabled,
                    thumbLayout: MobileTouchThumbLayout(rawValue: thumbLayoutRaw) ?? .classic,
                    chromeVisible: chromeVisible,
                    cameraControl: cameraControl,
                    cameraSensitivity: cameraSensitivity,
                    onButtonChange: setTouchButton(_:pressed:),
                    onStickChange: setTouchStick(_:x:y:),
                    onTriggerChange: setTouchTrigger(_:value:),
                    onTouchpadChange: setTouchpad(x:y:active:),
                    onCameraPadChange: setCameraPad(x:y:)
                )
                .id(touchLayoutGeneration)
                .opacity(min(1, max(0.4, touchOpacity)))
            }
        } actions: { chromeVisible in
            MobilePlayerQuickActions(
                health: streamHealth,
                goHome: {
                    resetTouchSnapshot()
                    Task { await coordinator.goHome() }
                },
                openHealth: {
                    resetTouchSnapshot()
                    menuState.diagnosticsOverlayIsPresented = true
                },
                openSession: {
                    resetTouchSnapshot()
                    sessionIsPresented = true
                },
                endSession: {
                    resetTouchSnapshot()
                    endPromptIsPresented = true
                },
                isExpanded: chromeVisible
            )
        } onResize: {
            // Releasing held input on every resize is correct: a finger down
            // during a window drag must not stay pressed. Rebuilding the whole
            // overlay is not. iPadOS window dragging delivers a size on every
            // frame, and each rebuild tore down and restarted the haptic engine
            // through onAppear/onDisappear. The overlay already carries an
            // `.id(geometry)` that rebuilds when the resolved layout policy
            // actually changes, which is the only time it needs to.
            resetTouchSnapshot()
        }
        .overlay { connectionOverlay }
        .overlay { diagnosticsOverlay }
        .toolbarVisibility(.hidden, for: .tabBar, .navigationBar)
        .statusBarHidden(true)
        .sheet(isPresented: $sessionIsPresented) { sessionSheet }
        // End's whole confirmation, in one dialog.
        //
        // It used to be a menu on the HUD offering Disconnect and Rest, each of
        // which then opened a second dialog to confirm. Two presentations
        // chained off one dismissal is a race iOS can and does drop, and it was
        // never worth it: this dialog names both endings, styles both
        // destructively, says what each does to the console, and offers Keep
        // Playing. That is the confirmation.
        .confirmationDialog("End this session?", isPresented: $endPromptIsPresented,
                            titleVisibility: .visible) {
            Button("Disconnect, leave PS5 awake", role: .destructive) {
                Task { await coordinator.disconnect() }
            }
            if isStreaming {
                Button("Rest PS5 and disconnect", role: .destructive) {
                    Task { await coordinator.restAndDisconnect() }
                }
            }
            Button("Keep Playing", role: .cancel) {}
        } message: {
            Text("Disconnect leaves your PS5 awake so you can connect from another device. Rest turns Remote Play off on the PS5.")
        }
        .alert("PlayStation command failed", isPresented: Binding(
            get: { coordinator.actionErrorMessage != nil },
            set: { if !$0 { coordinator.dismissActionError() } }
        )) {
            Button("OK") { coordinator.dismissActionError() }
        } message: {
            Text(coordinator.actionErrorMessage ?? "Try the command again.")
        }
        .onAppear {
            synchronizeInputSurfaces()
            // A connected display only takes the picture while there is a
            // picture to take, so the external window is told when one exists.
            routing.setSessionIsLive(true)
        }
        .onChange(of: touchControlsAreActive) { _, _ in synchronizeInputSurfaces() }
        .onChange(of: gameplaySurfaceIsActive) { _, _ in synchronizeInputSurfaces() }
        .onChange(of: touchControlPresetRaw) { _, _ in invalidateTouchLayout() }
        .onChange(of: cameraSensitivity) { _, _ in invalidateTouchLayout() }
        .onChange(of: thumbLayoutRaw) { _, _ in invalidateTouchLayout() }
        .onChange(of: cameraControlRaw) { _, _ in invalidateTouchLayout() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.userDidTakeScreenshotNotification
        )) { _ in
            guard coordinator.hasActiveSession else { return }
            Task {
                do {
                    try await coordinator.saveDiagnosticsReport(trigger: .screenshot)
                } catch {
                    diagnosticsReportError = error.localizedDescription
                }
            }
        }
        .onDisappear {
            resetTouchSnapshot()
            coordinator.setTouchControlsEnabled(false)
            coordinator.setGameplaySurfaceActive(false)
            menuState.diagnosticsOverlayIsPresented = false
            routing.setSessionIsLive(false)
        }
    }

    @ViewBuilder private var diagnosticsOverlay: some View {
        if menuState.diagnosticsOverlayIsPresented {
            MobileStreamHealthOverlay(
                assessment: streamHealth,
                advice: coordinator.streamDiagnosticsAdvice,
                audio: coordinator.audioPlaybackSnapshot,
                video: coordinator.videoDiagnosticsSnapshot,
                copyDiagnosis: {
                    UIPasteboard.general.string = coordinator.streamDiagnosticsPlainText()
                },
                reportURL: coordinator.latestDiagnosticsReportURL,
                reportStatus: diagnosticsReportError ?? coordinator.diagnosticsReportStatusMessage,
                saveReport: {
                    diagnosticsReportError = nil
                    Task {
                        do {
                            try await coordinator.saveDiagnosticsReport(trigger: .manual)
                        } catch {
                            diagnosticsReportError = error.localizedDescription
                        }
                    }
                },
                close: { menuState.diagnosticsOverlayIsPresented = false }
            )
        }
    }

    private var video: some View {
        ZStack {
            Color.black
            // Exactly one surface hosts the decode. When the game is on a
            // connected display, this one is not built at all, so the presenter
            // is never asked to hold two backends it cannot hold.
            if routing.destination == .device,
               let surface = coordinator.videoSurface, let sessionID = coordinator.activeSessionID {
                MobileSampleBufferDisplayView(
                    sessionID: sessionID, videoSurface: surface,
                    onSurfaceQueued: { onSurfaceQueued(sessionID) },
                    contentMode: MobileVideoContentMode(rawValue: videoModeRaw) ?? .fit
                )
            }
            if coordinator.remoteDisplayIsBlocked {
                VStack(spacing: 12) {
                    Image(systemName: "eye.slash.fill").font(.title)
                    Text("This content is restricted").font(.headline)
                    Text("Sony blocks cloud-streamed PS Plus video in Remote Play. Open an installed game from PS5 Home.")
                        .font(.callout).multilineTextAlignment(.center)
                    Button("Go to PS5 Home") { Task { await coordinator.goHome() } }
                        .buttonStyle(.glassProminent)
                }
                .farframePlayerPanel()
            } else if let title = routing.state.deviceSubstituteTitle {
                MobileBigScreenDevicePanel(
                    title: title,
                    sizeDescription: routing.state.displaySizeDescription,
                    health: streamHealth,
                    bringItBack: { routing.preferenceIsEnabled = false }
                )
            }
        }
    }

    /// Connecting, disconnecting and ended are the same panel changing its
    /// mind, so they share one glass identity inside one container and morph
    /// between each other rather than cross-fading two separate sheets of
    /// glass over the same frame.
    @ViewBuilder private var connectionOverlay: some View {
        // The container exists only while a panel does. An empty one sitting
        // permanently over the picture is a layer between a finger and the tap
        // that brings the session shortcuts back.
        if showsConnectionPanel {
            connectionPanel
        }
    }

    private var showsConnectionPanel: Bool {
        switch coordinator.phase {
        case .prepared, .connecting, .disconnecting, .failed: true
        default: false
        }
    }

    @ViewBuilder private var connectionPanel: some View {
        GlassEffectContainer(spacing: MobilePlayerGlass.hudContainerSpacing) {
            switch coordinator.phase {
            case .prepared, .connecting:
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Connecting to PS5…").font(.headline)
                    Button("Cancel") { Task { await coordinator.cancelConnection() } }
                        .buttonStyle(.glass)
                }
                .farframePlayerPanel(maximumWidth: nil)
                .glassEffectID(MobilePlayerPanelID.connection, in: panelNamespace)
            case .disconnecting:
                ProgressView("Disconnecting…")
                    .farframePlayerPanel(maximumWidth: nil)
                    .glassEffectID(MobilePlayerPanelID.connection, in: panelNamespace)
            case .failed(let message):
                VStack(spacing: 10) {
                    Text("Connection ended").font(.headline)
                    Text(message).font(.callout).multilineTextAlignment(.center)
                }
                .farframePlayerPanel()
                .glassEffectID(MobilePlayerPanelID.connection, in: panelNamespace)
            default: EmptyView()
            }
        }
        .glassEffectTransition(.matchedGeometry)
    }

    private var sessionSheet: some View {
        NavigationStack {
            Form {
                if routing.displayIsConnected {
                    Section("Big Screen") {
                        Toggle("Play on \(routing.connectedDisplayName ?? "the connected display")",
                               isOn: $routing.preferenceIsEnabled)
                        Text("The game fills the connected display and this device keeps the controls, the stats and the session actions. Turn it off to bring the picture back here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Picture") {
                    Picker("Screen size", selection: $videoModeRaw) {
                        ForEach(MobileVideoContentMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    Text("Fit keeps the whole game visible. Fill zooms and crops. Stretch fills the screen without cropping, but changes proportions. Holding the device upright, Fill is worth trying: a 16:9 game cannot fill a tall screen on its own, and Fill uses the whole space above the controls instead of leaving bars.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Session shortcuts") {
                    Toggle("Auto-hide session shortcuts", isOn: $autoHideChrome)
                    Text("The shortcuts put themselves away after four seconds. Tap an empty part of the picture to show them, and tap again to put them away. They never disappear entirely: a small chevron stays in the top corner, so ending a session is always one tap away. Gameplay buttons are unaffected, and VoiceOver keeps the shortcuts up.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Touch controls") {
                    Toggle("Show on-screen controls", isOn: Binding(
                        get: { touchControlsAreVisible },
                        set: { menuState.touchControlsPreference = $0 }
                    ))
                    Picker("Layout", selection: $touchControlPresetRaw) {
                        ForEach(MobileTouchControlPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset.rawValue)
                        }
                    }
                    Text(touchControlPreset.detail).font(.caption).foregroundStyle(.secondary)
                    Picker("Thumb arrangement", selection: $thumbLayoutRaw) {
                        ForEach(MobileTouchThumbLayout.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Text("Classic puts the D-pad and face buttons outside, with sticks inward and lower. L3/R3 stay just above the sticks. Centred brings both hands in toward the middle for a device resting on a table, and changes nothing on a screen with no room to spare.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Camera", selection: $cameraControlRaw) {
                        ForEach(MobileTouchCameraControl.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Text(cameraControl.detail)
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Visibility", value: "\(Int(touchOpacity * 100))%")
                    Slider(value: $touchOpacity, in: 0.4...1, step: 0.05) { Text("Control visibility") }
                    LabeledContent("Camera sensitivity", value: cameraSensitivity.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $cameraSensitivity, in: 0.4...1.2, step: 0.1) { Text("Right stick sensitivity") }
                    if MobileTouchHapticsCapability.deviceSupportsHaptics {
                        Toggle("Button haptics", isOn: $touchHapticsAreEnabled)
                        Text("Haptics confirm your touches. They are not console rumble.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("This device has no haptic engine, so touch buttons cannot vibrate.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if MobileFeatureFlags.keyboardGameplayUI {
                    Section("Keyboard") {
                        Toggle("Keyboard gameplay", isOn: $coordinator.keyboardControlsEnabled)
                        NavigationLink {
                            MobileKeyboardControlsView()
                        } label: { Label("Keyboard controls", systemImage: "keyboard") }
                        Text("Play with an attached hardware keyboard when no controller is paired. Command, Control and Option shortcuts never send PS5 input.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Sound") {
                    Toggle("Mute", isOn: $coordinator.audioIsMuted)
                    Slider(value: $coordinator.audioVolume, in: 0...1) { Text("Volume") }
                        .disabled(coordinator.audioIsMuted)
                }
                Section("PlayStation") {
                    Button {
                        Task { await coordinator.goHome() }
                    } label: { Label("Go to PS5 Home", systemImage: "playstation.logo") }
                    .disabled(!isStreaming && !coordinator.remoteDisplayIsBlocked)
                    NavigationLink {
                        MobilePlayerDiagnosticsView(coordinator: coordinator)
                    } label: { Label("Stream diagnostics", systemImage: "waveform.path.ecg") }
                }
                Section {
                    Button("Disconnect — leave PS5 awake", role: .destructive) { endAction = .disconnect }
                    Button("Put PS5 in Rest Mode", role: .destructive) { endAction = .rest }
                        .disabled(!isStreaming)
                } header: { Text("End session") } footer: {
                    Text("Use Disconnect when switching to another device. Rest turns off Remote Play on the PS5.")
                }
                .disabled(isDisconnecting)
            }
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { sessionIsPresented = false }
                }
            }
            .confirmationDialog(endAction?.title ?? "End session?", isPresented: Binding(
                get: { endAction != nil }, set: { if !$0 { endAction = nil } }
            ), titleVisibility: .visible, presenting: endAction) { action in
                Button(action.confirmTitle, role: .destructive) {
                    endAction = nil
                    sessionIsPresented = false
                    Task {
                        if action == .rest { await coordinator.restAndDisconnect() }
                        else { await coordinator.disconnect() }
                    }
                }
                Button("Keep Playing", role: .cancel) { endAction = nil }
            } message: { action in Text(action.detail) }
        }
        .presentationSizing(.page)
        .preferredColorScheme(.dark)
    }

    private var isStreaming: Bool { if case .streaming = coordinator.phase { true } else { false } }
    private var isDisconnecting: Bool { if case .disconnecting = coordinator.phase { true } else { false } }
    private var touchControlsAreVisible: Bool {
        menuState.touchControlsPreference ?? !coordinator.controllerConnection.isConnected
    }
    private var touchControlPreset: MobileTouchControlPreset {
        MobileTouchControlPreset(rawValue: touchControlPresetRaw) ?? .play
    }
    private var cameraControl: MobileTouchCameraControl {
        MobileTouchCameraControl(rawValue: cameraControlRaw) ?? .stick
    }
    /// Gameplay input of any kind may reach the PS5 only from the uncovered
    /// player surface. Touch adds its own visibility rule on top of this;
    /// a hardware keyboard does not, because it is reachable whether or not
    /// the on-screen controls are drawn.
    private var gameplaySurfaceIsActive: Bool {
        isStreaming && scenePhase == .active
            && !sessionIsPresented && !menuState.diagnosticsOverlayIsPresented
            && coordinator.actionErrorMessage == nil
            && !coordinator.remoteDisplayIsBlocked
    }
    private var touchControlsAreActive: Bool {
        touchControlsAreVisible && gameplaySurfaceIsActive
    }
    private var streamHealth: MobileStreamHealthAssessment {
        MobileStreamHealthAssessment(
            audio: coordinator.audioPlaybackSnapshot,
            video: coordinator.videoDiagnosticsSnapshot
        )
    }
    private func invalidateTouchLayout() {
        resetTouchSnapshot()
        touchLayoutGeneration &+= 1
    }
    private func synchronizeInputSurfaces() {
        coordinator.setTouchControlsEnabled(touchControlsAreActive)
        coordinator.setGameplaySurfaceActive(gameplaySurfaceIsActive)
        if !touchControlsAreActive { invalidateTouchLayout() }
    }
    private func setTouchButton(_ button: ControllerButton, pressed: Bool) {
        var next = touchSnapshot
        if pressed { next.pressedButtons.insert(button) }
        else { next.pressedButtons.remove(button) }
        commitTouchSnapshot(next)
    }
    private func setTouchStick(_ stick: MobileTouchStick, x: Float, y: Float) {
        var next = touchSnapshot
        switch stick {
        case .left: next.leftX = x; next.leftY = y
        case .right:
            let response = MobileTouchCameraResponse.apply(x: x, y: y, sensitivity: Float(cameraSensitivity))
            next.rightX = response.x; next.rightY = response.y
        }
        commitTouchSnapshot(next)
    }
    private func setTouchTrigger(_ trigger: ControllerButton, value: Float) {
        var next = touchSnapshot
        let value = min(1, max(0, value))
        switch trigger {
        case .leftTrigger: next.leftTrigger = value
        case .rightTrigger: next.rightTrigger = value
        default: return
        }
        if value > 0.1 { next.pressedButtons.insert(trigger) }
        else { next.pressedButtons.remove(trigger) }
        commitTouchSnapshot(next)
    }
    /// The swipe camera has already produced a stick vector and already applied
    /// sensitivity, so it goes straight into the snapshot. Running it through
    /// `MobileTouchCameraResponse` would apply a position curve to a velocity
    /// and lose the small adjustments the control exists to make.
    private func setCameraPad(x: Float, y: Float) {
        var next = touchSnapshot
        next.rightX = x
        next.rightY = y
        commitTouchSnapshot(next)
    }
    private func setTouchpad(x: Float, y: Float, active: Bool) {
        var next = touchSnapshot
        next.touchpadX = x; next.touchpadY = y; next.touchpadActive = active
        commitTouchSnapshot(next)
    }
    private func commitTouchSnapshot(_ snapshot: ControllerSnapshot) {
        touchSnapshot = touchControlsAreActive ? snapshot : .neutral
        coordinator.setTouchControllerSnapshot(touchSnapshot)
    }
    private func resetTouchSnapshot() { commitTouchSnapshot(.neutral) }
}

enum MobileSessionEndAction: String, Identifiable {
    case disconnect, rest
    var id: String { rawValue }
    var title: String { self == .rest ? "Put PS5 in Rest Mode?" : "Disconnect from PS5?" }
    var confirmTitle: String { self == .rest ? "Rest PS5 and Disconnect" : "Disconnect" }
    var detail: String {
        self == .rest ? "The PS5 will enter Rest Mode and this stream will end."
            : "This stream will end. Your PS5 stays awake so you can connect from another device."
    }
}

enum MobileStreamHealthLevel {
    case measuring, good, watch, poor

    var title: String {
        switch self {
        case .measuring: "Measuring"
        case .good: "Good"
        case .watch: "Watch"
        case .poor: "Poor"
        }
    }

    var color: Color {
        switch self {
        case .measuring: .blue
        case .good: .green
        case .watch: .orange
        case .poor: .red
        }
    }
}

struct MobileStreamHealthAssessment {
    let level: MobileStreamHealthLevel
    let summary: String
    let audioDropPercent: Double?
    let videoPressurePercent: Double?

    init(audio: PCMAudioPlaybackSnapshot?, video: VideoPresentationRateSnapshot?) {
        let audioPercent = audio.flatMap { snapshot -> Double? in
            guard snapshot.queue.receivedBuffers > 0 else { return nil }
            return Double(snapshot.queue.droppedBuffers)
                / Double(snapshot.queue.receivedBuffers) * 100
        }
        let videoPercent = video.flatMap { snapshot -> Double? in
            guard snapshot.counters.framesSubmitted > 0 else { return nil }
            let pressure = snapshot.counters.workerBackpressureDrops
                + snapshot.counters.rendererBackpressureDrops
            return Double(pressure) / Double(snapshot.counters.framesSubmitted) * 100
        }
        audioDropPercent = audioPercent
        videoPressurePercent = videoPercent

        let feed = video?.enqueuedFramesPerSecond
        if audioPercent == nil && videoPercent == nil && feed == nil {
            level = .measuring
            summary = "Waiting for live stream counters."
        } else if (audio.map { $0.queue.receivedBuffers < 1_000 } ?? false)
                    || (video.map { $0.counters.framesSubmitted < 120 } ?? false) {
            level = .measuring
            summary = "Collecting a stable baseline before grading the stream."
        } else if (audioPercent ?? 0) >= 2 || (videoPercent ?? 0) >= 2
                    || (feed.map { $0 < 45 } ?? false) {
            level = .poor
            summary = (audioPercent ?? 0) >= 2
                ? "Audio is being shed under local playback pressure."
                : "Video delivery is under sustained pressure."
        } else if (audioPercent ?? 0) >= 0.5 || (videoPercent ?? 0) >= 0.5
                    || (feed.map { $0 < 55 } ?? false) {
            level = .watch
            summary = "The stream is playable, but delivery is not fully clean."
        } else {
            level = .good
            summary = "No meaningful local playback pressure is visible."
        }
    }

    static let measuring = MobileStreamHealthAssessment(audio: nil, video: nil)
}

struct MobilePlayerQuickActions: View {
    let health: MobileStreamHealthAssessment
    let goHome: () -> Void
    let openHealth: () -> Void
    let openSession: () -> Void
    var endSession: () -> Void = {}
    /// Whether the HUD is showing its shortcuts or is put away.
    var isExpanded = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Brings the shortcuts back. The collapsed HUD is the one affordance that
    /// does not depend on knowing the tap-the-picture gesture, and it reaches
    /// the canvas the same way the swipe camera does rather than through a
    /// closure every call site would have to remember to pass.
    @Environment(\.farframeTogglePlayerChrome) private var toggleChrome
    @Namespace private var hudNamespace

    static let accessibleTargetSize = MobilePlayerGlass.hudTargetSize
    static func usesSymbolsOnly(for dynamicTypeSize: DynamicTypeSize) -> Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    /// One sampling region for the whole HUD, and two pieces of glass in it.
    ///
    /// Liquid Glass cannot sample other glass, so glass views in separate
    /// containers each make their own light/dark decision and drift apart over
    /// the same frame. Over a 60fps decode that is both a visible mismatch and
    /// five compositing passes where one will do. Apple's guidance for exactly
    /// this shape is a container, and the strip is width-capped in
    /// `MobilePlayerCanvasGeometry` so a large canvas cannot fling its two ends
    /// to opposite edges of the screen.
    ///
    /// Inside that container the two ends are *unioned*, so PS Home and Health
    /// are one continuous capsule and End and Session are another. Four pills
    /// floating over a game read as four decisions; two fused shapes read as a
    /// HUD. It is also two glass shapes to composite per frame instead of four,
    /// on the one surface in the app where per-frame cost is not theoretical.
    ///
    /// Put away, the whole thing becomes one small capsule rather than nothing
    /// at all. That is deliberate and it is the fix for the worst part of this
    /// screen's history: a player who did not know that tapping the picture
    /// brings the shortcuts back had no way to end a session.
    var body: some View {
        GlassEffectContainer(spacing: MobilePlayerGlass.hudContainerSpacing) {
            if isExpanded {
                expandedHUD
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            } else {
                collapsedHUD
                    .transition(.opacity.combined(with: .scale(scale: 0.7, anchor: .topTrailing)))
            }
        }
    }

    private var expandedHUD: some View {
        HStack(spacing: 0) {
            HStack(spacing: MobilePlayerGlass.hudPillSpacing) {
                quickAction("PS Home", symbol: "playstation.logo",
                            cluster: .leading, perform: goHome)
                healthAction
            }
            // The two ends are pushed apart rather than packed. On a large
            // canvas this is what stops the HUD reading as one crowded lump
            // dropped on the top edge of the game.
            Spacer(minLength: MobilePlayerGlass.hudContainerSpacing)
            HStack(spacing: MobilePlayerGlass.hudPillSpacing) {
                endButton
                quickAction("Session", symbol: "slider.horizontal.3",
                            cluster: .trailing, perform: openSession)
            }
        }
    }

    /// The put-away HUD: one capsule that brings the shortcuts back.
    ///
    /// Deliberately larger than the 44-point floor. It is the only control on
    /// screen at this point and the only route out of a session, it carries no
    /// label to aim at, and it is reached one-handed around the edge of a
    /// device whose other side is being held.
    private var collapsedHUD: some View {
        Button(action: toggleChrome) {
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: MobilePlayerGlass.hudHandleSize,
                       height: MobilePlayerGlass.hudHandleSize)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Show session shortcuts")
        .accessibilityHint("PlayStation Home, stream health, ending the session and session settings")
        // Present, reachable and quiet. It is a way out, not a fifth control
        // competing with the game for attention.
        .opacity(0.55)
    }

    private var healthAction: some View {
        hudButton(cluster: .leading, action: openHealth) {
            if Self.usesSymbolsOnly(for: dynamicTypeSize) {
                Circle().fill(health.level.color)
                    .frame(width: 14, height: 14)
            } else {
                Label {
                    Text("Health")
                } icon: {
                    Circle().fill(health.level.color).frame(width: 11, height: 11)
                }
            }
        }
        .accessibilityLabel("Stream health: \(health.level.title)")
    }

    /// A glass HUD button.
    ///
    /// Hand-rolled rather than `.buttonStyle(.glass)` because a button style
    /// owns its own glass shape and cannot be unioned with its neighbour.
    /// `.interactive()` is Apple's stated way to get back exactly the touch and
    /// pointer reactions the standard glass style provides, and the plain
    /// button style keeps the real `Button` semantics — traits, actions and
    /// VoiceOver — that a custom-drawn control would have thrown away.
    ///
    /// The padding and the `contentShape` are inside the button, ahead of the
    /// glass, and that ordering is the whole fix. With `.buttonStyle(.plain)` a
    /// button answers to its label's own bounds, while `glassEffect` draws a
    /// capsule around them: the pill a player aims at was measurably larger
    /// than the control that replies, and on iPad the control was fourteen
    /// points tall. Padding first, then a shape, then glass, makes the drawn
    /// capsule and the region that answers the same rectangle.
    private func hudButton<Label: View>(
        cluster: MobilePlayerGlass.HUDCluster,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .font(.subheadline.weight(.semibold))
                .padding(MobilePlayerGlass.hudPillPadding)
                .frame(minWidth: Self.accessibleTargetSize,
                       minHeight: Self.accessibleTargetSize)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectUnion(id: cluster, namespace: hudNamespace)
    }

    /// The way out of a session, as an ordinary button.
    ///
    /// This was a `Menu` offering Disconnect and Rest directly, and it had to
    /// stop being one. A `Menu` installs its own interaction over its label and
    /// will not take a `contentShape`: adding one stops the menu presenting at
    /// all, and leaving it off leaves the control answering to the size of the
    /// word "End" rather than to its pill — the exact defect this whole change
    /// exists to remove, on the exact control a trapped player needs most. The
    /// symptom was precise: a tap on the pill fell through to the picture and
    /// merely put the HUD away.
    ///
    /// Both endings are still one tap from here, in a confirmation the player
    /// has to read. For an action that ends a stream and can put a console to
    /// sleep, a labelled confirmation is the better shape anyway.
    private var endButton: some View {
        hudButton(cluster: .trailing, action: endSession) {
            if Self.usesSymbolsOnly(for: dynamicTypeSize) {
                Image(systemName: "power")
            } else {
                Label("End", systemImage: "power")
            }
        }
        .accessibilityLabel("End session")
        .accessibilityHint("Disconnect, or put the PS5 in Rest Mode")
    }

    /// At accessibility text sizes the labels drop and the symbols stay, so the
    /// HUD keeps its strip at every text size. Full-size text and every session
    /// action remain in the scrolling Form behind Session.
    @ViewBuilder
    private func quickAction(
        _ title: String,
        symbol: String,
        cluster: MobilePlayerGlass.HUDCluster,
        perform: @escaping () -> Void
    ) -> some View {
        hudButton(cluster: cluster, action: perform) {
            if Self.usesSymbolsOnly(for: dynamicTypeSize) {
                Image(systemName: symbol)
            } else {
                Label(title, systemImage: symbol)
            }
        }
        .accessibilityLabel(title)
    }
}

private struct MobileStreamHealthOverlay: View {
    let assessment: MobileStreamHealthAssessment
    let advice: StreamDiagnosticsAdvice
    let audio: PCMAudioPlaybackSnapshot?
    let video: VideoPresentationRateSnapshot?
    let copyDiagnosis: () -> Void
    let reportURL: URL?
    let reportStatus: String?
    let saveReport: () -> Void
    let close: () -> Void

    @State private var expandedFindingID: String?
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(assessment.level.color).frame(width: 12, height: 12)
                Text("Stream health · \(assessment.level.title)")
                    .font(.headline)
                Spacer()
                Button("Close", action: close).buttonStyle(.glass)
            }
            Text(assessment.summary).font(.callout).foregroundStyle(.secondary)
            Divider().opacity(0.35)
            diagnosis
            Divider().opacity(0.35)
            metric("Audio drops", assessment.audioDropPercent.map(percent) ?? "Measuring…",
                   color: metricColor(assessment.audioDropPercent))
            if let audio {
                metric("Audio queue", "\(audio.queue.backlogMilliseconds) ms · \(audio.queue.scheduledBuffers)/\(audio.queue.highWaterMark)")
                metric("Audio underruns", "\(audio.queue.underruns) · target \(Int(audio.queue.targetLatencyMilliseconds)) ms",
                       color: audio.queue.underruns > 0 ? .orange : .green)
                metric("Audio skipped", "\(audio.queue.backpressureDrops)",
                       color: audio.queue.backpressureDrops > 0 ? .orange : .green)
            }
            metric("Renderer feed", video?.enqueuedFramesPerSecond.map {
                $0.formatted(.number.precision(.fractionLength(1))) + " frames/s"
            } ?? "Measuring…", color: feedColor(video?.enqueuedFramesPerSecond))
            if video != nil {
                metric("Video pressure", assessment.videoPressurePercent.map(percent) ?? "0.0%",
                       color: metricColor(assessment.videoPressurePercent))
            }
            Text("Percentages are cumulative for this session. Renderer feed is not measured display FPS or network loss.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Save report", systemImage: "doc.badge.plus", action: saveReport)
                    .buttonStyle(.glass)
                Button(
                    didCopy ? "Copied" : "Copy diagnosis",
                    systemImage: didCopy ? "checkmark" : "doc.on.doc"
                ) {
                    copyDiagnosis()
                    didCopy = true
                }
                .buttonStyle(.glass)
                if let reportURL {
                    ShareLink(item: reportURL) {
                        Label("Share latest", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.glass)
                }
            }
            if let reportStatus {
                Text(reportStatus).font(.caption).foregroundStyle(.secondary)
            }
            Text("Copy diagnosis puts the findings above on the clipboard as plain text, with every number explained. It is meant for pasting into a message or into an AI assistant.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Reports stay on this device unless you choose Share. They exclude account IDs, credentials, console addresses and device identifiers.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: 390)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.16)) }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The advisor's verdict and its findings. Tapping a finding opens what to
    /// try, cheapest option first.
    @ViewBuilder private var diagnosis: some View {
        Text(advice.headline)
            .font(.callout.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
        ForEach(advice.findings.prefix(4)) { finding in
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    expandedFindingID = expandedFindingID == finding.id ? nil : finding.id
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle()
                            .fill(finding.severity.indicatorColor)
                            .frame(width: 8, height: 8)
                        Text(finding.title)
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Image(systemName: expandedFindingID == finding.id ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows what to try")

                if expandedFindingID == finding.id {
                    Text(finding.what)
                        .font(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(finding.why)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(finding.actions.enumerated()), id: \.offset) { rank, action in
                        Text("\(rank + 1). \(action.text)\(action.tradeoff.map { " Trade-off: \($0)" } ?? "")")
                            .font(.caption2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        if advice.findings.count > 4 {
            Text("\(advice.findings.count - 4) more in the saved report.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, _ value: String, color: Color = .white) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(color)
        }
        .font(.caption)
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + "%"
    }

    private func metricColor(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        if value >= 2 { return .red }
        if value >= 0.5 { return .orange }
        return .green
    }

    private func feedColor(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        if value < 45 { return .red }
        if value < 55 { return .orange }
        return .green
    }
}

/// A reference sheet, not an input surface. Keyboard gameplay is armed by the
/// toggle in Session, and only while the uncovered player surface is showing.
struct MobileKeyboardControlsView: View {
    var body: some View {
        List {
            Section("Movement and camera") {
                mapping("W A S D", "Left stick · move")
                mapping("← ↓ ↑ →", "Right stick · look", spokenKeys: "Arrow keys")
            }
            Section("Buttons") {
                mapping("J / K / U / I", "Cross / Circle / Square / Triangle")
                mapping("Q / E", "L1 / R1")
                mapping("Z / C", "L2 / R2")
                mapping("F / H", "L3 / R3 · stick clicks")
                mapping("F1 / F2 / F3 / F4", "D-pad left / down / up / right")
                mapping("Return", "Options")
                mapping("V", "Create")
                mapping("P", "PlayStation button")
                mapping("T", "Touchpad click only")
            }
            Section {
                Text("Command, Control and Option shortcuts never send PS5 input, so the menu bar and system shortcuts keep working while you play.")
                Text("Trackpad and mouse gameplay is not implemented. Pointer movement and clicks do not control the PS5.")
            } footer: {
                Text("For F1–F4 you may need to hold the Fn or Globe key.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Keyboard Controls")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func mapping(_ keys: String, _ action: String, spokenKeys: String? = nil) -> some View {
        LabeledContent {
            Text(action)
        } label: {
            Text(keys).font(.callout.monospaced())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spokenKeys ?? keys): \(action)")
    }
}

struct MobilePlayerDiagnosticsView: View {
    let coordinator: MobileRemotePlayCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Two columns need enough width that each one is still readable. A page
    /// sheet on iPad reports the regular size class at about 700 points, where
    /// splitting would make both halves worse than one column.
    private static let twoColumnMinimumWidth: CGFloat = 900

    var body: some View {
        GeometryReader { proxy in
            if horizontalSizeClass == .regular, proxy.size.width >= Self.twoColumnMinimumWidth {
                // The verdict is a narrative and the counters are a table.
                // They read as one screen side by side and cost nothing to
                // separate; stretching either across a large canvas puts its
                // label and its value most of a screen apart.
                HStack(alignment: .top, spacing: 0) {
                    List {
                        sessionSection
                        diagnosisSection
                    }
                    Divider()
                    List { MobileMediaDiagnosticsSections(coordinator: coordinator) }
                }
            } else {
                List {
                    sessionSection
                    diagnosisSection
                    MobileMediaDiagnosticsSections(coordinator: coordinator)
                }
            }
        }
        .navigationTitle("Stream Diagnostics")
    }

    private var sessionSection: some View {
        Section("Session") {
            LabeledContent("State", value: coordinator.phase.statusText)
            LabeledContent("Requested quality", value: (coordinator.activeStreamQuality ?? coordinator.streamQuality).detail)
            Text("The requested frame rate is not measured display FPS.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var diagnosisSection: some View {
        MobileDiagnosisSection(advice: coordinator.streamDiagnosticsAdvice) {
            UIPasteboard.general.string = coordinator.streamDiagnosticsPlainText()
        }
    }
}

extension StreamDiagnosticsSeverity {
    var indicatorColor: Color {
        switch self {
        case .healthy: .green
        case .informational: .secondary
        case .watch: .yellow
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// The advisor's verdict as a list section: what is happening, why, and what to
/// try. Everything below it in this screen is the raw counters that back it up.
struct MobileDiagnosisSection: View {
    let advice: StreamDiagnosticsAdvice
    let copyDiagnosis: () -> Void

    @State private var didCopy = false

    var body: some View {
        Section("What these numbers mean") {
            Text(advice.headline)
                .font(.callout.weight(.medium))
            ForEach(advice.findings) { finding in
                DisclosureGroup {
                    Text(finding.what).font(.callout)
                    Text(finding.why).font(.callout).foregroundStyle(.secondary)
                    if finding.evidence.isEmpty == false {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(finding.evidence.enumerated()), id: \.offset) { _, item in
                                Text("\(item.label): \(item.value)")
                                    .font(.caption.weight(.medium))
                                Text(item.meaning)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if finding.actions.isEmpty {
                        Text("Nothing to do about this one.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("What to try, cheapest first")
                                .font(.caption.weight(.semibold))
                            ForEach(Array(finding.actions.enumerated()), id: \.offset) { rank, action in
                                Text("\(rank + 1). \(action.text)").font(.caption)
                                if let tradeoff = action.tradeoff {
                                    Text("Trade-off: \(tradeoff)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(finding.severity.indicatorColor)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.title).font(.callout)
                            Text(finding.severity.title).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button(didCopy ? "Copied" : "Copy diagnosis", systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                copyDiagnosis()
                didCopy = true
            }
            Text("Copy diagnosis puts all of this on the clipboard as plain text, with every number explained, ready to paste into a message or an AI assistant. It contains no account, console or network identifiers.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MobileMediaDiagnosticsSections: View {
    let coordinator: MobileRemotePlayCoordinator
    var body: some View {
        if let audio = coordinator.hasActiveSession ? coordinator.audioPlaybackSnapshot : coordinator.lastSessionAudioSnapshot {
            Section(coordinator.hasActiveSession ? "Audio · current session" : "Audio · last session") {
                LabeledContent("Received / rendered / dropped", value: "\(audio.queue.receivedBuffers) / \(audio.queue.renderedBuffers) / \(audio.queue.droppedBuffers)")
                LabeledContent("Queued PCM", value: "\(audio.queue.backlogMilliseconds) ms · \(audio.queue.scheduledBuffers)/\(audio.queue.highWaterMark)")
                LabeledContent("Playout target", value: "\(Int(audio.queue.targetLatencyMilliseconds)) ms")
                LabeledContent("Underruns / silence", value: "\(audio.queue.underruns) / \(Int(audio.queue.silenceMilliseconds)) ms")
                LabeledContent("Skipped to catch up", value: "\(audio.queue.backpressureDrops)")
                LabeledContent("Stale / overflow / scheduling", value: "\(audio.queue.stalePacketDrops) / \(audio.queue.pendingOverflowDrops) / \(audio.queue.schedulingFailureDrops)")
                LabeledContent("Callback gap p95", value: ms(audio.queue.callbackGapP95Milliseconds))
                LabeledContent("Worker wait p95", value: ms(audio.queue.schedulerWaitP95Milliseconds))
                LabeledContent("Conversion p95", value: ms(audio.queue.conversionP95Milliseconds))
                LabeledContent("Output sample rate", value: "\(Int(audio.queue.sampleRate)) Hz")
                LabeledContent("I/O buffer", value: ms(audio.queue.ioBufferDurationMilliseconds))
                LabeledContent("Output latency", value: ms(audio.queue.outputLatencyMilliseconds))
                LabeledContent("Presentation latency", value: ms(audio.queue.presentationLatencyMilliseconds))
                LabeledContent("Engine recoveries", value: "\(audio.recoveries)")
                Text("These are local PCM buffers, not network packets or a count of audible clicks. Rendered does not guarantee clean speaker output.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let video = coordinator.hasActiveSession ? coordinator.videoDiagnosticsSnapshot : coordinator.lastSessionVideoSnapshot {
            Section(coordinator.hasActiveSession ? "Video · current session" : "Video · last session") {
                LabeledContent("Renderer enqueue rate", value: video.enqueuedFramesPerSecond.map { $0.formatted(.number.precision(.fractionLength(1))) + " frames/s" } ?? "Measuring…")
                LabeledContent("Enqueued frames", value: "\(video.counters.framesEnqueued)")
                LabeledContent("Worker / renderer pressure drops", value: "\(video.counters.workerBackpressureDrops) / \(video.counters.rendererBackpressureDrops)")
                Text("Renderer enqueue rate is not display scan-out FPS or network loss. Last-session values are the last sampled values; nothing is uploaded or saved to disk.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func ms(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) + " ms" }
}
