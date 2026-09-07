import AppKit
import AppleMediaCore
import ExperienceDomain
import SwiftUI

/// The Mac session surface. Video owns the whole detail area; every control
/// lives in a glass strip that fades while you play and returns on mouse
/// movement or a click, so a full-screen window shows only the game.
struct MacRemotePlayPlayerView: View {
    @Bindable var coordinator: MacRemotePlayCoordinator
    let onSurfaceQueued: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var gameplayHasKeyboardFocus: Bool
    @State private var keyboardControlsArePresented = false
    @State private var focusKeyboardAfterControlsDismissal = false
    @State private var liveDiagnosticsArePresented = false
    @State private var restConfirmationIsPresented = false
    @State private var chromeIsVisible = true
    @State private var chromeHideTask: Task<Void, Never>?
    @State private var diagnosticsReportError: String?

    private static let chromeIdleDelay: Duration = .seconds(3)

    var body: some View {
        ZStack {
            player
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusable(MacFeatureFlags.keyboardGameplayUI)
                .focused($gameplayHasKeyboardFocus)
                .focusEffectDisabled()
                .contentShape(Rectangle())
                .onTapGesture {
                    if MacFeatureFlags.keyboardGameplayUI {
                        gameplayHasKeyboardFocus = true
                    }
                    toggleChrome()
                }
                .onKeyPress(.escape) {
                    gameplayHasKeyboardFocus = false
                    revealChrome()
                    return .handled
                }

            VStack {
                Spacer(minLength: 0)
                controls
                    .opacity(chromeIsVisible ? 1 : 0)
                    .allowsHitTesting(chromeIsVisible)
                    .accessibilityHidden(chromeIsVisible == false)
            }
        }
        .background(Color.black)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                revealChrome()
            case .ended:
                scheduleChromeHide()
            }
        }
        .onAppear {
            if MacFeatureFlags.keyboardGameplayUI {
                gameplayHasKeyboardFocus = true
            }
            revealChrome()
        }
        .onChange(of: gameplayHasKeyboardFocus, initial: true) { _, hasFocus in
            coordinator.setKeyboardGameplayFocus(
                MacFeatureFlags.keyboardGameplayUI && hasFocus && !keyboardControlsArePresented
            )
        }
        .onChange(of: isStreaming) { _, streaming in
            if streaming {
                scheduleChromeHide()
            } else {
                revealChrome(keepVisible: true)
            }
        }
        .onDisappear {
            chromeHideTask?.cancel()
            chromeHideTask = nil
            focusKeyboardAfterControlsDismissal = false
            coordinator.setKeyboardGameplayFocus(false)
        }
        .navigationTitle(coordinator.selectedConsole?.name ?? "Farframe")
        .toolbar(chromeIsVisible ? .visible : .hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem {
                controllerBadge
            }
            if MacFeatureFlags.keyboardGameplayUI {
                ToolbarItem {
                    Button {
                        focusKeyboardAfterControlsDismissal = false
                        gameplayHasKeyboardFocus = false
                        coordinator.setKeyboardGameplayFocus(false)
                        keyboardControlsArePresented = true
                    } label: {
                        Label("Controls", systemImage: "keyboard")
                    }
                    .buttonStyle(.glass)
                    .tint(.blue)
                    .help("Keyboard controls and gameplay focus")
                    .accessibilityIdentifier("remoteplay.mac.keyboard-controls")
                }
            }
        }
        .sheet(
            isPresented: $keyboardControlsArePresented,
            onDismiss: keyboardControlsDidDismiss
        ) {
            MacKeyboardControlsView(
                keyboardControlsEnabled: $coordinator.keyboardControlsEnabled,
                canFocusGameplay: isStreaming,
                onEnableAndFocus: {
                    focusKeyboardAfterControlsDismissal = true
                    keyboardControlsArePresented = false
                }
            )
        }
        .confirmationDialog(
            "Put PS5 in Rest Mode?",
            isPresented: $restConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            Button("Rest PS5 and Disconnect", role: .destructive) {
                Task { await coordinator.restAndDisconnect() }
            }
            Button("Keep Playing", role: .cancel) {}
        } message: {
            Text("The PS5 will enter Rest Mode and this stream will end.")
        }
        .alert(
            "PlayStation command failed",
            isPresented: Binding(
                get: { coordinator.actionErrorMessage != nil },
                set: { isPresented in
                    if isPresented == false { coordinator.dismissActionError() }
                }
            )
        ) {
            Button("OK") { coordinator.dismissActionError() }
        } message: {
            Text(coordinator.actionErrorMessage ?? "Try the command again.")
        }
    }

    // MARK: - Chrome visibility

    private func revealChrome(keepVisible: Bool = false) {
        chromeHideTask?.cancel()
        chromeHideTask = nil
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            chromeIsVisible = true
        }
        if keepVisible == false {
            scheduleChromeHide()
        }
    }

    private func scheduleChromeHide() {
        chromeHideTask?.cancel()
        // Only an active stream hides its controls. While connecting, failed,
        // or disconnecting the strip stays put so the state is never hidden.
        guard isStreaming, liveDiagnosticsArePresented == false else { return }
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(for: Self.chromeIdleDelay)
            guard Task.isCancelled == false, isStreaming, liveDiagnosticsArePresented == false else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.25)) {
                chromeIsVisible = false
            }
        }
    }

    private func toggleChrome() {
        if chromeIsVisible, isStreaming {
            chromeHideTask?.cancel()
            chromeHideTask = nil
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) {
                chromeIsVisible = false
            }
        } else {
            revealChrome()
        }
    }

    // MARK: - Video

    @ViewBuilder
    private var player: some View {
        if let videoSurface = coordinator.videoSurface,
           let sessionID = coordinator.activeSessionID {
            ZStack {
                Color.black

                MacSampleBufferDisplayView(
                    videoSurface: videoSurface,
                    onSurfaceQueued: {
                        onSurfaceQueued(sessionID)
                    }
                )
                // A replacement session must receive a replacement AppKit view
                // and display layer. Reusing the previous representable can
                // leave decoded frames attached to the retired presenter.
                .id(sessionID)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)

                connectionOverlay

                if coordinator.remoteDisplayIsBlocked {
                    restrictedContentOverlay
                }
            }
        } else {
            ContentUnavailableView(
                "No video surface",
                systemImage: "rectangle.slash",
                description: Text("Return to Play and reconnect to your saved PS5.")
            )
        }
    }

    @ViewBuilder
    private var connectionOverlay: some View {
        switch coordinator.phase {
        case .prepared, .connecting:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Connecting to PS5…")
                    .font(.headline)
                Button("Cancel") {
                    Task { await coordinator.cancelConnection() }
                }
                .buttonStyle(.glass)
            }
            .padding(22)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))

        case .disconnecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Disconnecting…")
                    .font(.headline)
            }
            .padding(22)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))

        case .failed(let message):
            ContentUnavailableView(
                "Connection ended",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .padding(22)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))

        case .loading, .recoveryRequired, .ready, .waking, .streaming:
            EmptyView()
        }
    }

    private var restrictedContentOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "eye.slash.fill")
                .font(.title)
            Text("PlayStation Plus streaming is restricted")
                .font(.headline)
            Text("Sony blocks cloud-streamed PS Plus video inside Remote Play. Return to PlayStation Home and launch an installed game.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 470)
            Button {
                Task { await coordinator.goHome() }
            } label: {
                Label("Go to PlayStation Home", systemImage: "playstation.logo")
            }
            .buttonStyle(.glassProminent)
        }
        .padding(24)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Controls strip

    private var controls: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 16) {
                Button {
                    Task { await coordinator.goHome() }
                } label: {
                    Label("PS Home", systemImage: "playstation.logo")
                }
                .buttonStyle(.glass)
                .disabled(canSendHome == false)

                Divider()
                    .frame(height: 24)

                Button {
                    coordinator.audioIsMuted.toggle()
                } label: {
                    Image(systemName: coordinator.audioIsMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.glass)
                .accessibilityLabel(coordinator.audioIsMuted ? "Unmute" : "Mute")

                Slider(value: $coordinator.audioVolume, in: 0...1) {
                    Text("Volume")
                }
                    .frame(width: 150)
                    .disabled(coordinator.audioIsMuted)

                VStack(alignment: .leading, spacing: 3) {
                    Text((coordinator.activeStreamQuality ?? coordinator.streamQuality).detail)
                    if let rate = coordinator.videoDiagnosticsSnapshot?.enqueuedFramesPerSecond {
                        Text("Renderer: \(rate.formatted(.number.precision(.fractionLength(1)))) frames/s")
                            .help("Measured frames handed to the video renderer, not confirmed screen refreshes or network receive FPS.")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                Button {
                    liveDiagnosticsArePresented.toggle()
                } label: {
                    Label("Stats", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.glass)
                .popover(isPresented: $liveDiagnosticsArePresented, arrowEdge: .bottom) {
                    MacLiveStreamDiagnostics(
                        advice: coordinator.streamDiagnosticsAdvice,
                        audio: coordinator.audioPlaybackSnapshot,
                        video: coordinator.videoDiagnosticsSnapshot,
                        copyDiagnosis: {
                            let text = coordinator.streamDiagnosticsPlainText()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
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
                        }
                    )
                }
                .onChange(of: liveDiagnosticsArePresented) { _, presented in
                    if presented { revealChrome(keepVisible: true) } else { scheduleChromeHide() }
                }

                Spacer(minLength: 16)

                Button("Disconnect") {
                    Task { await coordinator.disconnect() }
                }
                .buttonStyle(.glass)
                .disabled(isDisconnecting)

                Button("Rest PS5") {
                    restConfirmationIsPresented = true
                }
                .buttonStyle(.glassProminent)
                .tint(.orange)
                .disabled(isStreaming == false)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .padding(12)
    }

    private var controllerBadge: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if coordinator.controllerConnection.isConnected {
                Label(
                    coordinator.controllerConnection.name ?? "Controller",
                    systemImage: "gamecontroller.fill"
                )
            } else {
                Label("No controller", systemImage: "gamecontroller")
                    .foregroundStyle(.secondary)
            }
            if MacFeatureFlags.keyboardGameplayUI {
                Text(keyboardStatus)
                    .foregroundStyle(coordinator.keyboardGameplayIsActive ? .primary : .secondary)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private var keyboardStatus: String {
        if coordinator.keyboardGameplayIsActive { return "Keyboard input enabled · Esc releases" }
        if !coordinator.keyboardControlsEnabled { return "Keyboard off" }
        if !isStreaming { return "Keyboard waiting for gameplay" }
        return "Keyboard paused · click video to focus"
    }

    private func keyboardControlsDidDismiss() {
        let shouldFocus = focusKeyboardAfterControlsDismissal
            && coordinator.keyboardControlsEnabled
            && isStreaming
            && coordinator.actionErrorMessage == nil
        focusKeyboardAfterControlsDismissal = false
        gameplayHasKeyboardFocus = shouldFocus
        if !shouldFocus { coordinator.setKeyboardGameplayFocus(false) }
    }

    private var isStreaming: Bool {
        if case .streaming = coordinator.phase { return true }
        return false
    }

    private var isDisconnecting: Bool {
        if case .disconnecting = coordinator.phase { return true }
        return false
    }

    private var canSendHome: Bool {
        isStreaming || coordinator.remoteDisplayIsBlocked
    }
}

extension StreamDiagnosticsSeverity {
    var macIndicatorColor: Color {
        switch self {
        case .healthy: .green
        case .informational: .secondary
        case .watch: .yellow
        case .warning: .orange
        case .critical: .red
        }
    }
}

private struct MacLiveStreamDiagnostics: View {
    let advice: StreamDiagnosticsAdvice
    let audio: PCMAudioPlaybackSnapshot?
    let video: MacVideoDiagnosticsSnapshot?
    let copyDiagnosis: () -> Void
    let reportURL: URL?
    let reportStatus: String?
    let saveReport: () -> Void

    @State private var expandedFindingID: String?
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Live stream health", systemImage: "waveform.path.ecg")
                .font(.headline)
            Divider()
            diagnosis
            Divider()
            metric("Audio drops", audioDropText)
            if let audio {
                metric("Audio queue", "\(audio.queue.backlogMilliseconds) ms · \(audio.queue.scheduledBuffers)/\(audio.queue.highWaterMark)")
                metric("Audio underruns", "\(audio.queue.underruns) · target \(Int(audio.queue.targetLatencyMilliseconds)) ms")
                metric("Audio skipped", "\(audio.queue.backpressureDrops)")
            }
            metric("Renderer feed", video?.enqueuedFramesPerSecond.map {
                $0.formatted(.number.precision(.fractionLength(1))) + " frames/s"
            } ?? "Measuring…")
            if let video {
                metric("Video pressure", "\(video.counters.workerBackpressureDrops) / \(video.counters.rendererBackpressureDrops)")
            }
            Text("Renderer feed is not measured display FPS or network loss.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
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
            Text("Copy diagnosis puts the findings above on the clipboard as plain text, with every number explained, ready to paste into a message or an AI assistant.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Reports stay on this Mac unless you choose Share. They exclude account IDs, credentials, console addresses and device identifiers.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 380)
    }

    /// The advisor's verdict and its findings. Clicking a finding opens what to
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
                            .fill(finding.severity.macIndicatorColor)
                            .frame(width: 8, height: 8)
                        Text(finding.title)
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Image(systemName: expandedFindingID == finding.id ? "chevron.up" : "chevron.down")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if expandedFindingID == finding.id {
                    Text(finding.what).font(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(finding.why).font(.caption2).foregroundStyle(.secondary)
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

    private var audioDropText: String {
        guard let audio, audio.queue.receivedBuffers > 0 else { return "Measuring…" }
        let percent = Double(audio.queue.droppedBuffers)
            / Double(audio.queue.receivedBuffers) * 100
        return percent.formatted(.number.precision(.fractionLength(1))) + "%"
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }
}
