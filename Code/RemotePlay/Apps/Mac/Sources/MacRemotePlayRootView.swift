import CommerceCore
import ExperienceDomain
import FarframeCommerceUI
import FarframeStorefront
import PlayStationRemotePlay
import PlayStationRemotePlayUI
import SwiftUI

/// Pure, test-visible handoff that prevents pairing completion from opening a
/// stream underneath its sheet. The one queued console ID is consumed exactly
/// once by the sheet's `onDismiss` callback.
struct MacPairingConnectHandoff: Equatable {
    private(set) var pendingConsoleID: UUID?

    mutating func pairingCompleted(consoleID: UUID) {
        pendingConsoleID = consoleID
    }

    mutating func pairingSheetDismissed() -> UUID? {
        defer { pendingConsoleID = nil }
        return pendingConsoleID
    }
}

private enum MacSidebarDestination: String, CaseIterable, Identifiable {
    case play
    case settings
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .play: "Play"
        case .settings: "Settings"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .play: "play.rectangle.fill"
        case .settings: "slider.horizontal.3"
        case .diagnostics: "waveform.path.ecg"
        }
    }
}

struct MacRemotePlayRootView: View {
    @Bindable var coordinator: MacRemotePlayCoordinator
    @Bindable var accessStore: FarframeAccessStore

    @Environment(\.scenePhase) private var scenePhase

    @State private var selection: MacSidebarDestination? = .play
    @State private var pairingTarget: MacPairingTarget?
    @State private var pairingConnectHandoff = MacPairingConnectHandoff()
    @State private var consolePendingRemoval: MacConsoleSummary?
    @State private var addressesTarget: PlayStationConsoleAddressesTarget?
    @State private var paywallIsPresented = false
    @State private var consolePendingAccess: UUID?
    @State private var playStyleOnboardingIsPresented = false
    /// Records only that the question has been asked, never the answer. The
    /// answer is the quality and smooth-motion preferences a style writes.
    @AppStorage(FarframePlayStyleOnboarding.hasBeenAskedKey)
    private var playStyleWasAsked = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                sidebarBrand
                List(MacSidebarDestination.allCases, selection: $selection) { destination in
                    Label(destination.title, systemImage: destination.symbol)
                        .tag(destination)
                }
                .listStyle(.sidebar)
            }
            .navigationTitle("Farframe")
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
            .safeAreaInset(edge: .bottom) {
                GlassEffectContainer(spacing: 10) {
                    VStack(spacing: 10) {
                        accessEntry
                        connectionSummary
                    }
                }
                .padding(12)
            }
        } detail: {
            detail
        }
        .task {
            await coordinator.prepare()
        }
        .task {
            await accessStore.prepare()
            // Somebody who already has access — a returning install, a restore,
            // a family member covered by somebody else's Lifetime Unlock — has
            // no purchase decision to make, so there is nothing for the
            // question to wait behind.
            askPlayStyleIfEntitledAndUnasked()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    if let authorization = await coordinator.applicationDidBecomeActive() {
                        await resolvePreparedSessionStart(authorization)
                    } else {
                        await accessStore.refresh()
                    }
                }
            case .inactive, .background:
                Task { await coordinator.applicationWillResignActive() }
            @unknown default:
                Task { await coordinator.applicationWillResignActive() }
            }
        }
        .onChange(of: coordinator.hasActiveSession) { _, hasSession in
            if hasSession {
                selection = .play
            }
        }
        .sheet(
            item: $pairingTarget,
            onDismiss: connectAfterPairingSheetDismissal
        ) { target in
            MacPlayStationPairingView(
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
        }
        // Marking the question asked on dismissal — not on choosing — is what
        // makes Skip and a window close equally final. It can never nag.
        .sheet(
            isPresented: $playStyleOnboardingIsPresented,
            onDismiss: {
                playStyleWasAsked = true
                // A connection held behind the purchase sheet was held for this
                // question too: a play style writes the quality a session opens
                // at, and quality is fixed once the session starts.
                resumeConnectionPendingAccess()
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
        }
        .sheet(
            isPresented: $paywallIsPresented,
            onDismiss: connectAfterPaywallDismissal
        ) {
            FarframePaywallView(accessStore: accessStore)
        }
        .confirmationDialog(
            "Remove this PS5 from this Mac?",
            isPresented: Binding(
                get: { consolePendingRemoval != nil },
                set: { isPresented in
                    if isPresented == false { consolePendingRemoval = nil }
                }
            ),
            presenting: consolePendingRemoval
        ) { console in
            Button("Remove \(console.name)", role: .destructive) {
                consolePendingRemoval = nil
                Task {
                    do {
                        try await coordinator.removeConsole(console.id)
                    } catch {
                        // The coordinator owns the mutation state and exposes
                        // the failure on Home; there is no optimistic row edit.
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                consolePendingRemoval = nil
            }
        } message: { console in
            Text("Its device-local Remote Play credential will be removed from this Mac. Other devices are unchanged.")
        }
        .onDisappear {
            Task { await coordinator.disconnect() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .play {
        case .play:
            if coordinator.hasActiveSession {
                MacRemotePlayPlayerView(
                    coordinator: coordinator,
                    onSurfaceQueued: authorizePreparedSessionStart
                )
            } else {
                MacRemotePlayHomeView(
                    coordinator: coordinator,
                    accessStore: accessStore,
                    onPair: {
                        pairingTarget = MacPairingTarget()
                    },
                    onConnect: requestConnection,
                    onShowAccess: { presentPaywall() },
                    onReRegister: { target in
                        pairingTarget = target
                    },
                    onRemove: { console in
                        consolePendingRemoval = console
                    },
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
        case .settings:
            MacRemotePlaySettingsView(
                coordinator: coordinator,
                accessStore: accessStore,
                onShowAccess: { presentPaywall() }
            )
        case .diagnostics:
            MacRemotePlayDiagnosticsView(coordinator: coordinator)
        }
    }

    private var sidebarBrand: some View {
        HStack(spacing: 10) {
            FarframeBrandMark(size: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("FARFRAME")
                    .font(.headline.weight(.bold))
                    .tracking(1)
                Text("Remote Play")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }

    private var connectionSummary: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.phase.statusText)
                    .font(.caption.weight(.semibold))
                Text(controllerText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private var accessEntry: some View {
        Button {
            presentPaywall()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: accessStore.entrySymbol)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Farframe Pro")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(accessStore.statusTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .buttonStyle(.glass)
        .help(accessStore.entryTitle)
        .accessibilityLabel(accessStore.entryTitle)
        .accessibilityValue(accessStore.statusTitle)
        .accessibilityHint("View trial, lifetime unlock, and restore options")
    }

    private var statusColor: Color {
        switch coordinator.phase {
        case .streaming: .green
        case .failed, .recoveryRequired: .orange
        case .waking, .prepared, .connecting, .disconnecting, .loading: .blue
        case .ready: .secondary
        }
    }

    private var controllerText: String {
        if coordinator.controllerConnection.isConnected {
            coordinator.controllerConnection.name ?? "Controller connected"
        } else {
            "No controller"
        }
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

    private func requestConnection(_ consoleID: UUID) {
        guard accessStore.allowsConnect else {
            presentPaywall(for: consoleID)
            return
        }
        startConnection(consoleID)
    }

    private func startConnection(_ consoleID: UUID) {
        Task {
            // Recheck on the MainActor immediately before native session
            // preparation. Active playback is never interrupted by commerce.
            guard accessStore.allowsConnect else {
                presentPaywall(for: consoleID)
                return
            }
            _ = await coordinator.prepareConnection(consoleID: consoleID)
        }
    }

    /// The AppKit display host is the final boundary before native transport
    /// starts. Revalidate after asynchronous session preparation so expiry or
    /// revocation cannot authorize a new stream from stale cached state.
    private func authorizePreparedSessionStart(_ sessionID: UUID) {
        Task {
            guard let authorization = coordinator.surfaceWasQueued(
                sessionID: sessionID
            ) else { return }
            await resolvePreparedSessionStart(authorization)
        }
    }

    private func resolvePreparedSessionStart(
        _ authorization: MacPreparedSessionStartAuthorization
    ) async {
        let isAuthorized = await accessStore.revalidateConnectionStart()
        let resolution = await coordinator.resolvePreparedSessionStart(
            authorization,
            isAuthorized: isAuthorized
        )
        guard case let .denied(consoleID) = resolution else { return }
        presentPaywall(for: consoleID)
    }

    private func presentPaywall(for consoleID: UUID? = nil) {
        consolePendingAccess = consoleID
        paywallIsPresented = true
    }

    /// Runs when the purchase sheet closes.
    ///
    /// The first-run play-style question used to fire at launch, before sign-in
    /// and before any commitment. The owner's objection on hardware was that
    /// somebody asked to pick a streaming profile "right off the bat" has no
    /// context for the answer, and he is right: the question is about how to
    /// spend a connection nobody has decided to buy yet. It now lands here,
    /// immediately after the trial or Lifetime Unlock choice and ahead of any
    /// connection that choice unblocked.
    private func connectAfterPaywallDismissal() {
        guard askPlayStyleIfEntitledAndUnasked() == false else { return }
        resumeConnectionPendingAccess()
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

    /// Starts the connection the purchase sheet interrupted, if it is still
    /// wanted. Safe to call twice: the pending console is cleared here.
    private func resumeConnectionPendingAccess() {
        defer { consolePendingAccess = nil }
        guard accessStore.allowsConnect,
              let consoleID = consolePendingAccess else { return }
        startConnection(consoleID)
    }
}

private struct MacRemotePlaySettingsView: View {
    @Bindable var coordinator: MacRemotePlayCoordinator
    @Bindable var accessStore: FarframeAccessStore
    let onShowAccess: () -> Void
    @State private var legalIsExpanded = false
    /// Set when a play style is applied, so the panel can say what changed.
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
            Section("FARFRAME PRO") {
                LabeledContent("Access", value: accessStore.statusTitle)
                Text(accessStore.statusDetail)
                    .foregroundStyle(.secondary)

                if accessStore.state.isLifetimeUnlocked == false {
                    Button {
                        onShowAccess()
                    } label: {
                        Label(accessStore.entryTitle, systemImage: accessStore.entrySymbol)
                    }
                    .buttonStyle(.glassProminent)
                }

                Button {
                    Task { await accessStore.restorePurchases() }
                } label: {
                    Label(
                        accessStore.isRestoring ? "Restoring Purchases…" : "Restore Purchases",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(
                    accessStore.isRestoring
                        || accessStore.purchaseInProgressID != nil
                )

                if let notice = accessStore.notice {
                    Text(notice)
                        .font(.caption)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let playStyleNotice {
                    Text(playStyleNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Each one sets the quality and smooth motion below. You can still change either by hand.")
                        .font(.caption)
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
                    ForEach(MacStreamQuality.allCases) { quality in
                        StreamQualityPresetRow(preset: quality)
                            .tag(quality)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(coordinator.hasActiveSession)

                Text(MacStreamQuality.ladderFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    coordinator.hasActiveSession
                        ? MacStreamQuality.changeNotice(
                            selected: coordinator.streamQuality,
                            active: coordinator.activeStreamQuality
                        ) + " Disconnect to change it."
                        : MacStreamQuality.changeNotice(
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
            }

            Section("Controller") {
                if MacFeatureFlags.keyboardGameplayUI {
                    Toggle(
                        "Keyboard controls",
                        isOn: $coordinator.keyboardControlsEnabled
                    )
                }
                LabeledContent(
                    "Game controller",
                    value: coordinator.controllerConnection.isConnected
                        ? coordinator.controllerConnection.name ?? "Connected"
                        : "Not connected"
                )
                if MacFeatureFlags.keyboardGameplayUI {
                Text("Keyboard: WASD moves, arrow keys look, J/K/U/I are Cross/Circle/Square/Triangle, Q/E are L1/R1, Z/C are L2/R2, F/H are L3/R3, F1–F4 are D-pad, Return is Options, V is Create, P is PS, and T is Touchpad Click. Click the video to focus gameplay; Escape releases keyboard focus. Input is cleared when gameplay loses focus, and Command, Control, and Option shortcuts never press PS5 controls.")
                    .foregroundStyle(.secondary)
                }
                Text("Pair a DualSense in System Settings > Bluetooth: hold Create and the PS button until the light bar flashes, then choose it in the list.")
                    .foregroundStyle(.secondary)
                Text("Farframe also accepts compatible Apple game controllers, including DualSense, DualSense Edge, DualShock 4, Xbox Wireless, Xbox Elite Series 2, and Xbox Adaptive Controller. Farframe does not read controller serial numbers or PlayStation account data from a controller.")
                    .foregroundStyle(.secondary)
            }

            Section("PlayStation account and device data") {
                Text("App Store access follows the Apple Account signed into this Mac. Farframe does not receive that account's identity, password, or payment details, and App Store access does not sign you into PlayStation.")
                    .foregroundStyle(.secondary)
                Text("PS5 registrations and Remote Play credentials are stored in this Mac's device-local Keychain. They are not copied from Vision Pro or synchronized to other devices.")
                    .foregroundStyle(.secondary)
                Text("Manual pairing uses your numeric Remote Play Account ID and the temporary eight-digit code from PS5 Settings → System → Remote Play → Link Device. Farframe never asks for your PlayStation password, cookie, or access token, and pairing must be completed separately on each device.")
                    .foregroundStyle(.secondary)
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
                Text("Farframe is an independent application and is not affiliated with, endorsed by, or sponsored by Sony Interactive Entertainment. PlayStation and PS5 names describe compatibility with user-owned equipment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "—"
    }
}

private struct MacRemotePlayDiagnosticsView: View {
    let coordinator: MacRemotePlayCoordinator

    var body: some View {
        Form {
            LabeledContent("Session", value: coordinator.phase.statusText)
            LabeledContent(
                "Console",
                value: coordinator.selectedConsole?.name ?? "None"
            )
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

            if let video = coordinator.videoDiagnosticsSnapshot {
                Section("Video pipeline") {
                    LabeledContent("Decoded / submitted", value: videoRateText(video.submittedFramesPerSecond))
                    LabeledContent("Renderer enqueued", value: videoRateText(video.enqueuedFramesPerSecond))
                    LabeledContent("Frame totals", value: "submitted \(video.counters.framesSubmitted) · enqueued \(video.counters.framesEnqueued)")
                    LabeledContent("Pressure drops", value: "worker \(video.counters.workerBackpressureDrops) · renderer \(video.counters.rendererBackpressureDrops)")
                    LabeledContent("Other drops", value: "timing \(video.counters.invalidTimingDrops) · surface \(video.counters.noSurfaceDrops) · stale \(video.counters.staleGenerationDrops)")
                    LabeledContent("Flush recoveries", value: "\(video.counters.flushRecoveries)")
                    Text("Measured between refreshes. Enqueued frames are handed to the renderer, not confirmed displayed frames. These rates are not display FPS or network receive FPS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Use the live renderer rate below the video on Play. Opening this page removes the video surface, so enqueue rate can fall to zero and surface drops can increase while Diagnostics is open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let audio = coordinator.audioPlaybackSnapshot {
                Section("Audio") {
                    LabeledContent("Received", value: "\(audio.queue.receivedBuffers) buffers")
                    LabeledContent("Played", value: "\(audio.queue.renderedBuffers) buffers")
                    LabeledContent("Dropped", value: "\(audio.queue.droppedBuffers) buffers")
                    LabeledContent("Queue", value: "\(audio.queue.backlogMilliseconds) ms")
                    LabeledContent(
                        "Drop reasons",
                        value: "underruns \(audio.queue.underruns) · skipped \(audio.queue.backpressureDrops) · stale \(audio.queue.stalePacketDrops) · overflow \(audio.queue.pendingOverflowDrops) · target \(Int(audio.queue.targetLatencyMilliseconds)) ms"
                    )
                }
            }

            Section("Privacy") {
                Text("These diagnostics stay on this Mac. They do not contain account identity, console credentials, hardware addresses, device identifiers, or an analytics upload path.")
                    .foregroundStyle(.secondary)
            }

            Section("Connection tips") {
                Text("During sustained play, Received and Played should continue increasing. If Dropped rises quickly, connect the PS5 by Ethernet when possible, use a strong local connection on this Mac, and reconnect after changing networks or audio output.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnostics")
    }

    private func videoRateText(_ rate: Double?) -> String {
        guard let rate else { return "Measuring…" }
        return "\(rate.formatted(.number.precision(.fractionLength(1)))) frames/s"
    }
}

/// Attaches the shared PlayStation web sign-in only when this build supplies it.
///
/// Attach this to the pairing sheet's content, not the shell root: SwiftUI
/// presents one sheet per presenter, so a root-level sign-in sheet would wait
/// behind the pairing sheet that requested it and never appear.
struct MacWebSignInPresentation: ViewModifier {
    let acquirer: PlayStationWebAccountIdentityAcquirer?

    func body(content: Content) -> some View {
        if let acquirer {
            content.playStationWebSignInSheet(acquirer)
        } else {
            content
        }
    }
}
