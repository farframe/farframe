import AccountsAndSecurity
@testable import AppleMediaCore
import AVFoundation
import CoreMedia
import CoreVideo
import ExperienceDomain
import Foundation
@testable import PlayStationRemotePlay
import StreamingCore
import Testing

@Test
func sessionCoordinatorResolvesExactCredentialsAndQualityWithoutClaimingStreaming() async throws {
    let fixture = try await SessionCoordinatorFixture.make()
    let quality = QualityProfile(
        id: "sdr-proof",
        displayName: "SDR Proof",
        resolution: .p540,
        frameRate: .fps30,
        targetBitrateKbps: 7_777,
        dynamicRange: .sdr
    )

    let generation = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: quality
    )

    #expect(generation == 1)
    #expect(
        await fixture.session.configuration() == PlayStationConnectConfiguration(
            consoleID: fixture.console.id,
            host: fixture.console.hostAddress,
            registrationKey: fixture.registration.registrationKey,
            remotePlayKey: fixture.registration.remotePlayKey,
            videoProfile: try PlayStationResolvedVideoProfile(qualityProfile: quality)
        )
    )
    #expect(
        await fixture.coordinator.snapshot()
            == PlayStationSessionSnapshot(
                state: .connecting,
                generation: generation,
                transportIsReady: false,
                lastQuitReason: nil
            )
    )

    await fixture.session.emit(.transportReady)
    #expect(await eventually { await fixture.coordinator.snapshot().transportIsReady })

    let readySnapshot = await fixture.coordinator.snapshot()
    #expect(readySnapshot.state == .connecting)
    #expect(readySnapshot.state != .streaming)
    #expect(readySnapshot.generation == generation)
}

@Test
func sessionCoordinatorRequiresTransportAndCurrentDecodedFrameBeforeStreaming() async throws {
    let fixture = try await SessionCoordinatorFixture.make()
    let frameRecorder = LockedDecodedFrameCount()
    let generation = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default,
        decodedFrameHandler: { _ in frameRecorder.increment() }
    )
    let decoder = try #require(fixture.videoDecoderFactory.decoder(at: 0))
    decoder.emitFrame(
        DecodedVideoFrame(
            generation: generation,
            pixelBuffer: try coordinatorPixelBuffer(),
            presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 60)
        )
    )

    #expect(await eventually { await fixture.coordinator.snapshot().firstDecodedFrameSeen })
    #expect(frameRecorder.value() == 1)
    #expect(await fixture.coordinator.snapshot().state == .connecting)

    await fixture.session.emit(.transportReady)
    #expect(await eventually { await fixture.coordinator.snapshot().state == .streaming })
}

@Test
func decodedFrameArrivingDuringTeardownCannotReachPresentationOrStreamingState() async throws {
    let session = FakePlayStationNativeSession(holdJoin: true)
    let fixture = try await SessionCoordinatorFixture.make(sessions: [session])
    let frameRecorder = LockedDecodedFrameCount()
    let generation = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default,
        decodedFrameHandler: { _ in frameRecorder.increment() }
    )
    let decoder = try #require(fixture.videoDecoderFactory.decoder(at: 0))

    let disconnect = Task { await fixture.coordinator.disconnect() }
    #expect(await eventually { await session.joinCount() == 1 })
    decoder.emitFrame(
        DecodedVideoFrame(
            generation: generation,
            pixelBuffer: try coordinatorPixelBuffer(),
            presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 60)
        )
    )
    await yieldSeveralTimes()

    #expect(frameRecorder.value() == 0)
    #expect(fixture.videoPresenter.snapshot().framesSubmitted == 0)
    #expect(await fixture.coordinator.snapshot().state == .disconnecting)
    #expect(await fixture.coordinator.snapshot().firstDecodedFrameSeen == false)

    await session.releaseJoin()
    await disconnect.value
    #expect(fixture.videoPresenter.snapshot().activeGeneration == nil)
}

@Test
func encodedVideoBackpressureReturnsFalseToTheNativeSession() async throws {
    let fixture = try await SessionCoordinatorFixture.make()
    let generation = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default
    )
    let decoder = try #require(fixture.videoDecoderFactory.decoder(at: 0))
    decoder.setAdmission(.backpressure)
    let sample = try EncodedVideoSample(
        data: Data([0x00, 0x00, 0x01, 0x26, 0xaa]),
        framesLost: 0,
        frameRecovered: false,
        receivedUptimeNanoseconds: 1
    )

    #expect(await fixture.session.emitMedia(.encodedVideo(sample)) == false)
    #expect(decoder.admittedGenerations() == [generation])

    decoder.setAdmission(.accepted)
    #expect(await fixture.session.emitMedia(.encodedVideo(sample)) == true)
    #expect(decoder.admittedGenerations() == [generation, generation])
}

@Test
func encodedVideoAdmissionNeverRunsObserverWorkOnTheNativeCallback() async throws {
    let fixture = try await SessionCoordinatorFixture.make()
    let recorder = LockedMediaEventRecorder()
    let generation = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default,
        mediaHandler: { generation, event in
            recorder.record(generation: generation, event: event)
        }
    )
    let sample = try EncodedVideoSample(
        data: Data([0x00, 0x00, 0x01, 0x26, 0xaa]),
        framesLost: 0,
        frameRecovered: false,
        receivedUptimeNanoseconds: 1
    )

    #expect(await fixture.session.emitMedia(.encodedVideo(sample)) == true)
    #expect(fixture.videoDecoderFactory.decoder(at: 0)?.admittedGenerations() == [generation])
    #expect(recorder.events().isEmpty)
}

@Test
func currentDecodedFrameReachesBoundedPresenterAndDisconnectDeactivatesIt() async throws {
    let fixture = try await SessionCoordinatorFixture.make()
    let generation = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default
    )
    let decoder = try #require(fixture.videoDecoderFactory.decoder(at: 0))

    #expect(fixture.videoPresenter.snapshot().activeGeneration == generation)
    decoder.emitFrame(
        DecodedVideoFrame(
            generation: generation,
            pixelBuffer: try coordinatorPixelBuffer(),
            presentationTimeStamp: CMTime(value: 1, timescale: 60),
            duration: CMTime(value: 1, timescale: 60)
        )
    )

    #expect(await eventually {
        fixture.videoPresenter.snapshot().framesSubmitted == 1
    })
    let presentation = fixture.videoPresenter.snapshot()
    #expect(presentation.noSurfaceDrops == 1)
    #expect(presentation.framesEnqueued == 0)
    #expect(await fixture.coordinator.snapshot().firstDecodedFrameSeen)
    #expect(await fixture.coordinator.snapshot().state == .connecting)

    await fixture.session.emit(.transportReady)
    #expect(await eventually {
        await fixture.coordinator.snapshot().state == .streaming
    })

    await fixture.coordinator.disconnect()
    #expect(fixture.videoPresenter.snapshot().activeGeneration == nil)
    #expect(decoder.stopCount() == 1)
}

@Test
func sessionCoordinatorRejectsHDRBeforeCreatingNativeOrDecoderState() async throws {
    let fixture = try await SessionCoordinatorFixture.make()
    let hdr = QualityProfile(
        id: "hdr-not-ready",
        displayName: "HDR Not Ready",
        resolution: .p1080,
        frameRate: .fps60,
        targetBitrateKbps: 20_000,
        dynamicRange: .hdr
    )

    await #expect(throws: PlayStationSessionCoordinatorError.unsupportedVideoDynamicRange) {
        try await fixture.coordinator.connect(
            consoleID: fixture.console.id,
            qualityProfile: hdr
        )
    }
    #expect(await fixture.factory.makeCount() == 0)
    #expect(fixture.videoDecoderFactory.makeCount() == 0)
}

@Test
func connectConfigurationDescriptionsRedactBothCredentialValues() throws {
    let registrationKey = Data(SessionCoordinatorFixture.registrationSecret.utf8)
    let remotePlayKey = Data(SessionCoordinatorFixture.remotePlaySecret.utf8)
    let configuration = PlayStationConnectConfiguration(
        consoleID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        host: "192.0.2.20",
        registrationKey: registrationKey,
        remotePlayKey: remotePlayKey,
        videoProfile: try PlayStationResolvedVideoProfile(qualityProfile: .default)
    )

    let renderedValues = [String(describing: configuration), String(reflecting: configuration)]
    let forbiddenValues = [
        SessionCoordinatorFixture.registrationSecret,
        SessionCoordinatorFixture.remotePlaySecret,
        registrationKey.hexString,
        remotePlayKey.hexString,
        registrationKey.map(String.init).joined(separator: ", "),
        remotePlayKey.map(String.init).joined(separator: ", "),
    ]

    for rendered in renderedValues {
        #expect(rendered.contains("<redacted 16 bytes>"))
        for forbidden in forbiddenValues {
            #expect(rendered.localizedCaseInsensitiveContains(forbidden) == false)
        }
    }
}

@Test
func sessionCoordinatorRejectsDuplicateConnectWithoutCreatingAnotherSession() async throws {
    let firstSession = FakePlayStationNativeSession()
    let unusedSession = FakePlayStationNativeSession()
    let fixture = try await SessionCoordinatorFixture.make(sessions: [firstSession, unusedSession])

    _ = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default
    )

    await #expect(throws: PlayStationSessionCoordinatorError.connectionAlreadyActive) {
        try await fixture.coordinator.connect(
            consoleID: fixture.console.id,
            qualityProfile: .stability
        )
    }

    #expect(await fixture.factory.makeCount() == 1)
    #expect(await unusedSession.calls().isEmpty)
}

@Test
func overlappingConnectRequestsAreSerializedBeforeDuplicateRejection() async throws {
    let firstSession = FakePlayStationNativeSession(holdStart: true)
    let unusedSession = FakePlayStationNativeSession()
    let fixture = try await SessionCoordinatorFixture.make(sessions: [firstSession, unusedSession])

    let firstConnect = Task {
        try await fixture.coordinator.connect(
            consoleID: fixture.console.id,
            qualityProfile: .default
        )
    }
    #expect(await eventually { await firstSession.calls() == [.start] })

    let overlappingConnect = Task {
        try await fixture.coordinator.connect(
            consoleID: fixture.console.id,
            qualityProfile: .stability
        )
    }
    await yieldSeveralTimes()
    #expect(await fixture.factory.makeCount() == 1)
    #expect(await unusedSession.calls().isEmpty)

    await firstSession.releaseStart()
    #expect(try await firstConnect.value == 1)
    await #expect(throws: PlayStationSessionCoordinatorError.connectionAlreadyActive) {
        try await overlappingConnect.value
    }
    #expect(await fixture.factory.makeCount() == 1)
}

@Test
func quitDuringSuspendedStartCannotReturnSuccessAfterFailedTeardown() async throws {
    let session = FakePlayStationNativeSession(
        holdStart: true,
        joinFailuresRemaining: 1
    )
    let fixture = try await SessionCoordinatorFixture.make(sessions: [session])
    let frameRecorder = LockedDecodedFrameCount()

    let connectTask = Task {
        try await fixture.coordinator.connect(
            consoleID: fixture.console.id,
            qualityProfile: .default,
            decodedFrameHandler: { _ in frameRecorder.increment() }
        )
    }
    #expect(await eventually { await session.calls() == [.start] })
    let decoder = try #require(fixture.videoDecoderFactory.decoder(at: 0))

    await session.emit(.quit(.nativeFailure(code: -77)))
    #expect(await eventually {
        let snapshot = await fixture.coordinator.snapshot()
        let joinCount = await session.joinCount()
        return snapshot.state == .failed && joinCount == 1
    })

    decoder.emitFrame(
        DecodedVideoFrame(
            generation: 1,
            pixelBuffer: try coordinatorPixelBuffer(),
            presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 60)
        )
    )
    await yieldSeveralTimes()
    #expect(frameRecorder.value() == 0)

    await session.releaseStart()
    await #expect(throws: PlayStationSessionCoordinatorError.sessionEndedDuringConnect) {
        try await connectTask.value
    }

    let failedSnapshot = await fixture.coordinator.snapshot()
    #expect(failedSnapshot.state == .failed)
    #expect(failedSnapshot.generation == 1)
    #expect(failedSnapshot.firstDecodedFrameSeen == false)

    await fixture.coordinator.disconnect()
    #expect(await fixture.coordinator.snapshot().state == .disconnected)
    #expect(decoder.stopCount() == 1)
}

@Test
func sessionCoordinatorWaitsForTeardownBeforeReconnect() async throws {
    let firstSession = FakePlayStationNativeSession(holdJoin: true)
    let secondSession = FakePlayStationNativeSession()
    let fixture = try await SessionCoordinatorFixture.make(sessions: [firstSession, secondSession])

    _ = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default
    )

    let disconnectTask = Task {
        await fixture.coordinator.disconnect()
    }
    #expect(await eventually { await firstSession.joinCount() == 1 })
    let firstDecoder = try #require(fixture.videoDecoderFactory.decoder(at: 0))
    #expect(firstDecoder.stopCount() == 0)

    let reconnectTask = Task {
        try await fixture.coordinator.connect(
            consoleID: fixture.console.id,
            qualityProfile: .stability
        )
    }
    await yieldSeveralTimes()
    #expect(await fixture.factory.makeCount() == 1)
    #expect(await secondSession.calls().isEmpty)

    await firstSession.releaseJoin()
    await disconnectTask.value
    #expect(firstDecoder.stopCount() == 1)
    let secondGeneration = try await reconnectTask.value

    #expect(secondGeneration == 2)
    #expect(await fixture.factory.makeCount() == 2)
    #expect(await secondSession.calls() == [.start])
    #expect(await fixture.coordinator.snapshot().state == .connecting)
}

@Test
func failedNativeJoinRetainsSessionForExplicitRetry() async throws {
    // Two failures, because Disconnect now retries its own teardown once before
    // it strands the session; a single failure no longer reaches this state.
    let firstSession = FakePlayStationNativeSession(joinFailuresRemaining: 2)
    let secondSession = FakePlayStationNativeSession()
    let fixture = try await SessionCoordinatorFixture.make(sessions: [firstSession, secondSession])
    let frameRecorder = LockedDecodedFrameCount()

    let firstGeneration = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default,
        decodedFrameHandler: { _ in frameRecorder.increment() }
    )
    await fixture.coordinator.disconnect()

    let failedSnapshot = await fixture.coordinator.snapshot()
    #expect(failedSnapshot.state == .failed)
    #expect(failedSnapshot.generation == firstGeneration)
    #expect(await fixture.factory.makeCount() == 1)
    let firstDecoder = try #require(fixture.videoDecoderFactory.decoder(at: 0))
    #expect(firstDecoder.stopCount() == 0)
    #expect(fixture.videoPresenter.snapshot().activeGeneration == nil)

    await firstSession.emit(.transportReady)
    firstDecoder.emitFrame(
        DecodedVideoFrame(
            generation: firstGeneration,
            pixelBuffer: try coordinatorPixelBuffer(),
            presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 60)
        )
    )
    let lateSample = try EncodedVideoSample(
        data: Data([0x00, 0x00, 0x01, 0x26, 0xaa]),
        framesLost: 0,
        frameRecovered: false,
        receivedUptimeNanoseconds: 1
    )
    #expect(await firstSession.emitMedia(.encodedVideo(lateSample)) == false)
    await yieldSeveralTimes()

    let stillFailed = await fixture.coordinator.snapshot()
    #expect(stillFailed.state == .failed)
    #expect(stillFailed.transportIsReady == false)
    #expect(stillFailed.firstDecodedFrameSeen == false)
    #expect(frameRecorder.value() == 0)
    #expect(fixture.videoPresenter.snapshot().framesSubmitted == 0)

    await fixture.coordinator.disconnect()
    #expect(await fixture.coordinator.snapshot().state == .disconnected)
    #expect(await fixture.coordinator.snapshot().generation == nil)
    #expect(await firstSession.joinCount() == 3)
    #expect(firstDecoder.stopCount() == 1)

    let secondGeneration = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .stability
    )
    #expect(secondGeneration == 2)
    #expect(await fixture.factory.makeCount() == 2)
}

@Test
func explicitDisconnectAndNativeQuitShareExactlyOneStopJoinPath() async throws {
    let session = FakePlayStationNativeSession(holdJoin: true)
    let fixture = try await SessionCoordinatorFixture.make(sessions: [session])

    _ = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default
    )

    await session.emit(.quit(.remoteDisconnected))
    #expect(await eventually { await session.joinCount() == 1 })

    let explicitDisconnect = Task {
        await fixture.coordinator.disconnect()
    }
    await yieldSeveralTimes()

    #expect(await session.calls() == [.start, .stop, .join])
    await session.releaseJoin()
    await explicitDisconnect.value

    // Disconnect and the native quit handler await the same teardown task.
    // Either waiter may resume first, so disconnect completion alone is not
    // an acknowledgement of the quit handler's post-teardown bookkeeping.
    try #require(await eventually {
        await fixture.coordinator.snapshot().lastQuitReason == .remoteDisconnected
    })

    #expect(await session.calls() == [.start, .stop, .join])
    #expect(
        await fixture.coordinator.snapshot()
            == PlayStationSessionSnapshot(
                state: .disconnected,
                generation: nil,
                transportIsReady: false,
                lastQuitReason: .remoteDisconnected
            )
    )
}

@Test
func nativeFailureQuitRecordsCodeAndFailsUntilTheNextConnect() async throws {
    let firstSession = FakePlayStationNativeSession()
    let secondSession = FakePlayStationNativeSession()
    let fixture = try await SessionCoordinatorFixture.make(sessions: [firstSession, secondSession])

    _ = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default
    )
    await firstSession.emit(.quit(.nativeFailure(code: -55)))

    #expect(await eventually {
        let snapshot = await fixture.coordinator.snapshot()
        return snapshot.state == .failed
            && snapshot.lastQuitReason == .nativeFailure(code: -55)
    })
    #expect(await firstSession.calls() == [.start, .stop, .join])

    _ = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default
    )
    let replacementSnapshot = await fixture.coordinator.snapshot()
    #expect(replacementSnapshot.state == .connecting)
    #expect(replacementSnapshot.lastQuitReason == nil)
}

@Test
func staleNativeEventsCannotMutateReplacementGeneration() async throws {
    let firstSession = FakePlayStationNativeSession()
    let secondSession = FakePlayStationNativeSession()
    let fixture = try await SessionCoordinatorFixture.make(sessions: [firstSession, secondSession])
    let frameRecorder = LockedDecodedFrameCount()

    let firstGeneration = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default,
        decodedFrameHandler: { _ in frameRecorder.increment() }
    )
    let firstDecoder = try #require(fixture.videoDecoderFactory.decoder(at: 0))
    await fixture.coordinator.disconnect()
    let secondGeneration = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .maximumProof,
        decodedFrameHandler: { _ in frameRecorder.increment() }
    )

    #expect(firstGeneration == 1)
    #expect(secondGeneration == 2)

    await firstSession.emit(.transportReady)
    await firstSession.emit(.quit(.nativeFailure(code: -55)))
    firstDecoder.emitFrame(
        DecodedVideoFrame(
            generation: firstGeneration,
            pixelBuffer: try coordinatorPixelBuffer(),
            presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 60)
        )
    )
    await yieldSeveralTimes()

    let replacementSnapshot = await fixture.coordinator.snapshot()
    #expect(replacementSnapshot.generation == secondGeneration)
    #expect(replacementSnapshot.state == .connecting)
    #expect(replacementSnapshot.transportIsReady == false)
    #expect(replacementSnapshot.firstDecodedFrameSeen == false)
    #expect(replacementSnapshot.lastQuitReason == nil)
    #expect(frameRecorder.value() == 0)
    #expect(await secondSession.calls() == [.start])

    await secondSession.emit(.transportReady)
    #expect(await eventually { await fixture.coordinator.snapshot().transportIsReady })
    #expect(await fixture.coordinator.snapshot().state == .connecting)
}

@Test
func mediaCallbacksCarryTheirOriginatingSessionGenerationAndRejectClosedSessions() async throws {
    let firstSession = FakePlayStationNativeSession()
    let secondSession = FakePlayStationNativeSession()
    let recorder = LockedMediaEventRecorder()
    let fixture = try await SessionCoordinatorFixture.make(
        sessions: [firstSession, secondSession]
    )
    let mediaHandler: PlayStationSessionMediaEventHandler = { generation, event in
        recorder.record(generation: generation, event: event)
    }

    let firstGeneration = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default,
        mediaHandler: mediaHandler
    )
    await firstSession.emitMedia(.displayBlocked(false))
    await fixture.coordinator.disconnect()

    let secondGeneration = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .maximumProof,
        mediaHandler: mediaHandler
    )
    await firstSession.emitMedia(.displayBlocked(true))
    await secondSession.emitMedia(.displayBlocked(false))

    #expect(firstGeneration == 1)
    #expect(secondGeneration == 2)
    #expect(
        recorder.events()
            == [
                RecordedMediaEvent(generation: 1, event: .displayBlocked(false)),
                RecordedMediaEvent(generation: 2, event: .displayBlocked(false)),
            ]
    )
    #expect(await fixture.coordinator.snapshot().generation == secondGeneration)
}

@Test
func failedNativeStartIsSanitizedAndStillTearsDownOnce() async throws {
    let session = FakePlayStationNativeSession(failStartWithSensitiveError: true)
    let fixture = try await SessionCoordinatorFixture.make(sessions: [session])

    let capturedError: Error
    do {
        _ = try await fixture.coordinator.connect(
            consoleID: fixture.console.id,
            qualityProfile: .default
        )
        Issue.record("Expected native start to fail")
        return
    } catch {
        capturedError = error
    }

    #expect(capturedError as? PlayStationSessionCoordinatorError == .nativeConnectFailed)
    #expect(await session.calls() == [.start, .stop, .join])
    #expect(await fixture.coordinator.snapshot().state == .failed)

    let renderedError = String(describing: capturedError) + capturedError.localizedDescription
    #expect(renderedError.contains(SessionCoordinatorFixture.registrationSecret) == false)
    #expect(renderedError.contains(SessionCoordinatorFixture.remotePlaySecret) == false)
}

// MARK: Reconnect after a disconnect (device report, 2026-09-06)

/// The owner's report: after a clean disconnect, Connect fails until the app is
/// force quit. A native teardown that fails strands the native session, and the
/// only documented recovery was "a later Disconnect", which no shell issues —
/// all three drop the session after one `stop()`. So Disconnect must retry its
/// own failed teardown before it reports the session gone.
@Test
func disconnectRetriesItsOwnFailedNativeTeardownWithoutASecondShellCall() async throws {
    let session = FakePlayStationNativeSession(joinFailuresRemaining: 1)
    let fixture = try await SessionCoordinatorFixture.make(sessions: [session])

    _ = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default
    )
    await fixture.coordinator.disconnect()

    let snapshot = await fixture.coordinator.snapshot()
    #expect(snapshot.state == .disconnected)
    #expect(snapshot.generation == nil)
    #expect(await session.calls() == [.start, .stop, .join, .stop, .join])
    #expect(fixture.videoPresenter.snapshot().activeGeneration == nil)
    let decoder = try #require(fixture.videoDecoderFactory.decoder(at: 0))
    #expect(decoder.stopCount() == 1)
}

/// When even the retry cannot finish, the coordinator keeps the native session
/// so nothing is freed underneath a live thread — but the next Connect must
/// retry that teardown instead of refusing forever. Refusing forever is what
/// made a process relaunch the only recovery.
@Test
func connectRetriesAStrandedTeardownInsteadOfRefusingUntilRelaunch() async throws {
    let firstSession = FakePlayStationNativeSession(joinFailuresRemaining: 2)
    let secondSession = FakePlayStationNativeSession()
    let fixture = try await SessionCoordinatorFixture.make(
        sessions: [firstSession, secondSession]
    )

    let firstGeneration = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default
    )
    await fixture.coordinator.disconnect()

    let strandedSnapshot = await fixture.coordinator.snapshot()
    #expect(strandedSnapshot.state == .failed)
    #expect(strandedSnapshot.generation == firstGeneration)
    #expect(await fixture.factory.makeCount() == 1)

    let secondGeneration = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .stability
    )

    #expect(secondGeneration == 2)
    #expect(await fixture.factory.makeCount() == 2)
    #expect(await firstSession.joinCount() == 3)
    #expect(await secondSession.calls() == [.start])
    let firstDecoder = try #require(fixture.videoDecoderFactory.decoder(at: 0))
    #expect(firstDecoder.stopCount() == 1)
    #expect(await fixture.coordinator.snapshot().state == .connecting)
}

/// A live session must still be refused, so the stranded-teardown recovery
/// above can never tear down a stream that is working.
@Test
func connectStillRefusesALiveSessionAfterTheStrandedTeardownRecovery() async throws {
    let firstSession = FakePlayStationNativeSession()
    let unusedSession = FakePlayStationNativeSession()
    let fixture = try await SessionCoordinatorFixture.make(
        sessions: [firstSession, unusedSession]
    )

    _ = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default
    )
    await #expect(throws: PlayStationSessionCoordinatorError.connectionAlreadyActive) {
        try await fixture.coordinator.connect(
            consoleID: fixture.console.id,
            qualityProfile: .stability
        )
    }

    #expect(await firstSession.calls() == [.start])
    #expect(await unusedSession.calls().isEmpty)
}

/// `UP-026`: audio was activated before the console was contacted and a refusal
/// aborted the whole connect. The device log shows the audio session refusing
/// with OSStatus -50 on exactly the attempts that followed a disconnect, so the
/// hard gate turned a recoverable audio hiccup into "Farframe will not connect".
@Test
func audioActivationFailureDegradesToVideoOnlyInsteadOfRefusingTheConnect() async throws {
    let backend = AlwaysFailingPCMAudioPlaybackBackend()
    let fixture = try await SessionCoordinatorFixture.make(
        audioPlayer: BoundedPCMAudioPlayer(backend: backend)
    )

    let generation = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default
    )

    #expect(generation == 1)
    #expect(await fixture.session.calls() == [.start])
    let snapshot = await fixture.coordinator.snapshot()
    #expect(snapshot.state == .connecting)
    #expect(snapshot.audioIsUnavailable)
    // One retry, because the -50 refusal is transient while the previous
    // session's audio unit is still being released.
    #expect(backend.activationAttempts() == 2)

    // Video must still reach the presenter on a silent session.
    let decoder = try #require(fixture.videoDecoderFactory.decoder(at: 0))
    decoder.emitFrame(
        DecodedVideoFrame(
            generation: generation,
            pixelBuffer: try coordinatorPixelBuffer(),
            presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 60)
        )
    )
    await fixture.session.emit(.transportReady)
    #expect(await eventually { await fixture.coordinator.snapshot().state == .streaming })
    #expect(await fixture.coordinator.audioSnapshot().activationFailures > 0)
}

/// A working audio path must not be reported as unavailable, and the flag must
/// not survive into the next connect.
@Test
func audioAvailabilityIsRecomputedForEveryConnect() async throws {
    let backend = AlwaysFailingPCMAudioPlaybackBackend(failuresRemaining: 2)
    let fixture = try await SessionCoordinatorFixture.make(
        sessions: [FakePlayStationNativeSession(), FakePlayStationNativeSession()],
        audioPlayer: BoundedPCMAudioPlayer(backend: backend)
    )

    _ = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default
    )
    #expect(await fixture.coordinator.snapshot().audioIsUnavailable)
    await fixture.coordinator.disconnect()

    _ = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default
    )
    #expect(await fixture.coordinator.snapshot().audioIsUnavailable == false)
}

/// A failed teardown used to swallow the native quit reason, so the shells fell
/// back to "The Remote Play session ended unexpectedly" on exactly the failures
/// that most needed naming.
@Test
func aFailedTeardownStillRecordsTheNativeQuitReason() async throws {
    let session = FakePlayStationNativeSession(joinFailuresRemaining: 2)
    let fixture = try await SessionCoordinatorFixture.make(sessions: [session])

    _ = try await fixture.coordinator.connect(
        consoleID: fixture.console.id,
        qualityProfile: .default
    )
    await session.emit(.quit(.nativeFailure(code: 2)))

    #expect(await eventually { await fixture.coordinator.snapshot().state == .failed })
    let snapshot = await fixture.coordinator.snapshot()
    #expect(snapshot.lastQuitReason == .nativeFailure(code: 2))
    // Still retained, because the teardown could not finish.
    #expect(snapshot.generation == 1)
}

@Test
func failedNativeFactoryErrorCannotLeakCredentialMaterial() async throws {
    let fixture = try await SessionCoordinatorFixture.make(factoryFails: true)

    let capturedError: Error
    do {
        _ = try await fixture.coordinator.connect(
            consoleID: fixture.console.id,
            qualityProfile: .default
        )
        Issue.record("Expected native factory to fail")
        return
    } catch {
        capturedError = error
    }

    #expect(capturedError as? PlayStationSessionCoordinatorError == .nativeSessionCreationFailed)
    let renderedError = String(describing: capturedError) + capturedError.localizedDescription
    #expect(renderedError.contains(SessionCoordinatorFixture.registrationSecret) == false)
    #expect(renderedError.contains(SessionCoordinatorFixture.remotePlaySecret) == false)
}

@Test
func sessionCoordinatorFailsClosedBeforeNativeCreationForMissingRegistration() async throws {
    let console = SavedPlayStationConsole(
        displayName: "Unregistered PS5",
        hostAddress: "192.0.2.55"
    )
    let repository = PlayStationConsoleRepository(
        metadataStore: InMemoryPlayStationConsoleMetadataStore(consoles: [console]),
        credentialStore: InMemoryCredentialStore()
    )
    let factory = FakePlayStationNativeSessionFactory(sessions: [FakePlayStationNativeSession()])
    let coordinator = PlayStationSessionCoordinator(
        repository: repository,
        sessionFactory: factory
    )

    await #expect(throws: PlayStationSessionCoordinatorError.registrationMissing(console.id)) {
        try await coordinator.connect(consoleID: console.id, qualityProfile: .default)
    }

    #expect(await factory.makeCount() == 0)
    #expect(await coordinator.snapshot().state == .failed)
}

@Test
func sessionCoordinatorRejectsInvalidResolvedBitrateBeforeNativeCreation() async throws {
    let fixture = try await SessionCoordinatorFixture.make()
    let invalidQuality = QualityProfile(
        id: "invalid",
        displayName: "Invalid",
        resolution: .p1080,
        frameRate: .fps60,
        targetBitrateKbps: -1,
        dynamicRange: .sdr
    )

    await #expect(throws: PlayStationSessionCoordinatorError.invalidQualityProfile) {
        try await fixture.coordinator.connect(
            consoleID: fixture.console.id,
            qualityProfile: invalidQuality
        )
    }

    #expect(await fixture.factory.makeCount() == 0)
    #expect(await fixture.session.calls().isEmpty)
}

private extension QualityProfile {
    static let maximumProof = QualityProfile(
        id: "maximum-proof",
        displayName: "Maximum Proof",
        resolution: .p1080,
        frameRate: .fps60,
        targetBitrateKbps: 20_000,
        dynamicRange: .sdr
    )
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private struct SessionCoordinatorFixture {
    static let registrationSecret = "REG-SECRET-12345"
    static let remotePlaySecret = "REMOTE-KEY-12345"

    let console: SavedPlayStationConsole
    let registration: PlayStationConsoleRegistration
    let session: FakePlayStationNativeSession
    let factory: FakePlayStationNativeSessionFactory
    let videoDecoderFactory: FakeHEVCVideoDecoderFactory
    let videoPresenter: BoundedSampleBufferVideoPresenter
    let coordinator: PlayStationSessionCoordinator

    static func make(
        sessions: [FakePlayStationNativeSession]? = nil,
        factoryFails: Bool = false,
        audioPlayer: BoundedPCMAudioPlayer? = nil
    ) async throws -> SessionCoordinatorFixture {
        let console = SavedPlayStationConsole(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "Living Room PS5",
            hostAddress: "192.0.2.20",
            macAddress: testHardwareAddress([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
        )
        let registration = try PlayStationConsoleRegistration(
            registrationKey: Data(registrationSecret.utf8),
            remotePlayKey: Data(remotePlaySecret.utf8)
        )
        let repository = PlayStationConsoleRepository(
            metadataStore: InMemoryPlayStationConsoleMetadataStore(),
            credentialStore: InMemoryCredentialStore()
        )
        try await repository.save(console, registration: registration)

        let suppliedSessions = sessions ?? [FakePlayStationNativeSession()]
        let factory = FakePlayStationNativeSessionFactory(
            sessions: suppliedSessions,
            failWithSensitiveError: factoryFails
        )
        let videoDecoderFactory = FakeHEVCVideoDecoderFactory()
        let videoPresenter = BoundedSampleBufferVideoPresenter()
        let coordinator = PlayStationSessionCoordinator(
            repository: repository,
            sessionFactory: factory,
            videoDecoderFactory: videoDecoderFactory,
            videoPresenter: videoPresenter,
            audioPlayer: audioPlayer ?? BoundedPCMAudioPlayer()
        )

        return SessionCoordinatorFixture(
            console: console,
            registration: registration,
            session: suppliedSessions[0],
            factory: factory,
            videoDecoderFactory: videoDecoderFactory,
            videoPresenter: videoPresenter,
            coordinator: coordinator
        )
    }
}

private final class FakeHEVCVideoDecoderFactory: HEVCVideoDecoderBuilding, @unchecked Sendable {
    private let lock = NSLock()
    private var configurations: [HEVCDecodeConfiguration] = []
    private var decoders: [FakeHEVCVideoDecoder] = []

    func makeDecoder(
        configuration: HEVCDecodeConfiguration,
        frameHandler: @escaping HEVCDecodedFrameHandler,
        failureHandler: @escaping HEVCDecodeFailureHandler
    ) -> any HEVCVideoDecoding {
        _ = failureHandler
        let decoder = FakeHEVCVideoDecoder(frameHandler: frameHandler)
        lock.withLock {
            configurations.append(configuration)
            decoders.append(decoder)
        }
        return decoder
    }

    func decoder(at index: Int) -> FakeHEVCVideoDecoder? {
        lock.withLock {
            guard decoders.indices.contains(index) else { return nil }
            return decoders[index]
        }
    }

    func makeCount() -> Int {
        lock.withLock { decoders.count }
    }
}

private final class FakeHEVCVideoDecoder: HEVCVideoDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private let frameHandler: HEVCDecodedFrameHandler
    private var admission: HEVCDecodeAdmission = .accepted
    private var generations: [UInt64] = []
    private var stops = 0

    init(frameHandler: @escaping HEVCDecodedFrameHandler) {
        self.frameHandler = frameHandler
    }

    func admit(
        _ sample: EncodedVideoSample,
        generation: UInt64
    ) -> HEVCDecodeAdmission {
        _ = sample
        return lock.withLock {
            generations.append(generation)
            return admission
        }
    }

    func stop() async {
        lock.withLock { stops += 1 }
    }

    func setAdmission(_ admission: HEVCDecodeAdmission) {
        lock.withLock { self.admission = admission }
    }

    func admittedGenerations() -> [UInt64] {
        lock.withLock { generations }
    }

    func emitFrame(_ frame: DecodedVideoFrame) {
        frameHandler(frame)
    }

    func stopCount() -> Int {
        lock.withLock { stops }
    }
}

private struct FakeCoordinatorAudioBackendError: Error, Sendable {}

/// Reproduces the device log's `Session lookup failed` (OSStatus -50): the
/// audio backend refuses to take the output device. Counts attempts so the
/// coordinator's single retry is observable.
private final class AlwaysFailingPCMAudioPlaybackBackend:
    PCMAudioPlaybackBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var failuresRemaining: Int
    private var attempts = 0

    /// `Int.max` keeps every activation failing; a finite count lets a later
    /// connect succeed so the unavailable flag can be shown to reset.
    init(failuresRemaining: Int = .max) {
        self.failuresRemaining = failuresRemaining
    }

    func installRecoveryHandler(_ handler: @escaping @Sendable () -> Void) {
        _ = handler
    }

    func activate(
        outputFormat: AVAudioFormat,
        volume: Float,
        render: @escaping PCMAudioRenderHandler
    ) throws -> PCMAudioRouteMetrics {
        _ = volume
        _ = render
        try lock.withLock {
            attempts += 1
            guard failuresRemaining > 0 else { return }
            failuresRemaining -= 1
            throw FakeCoordinatorAudioBackendError()
        }
        return PCMAudioRouteMetrics(
            sampleRate: outputFormat.sampleRate,
            outputLatency: 0,
            ioBufferDuration: 0,
            presentationLatency: 0
        )
    }

    func setVolume(_ volume: Float) {
        _ = volume
    }

    func stop() {}

    func activationAttempts() -> Int {
        lock.withLock { attempts }
    }
}

private final class LockedDecodedFrameCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    func value() -> Int {
        lock.withLock { count }
    }
}

private enum FakeNativeCall: Equatable, Sendable {
    case start
    case stop
    case join
}

private struct FakeSensitiveNativeError: Error, Sendable {
    let sensitiveMessage: String
}

private struct FakeLifecycleError: Error, Sendable {}

private actor FakePlayStationNativeSession: PlayStationNativeSession {
    private let failStartWithSensitiveError: Bool
    private var holdStart: Bool
    private var holdJoin: Bool
    private var stopFailuresRemaining: Int
    private var joinFailuresRemaining: Int
    private var recordedCalls: [FakeNativeCall] = []
    private var recordedConfiguration: PlayStationConnectConfiguration?
    private var eventHandler: PlayStationNativeSessionEventHandler?
    private var mediaHandler: PlayStationNativeMediaEventHandler?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var joinContinuation: CheckedContinuation<Void, Never>?

    init(
        holdStart: Bool = false,
        holdJoin: Bool = false,
        stopFailuresRemaining: Int = 0,
        joinFailuresRemaining: Int = 0,
        failStartWithSensitiveError: Bool = false
    ) {
        self.holdStart = holdStart
        self.holdJoin = holdJoin
        self.stopFailuresRemaining = stopFailuresRemaining
        self.joinFailuresRemaining = joinFailuresRemaining
        self.failStartWithSensitiveError = failStartWithSensitiveError
    }

    func start(
        configuration: PlayStationConnectConfiguration,
        eventHandler: @escaping PlayStationNativeSessionEventHandler,
        mediaHandler: @escaping PlayStationNativeMediaEventHandler
    ) async throws {
        recordedCalls.append(.start)
        recordedConfiguration = configuration
        self.eventHandler = eventHandler
        self.mediaHandler = mediaHandler

        if holdStart {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }

        if failStartWithSensitiveError {
            throw FakeSensitiveNativeError(
                sensitiveMessage: SessionCoordinatorFixture.registrationSecret
            )
        }
    }

    func stop() throws {
        recordedCalls.append(.stop)
        if stopFailuresRemaining > 0 {
            stopFailuresRemaining -= 1
            throw FakeLifecycleError()
        }
    }

    func join() async throws {
        recordedCalls.append(.join)
        if joinFailuresRemaining > 0 {
            joinFailuresRemaining -= 1
            throw FakeLifecycleError()
        }
        guard holdJoin else { return }
        await withCheckedContinuation { continuation in
            joinContinuation = continuation
        }
    }

    func emit(_ event: PlayStationNativeSessionEvent) {
        eventHandler?(event)
    }

    @discardableResult
    func emitMedia(_ event: PlayStationNativeMediaEvent) -> Bool {
        mediaHandler?(event) ?? false
    }

    func releaseStart() {
        holdStart = false
        startContinuation?.resume()
        startContinuation = nil
    }

    func releaseJoin() {
        holdJoin = false
        joinContinuation?.resume()
        joinContinuation = nil
    }

    func calls() -> [FakeNativeCall] {
        recordedCalls
    }

    func joinCount() -> Int {
        recordedCalls.count(where: { $0 == .join })
    }

    func configuration() -> PlayStationConnectConfiguration? {
        recordedConfiguration
    }
}

private struct RecordedMediaEvent: Equatable, Sendable {
    let generation: UInt64
    let event: PlayStationNativeMediaEvent
}

private final class LockedMediaEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [RecordedMediaEvent] = []

    func record(generation: UInt64, event: PlayStationNativeMediaEvent) {
        lock.withLock {
            recordedEvents.append(RecordedMediaEvent(generation: generation, event: event))
        }
    }

    func events() -> [RecordedMediaEvent] {
        lock.withLock { recordedEvents }
    }
}

private actor FakePlayStationNativeSessionFactory: PlayStationNativeSessionFactory {
    private let sessions: [FakePlayStationNativeSession]
    private let failWithSensitiveError: Bool
    private var nextSessionIndex = 0

    init(
        sessions: [FakePlayStationNativeSession],
        failWithSensitiveError: Bool = false
    ) {
        self.sessions = sessions
        self.failWithSensitiveError = failWithSensitiveError
    }

    func makeSession() throws -> any PlayStationNativeSession {
        if failWithSensitiveError {
            throw FakeSensitiveNativeError(
                sensitiveMessage: SessionCoordinatorFixture.remotePlaySecret
            )
        }
        guard sessions.indices.contains(nextSessionIndex) else {
            throw FakeSensitiveNativeError(sensitiveMessage: "No fake session available")
        }
        defer { nextSessionIndex += 1 }
        return sessions[nextSessionIndex]
    }

    func makeCount() -> Int {
        nextSessionIndex
    }
}

private func coordinatorPixelBuffer() throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        2,
        2,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw HEVCDecodeFailure.decodeFailed(status)
    }
    return pixelBuffer
}

private func eventually(
    timeout: Duration = .seconds(5),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    repeat {
        if await condition() {
            return true
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    } while clock.now < deadline
    return await condition()
}

private func testHardwareAddress(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
}

private func yieldSeveralTimes() async {
    for _ in 0..<20 {
        await Task.yield()
    }
}
