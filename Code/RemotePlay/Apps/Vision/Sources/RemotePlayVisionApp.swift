import FarframeStorefront
import SwiftUI

enum VisionWindowID {
    static let setup = "remote-play-setup"
    static let player = "remote-play-player"
}

@main
struct RemotePlayVisionApp: App {
    @State private var coordinator = VisionRemotePlayCoordinator()
    @State private var accessStore = FarframeAccessStore()

    var body: some Scene {
        Window("Farframe", id: VisionWindowID.setup) {
            VisionHomeContainerView(
                coordinator: coordinator,
                accessStore: accessStore
            )
        }
        .windowStyle(.plain)
        .defaultSize(width: 720, height: 780)

        Window("Farframe", id: VisionWindowID.player) {
            VisionRemotePlayPlayerView(
                coordinator: coordinator,
                accessStore: accessStore
            )
        }
        .windowStyle(.plain)
        .defaultSize(width: 1_280, height: 720)
        .windowResizability(.contentSize)
        // A session never survives relaunch, so the system must not restore the
        // player scene as the only window. Without this, closing Home first and
        // the player second stranded an empty player on the next launch.
        .restorationBehavior(.disabled)
    }
}
