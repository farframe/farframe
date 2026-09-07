import ExperienceDomain
import Foundation
import InputCore

public struct StreamingProviderDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let supportedKinds: Set<ExperienceKind>

    public init(id: String, displayName: String, supportedKinds: Set<ExperienceKind>) {
        self.id = id
        self.displayName = displayName
        self.supportedKinds = supportedKinds
    }
}

public protocol StreamingSession: Sendable {
    var id: UUID { get }
    var experience: ExperienceDescriptor { get }
    func start() async throws
    func stop() async
    func send(_ input: ControllerSnapshot) async
}

public protocol StreamingProvider: Sendable {
    var descriptor: StreamingProviderDescriptor { get }
    func makeSession(for experience: ExperienceDescriptor) async throws -> any StreamingSession
}

public enum StreamingCoreError: Error, Equatable, Sendable {
    case duplicateProvider(String)
    case providerNotFound(String)
}

public actor StreamingProviderRegistry {
    private var providers: [String: any StreamingProvider] = [:]

    public init() {}

    public func register(_ provider: any StreamingProvider) throws {
        let id = provider.descriptor.id
        guard providers[id] == nil else {
            throw StreamingCoreError.duplicateProvider(id)
        }
        providers[id] = provider
    }

    public func provider(id: String) throws -> any StreamingProvider {
        guard let provider = providers[id] else {
            throw StreamingCoreError.providerNotFound(id)
        }
        return provider
    }

    public func descriptors() -> [StreamingProviderDescriptor] {
        providers.values.map(\.descriptor).sorted { $0.displayName < $1.displayName }
    }
}
