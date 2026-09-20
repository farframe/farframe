import Foundation

/// The supported, production-safe controls that can be pinned to the Vision
/// player's ornament. Raw values intentionally match the known-good app so an
/// in-place upgrade preserves the user's existing rail without importing any
/// retired display or capture experiments.
enum VisionPlayerControlID: String, CaseIterable, Hashable, Identifiable, Sendable {
    case recordGameplay
    case immersive
    case psMenu
    case psOptions
    case psCreate
    case psHome
    case sleep
    case showMain
    case disconnect
    case streamHUD
    case copyDiagnosis
    case volume

    var id: String { rawValue }
}

/// Versioned one-time migration. Nil is a fresh install; an explicit empty
/// array after migration means the user deliberately hid every optional action.
enum VisionPlayerControlPreferences {
    static let revision = 3
    static let defaults: [VisionPlayerControlID] = [
        .immersive, .psMenu, .showMain, .streamHUD, .recordGameplay, .volume, .sleep
    ]

    static func resolve(saved: [String]?, revision: Int) -> [VisionPlayerControlID] {
        guard let saved else { return defaults }
        var seen = Set<VisionPlayerControlID>()
        var supported = saved.compactMap(VisionPlayerControlID.init(rawValue:))
            .filter { seen.insert($0).inserted }
        guard revision < Self.revision else { return supported }
        let oldDefault: [VisionPlayerControlID] = [
            .psMenu, .showMain, .streamHUD, .sleep, .disconnect, .volume
        ]
        let olderDefault: [VisionPlayerControlID] = [
            .psMenu, .showMain, .streamHUD, .sleep, .disconnect, .psOptions, .volume
        ]
        if revision < 2 {
            if supported.isEmpty || supported == oldDefault || supported == olderDefault {
                return defaults
            }
            if !supported.contains(.immersive) { supported.insert(.immersive, at: 0) }
        }
        // Build8 omitted Record from customization. Add it once to existing
        // layouts without resetting other pins, then respect later hiding.
        if !supported.contains(.recordGameplay) { supported.append(.recordGameplay) }
        return supported
    }
}
