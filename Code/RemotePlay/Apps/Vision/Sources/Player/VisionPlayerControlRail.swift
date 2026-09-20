import AppleMediaCore
import ExperienceDomain
import FarframeCommerceUI
import Foundation
import FarframeStorefront
import GameController
import InputCore
import SwiftUI
import UIKit

/// One control implementation for the window and immersive player.
/// Pin preferences and settings belong to their existing coordinator.
struct VisionPlayerControlRail<RoomControls: View>: View {
    @Bindable var coordinator: VisionRemotePlayCoordinator
    @Bindable var accessStore: FarframeAccessStore
    let onInteraction: () -> Void
    let showHome: () -> Void
    let endSession: (Bool) -> Void
    @ViewBuilder var roomControls: () -> RoomControls
    enum Presentation { case rail, tablet }
    var presentation: Presentation = .rail
    var diagnosticsProvider: (() -> VisionPlayerDiagnostics?)? = nil
    var hideTablet: () -> Void = {}
    var dock: Binding<VisionControlDock>? = nil
    var playerSize: CGSize = .zero
    var recallControls = 0
    @State private var dragStart: VisionControlDock?
    private enum TabletSection: String, CaseIterable {
        case controls = "Controls", room = "Screen", settings = "Settings", stats = "Stats"
        var localizedTitle: LocalizedStringKey { LocalizedStringKey(rawValue) }
    }
    @State private var tabletSection: TabletSection = .controls
    @State private var controlsExpanded = false
    @State private var collapsedControlIsDimmed = false
    @State private var collapsedControlHasGaze = false
    @State private var showControlsMenu = false
    @State private var showSettings = false
    @State private var showSessionChoices = false
    @Environment(\.openWindow) private var openWindow
    @State private var didCopyDiagnosis = false
    @State private var pinnedVolumeDragStart: Float?
    @State private var isDraggingPinnedVolume = false
    @State private var pinnedVolumeDragDidMove = false

    var body: some View {
        Group {
            if presentation == .tablet { tablet }
            else { controlRail }
        }
            .confirmationDialog("End Session", isPresented: $showSessionChoices, titleVisibility: .visible) {
                Button("Rest and Disconnect") { endSession(true); onInteraction() }
                Button("Disconnect Only") { endSession(false); onInteraction() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("To turn off your DualSense afterward, hold its physical PS button until the lights turn off.")
            }
            .sheet(isPresented: $showSettings, onDismiss: onInteraction) {
                VisionRemotePlaySettingsView(coordinator: coordinator, accessStore: accessStore, context: .gameplay)
            }
    }

    private var tablet: some View {
        VStack(spacing: 12) {
            VisionGameplayRecordingStatus(coordinator: coordinator)
            HStack {
                FarframeBrandMark(size: 28)
                Text("FARFRAME").font(.headline)
                    .accessibilityIdentifier("farframe.arena.brand")
                Spacer()
                Button("PS Home", systemImage: VisionPlayerControlID.psMenu.reference.symbol) { coordinator.pulse(.playStation); onInteraction() }
                    .accessibilityIdentifier("farframe.arena.psHome")
                Menu {
                    Button("Glass Arena controls") { tabletSection = .room; onInteraction() }
                    Button("Exit immersion", systemImage: "rectangle.on.rectangle") {
                        showHome(); onInteraction()
                    }
                } label: {
                    Image(systemName: "cube.transparent").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Immersive environment")
                .help("Immersive environment")
                .accessibilityIdentifier("farframe.arena.environmentMenu")
                Button("Hide", systemImage: "minus") { hideTablet() }
                    .disabled(coordinator.gameplayRecording.isBusy)
                    .accessibilityIdentifier("farframe.arena.hideControls")
            }
            Picker("Section", selection: $tabletSection) {
                ForEach(TabletSection.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("farframe.arena.controlSection")
            Group {
                switch tabletSection {
                case .controls: controlsOverflowMenu
                case .room: roomControls()
                case .settings:
                    VisionRemotePlaySettingsView(coordinator: coordinator, accessStore: accessStore,
                        context: .gameplay, embedded: true, onDone: { tabletSection = .controls })
                case .stats:
                    ScrollView {
                        VisionPlayerHealthHUD(coordinator: coordinator, mode: "arena",
                            presentationIsActive: true, alwaysVisible: true,
                            snapshotProvider: diagnosticsProvider)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .frame(minWidth: 480, idealWidth: 540, maxWidth: 760,
               minHeight: 600, idealHeight: 720, maxHeight: 960)
        .background(Color(white: 0.055).opacity(0.96),
                    in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.12)))
        .preferredColorScheme(.dark)
        .onChange(of: tabletSection) { _, section in
            onInteraction()
        }
    }

    private func openSettings() {
        if presentation == .tablet { tabletSection = .settings }
        else { showSettings = true }
        onInteraction()
    }

    private var controlRail: some View {
        let horizontal = dock?.wrappedValue.edge.horizontal == true
        return VisionRailStack(horizontal: horizontal) {
            railCore
        }
        .animation(nil, value: horizontal)
        .transaction(value: horizontal) { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        // Use the new axis's intrinsic size in the same layout pass. A geometry
        // group can retain the prior axis bounds as the ornament anchor moves.
        .fixedSize()
        .padding(controlsExpanded ? 8 : 0)
        .background {
            if controlsExpanded {
                Capsule().fill(Color(white: 0.055).opacity(0.96))
                    .overlay(Capsule().stroke(.white.opacity(0.16)))
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onChange(of: recallControls, initial: true) { _, value in
            if value > 0 {
                controlsExpanded = true
                collapsedControlIsDimmed = false
            }
        }
        .animation(.snappy, value: coordinator.pinnedPlayerControlIDs)
        .animation(.snappy, value: controlsExpanded)
        .offset(dock?.wrappedValue.edge.outwardOffset ?? .zero)
        .padding(dock == nil ? 0 : 36)
        .transaction { transaction in
            if dragStart != nil {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    private func updateDock(_ value: VisionControlDock, binding: Binding<VisionControlDock>) {
        // Move the attachment and reflow its axis in one nonanimated transaction.
        // Retain view identity so an edge crossing does not cancel the drag.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { binding.wrappedValue = value }
    }

    private func toggleControlsExpanded() {
        controlsExpanded.toggle()
        collapsedControlIsDimmed = false
        onInteraction()
    }

    @ViewBuilder
    private var railCore: some View {
        circleButton(
            title: controlsExpanded ? "Collapse Controls" : "Expand Controls",
            symbol: controlsExpanded ? "chevron.up" : "chevron.down"
        ) {
            toggleControlsExpanded()
        }
        .opacity(controlsExpanded || collapsedControlIsDimmed == false ? 1 : 0.3)
        .scaleEffect(controlsExpanded || collapsedControlIsDimmed == false ? 1 : 0.92)
        .animation(.easeOut(duration: 0.2), value: collapsedControlIsDimmed)
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
            if let dock {
                Image(systemName: VisionPlayerControlReference.move.symbol)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .contentShape(.hoverEffect, Circle())
                    .hoverEffect(.highlight)
                    .visionControlHint("Move Controls")
                    .accessibilityLabel("Move Controls")
                    .accessibilityHint("Drag to any edge of the window")
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStart ?? dock.wrappedValue
                            dragStart = start
                            updateDock(start.moved(by: value.translation, in: playerSize, retaining: dock.wrappedValue.edge), binding: dock)
                        }
                        .onEnded { value in
                            let start = dragStart ?? dock.wrappedValue
                            updateDock(start.moved(by: value.translation, in: playerSize, retaining: dock.wrappedValue.edge), binding: dock)
                            dock.wrappedValue.save()
                            dragStart = nil
                            onInteraction()
                        })
                    .accessibilityAction(named: "Move to next edge") {
                        let edges = VisionControlDock.Edge.allCases
                        let index = edges.firstIndex(of: dock.wrappedValue.edge) ?? 0
                        updateDock(VisionControlDock(edge: edges[(index + 1) % edges.count]), binding: dock)
                        dock.wrappedValue.save()
                    }
            }
            if coordinator.isPlayerControlPinned(.immersive) { roomControls() }
            ForEach(coordinator.pinnedPlayerControlIDs.compactMap { descriptor(for: $0) }) { control in
                ornamentButton(control)
            }

            circleButton(title: VisionPlayerControlReference.customize.title, symbol: VisionPlayerControlReference.customize.symbol) {
                showControlsMenu.toggle()
                onInteraction()
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

    /// One scrolling surface: Video Settings, Primary, Audio, then the less
    /// frequent console/session/diagnostic actions and help.
    private var controlsOverflowMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            if presentation == .rail {
                controlsMenuHeader
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                Divider().opacity(0.35)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    qualityPanel
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PRIMARY").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        ForEach([VisionPlayerControlID.showMain, .psMenu].compactMap { descriptor(for: $0) }) { control in
                            controlRow(control)
                        }
                        if presentation == .rail { immersiveControlRow }
                        else {
                            Button("Immersive", systemImage: "cube.transparent") { tabletSection = .room }
                        }
                        ForEach([VisionPlayerControlID.recordGameplay, .streamHUD].compactMap { descriptor(for: $0) }) { control in
                            controlRow(control)
                        }
                    }
                    volumeControlPanel
                    controlSection("Console", ids: [.psOptions, .psCreate])
                    controlSection("Session", ids: [.sleep, .disconnect])
                    controlSection("Diagnostics", ids: [.copyDiagnosis])
                    Button("Controls guide", systemImage: "questionmark.circle") {
                        showControlsMenu = false
                        openWindow(id: VisionWindowID.controlsHelp, value: VisionWindowID.controlsHelp)
                        onInteraction()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.visible)
        }
        .frame(minWidth: presentation == .tablet ? 0 : 360,
               maxWidth: presentation == .tablet ? .infinity : 360)
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
        return VStack(alignment: .leading, spacing: 6) {
            Button(action: openSettings) {
                HStack {
                    Label("Video Settings", systemImage: "slider.horizontal.3")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
            }
            Text("Stream: \(quality.profile.resolution.rawValue) · \(quality.profile.framesPerSecond) FPS · \(quality.profile.targetBitrateKbps / 1_000) Mbps target")
                .font(.caption).foregroundStyle(.secondary)
            if let active = coordinator.activeStreamQuality, active != coordinator.streamQuality {
                Text("Quality change pending. Disconnect, then Connect to apply.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// The HUD shows the verdict and the first few findings; the clipboard
    /// carries all of them, which is what makes the truncation safe here.
    private func copyDiagnosis() {
        guard let text = coordinator.streamDiagnosticsPlainText() else { return }
        UIPasteboard.general.string = text
        didCopyDiagnosis = true
        onInteraction()
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyDiagnosis = false
        }
    }

    private var volumeControlPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Audio", systemImage: audioSymbol)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(volumePercent)%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                if presentation == .rail { pinButton(.volume, label: "Volume") }
            }
            Toggle("Mute game audio", isOn: $coordinator.audioIsMuted)
            Text("Game volume is separate from headset volume.")
                .font(.caption2).foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { Double(coordinator.audioVolume) },
                    set: { setAudioVolume($0) }
                ),
                in: 0...1
            )
            .help("Volume. Drag to 0% to mute.")

            Button("Restore Audio", systemImage: "arrow.clockwise") {
                coordinator.restoreAudioPlayback()
                onInteraction()
            }
            .disabled(coordinator.activeSessionID == nil)
            .accessibilityIdentifier("farframe.player.restoreAudio")
            .help("Restart sound without disconnecting your game. Keeps your volume and mute settings.")
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
            .accessibilityIdentifier("farframe.controls.action.\(control.id.rawValue)")

            if presentation == .rail {
                pinButton(control.id, label: control.label)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var immersiveControlRow: some View {
        HStack(spacing: 10) {
            roomControls()
            Text(LocalizedStringKey(VisionPlayerControlID.immersive.reference.title))
                .frame(maxWidth: .infinity, alignment: .leading)
            pinButton(.immersive, label: VisionPlayerControlID.immersive.reference.title)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func pinButton(_ id: VisionPlayerControlID, label: String) -> some View {
        Button {
            coordinator.setPlayerControl(
                id,
                pinned: coordinator.isPlayerControlPinned(id) == false
            )
        } label: {
            let isPinned = coordinator.isPlayerControlPinned(id)
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
            coordinator.isPlayerControlPinned(id)
                ? "Hide \(label)"
                : "Show \(label)"
        )
    }

    private var playerControlDescriptors: [VisionPlayerControlDescriptor] {
        [
            VisionPlayerControlDescriptor(
                id: .recordGameplay,
                label: coordinator.recordingActionTitle,
                symbol: coordinator.gameplayRecording.canStop ? "stop.circle.fill" : "record.circle",
                detail: "Game picture and audio → Photos. Tap again to stop.",
                isOn: coordinator.gameplayRecording.isBusy || coordinator.recordingPhotoOperationIsBusy
            ) { coordinator.toggleGameplayRecording() },
            VisionPlayerControlDescriptor(
                id: .psMenu,
                label: VisionPlayerControlID.psMenu.reference.title,
                symbol: VisionPlayerControlID.psMenu.reference.symbol,
                detail: VisionPlayerControlID.psMenu.reference.detail
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
                label: VisionPlayerControlID.psOptions.reference.title,
                symbol: VisionPlayerControlID.psOptions.reference.symbol,
                detail: VisionPlayerControlID.psOptions.reference.detail
            ) {
                coordinator.pulse(.options)
            },
            VisionPlayerControlDescriptor(
                id: .psCreate,
                label: VisionPlayerControlID.psCreate.reference.title,
                symbol: VisionPlayerControlID.psCreate.reference.symbol,
                detail: VisionPlayerControlID.psCreate.reference.detail
            ) {
                coordinator.pulse(.create)
            },
            VisionPlayerControlDescriptor(
                id: .showMain,
                label: presentation == .tablet ? "Exit Room" : VisionPlayerControlID.showMain.reference.title,
                symbol: "macwindow",
                detail: presentation == .tablet
                    ? "Returns to your window without disconnecting"
                    : VisionPlayerControlID.showMain.reference.detail,
                usesBrandMark: true
            ) {
                showHome()
            },
            VisionPlayerControlDescriptor(
                id: .streamHUD,
                label: VisionPlayerControlID.streamHUD.reference.title,
                symbol: VisionPlayerControlID.streamHUD.reference.symbol,
                detail: VisionPlayerControlID.streamHUD.reference.detail,
                isOn: coordinator.streamHealthHUDEnabled
            ) {
                if presentation == .tablet {
                    tabletSection = .stats
                } else {
                    coordinator.streamHealthHUDEnabled.toggle()
                }
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
                label: VisionPlayerControlID.sleep.reference.title,
                symbol: VisionPlayerControlID.sleep.reference.symbol,
                detail: VisionPlayerControlID.sleep.reference.detail
            ) {
                showSessionChoices = true
            },
            VisionPlayerControlDescriptor(
                id: .disconnect,
                label: VisionPlayerControlID.disconnect.reference.title,
                symbol: VisionPlayerControlID.disconnect.reference.symbol,
                detail: VisionPlayerControlID.disconnect.reference.detail
            ) {
                endSession(false)
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
                    onInteraction()
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
                        onInteraction()
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
                    onInteraction()
                    Task { @MainActor in
                        await Task.yield()
                        pinnedVolumeDragDidMove = false
                    }
                }
        )
        .animation(.easeOut(duration: 0.15), value: isDraggingPinnedVolume)
        .visionControlHint("Volume \(volumePercent)%. Tap or drag.")
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
            .help(title)
            .contentShape(.interaction, Circle())
            .contentShape(.hoverEffect, Circle())
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Circle())
        .clipShape(Circle())
        .contentShape(Circle())
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


private struct VisionRailStack: Layout {
    var horizontal: Bool
    private let spacing: CGFloat = 14

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard sizes.isEmpty == false else { return .zero }
        let extra = spacing * CGFloat(sizes.count - 1)
        if horizontal {
            return CGSize(
                width: sizes.reduce(0) { $0 + $1.width } + extra,
                height: sizes.map(\.height).max() ?? 0
            )
        }
        return CGSize(
            width: sizes.map(\.width).max() ?? 0,
            height: sizes.reduce(0) { $0 + $1.height } + extra
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if horizontal {
                subview.place(
                    at: CGPoint(x: x, y: bounds.midY - size.height / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            } else {
                subview.place(
                    at: CGPoint(x: bounds.midX - size.width / 2, y: y),
                    proposal: ProposedViewSize(size)
                )
                y += size.height + spacing
            }
        }
    }
}

extension VisionPlayerControlRail {
    func configuredDock(_ dock: Binding<VisionControlDock>, size: CGSize, recall: Int) -> Self {
        var result = self
        result.dock = dock
        result.playerSize = size
        result.recallControls = recall
        return result
    }
}


// Native help is rendered by visionOS for gaze. onHover only reports fingers
// and trackpad pointers, so it must not gate whether these hints exist.
extension View {
    func visionControlHint(_ title: String) -> some View {
        help(title)
    }
}
