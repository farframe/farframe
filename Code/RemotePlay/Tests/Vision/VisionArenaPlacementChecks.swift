import Foundation

@main struct PlacementChecks {
    @MainActor static func main() {
        let standard = VisionArenaScreenPlacement().bounded
        precondition(standard.height == 1.15 && standard.distance == 4.5 && standard.scale == 0.75)
        for preset in VisionArenaScreenPlacement.Preset.allCases {
            let p = preset.placement.bounded
            precondition(p == p.bounded)
            let extent = (1.2 * abs(cos(p.tilt * .pi / 180)) + 0.08 * abs(sin(p.tilt * .pi / 180))) * p.scale
            precondition(p.height - extent >= 0.0999)
        }
        precondition(VisionArenaScreenPlacement.Preset.cinema.placement.scale > standard.scale * 1.9)
        precondition(VisionArenaScreenPlacement.Preset.ceiling.placement.tilt == 90)
        for height: Float in [-100, 0, 1.15, 2.3, 100, .nan, .infinity] {
            for scale: Float in [-100, 0.35, 2.25, 100, .nan] {
                let p = VisionArenaScreenPlacement(height: height, distance: .infinity,
                    horizontal: 100, scale: scale, yaw: 100, tilt: -100).bounded
                precondition(p.height.isFinite && p.distance.isFinite)
                precondition(VisionArenaScreenPlacement.scaleRange.contains(p.scale))
                precondition(p.horizontal == 4 && p.yaw == 90 && p.tilt == -45)
                precondition(p == p.bounded)
            }
        }
        let cinema = VisionArenaScreenPlacement.Preset.cinema.placement.bounded
        precondition(cinema.tilt == 9 && cinema.scale == 2.04)
        let rise = cinema.height - 1.15
        precondition(abs(sqrt(cinema.distance * cinema.distance + rise * rise)
            - VisionArenaScreenPlacement.cinemaDistance) < 0.001)
        for tilt: Float in [-45, 0, 8, 45, 90] {
            for yaw: Float in [-90, -35, 0, 35, 90] {
                let p = VisionArenaScreenPlacement(distance: 12, scale: 2.25, yaw: yaw, tilt: tilt).bounded
                let y = yaw * .pi / 180, t = tilt * .pi / 180
                let dz = p.scale * (2.1 * abs(sin(y)) + 1.2 * abs(cos(y)*sin(t)) + 0.08 * abs(cos(y)*cos(t)))
                precondition(p.distance + dz <= VisionArenaScreenPlacement.backClearance + 0.0001)
            }
        }
        savedScreenChecks()
        print("Display placement: seated/cinema/reclined/ceiling, clearance, finite bounds and idempotence passed")
    }
    @MainActor static func savedScreenChecks() {
        let suite = "Farframe.SavedScreenChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VisionArenaSavedScreens(defaults: defaults)
        precondition(store.items.isEmpty)
        let original = VisionArenaSavedScreen(id: UUID(), name: "My Cinema", position: [1, 3, -10],
            rotation: [0, 0, 0, 1], scale: 2.1, keepFacingViewer: false)
        precondition(store.add(original))
        precondition(!store.add(original), "Duplicate identities must not be saved")
        precondition(VisionArenaSavedScreens(defaults: defaults).items == [original], "Must survive store recreation")
        for i in 1..<VisionArenaSavedScreens.limit {
            precondition(store.add(.init(id: UUID(), name: "Screen \(i)", position: [0, 2, -5],
                rotation: [0, 0, 0, 1], scale: 1, keepFacingViewer: true)))
        }
        precondition(!store.add(.init(id: UUID(), name: "Overflow", position: [0, 2, -5],
            rotation: [0, 0, 0, 1], scale: 1, keepFacingViewer: true)))
        store.remove(original.id)
        precondition(VisionArenaSavedScreens(defaults: defaults).items.count == 7)
        for invalid: Float in [.nan, .infinity, -1, 0, 3] {
            precondition(!store.add(.init(id: UUID(), name: "Bad", position: [0, 2, -5],
                rotation: [0, 0, 0, 1], scale: invalid, keepFacingViewer: true)))
        }
        let encoder = JSONEncoder()
        let good = try! JSONSerialization.jsonObject(with: encoder.encode(original)) as! [String: Any]
        var bad = good; bad["rotation"] = [0, 0, 0, 0]
        // Corrupt one entry and duplicate another; retain only the valid unique record.
        let mixed = try! JSONSerialization.data(withJSONObject: ["version": 1, "items": [bad, good, good]])
        defaults.set(mixed, forKey: VisionArenaSavedScreens.key)
        precondition(VisionArenaSavedScreens(defaults: defaults).items == [original])
        defaults.set(Data("invalid".utf8), forKey: VisionArenaSavedScreens.key)
        precondition(VisionArenaSavedScreens(defaults: defaults).items.isEmpty)
        defaults.set(try! JSONSerialization.data(withJSONObject: ["version": 99, "items": [good]]), forKey: VisionArenaSavedScreens.key)
        precondition(VisionArenaSavedScreens(defaults: defaults).items.isEmpty)
        precondition(!VisionArenaSavedScreen(id: UUID(), name: "  ", position: [0, 2, -5],
            rotation: [0, 0, 0, 1], scale: 1, keepFacingViewer: true).isValid)
        print("Saved screens: persistence, deletion, capacity, identity, corrupt/future schema and invalid transforms passed")
    }
}
