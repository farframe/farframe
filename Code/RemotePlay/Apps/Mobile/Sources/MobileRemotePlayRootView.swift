import ExperienceDomain
import FarframeCommerceUI
import FarframeStorefront
import PlayStationRemotePlay
import PlayStationRemotePlayUI
import SwiftUI
import UIKit

private enum MobileAppDestination: String, CaseIterable, Hashable {
    case play
    case settings
    case diagnostics
}

/// The one adaptive iOS shell. It deliberately responds to its available
/// window rather than branching on iPhone/iPad model names, which keeps the
/// same target useful in Split View and future aspect ratios.
struct MobileRemotePlayRootView: View {
    @Bindable var coordinator: MobileRemotePlayCoordinator
    @Bindable var accessStore: FarframeAccessStore
    var startGate: MobileSessionStartGate
    var menuState: MobilePlayerMenuState
    var routing: MobileBigScreenRouting
    var ownership: MobileSceneOwnership

    @Environment(\.scenePhase) private var scenePhase
    /// This window's identity, so the player can be single-occupancy without
    /// the app having to reason about `UIScene` objects.
    @State private var windowID = UUID()
    @State private var selection = MobileAppDestination.play
    @State private var pairingTarget: MobilePairingTarget?
    @State private var pairingConnectHandoff = MobilePairingConnectHandoff()
    @State private var consolePendingRemoval: MobileConsoleSummary?
    @State private var addressesTarget: PlayStationConsoleAddressesTarget?
    @State private var paywallIsPresented = false
    @State private var paywalledConsoleID: UUID?
    @State private var backgroundReconnectConsoleID: UUID?
    @State private var backgroundLease = MobileBackgroundTeardownLease()
    @State private var playStyleOnboardingIsPresented = false
    /// Records only that the question has been asked, never the answer. The
    /// answer is the quality and smooth-motion preferences a style writes.
    @AppStorage(FarframePlayStyleOnboarding.hasBeenAskedKey)
    private var playStyleWasAsked = false

    var body: some View {
        TabView(selection: $selection) {
            Tab("Play", systemImage: "play.rectangle.fill", value: .play) {
                NavigationStack {
                    playDestination
                }
            }

            Tab("Settings", systemImage: "slider.horizontal.3", value: .settings) {
                NavigationStack {
                    MobileRemotePlaySettingsView(
                        coordinator: coordinator,
                        accessStore: accessStore,
                        onShowAccess: { paywallIsPresented = true }
                    )
                }
            }

            Tab("Diagnostics", systemImage: "waveform.path.ecg", value: .diagnostics) {
                NavigationStack {
                    MobileRemotePlayDiagnosticsView(coordinator: coordinator)
                }
            }
        }
        // Three destinations, one bar, every size class.
        //
        // `.tabViewStyle(.sidebarAdaptable)` stood here on the iPad research
        // team's recommendation. On hardware it earns nothing: the sidebar it
        // reveals holds Play, Settings and Diagnostics — the same three items
        // already in the bar, in the same order — so the toggle animates the
        // shell sideways to show somebody what they were already looking at. A
        // sidebar pays for itself when a section list is longer than a bar can
        // hold, or when it survives as context beside a detail view. Neither is
        // true of three tabs, so the style and the toggle button it brings with
        // it are both gone. What is left is the default: a bottom bar on an
        // iPhone, the floating Liquid Glass bar on an iPad.
        .onAppear { ownership.windowAppeared(windowID) }
        .onDisappear { ownership.windowDisappeared(windowID) }
        // Entitlement revalidation happens wherever the first display surface
        // queued — which, with a display connected, is the external window.
        // The refusal comes back here, because the purchase belongs in the
        // window the person is actually touching.
        .onChange(of: startGate.deniedConsoleID) { _, consoleID in
            guard let consoleID, ownership.ownsPlayer(windowID) else { return }
            startGate.acknowledgeDenial()
            paywalledConsoleID = consoleID
            paywallIsPresented = true
        }
        .task {
            await coordinator.prepare()
            await accessStore.prepare()
            // Somebody who already has access — a returning install, a restore,
            // a family member covered by somebody else's Lifetime Unlock — has
            // no purchase decision to make, so there is nothing for the question
            // to wait behind. Everyone else is asked when they get access, in
            // `finishPaywalledConnection`. One rule covers both: never ask
            // before there is something to play.
            askPlayStyleIfEntitledAndUnasked()
        }
        .onChange(of: coordinator.hasActiveSession) { _, hasSession in
            if hasSession { selection = .play }
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhase(phase)
        }
        .sheet(
            item: $pairingTarget,
            onDismiss: connectAfterPairingSheetDismissal
        ) { target in
            MobilePlayStationPairingView(
                coordinator: coordinator,
                target: target,
                onConnect: queueConnectionAfterPairing
            )
        }
        .sheet(item: $addressesTarget) { target in
            PlayStationConsoleAddressesView(target: target) { host, away, route in
                try await coordinator.updateConnectionAddresses(
                    consoleID: target.id,
                    hostAddress: host,
                    awayHostAddress: away,
                    connectionRoute: route
                )
            }
            .presentationSizing(.page)
        }
        // Marking the question asked on dismissal — not on choosing — is what
        // makes Skip and a swipe-down equally final. It can never nag.
        .sheet(
            isPresented: $playStyleOnboardingIsPresented,
            onDismiss: {
                playStyleWasAsked = true
                // A connection that was waiting behind the purchase surface was
                // held for this question too, because a play style writes the
                // quality the connection is about to open at and quality is
                // fixed for the life of a session. Asking after the stream
                // started would be asking too late to matter.
                resumePaywalledConnection()
            }
        ) {
            FarframePlayStyleOnboardingView(
                currentStyle: StreamPlayStyle.matching(
                    quality: coordinator.streamQuality,
                    smoothMotionEnabled: coordinator.smoothMotionEnabled
                ),
                onChoose: { style in
                    coordinator.apply(style)
                    playStyleOnboardingIsPresented = false
                },
                onSkip: { playStyleOnboardingIsPresented = false }
            )
            // Page, not fitted: the step is a ScrollView, and fitted sizing
            // collapses a scroll view to nothing because it has no ideal
            // height of its own. Verified on an iPad Pro simulator.
            .presentationSizing(.page)
        }
        .sheet(isPresented: $paywallIsPresented, onDismiss: finishPaywalledConnection) {
            FarframePaywallView(accessStore: accessStore)
                // Give the adaptive ScrollView a bounded page-sized viewport.
                // Without an explicit sizing policy, iPad can measure the sheet
                // against its full ideal height and then visually clip the lower
                // purchase actions instead of making them reachable by scrolling.
                .presentationSizing(.page)
        }
        .confirmationDialog(
            "Remove this PS5 from this device?",
            isPresented: Binding(
                get: { consolePendingRemoval != nil },
                set: { if $0 == false { consolePendingRemoval = nil } }
            ),
            presenting: consolePendingRemoval
        ) { console in
            Button("Remove \(console.name)", role: .destructive) {
                consolePendingRemoval = nil
                Task {
                    do {
                        try await coordinator.removeConsole(console.id)
                    } catch {
                        // The coordinator publishes the authoritative failure.
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                consolePendingRemoval = nil
            }
        } message: { _ in
            Text("Its device-local Remote Play registration will be removed. Your other Apple devices are unchanged.")
        }
    }

    @ViewBuilder
    private var playDestination: some View {
        if coordinator.hasActiveSession {
            if ownership.ownsPlayer(windowID) {
                MobileRemotePlayPlayerView(
                    coordinator: coordinator,
                    menuState: menuState,
                    routing: routing,
                    onSurfaceQueued: startGate.surfaceQueued(sessionID:)
                )
            } else {
                sessionIsElsewhereCard
            }
        } else {
            MobileRemotePlayHomeView(
                coordinator: coordinator,
                accessStore: accessStore,
                reconnectConsole: reconnectConsole,
                onConnect: requestConnection,
                onShowAccess: { paywallIsPresented = true },
                onPair: { pairingTarget = MobilePairingTarget() },
                onReRegister: { pairingTarget = $0 },
                onRemove: { consolePendingRemoval = $0 },
                onEditAddresses: { console in
                    addressesTarget = PlayStationConsoleAddressesTarget(
                        id: console.id,
                        consoleName: console.name,
                        hostAddress: console.hostAddress,
                        awayHostAddress: console.awayHostAddress,
                        connectionRoute: console.connectionRoute
                    )
                }
            )
        }
    }

    private var reconnectConsole: MobileConsoleSummary? {
        guard let backgroundReconnectConsoleID else { return nil }
        return coordinator.consoles.first { $0.id == backgroundReconnectConsoleID }
    }

    private func requestConnection(_ consoleID: UUID) {
        selection = .play
        guard accessStore.allowsConnect else {
            paywalledConsoleID = consoleID
            paywallIsPresented = true
            return
        }
        beginConnection(consoleID)
    }

    private func beginConnection(_ consoleID: UUID) {
        backgroundReconnectConsoleID = nil
        Task {
            guard accessStore.allowsConnect else {
                paywalledConsoleID = consoleID
                paywallIsPresented = true
                return
            }
            _ = await coordinator.prepareConnection(consoleID: consoleID)
        }
    }

    /// The app owns one stream coordinator and one video surface, so exactly
    /// one window may present the player. A second window says where the game
    /// went rather than quietly taking the picture from the first.
    private var sessionIsElsewhereCard: some View {
        ContentUnavailableView {
            Label("Playing in another window", systemImage: "macwindow.on.rectangle")
        } description: {
            Text("Farframe streams in one window at a time. Everything else — your consoles, Settings and Diagnostics — works in as many windows as you like.")
        } actions: {
            Button("Move the Game Here") { ownership.takeOwnership(windowID) }
                .buttonStyle(.glassProminent)
        }
    }

    /// Runs when the purchase surface closes.
    ///
    /// The first-run play-style question used to fire at launch, before sign-in
    /// and before any commitment. The owner's objection on hardware was that
    /// somebody being asked to pick a streaming profile "right off the bat" has
    /// no context for the answer, and he is right — the question is about how
    /// you want to spend a connection you have not yet decided to buy. It now
    /// lands here, immediately after the trial or Lifetime Unlock choice, and
    /// ahead of any connection that choice unblocked.
    private func finishPaywalledConnection() {
        guard askPlayStyleIfEntitledAndUnasked() == false else { return }
        resumePaywalledConnection()
    }

    /// Asks what they play, once, and only once there is access to play with.
    /// Returns whether the question was presented, so the caller knows whether
    /// something else now owns the next step.
    @discardableResult
    private func askPlayStyleIfEntitledAndUnasked() -> Bool {
        guard accessStore.allowsConnect, playStyleWasAsked == false else {
            return false
        }
        playStyleOnboardingIsPresented = true
        return true
    }

    /// Starts the connection that the purchase surface interrupted, if it is
    /// still wanted. Safe to call twice: the pending console is cleared here.
    private func resumePaywalledConnection() {
        defer { paywalledConsoleID = nil }
        guard accessStore.allowsConnect, let consoleID = paywalledConsoleID else {
            return
        }
        beginConnection(consoleID)
    }

    private func queueConnectionAfterPairing(_ consoleID: UUID) {
        pairingConnectHandoff.pairingCompleted(consoleID: consoleID)
    }

    private func connectAfterPairingSheetDismissal() {
        guard let consoleID = pairingConnectHandoff.pairingSheetDismissed() else {
            return
        }
        requestConnection(consoleID)
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            backgroundLease.end()
            Task { await startGate.applicationDidBecomeActive() }

        case .inactive:
            rememberActiveConsoleForReconnect()
            Task { await coordinator.applicationWillResignActive() }

        case .background:
            rememberActiveConsoleForReconnect()
            backgroundLease.begin()
            Task {
                await coordinator.applicationDidEnterBackground()
                backgroundLease.end()
            }

        @unknown default:
            break
        }
    }

    private func rememberActiveConsoleForReconnect() {
        if let consoleID = coordinator.activeConsoleID {
            backgroundReconnectConsoleID = consoleID
        }
    }
}

@MainActor
private final class MobileBackgroundTeardownLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Farframe Remote Play teardown"
        ) { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }

}

private struct MobileRemotePlaySettingsView: View {
    @Bindable var coordinator: MobileRemotePlayCoordinator
    @Bindable var accessStore: FarframeAccessStore
    let onShowAccess: () -> Void
    @AppStorage("RemotePlayMobile.touchControlPreset")
    private var touchControlPresetRaw = MobileTouchControlPreset.play.rawValue
    @AppStorage("RemotePlayMobile.touchHapticsEnabled")
    private var touchHapticsAreEnabled = true
    @State private var legalIsExpanded = false
    /// Set when a play style is applied, so the sheet can say what changed.
    @State private var playStyleNotice: String?

    /// Derived, never stored: the style whose two settings are the ones
    /// currently set, if any. Nudging quality or smooth motion by hand simply
    /// leaves nothing marked, which is the truth.
    private var currentPlayStyle: StreamPlayStyle? {
        StreamPlayStyle.matching(
            quality: coordinator.streamQuality,
            smoothMotionEnabled: coordinator.smoothMotionEnabled
        )
    }

    var body: some View {
        Form {
            Section("Farframe Pro") {
                LabeledContent("Status", value: accessStore.statusTitle)
                Text(accessStore.statusDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button(action: onShowAccess) {
                    Label(
                        accessStore.allowsConnect ? "View Access" : "Upgrade to Pro",
                        systemImage: accessStore.entrySymbol
                    )
                }

                Button {
                    Task { await accessStore.restorePurchases() }
                } label: {
                    Label(
                        accessStore.isRestoring ? "Restoring Purchases…" : "Restore Purchases",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(accessStore.isRestoring || accessStore.purchaseInProgressID != nil)

                if let notice = accessStore.notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section(StreamPlayStyle.question) {
                ForEach(StreamPlayStyle.allCases) { style in
                    Button {
                        coordinator.apply(style)
                        playStyleNotice = style.appliedNotice(hasActiveSession: false)
                    } label: {
                        StreamPlayStyleRow(style: style, isCurrent: style == currentPlayStyle)
                    }
                    .buttonStyle(.plain)
                }
                .disabled(coordinator.hasActiveSession)

                if coordinator.hasActiveSession {
                    Text("Disconnect to change these. Quality is chosen when a connection starts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let playStyleNotice {
                    Text(playStyleNotice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Each one sets the quality and smooth motion below. You can still change either by hand.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Stream quality") {
                Toggle("Smooth motion", isOn: $coordinator.smoothMotionEnabled)
                Text("Holds a few frames so a busy Wi-Fi network does not stutter. Costs about 50 ms of input lag, and up to about 200 ms while the network is rough. Turn off for the fastest response.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if FarframeReleaseFeatures.advancedMedia {
                    Toggle("Controller feedback", isOn: $coordinator.controllerFeedbackEnabled)
                    Text("Plays the game's rumble, light bar colour, and DualSense trigger resistance on your controller.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Picker("Video enhancement", selection: $coordinator.videoEnhancement) {
                        ForEach(StreamUpscaling.allCases) { mode in
                            VStack(alignment: .leading) {
                                Text(mode.displayName)
                                Text(mode.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(mode)
                        }
                    }
                    Text(StreamUpscaling.settingFootnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Picker("Quality", selection: $coordinator.streamQuality) {
                    ForEach(MobileStreamQuality.allCases) { quality in
                        StreamQualityPresetRow(preset: quality)
                            .tag(quality)
                    }
                }
                .pickerStyle(.inline)
                .disabled(coordinator.hasActiveSession)

                Text(MobileStreamQuality.ladderFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    coordinator.hasActiveSession
                        ? MobileStreamQuality.changeNotice(
                            selected: coordinator.streamQuality,
                            active: coordinator.activeStreamQuality
                        ) + " Disconnect to change it."
                        : MobileStreamQuality.changeNotice(
                            selected: coordinator.streamQuality,
                            active: nil
                        )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Audio") {
                Toggle("Mute", isOn: $coordinator.audioIsMuted)
                Slider(value: $coordinator.audioVolume, in: 0...1) {
                    Text("Volume")
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill")
                }
                .disabled(coordinator.audioIsMuted)
            }

            Section("Controller") {
                LabeledContent(
                    "Status",
                    value: coordinator.controllerConnection.isConnected
                        ? coordinator.controllerConnection.name ?? "Connected"
                        : "On-screen controls available"
                )
                Text("Farframe is DualSense-first, with on-screen controls for controller-free play. DualSense Edge, DualShock 4, Xbox, and other Apple-compatible extended gamepads use the same shared mapping where their buttons are available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Touch layout", selection: $touchControlPresetRaw) {
                    ForEach(MobileTouchControlPreset.allCases) { preset in
                        VStack(alignment: .leading) {
                            Text(preset.displayName)
                            Text(preset.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(preset.rawValue)
                    }
                }

                // No iPad has ever shipped a Taptic Engine. Advertising a
                // toggle the hardware cannot honour is a promise the app
                // cannot keep, so the row follows the hardware, not the
                // device family.
                if MobileTouchHapticsCapability.deviceSupportsHaptics {
                    Toggle("Touch button haptics", isOn: $touchHapticsAreEnabled)
                    Text("Button haptics confirm local touch input. Console-driven rumble and adaptive-trigger effects require a separate native feedback path and are not claimed by this setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("This device has no haptic engine, so touch buttons cannot vibrate. Console-driven rumble and adaptive-trigger effects play on a connected controller and are unaffected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if MobileFeatureFlags.keyboardGameplayUI {
                    Toggle("Keyboard gameplay", isOn: $coordinator.keyboardControlsEnabled)
                    NavigationLink {
                        MobileKeyboardControlsView()
                    } label: {
                        Label("Keyboard controls", systemImage: "keyboard")
                    }
                    Text("Play with an attached hardware keyboard when no controller is paired. Keys only reach the PS5 while the player is on screen, and Command, Control and Option shortcuts never send input.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Accounts and devices") {
                Text("App Store access follows the Apple Account signed into Media & Purchases. Lifetime Unlock is shared with your Apple family through Family Sharing, so one purchase covers everyone.")
                Text("PS5 registrations remain encrypted and device-local. Pair each device separately; Farframe never syncs PlayStation credentials through iCloud.")
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                Link(
                    "Farframe Support",
                    destination: URL(string: "https://unshackledpursuit.com/farframe#support")!
                )
                DisclosureGroup("Privacy, source, and licenses", isExpanded: $legalIsExpanded) {
                    Link(
                        "Privacy Policy",
                        destination: URL(string: "https://unshackledpursuit.com/farframe#privacy")!
                    )
                    Link(
                        "Terms of Use",
                        destination: URL(string: "https://unshackledpursuit.com/farframe#terms")!
                    )
                    Link(
                        "Apple Standard EULA",
                        destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
                    )
                    Link(
                        "Source & Build Materials",
                        destination: URL(string: "https://unshackledpursuit.com/farframe#faq")!
                    )
                    NavigationLink {
                        FarframeThirdPartyNoticesView()
                    } label: {
                        Label("Third-Party Notices", systemImage: "doc.badge.gearshape")
                    }
                }
                Text("Farframe is independent and is not affiliated with or endorsed by Sony Interactive Entertainment. PlayStation and PS5 are used only to describe compatibility with user-owned equipment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .farframeReadableWidth()
        .navigationTitle("Settings")
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "—"
    }
}

private struct MobileRemotePlayDiagnosticsView: View {
    let coordinator: MobileRemotePlayCoordinator

    var body: some View {
        List {
            Section("Session") {
                LabeledContent("State", value: coordinator.phase.statusText)
                LabeledContent("Console", value: coordinator.selectedConsole?.name ?? "None")
                LabeledContent(
                    "Quality",
                    value: (coordinator.activeStreamQuality ?? coordinator.streamQuality).detail
                )
                LabeledContent(
                    "Controller",
                    value: coordinator.controllerConnection.isConnected
                        ? coordinator.controllerConnection.name ?? "Connected"
                        : "Not connected"
                )
                LabeledContent(
                    "Restricted display",
                    value: coordinator.remoteDisplayIsBlocked ? "Yes" : "No"
                )
            }

            // The owner reported he "could not click on any reports". The row
            // is fine — a UI test taps it and gets a share sheet — and there
            // was simply no report, because his sessions connected. What was
            // wrong is that this section did not say so. A heading promising a
            // "latest connection attempt" over a paragraph about reports
            // appearing automatically reads as a control that should be there
            // and is not, rather than as a state.
            //
            // It is now a value row in the same shape as the Session rows
            // directly above it, so "none" is legible as an answer, and the
            // prose says all three reasons there may be nothing: it takes a
            // failure, the failure has to happen before the picture starts,
            // and the next attempt clears it.
            Section("Latest connection attempt") {
                if let reportURL = coordinator.latestConnectionReportURL {
                    ShareLink(item: reportURL) {
                        Label("Share Connection Report", systemImage: "square.and.arrow.up")
                    }
                    if let status = coordinator.connectionReportStatusMessage {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent("Connection report", value: "None to share")
                    Text("One is written by itself when a Connect attempt fails before the picture starts, and it stays here until the next attempt. A connection that worked, or one that dropped after the game was already on screen, does not produce one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            MobileMediaDiagnosticsSections(coordinator: coordinator)

            Section("Privacy") {
                Text("These diagnostics stay on this device. Connection reports classify the saved address without including it. Reports do not contain account identity, console credentials, MAC addresses, device identifiers, native log text, or an analytics upload path.")
                    .foregroundStyle(.secondary)
            }

            Section("Connection tips") {
                Text("Audio buffer drops and video renderer drops are separate. Compare counter changes during the same scene and audio output. A configured 60 FPS profile does not prove measured display FPS.")
                    .foregroundStyle(.secondary)
            }
        }
        .farframeReadableWidth()
        .navigationTitle("Diagnostics")
    }
}

extension View {
    /// Caps a settings or diagnostics column at the same readable width the
    /// home view already uses. A `Form` or `List` row that spans a 13-inch
    /// canvas puts its label and its value most of a screen apart, which is
    /// the clearest tell that an iPhone layout was merely stretched.
    ///
    /// Driven by available width, never by the interface idiom: a narrow iPad
    /// window and an iPhone get the same answer, which is the point.
    func farframeReadableWidth(_ width: CGFloat = 1_080) -> some View {
        frame(maxWidth: width)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
    }
}

/// Attaches the shared PlayStation web sign-in only when this build supplies it.
///
/// Attach this to the pairing sheet's content, not the shell root: SwiftUI
/// presents one sheet per presenter, so a root-level sign-in sheet would wait
/// behind the pairing sheet that requested it and never appear.
struct MobileWebSignInPresentation: ViewModifier {
    let acquirer: PlayStationWebAccountIdentityAcquirer?

    func body(content: Content) -> some View {
        if let acquirer {
            content.playStationWebSignInSheet(acquirer)
        } else {
            content
        }
    }
}
