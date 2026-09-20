import GuidedHelp
import SwiftUI

/// The second consumer of GuidedHelp: native icon rows instead of screenshots.
/// The wrapper owns presentation; no guide page can send console/session input.
struct VisionPlayerControlsGuide: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var stepID = "move"
    static let revision = 1

    static let guide = HelpGuide(id: "farframe.vision.player-controls", revision: revision,
        title: "Player controls", steps: [
            .init(id: "move", title: "Make the controls yours", items: [
                .init(id: "visibility", title: "Show or hide controls", detail: "Tap the game picture to show or hide controls.", systemImage: "hand.tap"),
                .init(id: "collapse", title: "Collapse or expand", detail: "Tap the chevron to collapse or expand the controls.", systemImage: "chevron.up"),
                item("move", .move), item("customize", .customize)
            ]),
            .init(id: "play", title: "Home, sound and surroundings", items: [
                item(.psMenu), item(.showMain), item(.volume), item(.immersive)
            ]),
            .init(id: "finish", title: "Check your stream. Finish your session.", items: [
                item(.streamHUD), item(.recordGameplay), item(.sleep)
            ])
        ])

    var body: some View {
        HelpGuideView(guide: Self.guide, selectedStepID: $stepID) {
            dismissWindow(id: VisionWindowID.controlsHelp, value: VisionWindowID.controlsHelp)
        }
        .frame(minWidth: 480, idealWidth: 600, maxWidth: 760,
               minHeight: 440, idealHeight: 550, maxHeight: 900)
    }

    private static func item(_ id: VisionPlayerControlID) -> HelpGuideItem {
        item(id.rawValue, id.reference)
    }
    private static func item(_ id: String, _ reference: VisionPlayerControlReference) -> HelpGuideItem {
        .init(id: id, title: reference.title, detail: reference.detail,
              systemImage: reference.symbol, assetName: reference.assetName)
    }
}
