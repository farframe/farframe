import Foundation
import SwiftUI

@main
enum VisionControlDockPreferenceChecks {
    static func main() {
        let suite = "FarframeDockChecks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // The selected update moves an existing rail once, not on every launch.
        VisionControlDock(edge: .trailing, progress: 0.7).save(defaults: defaults)
        precondition(VisionControlDock.load(defaults: defaults) == VisionControlDock(edge: .trailing, progress: 0.5))
        defaults.set(1, forKey: "farframe.vision.controlDock.defaultRevision")
        VisionControlDock(edge: .top, progress: 0.5).save(defaults: defaults)
        precondition(VisionControlDock.load(defaults: defaults) == VisionControlDock(edge: .trailing, progress: 0.5))
        let dragged = VisionControlDock(edge: .leading, progress: 0.3)
        dragged.save(defaults: defaults)
        precondition(VisionControlDock.load(defaults: defaults) == dragged)
        VisionControlDock(edge: .bottom, progress: 100).save(defaults: defaults)
        precondition(VisionControlDock.load(defaults: defaults).progress == 0.75)
        defaults.set(Data([0, 255]), forKey: "farframe.vision.controlDock")
        precondition(VisionControlDock.load(defaults: defaults) == VisionControlDock())
        print("PASS: 5 one-time right-side migration, saved-position, clamping and invalid-data checks")
    }
}
