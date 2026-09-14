import Foundation
import Observation

/// Room-relative geometry only. No account, console, network or world-map data.
struct VisionArenaSavedScreen: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let position: SIMD3<Float>
    let rotation: SIMD4<Float>
    let scale: Float
    let keepFacingViewer: Bool

    var isValid: Bool {
        let values = [position.x, position.y, position.z, rotation.x, rotation.y, rotation.z, rotation.w, scale]
        guard values.allSatisfy({ $0.isFinite && abs($0) < 100 }),
              (-4...4).contains(position.x), (0.1...5.8).contains(position.y),
              (-12 ... -0.3).contains(position.z),
              VisionArenaScreenPlacement.scaleRange.contains(scale),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 32 else { return false }
        let norm = rotation.x * rotation.x + rotation.y * rotation.y + rotation.z * rotation.z + rotation.w * rotation.w
        return (0.99...1.01).contains(norm)
    }
}

@MainActor @Observable final class VisionArenaSavedScreens {
    static let key = "farframe.arena.savedScreens.v1"
    static let limit = 8
    private(set) var items: [VisionArenaSavedScreen] = []
    @ObservationIgnored private let defaults: UserDefaults
    private struct Document: Codable {
        var version = 1
        var items: [VisionArenaSavedScreen]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.key), data.count <= 32_768,
              let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 else { return }
        var seen = Set<UUID>()
        items = Array(document.items.filter { $0.isValid && seen.insert($0.id).inserted }.prefix(Self.limit))
    }

    @discardableResult func add(_ item: VisionArenaSavedScreen) -> Bool {
        guard item.isValid, items.count < Self.limit, !items.contains(where: { $0.id == item.id }) else { return false }
        return persist(items + [item])
    }

    func remove(_ id: UUID) { _ = persist(items.filter { $0.id != id }) }

    private func persist(_ next: [VisionArenaSavedScreen]) -> Bool {
        guard let data = try? JSONEncoder().encode(Document(items: next)) else { return false }
        defaults.set(data, forKey: Self.key)
        items = next
        return true
    }
}
