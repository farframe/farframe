import AppleMediaCore
import ExperienceDomain
import FarframeCommerceUI
import Foundation
import FarframeStorefront
import GameController
import InputCore
import SwiftUI
import Spatial
import UIKit

struct VisionRemotePlayPlayerView: View {
    @Bindable var coordinator: VisionRemotePlayCoordinator
    @Bindable var accessStore: FarframeAccessStore
    #if os(visionOS)
    var arenaState: VisionArenaPreviewState? = nil
    #endif

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    #if os(visionOS)
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.physicalMetrics) private var physicalMetrics
    #endif
    @State private var controlDock = VisionControlDock.load()
    @State private var playerSize: CGSize = .zero
    @State private var recallControls = 0
    @State private var controlsVisible = true
    @AppStorage("farframe.vision.controlsGuide.seenRevision") private var controlsGuideSeenRevision = 0
    @State private var instanceID = UUID()
    @State private var lifecycle = VisionPlayerLifecycle()
    @State private var isReturningHome = false
    @FocusState private var playerFocused: Bool

    var body: some View {
        Group {
            if let videoSurface = coordinator.videoSurface,
               let sessionID = coordinator.activeSessionID {
                ZStack {
                    flatPresentation(videoSurface: videoSurface, sessionID: sessionID)
                        .contentShape(Rectangle())
                        .onTapGesture { controlsVisible.toggle(); playerFocused = true }
                        .accessibilityAction(named: "Toggle Controls") { controlsVisible.toggle() }
                    connectionOverlay
                    VStack {
                        VisionGameplayRecordingStatus(coordinator: coordinator)
                        Spacer()
                    }
                    .padding(16)
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible)
                    .accessibilityHidden(!controlsVisible)

                    if coordinator.remoteDisplayIsBlocked {
                        restrictedContentOverlay
                    }

                    if coordinator.streamHealthHUDEnabled && coordinator.arenaPresentation.shouldRenderFlat {
                    ScrollView {
                        VisionPlayerHealthHUD(coordinator: coordinator, mode: "window",
                            presentationIsActive: coordinator.arenaPresentation.shouldRenderFlat)
                    }
                        .frame(width: 380)
                        .padding(18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    playerSize = size
                    #if os(visionOS)
                    let width = physicalMetrics.convert(size.width, to: .meters)
                    let height = physicalMetrics.convert(size.height, to: .meters)
                    if width.isFinite, height.isFinite, width > 0.2, height > 0.1 {
                        arenaState?.mixedLighting.windowExtentMeters = SIMD2(Float(width), Float(height))
                    }
                    #endif
                }
                .onGeometryChange3D(for: Point3D?.self) { proxy in
                    proxy.frame(in: .immersiveSpace).center
                } action: { center in
                    arenaState?.mixedLighting.windowCenter = center
                }
                .onGeometryChange3D(for: AffineTransform3D?.self) { proxy in
                    proxy.transform(in: .immersiveSpace)
                } action: { transform in
                    arenaState?.alignEntry(to: transform)
                    arenaState?.mixedLighting.windowTransform = transform
                }
                .onGeometryChange3D(for: Size3D.self) { proxy in
                    proxy.frame(in: .immersiveSpace).size
                } action: { size in
                    arenaState?.mixedLighting.windowSize = size
                }
                .modifier(VisionPlayerAspectRatio(
                    glowActive: arenaState?.mixedLighting.screenGlowStyle.isActive == true
                ))
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .frame(
                    minWidth: 700,
                    maxWidth: 3_200,
                    minHeight: 394,
                    maxHeight: 1_800
                )
            } else {
                ContentUnavailableView {
                    Label("No Active Session", systemImage: "gamecontroller")
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
        .ornament(attachmentAnchor: .scene(controlDock.point), contentAlignment: .center) {
            if coordinator.videoSurface != nil {
                VisionPlayerControlRail(coordinator: coordinator, accessStore: accessStore,
                    onInteraction: { playerFocused = true }, showHome: showMainWindow,
                    endSession: { rest in
                        Task {
                            if rest { await coordinator.restAndDisconnect() }
                            else { await coordinator.disconnect() }
                            returnToHome()
                        }
                    }) {
                    if let arenaState, coordinator.arenaPresentation.flatOwnsLifecycle,
                       case .streaming = coordinator.phase {
                        VisionEnvironmentControl(arena: arenaState, coordinator: coordinator, accessStore: accessStore)
                    }
                }
                .configuredDock($controlDock, size: playerSize, recall: recallControls)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
                .accessibilityHidden(!controlsVisible)
            }
        }
        .onAppear {
            coordinator.claimPlayerWindow(instanceID)
            let event = lifecycle.appeared(activity(for: scenePhase))
            reconcileActivity(scenePhase, event: event)
            arenaState?.mixedLighting.windowVisible = scenePhase != .background
            playerFocused = true
            offerControlsGuideIfNeeded()
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
        .onChange(of: coordinator.setupWindowIsActive) { _, active in
            if active && hasNoSession { returnToHome() }
        }
        .onDisappear {
            lifecycle.disappeared()
            let closingSessionID = coordinator.activeSessionID
            let wasOwningPlayer = coordinator.playerWindowDidDisappear(instanceID)
            guard wasOwningPlayer, let closingSessionID else { return }
            Task { @MainActor in
                // The old window may finish closing after a replacement opens.
                // Never let that delayed callback stop the replacement session.
                await coordinator.playerWindowClosed(ifSessionMatches: closingSessionID)
                if coordinator.activeSessionID == nil {
                    openWindow(id: VisionWindowID.setup, value: VisionWindowID.setup)
                }
            }
        }
        .onChange(of: coordinator.phase) { _, phase in
            if case .streaming = phase {
                playerFocused = true
                // Home hides only once video is actually flowing, so the user
                // never watches every window vanish while Connect is pending.
                dismissWindow(id: VisionWindowID.setup, value: VisionWindowID.setup)
                offerControlsGuideIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            arenaState?.mixedLighting.windowVisible = phase != .background
            reconcileActivity(phase, event: lifecycle.changed(activity(for: phase)))
        }
        #if os(visionOS)
        .onChange(of: coordinator.arenaPresentation.phase) { _, _ in
            let lifecycleID = coordinator.flatPresentationEventID
            guard coordinator.canHandleFlatActivity(eventID: lifecycleID) else { return }
            playerFocused = true
            Task { @MainActor in
                guard coordinator.canHandleFlatActivity(eventID: lifecycleID) else { return }
                _ = await coordinator.playerSceneBecameActive()
            }
        }
        #endif

    }

    private func offerControlsGuideIfNeeded() {
        guard case .streaming = coordinator.phase,
              controlsGuideSeenRevision < VisionPlayerControlsGuide.revision else { return }
        controlsGuideSeenRevision = VisionPlayerControlsGuide.revision
        controlsVisible = true
        recallControls += 1
        openWindow(id: VisionWindowID.controlsHelp, value: VisionWindowID.controlsHelp)
    }

    private func activity(for phase: ScenePhase) -> VisionPlayerLifecycle.Activity {
        switch phase {
        case .active: .active
        case .background: .background
        default: .inactive
        }
    }

    /// Initial appearance must reconcile activity too: a new window may already
    /// be active, with no subsequent scenePhase change to release prepared start.
    private func reconcileActivity(_ phase: ScenePhase, event: UUID) {
        #if os(visionOS)
        let lifecycleID = coordinator.recordFlatPresentationActivity(isActive: phase == .active)
        guard coordinator.arenaPresentation.flatOwnsLifecycle else { return }
        #endif
        switch phase {
        case .active:
            Task { @MainActor in
                guard lifecycle.canActivate(event) else { return }
                #if os(visionOS)
                guard coordinator.canHandleFlatActivity(eventID: lifecycleID) else { return }
                #endif
                if let authorization = await coordinator.playerSceneBecameActive() {
                    await resolvePreparedSessionStart(authorization)
                }
            }
        case .background:
            coordinator.playerSceneBecameNonActive()
        default:
            coordinator.playerSceneBecameInactive()
        }
    }

    @ViewBuilder
    private func flatPresentation(videoSurface: SampleBufferVideoSurfaceBinding, sessionID: UUID) -> some View {
        #if os(visionOS)
        if coordinator.arenaPresentation.shouldRenderFlat {
            let revision = coordinator.arenaPresentation.flatRevision
            VisionFlatPlayerView(
                videoSurface: videoSurface,
                mixedLighting: arenaState?.mixedLighting,
                onSurfaceQueued: { authorizePreparedSessionStart(sessionID: sessionID) },
                onSurfaceAttached: {
                    coordinator.arenaFlatSurfaceDidAttach(sessionID: sessionID, revision: revision)
                },
                onSurfaceReady: {
                    coordinator.arenaFlatSurfaceDidDisplay(sessionID: sessionID, revision: revision)
                }
            )
            .id("\(sessionID)-\(revision)")
        } else {
            ContentUnavailableView("Playing in Glass Arena", systemImage: "cube.transparent",
                description: Text("Exit Room returns your game to this window."))
        }
        #else
        VisionFlatPlayerView(videoSurface: videoSurface,
            onSurfaceQueued: { authorizePreparedSessionStart(sessionID: sessionID) })
            .id(sessionID)
        #endif
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
                Label("Exit to PlayStation Home", systemImage: "gamecontroller")
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

    /// Opens Home, then closes this player window. The stable presentation
    /// value brings an existing Home forward, so this never consults
    /// the coordinator's visibility set to decide *whether* to open Home, which
    /// can go stale when the system destroys a scene without an `onDisappear`.
    ///
    /// Wait for Home to become active, then dismiss the exact player value.
    /// Appearance alone does not prove the new scene finished connecting.
    /// Every asynchronous boundary rechecks that no replacement session exists.
    private func returnToHome() {
        guard hasNoSession, lifecycle.isPresented, !isReturningHome else { return }
        isReturningHome = true
        Task { @MainActor in
            defer { isReturningHome = false }
            openWindow(id: VisionWindowID.setup, value: VisionWindowID.setup)
            for _ in 0..<Self.homeReadinessPollCount {
                guard hasNoSession, lifecycle.isPresented else { return }
                if coordinator.setupWindowIsActive { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            // An appeared view may still be connecting or no longer visible.
            // Wait for Home's active scene; a later activation retries this path.
            guard hasNoSession, lifecycle.isPresented, coordinator.setupWindowIsActive else { return }
            #if os(visionOS)
            if let mixed = arenaState?.mixedLighting, mixed.phase == .open {
                await mixed.dismiss { await dismissImmersiveSpace() }
            }
            #endif
            // Dismissing an immersive space and connecting Home both finish
            // asynchronously. Retry only this empty player, never a new session.
            for _ in 0..<3 {
                guard hasNoSession, lifecycle.isPresented else { return }
                dismissWindow(id: VisionWindowID.player, value: VisionWindowID.player)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Up to three seconds; a later Home activation also retries.
    private static let homeReadinessPollCount = 60

    /// Always brings Home forward. Closing Home is done on Home itself.
    private func showMainWindow() {
        openWindow(id: VisionWindowID.setup, value: VisionWindowID.setup)
    }

}

private struct VisionPlayerAspectRatio: ViewModifier {
    var glowActive: Bool

    func body(content: Content) -> some View {
        if glowActive {
            content
        } else {
            content.aspectRatio(16.0 / 9.0, contentMode: .fit)
        }
    }
}
