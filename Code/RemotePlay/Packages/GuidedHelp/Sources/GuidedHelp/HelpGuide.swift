/// Product-neutral, serializable instructions. No account, payment, session,
/// persistence or window ownership belongs in a guide.
public struct HelpGuide: Codable, Equatable, Sendable {
    public let id: String
    public let revision: Int
    public let title: String
    public let footer: String?
    public let steps: [HelpGuideStep]

    public init(id: String, revision: Int = 1, title: String, footer: String? = nil,
                steps: [HelpGuideStep]) {
        self.id = id
        self.revision = revision
        self.title = title
        self.footer = footer
        self.steps = steps
    }

    /// Stable IDs keep a restored page meaningful when other steps are reordered.
    /// Removed/unknown IDs start at the first remaining step; an empty guide is safe.
    public func index(for stepID: String) -> Int? {
        guard !steps.isEmpty else { return nil }
        return steps.firstIndex(where: { $0.id == stepID }) ?? 0
    }

    public func stepID(from stepID: String, offset: Int) -> String? {
        guard let current = index(for: stepID) else { return nil }
        let next = offset < 0 ? max(0, current - 1) : min(steps.count - 1, current + 1)
        return steps[offset == 0 ? current : next].id
    }
}

public struct HelpGuideStep: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let message: String?
    public let illustration: HelpGuideIllustration?
    public let items: [HelpGuideItem]

    public init(id: String, title: String, message: String? = nil,
                illustration: HelpGuideIllustration? = nil, items: [HelpGuideItem] = []) {
        self.id = id
        self.title = title
        self.message = message
        self.illustration = illustration
        self.items = items
    }
}

public struct HelpGuideIllustration: Codable, Equatable, Sendable {
    public let assetName: String
    public let accessibleDescription: String
    public let usesDarkBacking: Bool

    public init(assetName: String, accessibleDescription: String, usesDarkBacking: Bool = false) {
        self.assetName = assetName
        self.accessibleDescription = accessibleDescription
        self.usesDarkBacking = usesDarkBacking
    }
}

public struct HelpGuideItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let systemImage: String?
    public let assetName: String?

    public init(id: String, title: String, detail: String,
                systemImage: String? = nil, assetName: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.assetName = assetName
    }
}
