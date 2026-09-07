import AppleMediaCore
import ExperienceDomain
import FarframeCommerceUI
import Foundation
import FarframeStorefront
import GameController
import InputCore
import SwiftUI
import UIKit

struct VisionRemotePlayPlayerView: View {
    @Bindable var coordinator: VisionRemotePlayCoordinator
    @Bindable var accessStore: FarframeAccessStore

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var instanceID = UUID()
    @State private var controlsExpanded = true
    @State private var collapsedControlIsDimmed = false
    @State private var collapsedControlHasGaze = false
    @State private var showControlsMenu = false
    @State private var diagnostics: VisionPlayerDiagnostics?
    @State private var didCopyDiagnosis = false
    @State private var pinnedVolumeDragStart: Float?
    @State private var isDraggingPinnedVolume = false
    @State private var pinnedVolumeDragDidMove = false
    @FocusState private var playerFocused: Bool

    var body: some View {
        Group {
            if let videoSurface = coordinator.videoSurface,
               let sessionID = coordinator.activeSessionID {
                ZStack {
                    VisionFlatPlayerView(
                        videoSurface: videoSurface,
                        onSurfaceQueued: {
                            authorizePreparedSessionStart(sessionID: sessionID)
                        }
                    )
                    .id(sessionID)
                    connectionOverlay

                    if coordinator.remoteDisplayIsBlocked {
                        restrictedContentOverlay
                    }

                    if coordinator.streamHealthHUDEnabled, let diagnostics {
                        streamHealthOverlay(diagnostics)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .frame(
                    minWidth: 700,
                    maxWidth: 3_200,
                    minHeight: 394,
                    maxHeight: 1_800
                )
            } else {
                ContentUnavailableView {
                    Label("No Active Session", systemImage: "playstation.logo")
                } description: {
                    Text("Choose a saved console from Farframe.")
                } actions: {
                    Button {
                        returnToHome()
                    } label: {
                        HStack(spacing: 10) {
                            FarframeBrandMark(size: 22)
                            Text("Open Farframe")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .focusable(true)
        .focused($playerFocused)
        .handlesGameControllerEvents(matching: .gamepad)
        .ornament(attachmentAnchor: .scene(.trailing), contentAlignment: .leading) {
            if coordinator.videoSurface != nil {
                controlRail
            }
        }
        .onAppear {
            coordinator.claimPlayerWindow(instanceID)
            playerFocused = true
        }
        .task(id: hasNoSession) {
            // Home only opens this window after a surface exists, so being here
            // without one means the scene was restored, orphaned, or its session
            // just ended. Keyed on the condition rather than run once on appear:
            // a player that outlives its session is exactly the "No Active
            // Session" window the owner was left with on 2026-09-06, and the
            // one-shot version had already run by then.
            guard hasNoSession else { return }
            await Task.yield()
            guard hasNoSession else { return }
            returnToHome()
        }
        .onDisappear {
            Task { @MainActor in
                let wasOwningPlayer = coordinator.playerWindowDidDisappear(instanceID)
                guard wasOwningPlayer else { return }
                // Always bring Home forward; the visibility set can be stale.
                openWindow(id: VisionWindowID.setup)
                await coordinator.playerWindowClosed()
            }
        }
        .onChange(of: coordinator.phase) { _, phase in
            if case .streaming = phase {
                playerFocused = true
                // Home hides only once video is actually flowing, so the user
                // never watches every window vanish while Connect is pending.
                dismissWindow(id: VisionWindowID.setup)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    if let authorization = await coordinator.playerSceneBecameActive() {
                        await resolvePreparedSessionStart(authorization)
                    }
                }
            case .inactive:
                coordinator.playerSceneBecameInactive()
            case .background:
                coordinator.playerSceneBecameNonActive()
            @unknown default:
                coordinator.playerSceneBecameInactive()
            }
        }
        .task(id: coordinator.streamHealthHUDEnabled) {
            diagnostics = coordinator.playerDiagnosticsSnapshot()
            guard coordinator.streamHealthHUDEnabled else { return }
            var diagnosticsTick = 0

            while Task.isCancelled == false {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                diagnostics = coordinator.playerDiagnosticsSnapshot()
                diagnosticsTick += 1
                #if DEBUG
                if diagnosticsTick.isMultiple(of: 4), let diagnostics {
                    let queue = diagnostics.audio.queue
                    print(
                        "[FARFRAME Audio] in=\(queue.receivedBuffers) "
                            + "play=\(queue.renderedBuffers) "
                            + "queued=\(queue.backlogMilliseconds)ms "
                            + "target=\(Int(queue.targetLatencyMilliseconds))ms "
                            + "underruns=\(queue.underruns) "
                            + "silence=\(Int(queue.silenceMilliseconds))ms "
                            + "skip=\(queue.backpressureDrops) "
                            + "stale=\(queue.stalePacketDrops) "
                            + "overflow=\(queue.pendingOverflowDrops) "
                            + "gapP95=\(queue.callbackGapP95Milliseconds)ms "
                            + "waitP95=\(queue.schedulerWaitP95Milliseconds)ms "
                            + "conversionP95=\(queue.conversionP95Milliseconds)ms"
                    )
                    if let decoder = diagnostics.decoder {
                        print(
                            "[FARFRAME Video] in=\(decoder.samplesAdmitted) "
                                + "out=\(decoder.framesDecoded) "
                                + "q=\(decoder.pendingFrames)/\(decoder.maximumPendingFrames) "
                                + "queueDrop=\(decoder.backpressureDrops) "
                                + "keyframeReq=\(decoder.keyframeRequests) "
                                + "rebuilds=\(decoder.sessionRecoveries) "
                                + "fail=\(decoder.decodeFailures) "
                                + "renderDrop=\(diagnostics.video.workerBackpressureDrops + diagnostics.video.rendererBackpressureDrops) "
                                + "suspended=\(diagnostics.video.suspendedDrops) "
                                + "pacing=\(diagnostics.video.pacingEnabled ? "on" : "off") "
                                + "paceQ=\(diagnostics.video.pacingQueuedFrames)/\(diagnostics.video.pacingTargetFrames) "
                                + "paceUnderruns=\(diagnostics.video.pacingUnderruns) "
                                + "paceSkips=\(diagnostics.video.pacingSkips)"
                        )
                    }
                }
                #endif
            }
        }
    }

    /// The player has nothing to show. Both halves matter: the surface is what
    /// draws, and the session id is what the start authorization is keyed to.
    private var hasNoSession: Bool {
        coordinator.videoSurface == nil && coordinator.activeSessionID == nil
    }

    private func authorizePreparedSessionStart(sessionID: UUID) {
        Task {
            guard let authorization = coordinator.surfaceWasQueued(
                sessionID: sessionID
            ) else { return }
            await resolvePreparedSessionStart(authorization)
        }
    }

    private func resolvePreparedSessionStart(
        _ authorization: VisionPreparedSessionStartAuthorization
    ) async {
        let isAuthorized = await accessStore.revalidateConnectionStart()
        _ = await coordinator.resolvePreparedSessionStart(
            authorization,
            isAuthorized: isAuthorized
        )
    }

    private var restrictedContentOverlay: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "eye.slash.fill")
                .font(.title2)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("PlayStation Plus Streaming Is Restricted")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Sony blocks PS Plus cloud-streamed games from Remote Play video. Download the game to this PS5, then launch the installed copy to play it here.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)

            VStack(alignment: .leading, spacing: 8) {
                Label("Option 1: use the button below to send PS, D-pad down, then Cross and return to PlayStation Home.", systemImage: "1.circle")
                Label("Manual: press the in-app PS button, press D-pad down once, then press Cross.", systemImage: "gamecontroller.fill")
                Label("Fallback: if the console is stuck on the PS Plus prompt, disconnect, wake/relaunch Remote Play, then open an installed game.", systemImage: "arrow.clockwise")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button {
                coordinator.exitBlockedRemotePlayContent()
            } label: {
                Label("Exit to PlayStation Home", systemImage: "playstation.logo")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding()
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
                    Task {
                        await coordinator.cancelConnection()
                        returnToHome()
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))

        case .failed(let message):
            ContentUnavailableView(
                "Connection Ended",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))

        case .loading, .recoveryFailed, .registrationRequired, .ready,
             .waking, .streaming, .disconnecting, .removing:
            EmptyView()
        }
    }

    private var controlRail: some View {
        VStack(spacing: 10) {
            circleButton(
                title: controlsExpanded ? "Collapse Controls" : "Expand Controls",
                symbol: "ellipsis"
            ) {
                toggleControlsExpanded()
            }
            .opacity(controlsExpanded || collapsedControlIsDimmed == false ? 1 : 0.3)
            .scaleEffect(controlsExpanded || collapsedControlIsDimmed == false ? 1 : 0.92)
            .animation(.easeOut(duration: 0.2), value: collapsedControlIsDimmed)
            .hoverEffect(.highlight)
            .onHover { hasGaze in
                collapsedControlHasGaze = hasGaze
                guard controlsExpanded == false else { return }
                collapsedControlIsDimmed = !hasGaze
            }
            .task(id: controlsExpanded) {
                guard controlsExpanded == false else { return }
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
                guard Task.isCancelled == false,
                      collapsedControlHasGaze == false else { return }
                collapsedControlIsDimmed = true
            }

            if controlsExpanded {
                ForEach(
                    playerControlDescriptors.filter {
                        coordinator.isPlayerControlPinned($0.id)
                    }
                ) { control in
                    ornamentButton(control)
                }

                circleButton(title: "Customize Controls", symbol: "slider.horizontal.3") {
                    showControlsMenu.toggle()
                    playerFocused = true
                }
                .popover(
                    isPresented: $showControlsMenu,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .trailing
                ) {
                    controlsOverflowMenu
                }
            }
        }
        .animation(.snappy, value: coordinator.pinnedPlayerControlIDs)
        .animation(.snappy, value: controlsExpanded)
    }

    private func toggleControlsExpanded() {
        controlsExpanded.toggle()
        collapsedControlIsDimmed = false
        playerFocused = true
    }

    /// One scrolling surface, not a fixed stack with a scrolling footer. The
    /// summary, quality, diagnosis and volume blocks used to be pinned above a
    /// `ScrollView` that wrapped only the control sections, so four content
    /// blocks spent the 620pt budget and the lists the panel exists for were
    /// left scrolling through a strip barely one row tall. Everything scrolls
    /// now except the title row, which stays because it carries the two pieces
    /// of live state the rail toggles from underneath this popover.
    private var controlsOverflowMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            controlsMenuHeader
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider().opacity(0.35)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    qualityPanel
                    diagnosisExportPanel
                    volumeControlPanel

                    controlSection(
                        "Primary",
                        ids: [.psMenu, .showMain, .streamHUD]
                    )
                    controlSection("Diagnostics", ids: [.copyDiagnosis])
                    controlSection("PlayStation", ids: [.psOptions, .psCreate])
                    controlSection("Session", ids: [.sleep, .disconnect])
                    controlSection("Audio", ids: [.volume])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.visible)
        }
        .frame(width: 360)
        .frame(maxHeight: 620)
    }

    /// The only row that earns staying put: the panel's name plus the stats and
    /// volume state, on one line so it costs a row rather than a block. The
    /// title is a `subheadline` and fixed at one line because a `headline` plus
    /// both chips overflows 360pt, which wraps the title and truncates the
    /// chip to "Stats…".
    private var controlsMenuHeader: some View {
        HStack(spacing: 8) {
            Text("Customize Controls")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            controlsStatusStrip
        }
    }

    private var controlsStatusStrip: some View {
        HStack(spacing: 8) {
            statusChip(
                coordinator.streamHealthHUDEnabled ? "Stats On" : "Stats Off",
                symbol: "chart.xyaxis.line",
                isOn: coordinator.streamHealthHUDEnabled
            )
            statusChip(
                coordinator.audioIsMuted ? "Muted" : "\(volumePercent)%",
                symbol: audioSymbol,
                isOn: coordinator.audioIsMuted == false
            )
        }
        .font(.caption2.weight(.semibold))
    }

    private var qualityPanel: some View {
        let quality = coordinator.activeStreamQuality ?? coordinator.streamQuality
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The name now carries its own resolution, so appending
                // "Quality" would only repeat the line beside it.
                Label(quality.displayName, systemImage: "rectangle.and.text.magnifyingglass")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 6)
                Text(quality.detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Text("Change quality in Main App Settings. Changes apply on the next connection.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The headset's only export path. There is no saved report and no share
    /// sheet on visionOS, and nobody is going to retype a diagnosis while
    /// wearing the device, so this panel sits in the menu rather than only
    /// behind a rail button the user has to pin first.
    private var diagnosisExportPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                copyDiagnosis()
            } label: {
                Label(
                    didCopyDiagnosis ? "Diagnosis Copied" : "Copy Diagnosis",
                    systemImage: didCopyDiagnosis ? "checkmark" : "doc.on.doc"
                )
                .font(.caption.weight(.semibold))
            }
            .disabled(coordinator.activeSessionID == nil)

            Text("Puts the whole diagnosis on the clipboard as plain text, every finding and every number explained, ready to paste into a message or an AI assistant. It contains no account, console or network identifiers.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The HUD shows the verdict and the first few findings; the clipboard
    /// carries all of them, which is what makes the truncation safe here.
    private func copyDiagnosis() {
        guard let text = coordinator.streamDiagnosticsPlainText() else { return }
        UIPasteboard.general.string = text
        didCopyDiagnosis = true
        playerFocused = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyDiagnosis = false
        }
    }

    private var volumeControlPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(coordinator.audioIsMuted ? "Volume Muted" : "Volume", systemImage: audioSymbol)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(volumePercent)%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { Double(coordinator.audioVolume) },
                    set: { setAudioVolume($0) }
                ),
                in: 0...1
            )
            .help("Volume. Drag to 0% to mute.")
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func controlSection(
        _ title: String,
        ids: [VisionPlayerControlID]
    ) -> some View {
        let controls = ids.compactMap { descriptor(for: $0) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)

            ForEach(controls) { control in
                controlRow(control)
            }
        }
    }

    private func controlRow(_ control: VisionPlayerControlDescriptor) -> some View {
        HStack(spacing: 10) {
            Button {
                control.action()
            } label: {
                HStack(spacing: 10) {
                    controlGlyph(control, size: 24)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(control.label)
                            .font(.callout.weight(.medium))
                        if let detail = control.detail {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                coordinator.setPlayerControl(
                    control.id,
                    pinned: coordinator.isPlayerControlPinned(control.id) == false
                )
            } label: {
                let isPinned = coordinator.isPlayerControlPinned(control.id)
                Label(
                    isPinned ? "Shown" : "Add",
                    systemImage: isPinned ? "checkmark.circle.fill" : "plus.circle"
                )
                .font(.caption.weight(.semibold))
                .frame(width: 72)
                .padding(.vertical, 6)
                .foregroundStyle(isPinned ? .blue : .secondary)
                .background(
                    isPinned ? Color.blue.opacity(0.14) : Color.secondary.opacity(0.10),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .help(
                coordinator.isPlayerControlPinned(control.id)
                    ? "Hide \(control.label)"
                    : "Show \(control.label)"
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var playerControlDescriptors: [VisionPlayerControlDescriptor] {
        [
            VisionPlayerControlDescriptor(
                id: .psMenu,
                label: "PS Menu",
                symbol: "playstation.logo",
                detail: "Opens the PS5 control center"
            ) {
                coordinator.pulse(.playStation)
            },
            VisionPlayerControlDescriptor(
                id: .volume,
                label: coordinator.audioIsMuted ? "Volume Muted" : "Volume",
                symbol: audioSymbol,
                detail: "\(volumePercent)% — tap to mute; drag to adjust",
                isOn: coordinator.audioIsMuted == false && coordinator.audioVolume > 0
            ) {
                toggleAudioMute()
            },
            VisionPlayerControlDescriptor(
                id: .psOptions,
                label: "Options",
                symbol: "line.3.horizontal",
                detail: "Direct PS5 Options"
            ) {
                coordinator.pulse(.options)
            },
            VisionPlayerControlDescriptor(
                id: .psCreate,
                label: "PS5 Create",
                symbol: "record.circle",
                detail: "Opens the console capture and sharing menu"
            ) {
                coordinator.pulse(.create)
            },
            VisionPlayerControlDescriptor(
                id: .showMain,
                label: "Farframe Home",
                symbol: "macwindow",
                detail: "Brings Farframe Home and Settings to the front",
                usesBrandMark: true
            ) {
                showMainWindow()
            },
            VisionPlayerControlDescriptor(
                id: .streamHUD,
                label: "Stats",
                symbol: "chart.xyaxis.line",
                detail: "Shows live video, audio, and controller health",
                isOn: coordinator.streamHealthHUDEnabled
            ) {
                coordinator.streamHealthHUDEnabled.toggle()
            },
            VisionPlayerControlDescriptor(
                id: .copyDiagnosis,
                label: didCopyDiagnosis ? "Diagnosis Copied" : "Copy Diagnosis",
                symbol: didCopyDiagnosis ? "checkmark" : "doc.on.doc",
                detail: "Puts the full stream diagnosis on the clipboard as plain text",
                isOn: didCopyDiagnosis
            ) {
                copyDiagnosis()
            },
            VisionPlayerControlDescriptor(
                id: .sleep,
                label: "Rest PS5",
                symbol: "moon.zzz.fill",
                detail: "Puts the connected PS5 in Rest Mode, then disconnects"
            ) {
                Task {
                    await coordinator.restAndDisconnect()
                    returnToHome()
                }
            },
            VisionPlayerControlDescriptor(
                id: .disconnect,
                label: "Disconnect",
                symbol: "cable.connector.slash",
                detail: "Ends Remote Play and leaves the PS5 awake"
            ) {
                Task {
                    await coordinator.disconnect()
                    returnToHome()
                }
            },
        ]
    }

    private func descriptor(
        for id: VisionPlayerControlID
    ) -> VisionPlayerControlDescriptor? {
        playerControlDescriptors.first { $0.id == id }
    }

    private func ornamentButton(_ control: VisionPlayerControlDescriptor) -> some View {
        Group {
            if control.id == .volume {
                pinnedVolumeControl(control)
            } else {
                circleButton(
                    title: control.label,
                    symbol: control.symbol,
                    isOn: control.isOn,
                    usesBrandMark: control.usesBrandMark
                ) {
                    control.action()
                    playerFocused = true
                }
            }
        }
        .transition(.scale.combined(with: .opacity))
    }

    private func pinnedVolumeControl(_ control: VisionPlayerControlDescriptor) -> some View {
        Button {
            if pinnedVolumeDragDidMove == false {
                toggleAudioMute()
            }
        } label: {
            Image(systemName: control.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(control.isOn ? .blue : .primary)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            if isDraggingPinnedVolume {
                Text("\(volumePercent)%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .offset(x: -64)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if pinnedVolumeDragStart == nil {
                        pinnedVolumeDragStart = coordinator.audioIsMuted
                            ? 0
                            : coordinator.audioVolume
                        playerFocused = true
                    }

                    let horizontalDistance = value.translation.width
                    pinnedVolumeDragDidMove = true
                    isDraggingPinnedVolume = true
                    let startingVolume = pinnedVolumeDragStart ?? 0
                    setAudioVolume(
                        Double(startingVolume) + Double(horizontalDistance / 120)
                    )
                }
                .onEnded { _ in
                    pinnedVolumeDragStart = nil
                    isDraggingPinnedVolume = false
                    playerFocused = true
                    Task { @MainActor in
                        await Task.yield()
                        pinnedVolumeDragDidMove = false
                    }
                }
        )
        .animation(.easeOut(duration: 0.15), value: isDraggingPinnedVolume)
        .help("Volume \(volumePercent)%. Tap to mute; drag left or right to adjust.")
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue(
            coordinator.audioIsMuted ? "Muted" : "\(volumePercent) percent"
        )
        .accessibilityHint("Tap to mute or unmute. Drag left or right to adjust volume.")
        .accessibilityAdjustableAction { direction in
            let currentVolume = coordinator.audioIsMuted
                ? 0
                : Double(coordinator.audioVolume)
            switch direction {
            case .increment:
                setAudioVolume(currentVolume + 0.1)
            case .decrement:
                setAudioVolume(currentVolume - 0.1)
            @unknown default:
                break
            }
        }
        .onDisappear {
            pinnedVolumeDragStart = nil
            isDraggingPinnedVolume = false
            pinnedVolumeDragDidMove = false
        }
    }

    @ViewBuilder
    private func controlGlyph(_ control: VisionPlayerControlDescriptor, size: CGFloat) -> some View {
        if control.usesBrandMark {
            FarframeBrandMark(size: size)
        } else {
            Image(systemName: control.symbol)
                .font(size >= 28 ? .title3.weight(.semibold) : .body.weight(.semibold))
                .foregroundStyle(control.isOn ? .blue : .primary)
        }
    }

    private func circleButton(
        title: String,
        symbol: String,
        isOn: Bool = false,
        usesBrandMark: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if usesBrandMark {
                    FarframeBrandMark(size: 28)
                } else {
                    Image(systemName: symbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isOn ? .blue : .primary)
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Circle())
        .clipShape(Circle())
        .contentShape(Circle())
        .help(title)
        .accessibilityLabel(title)
    }

    private func statusChip(
        _ label: String,
        symbol: String,
        isOn: Bool
    ) -> some View {
        Label(label, systemImage: symbol)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(isOn ? Color.primary : Color.secondary)
            .background(
                isOn ? Color.blue.opacity(0.14) : Color.secondary.opacity(0.12),
                in: Capsule()
            )
    }

    /// Opens Home, then closes this player window. `openWindow` on a single
    /// `Window` scene brings an existing Home forward, so this never consults
    /// the coordinator's visibility set to decide *whether* to open Home, which
    /// can go stale when the system destroys a scene without an `onDisappear`.
    ///
    /// It does wait for Home before dismissing. Streaming dismisses Home, so at
    /// disconnect the player is usually the app's only window, and visionOS
    /// refuses to close the last one: a single `Task.yield()` was not enough for
    /// the new Home scene to exist, the dismiss was swallowed, and the owner was
    /// left staring at an orphaned "No Active Session" player on 2026-09-06.
    /// The wait is bounded and the dismiss is issued either way, so a stale or
    /// never-arriving visibility signal costs a short delay, never the close.
    private func returnToHome() {
        Task { @MainActor in
            openWindow(id: VisionWindowID.setup)
            for _ in 0..<Self.homeReadinessPollCount {
                if coordinator.setupWindowIsPresented { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            dismissWindow(id: VisionWindowID.player)
        }
    }

    /// Up to one second of 50 ms polls.
    private static let homeReadinessPollCount = 20

    /// Always brings Home forward. Closing Home is done on Home itself.
    private func showMainWindow() {
        openWindow(id: VisionWindowID.setup)
    }

    private var volumePercent: Int {
        Int((coordinator.audioVolume * 100).rounded())
    }

    private var audioSymbol: String {
        if coordinator.audioIsMuted || coordinator.audioVolume <= 0.001 {
            return "speaker.slash.fill"
        }
        if coordinator.audioVolume < 0.35 {
            return "speaker.wave.1.fill"
        }
        return "speaker.wave.2.fill"
    }

    private func setAudioVolume(_ value: Double) {
        let clamped = Float(min(1, max(0, value)))
        coordinator.audioVolume = clamped
        coordinator.audioIsMuted = clamped <= 0.001
    }

    private func toggleAudioMute() {
        if coordinator.audioIsMuted {
            if coordinator.audioVolume <= 0.001 {
                setAudioVolume(0.7)
            } else {
                coordinator.audioIsMuted = false
            }
        } else {
            coordinator.audioIsMuted = true
        }
    }

    private func streamHealthOverlay(
        _ diagnostics: VisionPlayerDiagnostics
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Remote Play")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("Connected")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider().opacity(0.35)

            metricRow("Profile", diagnostics.quality.detail)
            metricRow("Decode", formattedDecoderStats(diagnostics.decoder))
            metricRow("Render", formattedVideoStats(diagnostics.video))
            metricRow("Pacing", formattedPacing(diagnostics.video))
            metricRow("Enhancement", formattedUpscaling(diagnostics.video))
            metricRow("Video Drops", formattedVideoDrops(diagnostics.video))
            metricRow("Audio", formattedAudioState(diagnostics.audio))
            metricRow("Audio Queue", formattedAudioQueue(diagnostics.audio))
            metricRow("Audio Drops", formattedAudioDrops(diagnostics.audio))
            metricRow("Audio Timing", formattedAudioTiming(diagnostics.audio))
            metricRow("Audio Route", formattedAudioRoute(diagnostics.audio))
            metricRow(
                "Controller",
                diagnostics.controllerIsConnected
                    ? diagnostics.controllerName ?? "Connected"
                    : "Not Connected"
            )
            metricRow("Buttons", diagnostics.controllerHasInput ? "Active" : "Idle")
            metricRow("Mapping", "Standard · right Options · left Create")

            Divider().opacity(0.35)
            diagnosisRows(diagnostics.advice)
        }
        .padding(12)
        .frame(width: 350)
        .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .foregroundStyle(.white)
        .padding(.top, 18)
        .padding(.trailing, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
    }

    /// The advisor's reading of the rows above: what the numbers mean and the
    /// first thing to try. This surface has room for the verdict and the top
    /// four findings, matching the Mobile and Mac panels. Anything past that is
    /// reachable through Copy Diagnosis, which puts every finding on the
    /// clipboard; there is no saved report on visionOS to point at instead.
    @ViewBuilder private func diagnosisRows(
        _ advice: StreamDiagnosticsAdvice
    ) -> some View {
        Text(advice.headline)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(advice.findings.prefix(4)) { finding in
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(severityColor(finding.severity))
                        .frame(width: 7, height: 7)
                    Text(finding.title)
                        .font(.caption2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let first = finding.actions.first {
                    Text("Try first: \(first.text)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if advice.findings.count > 4 {
            Text("\(advice.findings.count - 4) more. Use Copy Diagnosis for all of them.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func severityColor(_ severity: StreamDiagnosticsSeverity) -> Color {
        switch severity {
        case .healthy: .green
        case .informational: .white.opacity(0.6)
        case .watch: .yellow
        case .warning: .orange
        case .critical: .red
        }
    }

    private func formattedVideoStats(
        _ stats: SampleBufferVideoPresentationSnapshot
    ) -> String {
        guard stats.framesSubmitted > 0 else { return "--" }
        let drops = videoDropCount(stats)
        let percent = Double(drops) / Double(stats.framesSubmitted) * 100
        return "q \(stats.framesEnqueued)/\(stats.framesSubmitted) drop \(drops) (\(String(format: "%.1f", percent))%) flush \(stats.flushRecoveries)"
    }

    private func formattedDecoderStats(_ stats: HEVCDecoderDiagnostics?) -> String {
        guard let stats, stats.samplesAdmitted > 0 else { return "--" }
        return "in \(stats.samplesAdmitted) out \(stats.framesDecoded) q \(stats.pendingFrames)/\(stats.maximumPendingFrames) · queue-drop \(stats.backpressureDrops) · keyframe req \(stats.keyframeRequests) · rebuilds \(stats.sessionRecoveries) · fail \(stats.decodeFailures)"
    }

    private func formattedPacing(_ stats: SampleBufferVideoPresentationSnapshot) -> String {
        guard stats.pacingEnabled else { return "off (lowest latency)" }
        return "q \(stats.pacingQueuedFrames)/\(stats.pacingTargetFrames) frames · underruns \(stats.pacingUnderruns) · skipped \(stats.pacingSkips)"
    }

    private func formattedUpscaling(
        _ stats: SampleBufferVideoPresentationSnapshot
    ) -> String {
        guard stats.upscaling != .off else { return "off" }
        let upscaler = stats.upscaler
        guard upscaler.outputWidth > 0 else {
            return "\(stats.upscaling.displayName) · starting"
        }
        let gpu = String(format: "%.2f", upscaler.lastGPUMilliseconds)
        return "\(stats.upscaling.displayName) · \(upscaler.backendName)"
            + " \(upscaler.outputWidth)x\(upscaler.outputHeight)"
            + " · up \(upscaler.framesUpscaled) pass \(upscaler.framesPassedThrough)"
            + " fail \(upscaler.upscaleFailures) · gpu \(gpu)ms"
            + (upscaler.disabled ? " · DISABLED" : "")
    }

    private func formattedVideoDrops(
        _ stats: SampleBufferVideoPresentationSnapshot
    ) -> String {
        "worker \(stats.workerBackpressureDrops), renderer \(stats.rendererBackpressureDrops), timing \(stats.invalidTimingDrops)"
    }

    private func videoDropCount(
        _ stats: SampleBufferVideoPresentationSnapshot
    ) -> UInt64 {
        stats.staleGenerationDrops
            + stats.noSurfaceDrops
            + stats.workerBackpressureDrops
            + stats.rendererBackpressureDrops
            + stats.invalidTimingDrops
    }

    private func formattedAudioState(_ snapshot: PCMAudioPlaybackSnapshot) -> String {
        let state = switch snapshot.state {
        case .inactive: "Inactive"
        case .activating: "Starting"
        case .playing: "Playing"
        case .recovering: "Recovering"
        case .failed: "Failed"
        }
        guard let format = snapshot.negotiatedFormat else { return state }
        return "\(state) · \(format.channelCount)ch · \(format.sampleRate)Hz"
    }

    private func formattedAudioQueue(_ snapshot: PCMAudioPlaybackSnapshot) -> String {
        let queue = snapshot.queue
        return "\(queue.backlogMilliseconds)ms of \(Int(queue.targetLatencyMilliseconds))ms target · in \(queue.receivedBuffers) play \(queue.renderedBuffers) drop \(queue.droppedBuffers)"
    }

    private func formattedAudioDrops(_ snapshot: PCMAudioPlaybackSnapshot) -> String {
        let queue = snapshot.queue
        return "underruns \(queue.underruns) · silence \(Int(queue.silenceMilliseconds))ms · skipped \(queue.backpressureDrops) · stale \(queue.stalePacketDrops) · overflow \(queue.pendingOverflowDrops)"
    }

    private func formattedAudioTiming(_ snapshot: PCMAudioPlaybackSnapshot) -> String {
        let queue = snapshot.queue
        return "gap \(String(format: "%.1f", queue.callbackGapP95Milliseconds))ms wait \(String(format: "%.1f", queue.schedulerWaitP95Milliseconds))ms conv \(String(format: "%.2f", queue.conversionP95Milliseconds))ms"
    }

    private func formattedAudioRoute(_ snapshot: PCMAudioPlaybackSnapshot) -> String {
        let queue = snapshot.queue
        return "\(Int(queue.sampleRate))Hz io \(String(format: "%.1f", queue.ioBufferDurationMilliseconds))ms dev \(String(format: "%.1f", queue.outputLatencyMilliseconds))ms"
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.white.opacity(0.62))
            Spacer()
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }
}

private struct VisionPlayerControlDescriptor: Identifiable {
    let id: VisionPlayerControlID
    let label: String
    let symbol: String
    var detail: String? = nil
    var isOn = false
    var usesBrandMark = false
    let action: () -> Void
}
