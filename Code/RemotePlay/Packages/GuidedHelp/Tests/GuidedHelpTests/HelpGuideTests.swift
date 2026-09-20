import Foundation
import Testing
@testable import GuidedHelp

private func guide(_ ids: [String]) -> HelpGuide {
    HelpGuide(id: "fixture", title: "Fixture", steps: ids.map { HelpGuideStep(id: $0, title: $0) })
}

@Test func resumeSurvivesReorderingAndRemoval() {
    #expect(guide(["c", "a", "b"]).index(for: "b") == 2)
    #expect(guide(["c", "a"]).index(for: "b") == 0)
    #expect(guide([]).index(for: "b") == nil)
}

@Test func navigationStaysInsideGuide() {
    let value = guide(["a", "b", "c"])
    #expect(value.stepID(from: "a", offset: -1) == "a")
    #expect(value.stepID(from: "b", offset: 1) == "c")
    #expect(value.stepID(from: "c", offset: 1) == "c")
    #expect(value.stepID(from: "removed", offset: 1) == "b")
    #expect(guide([]).stepID(from: "a", offset: 1) == nil)
}

@Test func contentRoundTripPreservesAssetAndAccessibilityContract() throws {
    let value = HelpGuide(id: "example", revision: 2, title: "Help", footer: "Example", steps: [
        HelpGuideStep(id: "start", title: "Start", illustration: HelpGuideIllustration(
            assetName: "Sample", accessibleDescription: "Use your own code", usesDarkBacking: true),
            items: [HelpGuideItem(id: "move", title: "Move", detail: "Drag", systemImage: "hand.draw")])
    ])
    let encoded = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(HelpGuide.self, from: encoded) == value)
}
