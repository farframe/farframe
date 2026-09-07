import AccountsAndSecurity
import ExperienceDomain
import Foundation
import StreamingCore

/// Shared construction boundary for future Apple shells. One composition owns
/// one repository actor and injects that exact instance into Pairing, Wake, and
/// every provider it creates, preventing independent actors from competing over
/// the same metadata and Keychain namespaces.
public struct PlayStationRemotePlayComposition: Sendable {
    public let repository: PlayStationConsoleRepository
    public let wakeService: PlayStationWakeService
    public let pairingService: PlayStationPairingService

    private let nativeSessionFactory: any PlayStationNativeSessionFactory

    public init(
        metadataStore: any PlayStationConsoleMetadataStore =
            UserDefaultsPlayStationConsoleMetadataStore(),
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        nativeSessionFactory: any PlayStationNativeSessionFactory =
            ChiakiPlayStationNativeSessionFactory(),
        nativeRegistrationClientFactory: any PlayStationNativeRegistrationClientFactory =
            ChiakiPlayStationNativeRegistrationClientFactory()
    ) {
        let repository = PlayStationConsoleRepository(
            metadataStore: metadataStore,
            credentialStore: credentialStore
        )
        self.repository = repository
        self.wakeService = PlayStationWakeService(repository: repository)
        self.pairingService = PlayStationPairingService(
            repository: repository,
            nativeClientFactory: nativeRegistrationClientFactory
        )
        self.nativeSessionFactory = nativeSessionFactory
    }

    public func makeProvider(
        qualityProfile: QualityProfile = .default
    ) -> PlayStationRemotePlayProvider {
        PlayStationRemotePlayProvider(
            repository: repository,
            nativeSessionFactory: nativeSessionFactory,
            qualityProfile: qualityProfile
        )
    }
}
