import Foundation

enum VisionArenaExteriorStyle: String, CaseIterable, Identifiable, Sendable {
    case quietHorizon, orbitalTerrace, lightSculpture
    var id: Self { self }
    var title: String {
        switch self {
        case .quietHorizon: "Quiet Horizon"
        case .orbitalTerrace: "Orbital Terrace"
        case .lightSculpture: "Light Sculpture"
        }
    }
}

enum VisionArenaGlow: String, CaseIterable, Identifiable {
    case off = "Off"
    case low = "Low"
    case medium = "Medium"
    var id: Self { self }
    var opacity: Float {
        switch self {
        case .off: 0
        case .low: 0.45
        case .medium: 0.8
        }
    }
}
