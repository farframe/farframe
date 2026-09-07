import FarframeStorefront
import SwiftUI

@main
struct RemotePlayMobileApp: App {
    @State private var coordinator: MobileRemotePlayCoordinator
    @State private var accessStore: FarframeAccessStore
    @State private var startGate: MobileSessionStartGate
    @State private var menuState = MobilePlayerMenuState()
    @State private var ownership = MobileSceneOwnership()
    private let bigScreen = MobileBigScreenHost.shared

    /// Built here rather than in a view because a connected display's scene can
    /// arrive before the first window has laid out, and the external window has
    /// to be able to reach the same coordinator and the same entitlement gate
    /// the moment it appears.
    init() {
        let coordinator = MobileRemotePlayCoordinator()
        let accessStore = FarframeAccessStore()
        let startGate = MobileSessionStartGate(coordinator: coordinator, accessStore: accessStore)
        _coordinator = State(initialValue: coordinator)
        _accessStore = State(initialValue: accessStore)
        _startGate = State(initialValue: startGate)
        MobileBigScreenHost.shared.register(coordinator: coordinator, startGate: startGate)
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--farframe-player-preview") {
                MobilePlayerPreviewHarness()
            } else {
                root
            }
            #else
            root
            #endif
        }
        .commands {
            MobileSessionCommands(
                coordinator: coordinator,
                menuState: menuState,
                routing: bigScreen.routing
            )
        }
    }

    private var root: some View {
        MobileRemotePlayRootView(
            coordinator: coordinator,
            accessStore: accessStore,
            startGate: startGate,
            menuState: menuState,
            routing: bigScreen.routing,
            ownership: ownership
        )
    }
}

/// The iPadOS menu bar, and the same list under a held Command key.
///
/// Every entry here is an action the app already had; none of them is a new
/// capability. Connect is deliberately absent: starting a session has to pass
/// the access revalidation the root view performs, and a menu item that
/// bypassed it would be a commerce hole rather than a shortcut.
private struct MobileSessionCommands: Commands {
    @Bindable var coordinator: MobileRemotePlayCoordinator
    @Bindable var menuState: MobilePlayerMenuState
    @Bindable var routing: MobileBigScreenRouting
    @AppStorage("RemotePlayMobile.videoContentMode")
    private var videoModeRaw = MobileVideoContentMode.fit.rawValue
    @AppStorage("RemotePlayMobile.autoHideSessionControls") private var autoHideChrome = true

    var body: some Commands {
        CommandMenu("Session") {
            Button("Go to PS5 Home") {
                Task { await coordinator.goHome() }
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(!isStreaming && !coordinator.remoteDisplayIsBlocked)

            Button("Stream Diagnostics") {
                menuState.diagnosticsOverlayIsPresented = true
            }
            .keyboardShortcut("d")
            .disabled(!coordinator.hasActiveSession)

            Divider()

            Button("Disconnect — Leave PS5 Awake", role: .destructive) {
                Task { await coordinator.disconnect() }
            }
            .keyboardShortcut("w")
            .disabled(!coordinator.hasActiveSession)

            Button("Put PS5 in Rest Mode", role: .destructive) {
                Task { await coordinator.restAndDisconnect() }
            }
            .disabled(!isStreaming)
        }

        CommandMenu("Picture") {
            Picker("Screen Size", selection: $videoModeRaw) {
                ForEach(MobileVideoContentMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.inline)

            Divider()

            // Only offered while there is a display to offer it for. A toggle
            // for hardware nobody has plugged in is a promise the app cannot
            // keep, which is the same reason the haptics row hides itself.
            if routing.displayIsConnected {
                Toggle("Big Screen", isOn: $routing.preferenceIsEnabled)
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
            }

            Toggle("Show On-Screen Controls", isOn: Binding(
                get: {
                    menuState.touchControlsPreference
                        ?? !coordinator.controllerConnection.isConnected
                },
                set: { menuState.touchControlsPreference = $0 }
            ))
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Toggle("Auto-Hide Session Shortcuts", isOn: $autoHideChrome)

            Divider()

            Toggle("Mute", isOn: $coordinator.audioIsMuted)
                .keyboardShortcut("m")

            if MobileFeatureFlags.keyboardGameplayUI {
                Toggle("Keyboard Gameplay", isOn: $coordinator.keyboardControlsEnabled)
                    .keyboardShortcut("k")
            }
        }
    }

    private var isStreaming: Bool {
        if case .streaming = coordinator.phase { true } else { false }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// The preview, optionally inside the app's real navigation shell.
///
/// A layout harness that renders the player on its own can prove where a
/// control is drawn and nothing about whether a finger can reach it: the
/// answer to that depends on everything stacked above the player, and in the
/// running app that is a `TabView` whose iPad tab bar lands in the same strip
/// of screen as the session shortcuts. `--farframe-preview-hosted` reproduces
/// that stack so a UI test can tap the shortcuts through it, and it earned its
/// place immediately — every shortcut test passed on the bare canvas while the
/// shipping app's controls were unreachable.
private struct MobilePlayerPreviewHarness: View {
    private var isHosted: Bool {
        ProcessInfo.processInfo.arguments.contains("--farframe-preview-hosted")
    }

    var body: some View {
        if isHosted {
            TabView {
                Tab("Play", systemImage: "play.rectangle.fill") {
                    NavigationStack { MobileDisconnectedPlayerPreview() }
                }
                Tab("Settings", systemImage: "slider.horizontal.3") {
                    NavigationStack { Text("Preview stand-in") }
                }
            }
            .tabViewStyle(.sidebarAdaptable)
        } else {
            MobileDisconnectedPlayerPreview()
        }
    }
}

/// A stand-in for the live video surface with the same touch behaviour.
///
/// It draws nothing but black and holds no session, and that is enough: what a
/// harness needs from the picture is not its pixels but the fact that a real
/// `UIView` sits in the SwiftUI hierarchy underneath everything, exactly as
/// `MobileSampleBufferDisplayView` does during a session.
private struct MobilePreviewVideoSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = MobileSampleBufferDisplayUIView()
        view.backgroundColor = .black
        view.isOpaque = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Exercises the actual canvas and touch controls without starting a provider or supplying credentials.
/// The geometric picture is intentionally not a screenshot or a live game.
private struct MobileDisconnectedPlayerPreview: View {
    /// Every starting choice can be set from the launch command, because
    /// reaching the picker inside the harness needs a tap and a simulator
    /// cannot be tapped from a script. `-farframePreviewThumbLayout centred`
    /// and friends land in the argument domain of `UserDefaults`, so a capture
    /// of any arrangement is one launch rather than an edit and a rebuild.
    private static func launchChoice<T: RawRepresentable>(
        _ key: String, default fallback: T
    ) -> T where T.RawValue == String {
        UserDefaults.standard.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }

    @State private var touchVisible = true
    @State private var sessionIsPresented = false
    @State private var preset = launchChoice("farframePreviewPreset", default: MobileTouchControlPreset.play)
    @State private var videoMode = launchChoice("farframePreviewVideoMode", default: MobileVideoContentMode.fit)
    @State private var thumbLayout = launchChoice("farframePreviewThumbLayout", default: MobileTouchThumbLayout.classic)
    @State private var cameraControl = launchChoice("farframePreviewCamera", default: MobileTouchCameraControl.stick)
    /// A UI test cannot outrun a four-second fade reliably, and a flaky test
    /// about disappearing controls would teach nobody anything. Pinning the
    /// shortcuts on is how a test asks the narrower question it actually wants
    /// answered: while they are on screen, does a tap reach them?
    ///
    /// Read with a presence check and then `bool(forKey:)`. `object(forKey:)`
    /// hands back the launch argument's raw string and `"NO" as? Bool` is nil,
    /// so a cast silently kept auto-hide on and the shortcuts vanished four
    /// seconds into a test that believed it had pinned them.
    @State private var autoHideChrome = UserDefaults.standard
        .object(forKey: "farframePreviewAutoHideChrome") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "farframePreviewAutoHideChrome")
    @State private var endPromptIsPresented = false
    @State private var input = "Move either stick or press a button"

    /// Whether the picture is a real UIKit view, as it is in a live session.
    ///
    /// This is the harness's one meaningful lie. A live player draws into a
    /// `UIView` backed by `AVSampleBufferDisplayLayer`, and a `UIView` accepts
    /// touches by default whether or not anything is listening; a SwiftUI
    /// `Canvas` does not. Everything about who receives a tap on the picture is
    /// different between those two, so the harness can host either.
    private var usesVideoSurface: Bool {
        ProcessInfo.processInfo.arguments.contains("--farframe-preview-video-surface")
    }

    var body: some View {
        MobilePlayerCanvas(touchVisible: touchVisible, autoHideChrome: autoHideChrome, preset: preset) {
            GeometryReader { proxy in
                let pictureSize = videoMode.pictureSize(in: proxy.size)
                ZStack {
                    if usesVideoSurface { MobilePreviewVideoSurface() }
                    previewPicture
                        .frame(width: 640, height: 360)
                        .scaleEffect(x: pictureSize.width / 640, y: pictureSize.height / 360)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            }
        } controls: { mode, chromeVisible in
            if touchVisible && !sessionIsPresented {
                MobileTouchControllerOverlay(
                    mode: mode, preset: preset, hapticsAreEnabled: false,
                    thumbLayout: thumbLayout, chromeVisible: chromeVisible,
                    cameraControl: cameraControl,
                    onButtonChange: { button, held in input = held ? "Button held" : "Button released" },
                    onStickChange: { _, x, y in input = String(format: "Stick %.2f / %.2f", x, y) },
                    onTriggerChange: { _, value in input = String(format: "Trigger %.2f", value) },
                    onTouchpadChange: { _, _, active in input = active ? "Touchpad contact" : "Touchpad released" },
                    onCameraPadChange: { x, y in input = String(format: "Swipe camera %.2f / %.2f", x, y) }
                )
                .opacity(0.72)
            }
        } actions: { chromeVisible in
            MobilePlayerQuickActions(
                health: .measuring,
                goHome: { input = "PS Home" },
                openHealth: { input = "Health" },
                openSession: { sessionIsPresented = true },
                endSession: { endPromptIsPresented = true },
                isExpanded: chromeVisible
            )
        } onResize: {
            input = "Layout adapted — input released"
        }
        // Exactly what the real player asks for, so the hosted harness is
        // asking the platform the same question the session does.
        .toolbarVisibility(.hidden, for: .tabBar, .navigationBar)
        .statusBarHidden(true)
        // The same shape the real player uses for End, so a UI test can prove
        // the way out of a session is reachable without a PS5 to leave.
        .confirmationDialog("End this session?", isPresented: $endPromptIsPresented,
                            titleVisibility: .visible) {
            Button("Disconnect, leave PS5 awake", role: .destructive) { input = "Disconnect" }
            Button("Rest PS5 and disconnect", role: .destructive) { input = "Rest" }
            Button("Keep Playing", role: .cancel) {}
        }
        .sheet(isPresented: $sessionIsPresented) {
            NavigationStack {
                Form {
                    Section {
                        Text("Disconnected layout preview. No PS5 session, console audio or console connection.")
                        Text(input).monospaced()
                    }
                    Toggle("Show touch controls", isOn: $touchVisible)
                    Toggle("Auto-hide session shortcuts", isOn: $autoHideChrome)
                    Picker("Picture", selection: $videoMode) {
                        ForEach(MobileVideoContentMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Thumb arrangement", selection: $thumbLayout) {
                        ForEach(MobileTouchThumbLayout.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Camera", selection: $cameraControl) {
                        ForEach(MobileTouchCameraControl.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Controls", selection: $preset) {
                        ForEach(MobileTouchControlPreset.allCases) { Text($0.displayName).tag($0) }
                    }
                    Text(preset.detail)
                }
                .navigationTitle("Layout preview")
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { sessionIsPresented = false }
                } }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var previewPicture: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.12, blue: 0.23), .black],
                           startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                let horizon = size.height * 0.36
                for line in 0...16 {
                    let base = CGFloat(line) / 16 * size.width
                    var path = Path()
                    path.move(to: CGPoint(x: size.width / 2 + (base - size.width / 2) * 0.08, y: horizon))
                    path.addLine(to: CGPoint(x: base, y: size.height))
                    context.stroke(path, with: .color(.cyan.opacity(0.3)), lineWidth: 1)
                }
                for row in 0...8 {
                    let fraction = CGFloat(row) / 8
                    let y = horizon + fraction * fraction * (size.height - horizon)
                    context.stroke(Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)),
                                   with: .color(.cyan.opacity(0.25)))
                }
            }
            VStack(spacing: 8) {
                Text("FARFRAME").font(.title2.bold()).tracking(4)
                Text("16:9 • LAYOUT PREVIEW").font(.caption.monospaced()).foregroundStyle(.cyan)
                Text("Not live gameplay").font(.caption2).foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
        }
        // Stand in for fixed video pixels, not dynamically sized app text.
        .dynamicTypeSize(.large)
    }
}
#endif
