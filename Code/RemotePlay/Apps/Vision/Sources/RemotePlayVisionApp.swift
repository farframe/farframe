import FarframeStorefront
import SwiftUI

enum VisionWindowID {
    static let setup = "remote-play-setup"
    static let player = "remote-play-player"
    static let signInHelp = "remote-play-sign-in-help"
    static let controlsHelp = "remote-play-controls-help"
}

@main
struct RemotePlayVisionApp: App {
    @State private var coordinator = VisionRemotePlayCoordinator()
    @State private var accessStore = FarframeAccessStore()
    #if os(visionOS)
    @State private var arenaPreview = VisionArenaPreviewState()
    #endif

    // Value-based groups can accept scene restoration/reconnection without
    // the already-connected singleton Window assertion. All open requests
    // supply the same value per role to bring its existing window forward.
    var body: some Scene {
        WindowGroup("Farframe", id: VisionWindowID.setup, for: String.self) { _ in
            VisionHomeContainerView(
                coordinator: coordinator,
                accessStore: accessStore
            )
        } defaultValue: {
            VisionWindowID.setup
        }
        .windowStyle(.plain)
        .defaultSize(width: 720, height: 780)

        WindowGroup("Farframe", id: VisionWindowID.player, for: String.self) { _ in
            #if os(visionOS)
            VisionRemotePlayPlayerView(
                coordinator: coordinator,
                accessStore: accessStore,
                arenaState: arenaPreview
            )
            #else
            VisionRemotePlayPlayerView(
                coordinator: coordinator,
                accessStore: accessStore
            )
            #endif
        } defaultValue: {
            VisionWindowID.player
        }
        .windowStyle(.plain)
        .defaultSize(width: 1_280, height: 720)
        .windowResizability(.contentSize)
        // A session never survives relaunch, so the system must not restore the
        // player scene as the only window. Without this, closing Home first and
        // the player second stranded an empty player on the next launch.
        .restorationBehavior(.disabled)

        WindowGroup("Sign-in help", id: VisionWindowID.signInHelp, for: String.self) { _ in
            VisionSonySignInGuide()
        } defaultValue: {
            VisionWindowID.signInHelp
        }
        .defaultSize(width: 720, height: 780)
        .windowResizability(.contentSize)
        .defaultWindowPlacement { _, context in
            if let home = context.windows.first(where: { $0.id == VisionWindowID.setup }) {
                WindowPlacement(.trailing(home))
            } else {
                WindowPlacement()
            }
        }
        .restorationBehavior(.disabled)

        WindowGroup("Player controls", id: VisionWindowID.controlsHelp, for: String.self) { _ in
            VisionPlayerControlsGuide()
        } defaultValue: {
            VisionWindowID.controlsHelp
        }
        .defaultSize(width: 600, height: 550)
        .windowResizability(.contentSize)
        .defaultWindowPlacement { _, context in
            if let player = context.windows.first(where: { $0.id == VisionWindowID.player }) {
                WindowPlacement(.trailing(player))
            } else {
                WindowPlacement()
            }
        }
        .restorationBehavior(.disabled)

        #if os(visionOS)
        VisionArenaPreviewScene(state: arenaPreview, coordinator: coordinator, accessStore: accessStore)
        #endif
    }
}
