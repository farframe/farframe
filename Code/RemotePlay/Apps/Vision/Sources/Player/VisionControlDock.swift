import SwiftUI

struct VisionControlDock: Codable, Equatable {
    enum Edge: String, Codable, CaseIterable {
        case top, trailing, bottom, leading
        var horizontal: Bool { self == .top || self == .bottom }
        // The native ornament always stays center-aligned. A small padded
        // content offset provides clearance without changing its anchor type.
        var outwardOffset: CGSize {
            switch self {
            case .top: CGSize(width: 0, height: -36)
            case .trailing: CGSize(width: 36, height: 0)
            case .bottom: CGSize(width: 0, height: 36)
            case .leading: CGSize(width: -36, height: 0)
            }
        }
        #if os(visionOS)
        var alignment: Alignment3D {
            switch self {
            case .top: .bottom
            case .trailing: .leading
            case .bottom: .top
            case .leading: .trailing
            }
        }
        #endif
    }
    var edge: Edge = .trailing
    var progress: Double = 0.5
    var point: UnitPoint {
        switch edge {
        case .top: UnitPoint(x: progress, y: 0)
        case .trailing: UnitPoint(x: 1, y: progress)
        case .bottom: UnitPoint(x: progress, y: 1)
        case .leading: UnitPoint(x: 0, y: progress)
        }
    }
    func moved(by translation: CGSize, in size: CGSize, retaining currentEdge: Edge? = nil) -> Self {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              translation.width.isFinite, translation.height.isFinite else { return self }
        // Keep signed distances outside the window. Clamping first pinned the
        // old edge at distance zero until a second sideways movement occurred.
        let x = point.x * size.width + translation.width
        let y = point.y * size.height + translation.height
        let distances: [(Edge, CGFloat)] = [(.top, y), (.trailing, size.width - x),
                                             (.bottom, size.height - y), (.leading, x)]
        let nearest = distances.min { $0.1 < $1.1 }!
        let current = currentEdge ?? edge
        let retained = distances.first { $0.0 == current }!.1
        let next = retained <= nearest.1 + 18 ? current : nearest.0
        let fraction = next.horizontal ? x / size.width : y / size.height
        return Self(edge: next, progress: min(0.75, max(0.25, fraction)))
    }
    static func load(defaults: UserDefaults = .standard) -> Self {
        let revisionKey = "farframe.vision.controlDock.defaultRevision"
        if defaults.integer(forKey: revisionKey) < 2 {
            let initial = Self()
            initial.save(defaults: defaults)
            defaults.set(2, forKey: revisionKey)
            return initial
        }
        guard let data = defaults.data(forKey: "farframe.vision.controlDock"),
              let dock = try? JSONDecoder().decode(Self.self, from: data),
              dock.progress.isFinite else { return Self() }
        return Self(edge: dock.edge, progress: min(0.75, max(0.25, dock.progress)))
    }
    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: "farframe.vision.controlDock")
        }
    }
}
