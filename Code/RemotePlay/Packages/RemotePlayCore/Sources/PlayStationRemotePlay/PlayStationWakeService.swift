import ChiakiNative
import Foundation

public enum PlayStationWakeError: Error, Equatable, Sendable, LocalizedError {
    case consoleNotFound(UUID)
    case registrationMissing(UUID)
    case invalidHost
    case invalidRegistrationKeyLength(Int)
    case nativeFailure(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .consoleNotFound:
            "The saved PlayStation console could not be found."
        case .registrationMissing:
            "Register this PlayStation console before using remote wake."
        case .invalidHost:
            "The saved PlayStation address is invalid."
        case .invalidRegistrationKeyLength:
            "The saved PlayStation registration is invalid. Re-register the console."
        case let .nativeFailure(_, message):
            "PlayStation wake failed: \(message)"
        }
    }
}

public protocol PlayStationWakeClient: Sendable {
    func wake(host: String, registrationKey: Data) async throws
}

/// Blocking hostname resolution and UDP delivery stay off the calling actor.
public struct ChiakiPlayStationWakeClient: PlayStationWakeClient {
    public init() {}

    public func wake(host: String, registrationKey: Data) async throws {
        guard host.isEmpty == false, host.utf8.contains(0) == false else {
            throw PlayStationWakeError.invalidHost
        }
        guard registrationKey.count == Int(RP_CHIAKI_REGISTRATION_KEY_SIZE) else {
            throw PlayStationWakeError.invalidRegistrationKeyLength(registrationKey.count)
        }

        try await Task.detached(priority: .userInitiated) {
            let result: Int32 = host.withCString { hostPointer in
                registrationKey.withUnsafeBytes { keyBytes in
                    rp_chiaki_wake_ps5(
                        hostPointer,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyBytes.count
                    )
                }
            }
            guard result == RP_CHIAKI_BRIDGE_SUCCESS.rawValue else {
                let message = rp_chiaki_result_string(result).map(String.init(cString:))
                    ?? "Native error \(result)"
                throw PlayStationWakeError.nativeFailure(code: result, message: message)
            }
        }.value
    }
}

public actor PlayStationWakeService {
    private let repository: PlayStationConsoleRepository
    private let client: any PlayStationWakeClient

    public init(
        repository: PlayStationConsoleRepository,
        client: any PlayStationWakeClient = ChiakiPlayStationWakeClient()
    ) {
        self.repository = repository
        self.client = client
    }

    public func wake(consoleID: UUID) async throws {
        guard let console = try await repository.consoles().first(where: { $0.id == consoleID }) else {
            throw PlayStationWakeError.consoleNotFound(consoleID)
        }
        guard let registration = try await repository.registration(for: consoleID) else {
            throw PlayStationWakeError.registrationMissing(consoleID)
        }

        // Wake follows the same Home/Away route as Connect. Over an Away route
        // the datagram reaches the console only if UDP 9302 is routed to it.
        try await client.wake(
            host: console.activeHostAddress,
            registrationKey: registration.registrationKey
        )
    }
}
