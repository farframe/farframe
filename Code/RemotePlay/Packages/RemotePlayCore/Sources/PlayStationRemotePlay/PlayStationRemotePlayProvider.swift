import AccountsAndSecurity
import AppleMediaCore
import ExperienceDomain
import Foundation
import InputCore
import StreamingCore

public enum PlayStationRemotePlayError: Error, Equatable, Sendable {
    case unsupportedExperience(ExperienceID)
    case invalidConsoleExperienceID(ExperienceID)
}

public struct PlayStationRemotePlayProvider: StreamingProvider {
    public let descriptor = StreamingProviderDescriptor(
        id: "playstation.remote-play",
        displayName: "PlayStation Remote Play",
        supportedKinds: [.remoteStream]
    )

    private let repository: PlayStationConsoleRepository
    private let nativeSessionFactory: any PlayStationNativeSessionFactory
    private let qualityProfile: QualityProfile

    /// Production composition. This creates no native session and reads no
    /// credentials until a returned streaming session is explicitly started.
    public init(qualityProfile: QualityProfile = .default) {
        self.init(
            repository: PlayStationConsoleRepository(
                metadataStore: UserDefaultsPlayStationConsoleMetadataStore(),
                credentialStore: KeychainCredentialStore()
            ),
            nativeSessionFactory: ChiakiPlayStationNativeSessionFactory(),
            qualityProfile: qualityProfile
        )
    }

    public init(
        repository: PlayStationConsoleRepository,
        nativeSessionFactory: any PlayStationNativeSessionFactory,
        qualityProfile: QualityProfile
    ) {
        self.repository = repository
        self.nativeSessionFactory = nativeSessionFactory
        self.qualityProfile = qualityProfile
    }

    public func makeSession(for experience: ExperienceDescriptor) async throws -> any StreamingSession {
        guard experience.kind == .remoteStream else {
            throw PlayStationRemotePlayError.unsupportedExperience(experience.id)
        }
        guard let consoleID = PlayStationRemotePlayExperienceID.consoleID(
            from: experience.id
        ) else {
            throw PlayStationRemotePlayError.invalidConsoleExperienceID(experience.id)
        }

        let transportOnlyExperience = ExperienceDescriptor(
            id: experience.id,
            kind: .remoteStream,
            displayName: experience.displayName,
            capabilities: PlayStationRemotePlayExperience.transportOnlyCapabilities
        )
        let videoPresenter = BoundedSampleBufferVideoPresenter()
        let audioPlayer = BoundedPCMAudioPlayer()
        return PlayStationRemotePlayStreamingSession(
            experience: transportOnlyExperience,
            consoleID: consoleID,
            qualityProfile: qualityProfile,
            videoPresenter: videoPresenter,
            audioPlayer: audioPlayer,
            coordinator: PlayStationSessionCoordinator(
                repository: repository,
                sessionFactory: nativeSessionFactory,
                videoPresenter: videoPresenter,
                audioPlayer: audioPlayer
            )
        )
    }
}
