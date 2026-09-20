import Foundation

@main
enum VisionPlayerControlPreferencesChecks {
    static func main() {
        typealias Pins = VisionPlayerControlPreferences
        let defaults: [VisionPlayerControlID] = [.immersive, .psMenu, .showMain, .streamHUD, .recordGameplay, .volume, .sleep]
        precondition(Pins.resolve(saved: nil, revision: 0) == defaults)
        let old = ["psMenu", "showMain", "streamHUD", "sleep", "disconnect", "volume"]
        precondition(Pins.resolve(saved: old, revision: 0) == defaults)
        let custom = ["volume", "disconnect", "psOptions"]
        let migrated = Pins.resolve(saved: custom, revision: 0)
        precondition(migrated == [.immersive, .volume, .disconnect, .psOptions, .recordGameplay])
        precondition(Pins.resolve(saved: migrated.map(\.rawValue), revision: 3) == migrated)
        // Revision2 already migrated Immersive; keep it hidden and add Record only.
        precondition(Pins.resolve(saved: custom, revision: 2) == [.volume, .disconnect, .psOptions, .recordGameplay])
        precondition(Pins.resolve(saved: [], revision: 2) == [.recordGameplay])
        precondition(Pins.resolve(saved: ["recordGameplay", "volume", "recordGameplay"], revision: 2) == [.recordGameplay, .volume])
        // Explicit hides at the current revision must survive every subsequent launch.
        precondition(Pins.resolve(saved: custom, revision: 3) == [.volume, .disconnect, .psOptions])
        precondition(Pins.resolve(saved: [], revision: 3).isEmpty)
        precondition(Pins.resolve(saved: ["volume", "removed", "volume", "psMenu"], revision: 3) == [.volume, .psMenu])
        precondition(Pins.resolve(saved: ["immersive", "volume"], revision: 0) == [.immersive, .volume, .recordGameplay])
        print("PASS: 11 fresh-install, legacy/custom migration, duplicate and hidden-control assertions")
    }
}
