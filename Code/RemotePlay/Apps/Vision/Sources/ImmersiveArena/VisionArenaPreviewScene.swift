#if os(visionOS)
import Combine
import Foundation
import FarframeStorefront
import GameController
import InputCore
import Observation
import RealityKit
import SwiftUI

/// Live mode transfers the existing session after a fresh signed-access check.
struct VisionArenaPreviewScene: SwiftUI.Scene {
    @Bindable var state: VisionArenaPreviewState
    let coordinator: VisionRemotePlayCoordinator
    let accessStore: FarframeAccessStore

    var body: some SwiftUI.Scene {
        ImmersiveSpace(id: VisionMixedLightingState.spaceID) {
            VisionMixedLightingView(state: state.mixedLighting, coordinator: coordinator, accessStore: accessStore)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)

        ImmersiveSpace(id: VisionArenaPreviewState.spaceID) {
            VisionArenaPreviewView(state: state, coordinator: coordinator, accessStore: accessStore)
        }
        .immersionStyle(selection: $state.immersionStyle,
            in: .full, .progressive(0.15...1, initialAmount: 0.5))
        .upperLimbVisibility(.visible)

        Window("Controls", id: VisionArenaPreviewState.controlsWindowID) {
            VisionArenaControlsWindow(state: state, coordinator: coordinator, accessStore: accessStore)
        }
        .windowStyle(.plain)
        .defaultSize(width: 540, height: 720)
        .windowResizability(.contentSize)
        // The flat player is closed during immersive playback. Restore the
        // lower utility placement without depending on that absent window.
        .defaultWindowPlacement { _, _ in WindowPlacement(.utilityPanel) }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

    }
}

/// Home passes no coordinator for a static preview. The existing player passes
/// its coordinator, and entry is allowed only for an already-streaming session.
struct VisionArenaPreviewLauncher: View {
    @Bindable var state: VisionArenaPreviewState
    let accessStore: FarframeAccessStore
    var coordinator: VisionRemotePlayCoordinator? = nil
    var showsTitle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: openRoom) {
            Group {
                if state.phase == .opening { ProgressView().controlSize(.small) }
                else if showsTitle { Label("Glass Arena", systemImage: "cube.transparent") }
                else { Image(systemName: "cube.transparent").font(.title3.weight(.semibold)) }
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Circle())
        .contentShape(Circle())
        .disabled(state.phase != .closed || state.mixedLighting.phase != .closed)
        .help("Play in Glass Arena")
        .accessibilityLabel("Play in Glass Arena")
        .accessibilityIdentifier("farframe.player.enterArena")
        .alert("Glass Arena", isPresented: Binding(
            get: { state.entryMessage != nil }, set: { if !$0 { state.entryMessage = nil } })) {
                Button("OK") { state.entryMessage = nil }
            } message: { Text(state.entryMessage ?? "") }
        .task {
            guard coordinator == nil, isEnabled,
                  ProcessInfo.processInfo.arguments.contains("--farframe-arena-preview"),
                  state.claimAutomaticPreview() else { return }
            await Task.yield()
            openRoom()
        }
    }

    private func openRoom() {
        guard state.phase == .closed, state.mixedLighting.phase == .closed else { return }
        let entryID = state.beginOpening()
        state.reduceMotion = reduceMotion
        Task { @MainActor in
            let allowed = await accessStore.revalidateImmersiveAccess()
            guard state.entryAttemptID == entryID, state.phase == .opening else { return }
            guard allowed, !Task.isCancelled else {
                state.tearDown()
                state.entryMessage = "Start a trial or unlock Farframe to enter."
                return
            }
            state.updateAccess(true)
            await state.prewarmRoom(forLiveSession: coordinator != nil)
            guard state.entryAttemptID == entryID, state.phase == .opening else { return }
            guard !Task.isCancelled, await accessStore.revalidateImmersiveAccess() else {
                state.tearDown()
                return
            }
            if let coordinator, !state.beginLivePresentation(coordinator: coordinator) {
                state.tearDown()
                state.entryMessage = "Start playing before opening the room."
                return
            }
            let ticket = state.liveTicket
            let result = await openImmersiveSpace(id: VisionArenaPreviewState.spaceID)
            guard state.entryAttemptID == entryID else { return }
            switch result {
            case .opened:
                let stillAllowed = await accessStore.revalidateImmersiveAccess()
                guard state.entryAttemptID == entryID else { return }
                guard stillAllowed, !Task.isCancelled else {
                    state.phase = .closing
                    state.updateAccess(false)
                    if let coordinator, ticket != nil { await coordinator.disconnect() }
                    openWindow(id: VisionWindowID.setup, value: VisionWindowID.setup)
                    await dismissImmersiveSpace()
                    if state.entryAttemptID == entryID { state.tearDown() }
                    return
                }
                if state.phase == .opening { state.phase = .open }
                if let ticket, let coordinator {
                    // A room which cannot mount a renderer must not own
                    // the session indefinitely with no visible output.
                    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
                    while state.liveTicket == ticket, !state.livePresentationReady,
                          state.phase == .open, ContinuousClock.now < deadline {
                        try? await Task.sleep(for: .milliseconds(100))
                        if Task.isCancelled { break }
                    }
                    guard state.entryAttemptID == entryID, state.liveTicket == ticket,
                          state.phase == .open else { return }
                    if state.livePresentationReady {
                        guard coordinator.arenaPresentation.phase == .immersive(ticket) else { return }
                        // Full immersion leaves app windows visible unless we
                        // close them. Transfer ownership first: the outgoing
                        // flat window's callbacks must not stop this session.
                        dismissWindow(id: VisionWindowID.player)
                        dismissWindow(id: VisionWindowID.setup)
                        return
                    }
                    state.phase = .closing
                    let restored = await state.restoreFlat(ticket: ticket, coordinator: coordinator) {
                        openWindow(id: VisionWindowID.player, value: VisionWindowID.player)
                    }
                    guard state.entryAttemptID == entryID else { return }
                    await dismissImmersiveSpace()
                    guard state.entryAttemptID == entryID else { return }
                    state.tearDown()
                    state.entryMessage = restored
                        ? "The immersive screen could not start. The flat player was restored."
                        : "The immersive screen could not start. The session was disconnected."
                } else if state.phase == .open {
                    // Close Home only after openImmersiveSpace confirms success;
                    // a failed or cancelled opening leaves its source intact.
                    dismissWindow(id: VisionWindowID.setup)
                }
            case .userCancelled, .error:
                if let ticket, let coordinator {
                    await state.restoreFlat(ticket: ticket, coordinator: coordinator) {
                        openWindow(id: VisionWindowID.player, value: VisionWindowID.player)
                    }
                }
                guard state.entryAttemptID == entryID else { return }
                state.tearDown()
            @unknown default:
                if let ticket, let coordinator {
                    await state.restoreFlat(ticket: ticket, coordinator: coordinator) {
                        openWindow(id: VisionWindowID.player, value: VisionWindowID.player)
                    }
                }
                guard state.entryAttemptID == entryID else { return }
                state.tearDown()
                state.entryMessage = "The room could not open."
            }
        }
    }
}

private struct VisionArenaPreviewView: View {
    @Bindable var state: VisionArenaPreviewState
    @Bindable var coordinator: VisionRemotePlayCoordinator
    @Bindable var accessStore: FarframeAccessStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var playerFocused: Bool
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var controlsLauncher = VisionArenaControlsLauncherRig()
    @State private var manipulationUpdates: EventSubscription?
    @State private var manipulationEnd: EventSubscription?

    var body: some View {
        RealityView { content, attachments in
            let mount = state.prepareScene()
            content.add(mount.root)
            if let launcher = attachments.entity(for: "arena-controls-launcher") {
                controlsLauncher.mount(launcher: launcher, in: mount.root)
            }
            manipulationUpdates = content.subscribe(to: ManipulationEvents.DidUpdateTransform.self) { event in
                state.screenWasMoved(event.entity, finished: false)
            }
            manipulationEnd = content.subscribe(to: ManipulationEvents.WillEnd.self) { event in
                state.screenWasMoved(event.entity, finished: true)
                playerFocused = true
            }
            state.applyPlacement()
            state.startLoading(mount)
        } update: { _, _ in
            // Do not reapply placement every SwiftUI update: system gestures own
            // it while moving. Only presets and explicit resize change it here.
            state.applyGlow()
            controlsLauncher.update(screen: state.currentScreenTransform)
        } attachments: {
            Attachment(id: "arena-controls-launcher") {
                Button("Controls", systemImage: "slider.horizontal.3") {
                    openWindow(id: VisionArenaPreviewState.controlsWindowID)
                    playerFocused = true
                }
                .buttonStyle(.plain)
                .font(.body.weight(.medium))
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(Color(white: 0.055).opacity(0.94), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.15)))
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityLabel("Recall Controls")
                .accessibilityIdentifier("farframe.arena.recallControls")
            }
        }
        .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { event in
            guard event.entity.name == "ArenaStaticScreen", !state.movable else { return }
            openWindow(id: VisionArenaPreviewState.controlsWindowID)
            playerFocused = true
        })
        .focusable(true)
        .focused($playerFocused)
        .handlesGameControllerEvents(matching: .gamepad)
        .onAppear {
            state.phase = .open
            state.scenePhase = scenePhase
            state.isActive = scenePhase == .active
            state.reduceMotion = reduceMotion
            state.updateAccess(accessStore.allowsImmersive)
            if !accessStore.allowsImmersive { accessLost() }
            playerFocused = true
            state.updateLiveScenePhase(coordinator: coordinator)
        }
        .onChange(of: scenePhase) { _, newPhase in
            state.scenePhase = newPhase
            state.isActive = newPhase == .active
            state.applyGlow()
            state.updateLiveScenePhase(coordinator: coordinator)
            if newPhase == .active {
                playerFocused = true
                Task { @MainActor in
                    let entryID = state.entryAttemptID
                    let allowed = await accessStore.revalidateImmersiveAccess()
                    guard state.entryAttemptID == entryID else { return }
                    state.updateAccess(allowed)
                    if !allowed { accessLost() }
                }
            }
        }
        .onChange(of: reduceMotion) { _, reduced in
            state.reduceMotion = reduced
            state.applyGlow()
        }
        .onChange(of: accessStore.verifiedState) { _, _ in
            state.updateAccess(accessStore.allowsImmersive)
            if !accessStore.allowsImmersive { accessLost() }
        }
        .task { await state.startViewerTracking() }
        .onWorldRecenter { event in
            if event == .ended {
                state.worldDidRecenter()
                controlsLauncher.update(screen: state.currentScreenTransform)
            }
        }
        .onChange(of: state.keepFacingViewer) { _, _ in state.reorientScreen() }
        .onChange(of: state.movable) { _, _ in state.updateManipulation() }
        .onChange(of: state.partialImmersion) { _, partial in
            state.immersionStyle = partial ? .progressive(0.15...1, initialAmount: 0.5) : .full
        }
        .onChange(of: state.glow) { _, _ in state.applyGlow() }
        .onChange(of: state.lightCoverage) { _, _ in state.applyGlow() }
        .onChange(of: state.pillarGlow) { _, _ in state.applyGlow() }
        .onChange(of: state.controlsCommand) { _, command in
            guard let command else { return }
            state.controlsCommand = nil
            switch command {
            case .exitRoom: exitRoom()
            case .endSession(let rest): endSession(rest: rest)
            }
        }
        .onChange(of: coordinator.activeSessionID) { _, sessionID in
            if let ticket = state.liveTicket, ticket.sessionID != sessionID { exitRoom() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            state.applyGlow()
        }
        .onDisappear {
            manipulationUpdates?.cancel()
            manipulationEnd?.cancel()
            manipulationUpdates = nil
            manipulationEnd = nil
            let ticket = state.liveTicket
            dismissWindow(id: VisionArenaPreviewState.controlsWindowID)
            controlsLauncher.unmount()
            state.tearDown()
            guard let ticket else {
                // Home was closed for the static room too. System dismissal
                // needs the same reachable return path as the Exit button.
                openWindow(id: VisionWindowID.setup, value: VisionWindowID.setup)
                return
            }
            // Covers the Digital Crown/system dismissal and a closed window.
            // Explicit Exit already completed this transfer, making it a no-op.
            Task { @MainActor in
                await state.restoreFlat(ticket: ticket, coordinator: coordinator) {
                    openWindow(id: VisionWindowID.player, value: VisionWindowID.player)
                }
                if coordinator.activeSessionID == nil { openWindow(id: VisionWindowID.setup, value: VisionWindowID.setup) }
            }
        }
    }

    private func accessLost() {
        guard state.phase != .closed, state.phase != .closing else { return }
        state.phase = .closing
        state.updateAccess(false)
        let entryID = state.entryAttemptID
        Task { @MainActor in
            if state.liveTicket != nil { await coordinator.disconnect() }
            guard state.entryAttemptID == entryID else { return }
            openWindow(id: VisionWindowID.setup, value: VisionWindowID.setup)
            await dismissImmersiveSpace()
        }
    }

    private func exitRoom(showHome: Bool = false) {
        guard state.phase != .closing else { return }
        state.phase = .closing
        let ticket = state.liveTicket
        let entryID = state.entryAttemptID
        Task { @MainActor in
            if let ticket {
                let restored = await state.restoreFlat(ticket: ticket, coordinator: coordinator) {
                    openWindow(id: VisionWindowID.player, value: VisionWindowID.player)
                }
                if !restored, state.phase == .open,
                   coordinator.arenaPresentation.phase == .immersive(ticket) {
                    dismissWindow(id: VisionWindowID.player)
                    openWindow(id: VisionArenaPreviewState.controlsWindowID)
                    return
                }
            }
            guard state.entryAttemptID == entryID else { return }
            if showHome || ticket == nil || coordinator.activeSessionID == nil { openWindow(id: VisionWindowID.setup, value: VisionWindowID.setup) }
            await dismissImmersiveSpace()
        }
    }

    private func endSession(rest: Bool) {
        guard state.phase != .closing else { return }
        state.phase = .closing
        let entryID = state.entryAttemptID
        Task { @MainActor in
            if rest { await coordinator.restAndDisconnect() } else { await coordinator.disconnect() }
            guard state.entryAttemptID == entryID else { return }
            openWindow(id: VisionWindowID.setup, value: VisionWindowID.setup)
            await dismissImmersiveSpace()
        }
    }
}

/// A native window owns placement and hit testing; it does not own playback.
/// Closing it leaves the room and stream running. The room dismisses it on exit.
private struct VisionArenaControlsWindow: View {
    @Bindable var state: VisionArenaPreviewState
    @Bindable var coordinator: VisionRemotePlayCoordinator
    @Bindable var accessStore: FarframeAccessStore
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VisionPlayerControlRail(coordinator: coordinator, accessStore: accessStore,
            onInteraction: {}, showHome: { state.controlsCommand = .exitRoom },
            endSession: { state.controlsCommand = .endSession(rest: $0) }, roomControls: { roomOptions },
            presentation: .tablet, hideTablet: { dismissWindow(id: VisionArenaPreviewState.controlsWindowID) })
        .disabled(state.phase != .open || !accessStore.allowsImmersive)
        .onChange(of: state.phase) { _, phase in
            if phase == .closed || phase == .closing {
                dismissWindow(id: VisionArenaPreviewState.controlsWindowID)
            }
        }
        .onAppear {
            if state.phase != .open { dismissWindow(id: VisionArenaPreviewState.controlsWindowID) }
        }
    }

    private var roomOptions: some View {
        VisionArenaControlsPanel(movable: $state.movable, partialImmersion: $state.partialImmersion,
            selectedPreset: state.selectedPreset,
            size: Binding(get: { state.screenSize }, set: state.setScreenSize),
            distance: Binding(get: { state.screenDistance }, set: state.setScreenDistance),
            tilt: Binding(get: { state.screenTilt }, set: state.setScreenTilt),
            keepFacing: $state.keepFacingViewer,
            selectPreset: state.selectPreset,
            savedScreens: state.savedScreens.items, selectedSavedScreenID: state.selectedSavedScreenID,
            saveScreen: state.saveScreen, recallScreen: state.recallScreen, removeScreen: state.removeScreen,
            reset: { state.selectPreset(.cinema) }, exit: { state.controlsCommand = .exitRoom }) {
            LabeledContent("Environment", value: "Quiet Horizon")
            VisionArenaCoveragePicker(selection: $state.lightCoverage, pillarGlow: $state.pillarGlow, available: state.wrapAvailable)
            Text("Ambient Glow").font(.subheadline.weight(.semibold))
            Picker("Ambient Glow", selection: $state.glow) {
                ForEach(VisionArenaGlow.allCases) { level in Text(level.localizedTitle).tag(level) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("farframe.arena.glow")
            .disabled(reduceMotion)
            if reduceMotion {
                Text("Reactive lighting is off with Reduce Motion.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if coordinator.remoteDisplayIsBlocked {
                Button("Return to Console Home") { coordinator.exitBlockedRemotePlayContent() }
            }
            if let status = state.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

}
#endif
