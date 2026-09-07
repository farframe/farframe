import FarframeStorefront
import SwiftUI

@main
struct RemotePlayMacApp: App {
    var body: some Scene {
        Window("Farframe", id: "farframe-main") {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--farframe-keychain-self-test") {
                // Do not construct the real root: its startup recovers registrations.
                Color.clear
                    .frame(width: 1, height: 1)
                    .task { await MacKeychainSelfTest.runAndExit() }
            } else {
                MacMainContent()
            }
            #else
            MacMainContent()
            #endif
        }
        .defaultSize(width: 1_180, height: 760)
        .windowResizability(.contentMinSize)
    }

}

// Construct production owners only for the real app scene. Even their initializers
// can start listeners, so the synthetic probe must not instantiate them.
private struct MacMainContent: View {
    @State private var coordinator = MacRemotePlayCoordinator()
    @State private var accessStore = FarframeAccessStore()

    var body: some View {
        MacRemotePlayRootView(coordinator: coordinator, accessStore: accessStore)
            .frame(minWidth: 880, minHeight: 600)
    }
}
