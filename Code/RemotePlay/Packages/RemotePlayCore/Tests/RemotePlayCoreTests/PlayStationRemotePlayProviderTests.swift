import AccountsAndSecurity
import AVFoundation
@testable import AppleMediaCore
import ExperienceDomain
import Foundation
import InputCore
@testable import PlayStationRemotePlay
import StreamingCore
import Testing

@Test
func playStationExperienceIDsAreNamespacedCanonicalAndAdvertiseProvenControllerInput() {
    let console = SavedPlayStationConsole(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "Living Room PS5",
        hostAddress: "192.0.2.20"
    )

    let experience = console.remotePlayExperience

    #expect(
        experience.id.rawValue
            == "playstation.remote-play.console/11111111-2222-3333-4444-555555555555"
    )
    #expect(PlayStationRemotePlayExperienceID.consoleID(from: experience.id) == console.id)
    #expect(experience.capabilities.contains(.physicalController))
    #expect(
        PlayStationRemotePlayExperienceID.consoleID(
            from: ExperienceID(rawValue: console.id.uuidString.lowercased())
        ) == nil
    )
    #expect(
        PlayStationRemotePlayExperienceID.consoleID(
            from: ExperienceID(
                rawValue: "playstation.remote-play.console/"
                    + "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
            )
        ) == nil
    )
}

@Test
func providerRejectsForeignAndUnsupportedExperienceIDs() async throws {
    let fixture = try await ProviderSessionFixture.make()
    let foreignID = ExperienceID(rawValue: "other-provider.console/11111111")
    let foreignExperience = ExperienceDescriptor(
        id: foreignID,
        kind: .remoteStream,
        displayName: "Foreign console",
        capabilities: []
    )

    await #expect(throws: PlayStationRemotePlayError.invalidConsoleExperienceID(foreignID)) {
        _ = try await fixture.provider.makeSession(for: foreignExperience)
    }

    let unsupported = ExperienceDescriptor(
        id: fixture.console.remotePlayExperience.id,
        kind: .cloudStream,
        displayName: fixture.console.displayName,
        capabilities: []
    )
    await #expect(
        throws: PlayStationRemotePlayError.unsupportedExperience(unsupported.id)
    ) {
        _ = try await fixture.provider.makeSession(for: unsupported)
    }
    #expect(await fixture.factory.makeCount() == 0)
}

@Test
func providerSanitizesForgedCapabilitiesToItsImplementedSurface() async throws {
    let fixture = try await ProviderSessionFixture.make()
    let forgedExperience = ExperienceDescriptor(
        id: fixture.console.remotePlayExperience.id,
        kind: .remoteStream,
        displayName: fixture.console.displayName,
        capabilities: [
            .wake,
            .physicalController,
            .touchController,
            .gameplayContinuity,
        ]
    )

    let session = try await fixture.provider.makeSession(for: forgedExperience)

    #expect(
        session.experience.capabilities
            == PlayStationRemotePlayExperience.transportOnlyCapabilities
    )
    #expect(session.experience.capabilities.contains(.physicalController))
    #expect(session.experience.capabilities.contains(.touchController) == false)
    #expect(session.experience.capabilities.contains(.gameplayContinuity) == false)
}

@Test
func providerFacadeStartsExactTransportWithoutClaimingStreaming() async throws {
    let fixture = try await ProviderSessionFixture.make()
    let genericSession = try await fixture.provider.makeSession(
        for: fixture.console.remotePlayExperience
    )
    let session = try #require(genericSession as? PlayStationRemotePlayStreamingSession)

    try await session.start()

    let configuration = try #require(await fixture.nativeSession.configuration())
    #expect(configuration.consoleID == fixture.console.id)
    #expect(configuration.host == fixture.console.hostAddress)
    #expect(configuration.registrationKey == fixture.registration.registrationKey)
    #expect(configuration.remotePlayKey == fixture.registration.remotePlayKey)
    #expect(configuration.videoProfile.bitrateKbps == 12_000)
    #expect(await session.snapshot().state == .connecting)

    await fixture.nativeSession.emit(.transportReady)
    #expect(
        await providerEventually {
            await session.snapshot().transportIsReady
        }
    )
    #expect(await session.snapshot().state == .connecting)

    await session.send(.neutral)
    await session.stop()
    #expect(await fixture.nativeSession.calls() == [.start, .stop, .join])
    #expect(await session.snapshot().state == .disconnected)
    #expect(session.videoPresenter.snapshot().activeGeneration == nil)
}

@Test
func providerFacadeTracksCurrentDisplayRestrictionAndClearsItOnStop() async throws {
    let fixture = try await ProviderSessionFixture.make()
    let genericSession = try await fixture.provider.makeSession(
        for: fixture.console.remotePlayExperience
    )
    let session = try #require(genericSession as? PlayStationRemotePlayStreamingSession)

    try await session.start()
    #expect(await session.snapshot().displayIsBlocked == false)

    #expect(await fixture.nativeSession.emitMedia(.displayBlocked(true)))
    #expect(
        await providerEventually {
            await session.snapshot().displayIsBlocked
        }
    )

    #expect(await fixture.nativeSession.emitMedia(.displayBlocked(false)))
    #expect(
        await providerEventually {
            await session.snapshot().displayIsBlocked == false
        }
    )

    await session.stop()
    #expect(await session.snapshot().displayIsBlocked == false)
    #expect(await fixture.nativeSession.emitMedia(.displayBlocked(true)) == false)
    #expect(await session.snapshot().displayIsBlocked == false)
}

@Test
func providerFacadePreservesDisplayRestrictionDeliveredDuringNativeStart() async throws {
    let nativeSession = ProviderFakeNativeSession(
        mediaEventDuringStart: .displayBlocked(true)
    )
    let fixture = try await ProviderSessionFixture.make(nativeSession: nativeSession)
    let genericSession = try await fixture.provider.makeSession(
        for: fixture.console.remotePlayExperience
    )
    let session = try #require(genericSession as? PlayStationRemotePlayStreamingSession)

    try await session.start()

    #expect(await session.snapshot().displayIsBlocked)
    await session.stop()
    #expect(await session.snapshot().displayIsBlocked == false)
}

@Test
func providerFacadeRepeatedStartDoesNotCorruptActiveDisplayRestriction() async throws {
    let fixture = try await ProviderSessionFixture.make()
    let genericSession = try await fixture.provider.makeSession(
        for: fixture.console.remotePlayExperience
    )
    let session = try #require(genericSession as? PlayStationRemotePlayStreamingSession)

    try await session.start()
    #expect(await fixture.nativeSession.emitMedia(.displayBlocked(true)))
    #expect(await session.snapshot().displayIsBlocked)

    await #expect(throws: (any Error).self) {
        try await session.start()
    }

    #expect(await session.snapshot().displayIsBlocked)
    #expect(await fixture.nativeSession.emitMedia(.displayBlocked(false)))
    #expect(await session.snapshot().displayIsBlocked == false)
    await session.stop()
}

@Test
func providerFacadeRetriesFailedTeardownWithoutReplacingItsCoordinator() async throws {
    let nativeSession = ProviderFakeNativeSession(stopFailuresRemaining: 1)
    let fixture = try await ProviderSessionFixture.make(nativeSession: nativeSession)
    let genericSession = try await fixture.provider.makeSession(
        for: fixture.console.remotePlayExperience
    )
    let session = try #require(genericSession as? PlayStationRemotePlayStreamingSession)

    try await session.start()
    // One Stop is all a shell ever issues: every platform coordinator drops its
    // session reference straight afterwards. The retry has to happen in here.
    await session.stop()

    #expect(await session.snapshot().state == .disconnected)
    #expect(await nativeSession.calls() == [.start, .stop, .stop, .join])
    #expect(session.videoPresenter.snapshot().activeGeneration == nil)
    #expect(await fixture.factory.makeCount() == 1)

    // Repeated Stop stays safe and adds no further native work.
    await session.stop()

    #expect(await session.snapshot().state == .disconnected)
    #expect(await nativeSession.calls() == [.start, .stop, .stop, .join])
}

@Test
func providerCreatesDistinctPresentersAndSessionReusesItsPresenterAcrossReconnect() async throws {
    let fixture = try await ProviderSessionFixture.make()
    let firstGeneric = try await fixture.provider.makeSession(
        for: fixture.console.remotePlayExperience
    )
    let secondGeneric = try await fixture.provider.makeSession(
        for: fixture.console.remotePlayExperience
    )
    let first = try #require(firstGeneric as? PlayStationRemotePlayStreamingSession)
    let second = try #require(secondGeneric as? PlayStationRemotePlayStreamingSession)

    #expect(ObjectIdentifier(first.videoPresenter) != ObjectIdentifier(second.videoPresenter))
    let firstPresenterID = ObjectIdentifier(first.videoPresenter)
    let firstSurfaceID = ObjectIdentifier(first.videoSurface)
    #expect(ObjectIdentifier(first.videoSurface) != ObjectIdentifier(second.videoSurface))
    #expect(firstGeneric is any SampleBufferVideoSurfaceSession)

    try await first.start()
    #expect(first.videoPresenter.snapshot().activeGeneration == 1)
    #expect(first.videoSurface.snapshot().activeGeneration == 1)
    await first.stop()
    #expect(first.videoPresenter.snapshot().activeGeneration == nil)

    try await first.start()
    #expect(first.videoPresenter.snapshot().activeGeneration == 2)
    #expect(ObjectIdentifier(first.videoPresenter) == firstPresenterID)
    #expect(ObjectIdentifier(first.videoSurface) == firstSurfaceID)
    await first.stop()
}

@Test
@MainActor
func providerSessionWaitsForPrestartSurfaceAttachmentBeforeNativeStart() async throws {
    let fixture = try await ProviderSessionFixture.make()
    let genericSession = try await fixture.provider.makeSession(
        for: fixture.console.remotePlayExperience
    )
    let session = try #require(genericSession as? PlayStationRemotePlayStreamingSession)
    let blockingBackend = FakeSampleBufferPresentationBackend()
    await session.videoPresenter.attach(backend: blockingBackend)
    blockingBackend.delayNextFlush()

    let layer = AVSampleBufferDisplayLayer()
    session.videoSurface.attach(layer)
    let start = Task { try await session.start() }

    #expect(await providerEventually { blockingBackend.pendingFlushCount() == 1 })
    #expect(await fixture.nativeSession.calls().isEmpty)

    blockingBackend.completeNextFlush()
    try await start.value
    #expect(await fixture.nativeSession.calls() == [.start])

    await session.stop()
    session.videoSurface.detach(layer)
    await session.videoSurface.synchronizeThroughCurrentOperations()
}

private struct ProviderSessionFixture {
    static let registrationBytes = Data(repeating: 0x11, count: 16)
    static let remotePlayBytes = Data(repeating: 0x22, count: 16)

    let console: SavedPlayStationConsole
    let registration: PlayStationConsoleRegistration
    let nativeSession: ProviderFakeNativeSession
    let factory: ProviderFakeNativeSessionFactory
    let provider: PlayStationRemotePlayProvider

    static func make(
        nativeSession: ProviderFakeNativeSession = ProviderFakeNativeSession()
    ) async throws -> ProviderSessionFixture {
        let console = SavedPlayStationConsole(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "Living Room PS5",
            hostAddress: "192.0.2.20",
            macAddress: testHardwareAddress([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
        )
        let registration = try PlayStationConsoleRegistration(
            registrationKey: registrationBytes,
            remotePlayKey: remotePlayBytes
        )
        let repository = PlayStationConsoleRepository(
            metadataStore: InMemoryPlayStationConsoleMetadataStore(),
            credentialStore: InMemoryCredentialStore()
        )
        try await repository.save(console, registration: registration)

        let factory = ProviderFakeNativeSessionFactory(session: nativeSession)
        return ProviderSessionFixture(
            console: console,
            registration: registration,
            nativeSession: nativeSession,
            factory: factory,
            provider: PlayStationRemotePlayProvider(
                repository: repository,
                nativeSessionFactory: factory,
                qualityProfile: .default
            )
        )
    }
}

private enum ProviderFakeNativeCall: Equatable, Sendable {
    case start
    case stop
    case join
}

private struct ProviderFakeLifecycleError: Error, Sendable {}

private actor ProviderFakeNativeSession: PlayStationNativeSession {
    private var stopFailuresRemaining: Int
    private let mediaEventDuringStart: PlayStationNativeMediaEvent?
    private var recordedCalls: [ProviderFakeNativeCall] = []
    private var recordedConfiguration: PlayStationConnectConfiguration?
    private var eventHandler: PlayStationNativeSessionEventHandler?
    private var mediaHandler: PlayStationNativeMediaEventHandler?

    init(
        stopFailuresRemaining: Int = 0,
        mediaEventDuringStart: PlayStationNativeMediaEvent? = nil
    ) {
        self.stopFailuresRemaining = stopFailuresRemaining
        self.mediaEventDuringStart = mediaEventDuringStart
    }

    func start(
        configuration: PlayStationConnectConfiguration,
        eventHandler: @escaping PlayStationNativeSessionEventHandler,
        mediaHandler: @escaping PlayStationNativeMediaEventHandler
    ) {
        recordedCalls.append(.start)
        recordedConfiguration = configuration
        self.eventHandler = eventHandler
        self.mediaHandler = mediaHandler
        if let mediaEventDuringStart {
            _ = mediaHandler(mediaEventDuringStart)
        }
    }

    func stop() throws {
        recordedCalls.append(.stop)
        if stopFailuresRemaining > 0 {
            stopFailuresRemaining -= 1
            throw ProviderFakeLifecycleError()
        }
    }

    func join() {
        recordedCalls.append(.join)
    }

    func emit(_ event: PlayStationNativeSessionEvent) {
        eventHandler?(event)
    }

    func emitMedia(_ event: PlayStationNativeMediaEvent) -> Bool {
        mediaHandler?(event) ?? false
    }

    func calls() -> [ProviderFakeNativeCall] {
        recordedCalls
    }

    func configuration() -> PlayStationConnectConfiguration? {
        recordedConfiguration
    }
}

private actor ProviderFakeNativeSessionFactory: PlayStationNativeSessionFactory {
    private let session: ProviderFakeNativeSession
    private var count = 0

    init(session: ProviderFakeNativeSession) {
        self.session = session
    }

    func makeSession() -> any PlayStationNativeSession {
        count += 1
        return session
    }

    func makeCount() -> Int {
        count
    }
}

private func providerEventually(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<250 {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

private func testHardwareAddress(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
}
