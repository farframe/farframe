import GuidedHelp
import SwiftUI

/// Vision owns the independent scene. Instructions, assets and rendering are shared.
struct VisionSonySignInGuide: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var selectedStepID = "email"

    var body: some View {
        HelpGuideView(guide: FarframeHelpGuides.playStationSignIn,
                      selectedStepID: $selectedStepID) {
            dismissWindow(id: VisionWindowID.signInHelp, value: VisionWindowID.signInHelp)
        }
        .frame(minWidth: 600, idealWidth: 720, maxWidth: 900,
               minHeight: 620, idealHeight: 780, maxHeight: 1_100)
    }
}
