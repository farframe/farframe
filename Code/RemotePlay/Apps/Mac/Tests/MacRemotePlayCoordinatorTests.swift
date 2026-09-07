import AppleMediaCore
import ExperienceDomain
import Foundation
import InputCore
import PlayStationRemotePlay
import Testing
@testable import RemotePlayMac

@Suite("Mac Remote Play coordinator", .serialized)
@MainActor
struct MacRemotePlayCoordinatorTests {
    @Test("Video rates use elapsed time and rebaseline on surface, generation, or counter changes")
    func videoRatesUseMonotonicDeltas() {
        let firstSurface = NSObject()
        let secondSurface = NSObject()
        let surface = ObjectIdentifier(firstSurface)
        var sampler = MacVideoRateSampler()
        func counters(_ submitted: UInt64, _ enqueued: UInt64, generation: UInt64? = 1) -> SampleBufferVideoPresentationSnapshot {
            SampleBufferVideoPresentationSnapshot(
                activeGeneration: generation, framesSubmitted: submitted,
                framesEnqueued: enqueued, staleGenerationDrops: 0,
                noSurfaceDrops: 0, workerBackpressureDrops: 2,
                rendererBackpressureDrops: 3, invalidTimingDrops: 0, flushRecoveries: 1
            )
        }
        let baseline = sampler.sample(counters(100, 80), surface: surface, uptimeNanoseconds: 1_000_000_000)
        #expect(baseline.submittedFramesPerSecond == nil)
        let measured = sampler.sample(counters(220, 180), surface: surface, uptimeNanoseconds: 3_000_000_000)
        #expect(measured.submittedFramesPerSecond == 60)
        #expect(measured.enqueuedFramesPerSecond == 50)
        #expect(measured.counters.rendererBackpressureDrops == 3)
        let idle = sampler.sample(counters(220, 180), surface: surface, uptimeNanoseconds: 4_000_000_000)
        #expect(idle.submittedFramesPerSecond == 0)
        #expect(idle.enqueuedFramesPerSecond == 0)
        let sameTime = sampler.sample(counters(250, 200), surface: surface, uptimeNanoseconds: 4_000_000_000)
        #expect(sameTime.submittedFramesPerSecond == nil)
        let backwards = sampler.sample(counters(260, 210), surface: surface, uptimeNanoseconds: 3_000_000_000)
        #expect(backwards.submittedFramesPerSecond == nil)
        let resetCounters = sampler.sample(counters(1, 1), surface: surface, uptimeNanoseconds: 5_000_000_000)
        #expect(resetCounters.submittedFramesPerSecond == nil)
        let newGeneration = sampler.sample(counters(2, 2, generation: 2), surface: surface, uptimeNanoseconds: 6_000_000_000)
        #expect(newGeneration.submittedFramesPerSecond == nil)
        let newSurface = sampler.sample(counters(3, 3, generation: 2), surface: ObjectIdentifier(secondSurface), uptimeNanoseconds: 7_000_000_000)
        #expect(newSurface.submittedFramesPerSecond == nil)
        let noGeneration = sampler.sample(counters(4, 4, generation: nil), surface: surface, uptimeNanoseconds: 8_000_000_000)
        #expect(noGeneration.submittedFramesPerSecond == nil)
        let resumed = sampler.sample(counters(5, 5), surface: surface, uptimeNanoseconds: 9_000_000_000)
        #expect(resumed.submittedFramesPerSecond == nil)
        sampler.reset()
        let explicitReset = sampler.sample(counters(10, 10), surface: surface, uptimeNanoseconds: 10_000_000_000)
        #expect(explicitReset.submittedFramesPerSecond == nil)
    }

    @Test("Failed Connect can Wake and then Connect without dismissing its error")
    func retryConsoleActionsAfterConnectionFailure() async {
        let console = testConsole()
        let session = FakeMacRemotePlaySession(snapshot: .idle)
        let fixture = makeFixture(console: console, factoryPlans: [
            .failure(.noSession, gate: nil), .session(session, gate: nil),
        ])
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id) == false)
        #expect(fixture.coordinator.canStartConsoleAction)
        await fixture.coordinator.wake(consoleID: console.id)
        #expect(await fixture.wakeRecorder.count == 1)
        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.wakeStatusMessage?.contains("not confirmed") == true)
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        #expect(fixture.coordinator.wakeStatusMessage == nil)
        await fixture.coordinator.disconnect()
    }

    @Test("Failed Wake permits Connect without a separate Dismiss")
    func connectAfterWakeFailure() async {
        let console = testConsole()
        let session = FakeMacRemotePlaySession(snapshot: .idle)
        let fixture = makeFixture(console: console, sessions: [session], wakeFailure: .commandRejected)
        await fixture.coordinator.prepare()
        await fixture.coordinator.wake(consoleID: console.id)
        #expect(fixture.coordinator.phase == .failed(FakeFailure.commandRejected.localizedDescription))
        #expect(fixture.coordinator.wakeStatusMessage == nil)
        #expect(fixture.coordinator.canStartConsoleAction)
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await fixture.coordinator.disconnect()
    }

    @Test("Wake sending and settling reject duplicate actions and retain honest feedback")
    func wakeSettlingAndDuplicateActions() async {
        let console = testConsole()
        let sendGate = AsyncGate()
        let settleGate = AsyncGate()
        let fixture = makeFixture(console: console, wakeGate: sendGate, wakeSettlingGate: settleGate)
        await fixture.coordinator.prepare()
        let wake = Task { await fixture.coordinator.wake(consoleID: console.id) }
        await sendGate.waitUntilEntered()
        #expect(fixture.coordinator.wakeRequestWasSent == false)
        #expect(fixture.coordinator.canStartConsoleAction == false)
        await fixture.coordinator.wake(consoleID: console.id)
        #expect(await fixture.wakeRecorder.count == 1)
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id) == false)
        await sendGate.open()
        await settleGate.waitUntilEntered()
        #expect(fixture.coordinator.phase == .waking(console.id))
        #expect(fixture.coordinator.wakeRequestWasSent)
        #expect(fixture.coordinator.canStartConsoleAction == false)
        await fixture.coordinator.wake(consoleID: console.id)
        #expect(await fixture.wakeRecorder.count == 1)
        await settleGate.open()
        await wake.value
        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.wakeRequestWasSent)
        #expect(fixture.coordinator.canStartConsoleAction)
    }

    @Test("Canceled Wake sends or settling cannot leave a busy phase or confirmed result", arguments: [false, true])
    func cancelWake(duringSettling: Bool) async {
        let console = testConsole()
        let gate = AsyncGate()
        let fixture = makeFixture(
            console: console,
            wakeGate: duringSettling ? nil : gate,
            wakeSettlingGate: duringSettling ? gate : nil
        )
        await fixture.coordinator.prepare()
        let wake = Task { await fixture.coordinator.wake(consoleID: console.id) }
        await gate.waitUntilEntered()
        wake.cancel()
        await gate.open()
        await wake.value
        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.canStartConsoleAction)
        #expect(fixture.coordinator.wakeStatusMessage == nil)
    }

    @Test("Late settling completion cannot overwrite a replacement connection")
    func staleWakeSettlingCannotOverwriteConnect() async {
        let console = testConsole()
        let gate = AsyncGate()
        let session = FakeMacRemotePlaySession(snapshot: .idle)
        let fixture = makeFixture(console: console, sessions: [session], wakeSettlingGate: gate)
        await fixture.coordinator.prepare()
        let wake = Task { await fixture.coordinator.wake(consoleID: console.id) }
        await gate.waitUntilEntered()
        await fixture.coordinator.disconnect()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await gate.open()
        await wake.value
        #expect(fixture.coordinator.phase == .prepared(console.id))
        #expect(fixture.coordinator.wakeStatusMessage == nil)
        await fixture.coordinator.disconnect()
    }

    @Test("Startup failure cannot become action-ready merely by dismissing the error")
    func failedStartupCannotBypassRecovery() async {
        let fixture = makeFixture(loader: StartupLoader([]))
        await fixture.coordinator.prepare()
        #expect(fixture.coordinator.startupRecoveryIsResolved == false)
        fixture.coordinator.dismissError()
        #expect(fixture.coordinator.canStartConsoleAction == false)
        await fixture.coordinator.wake(consoleID: UUID())
        #expect(await fixture.coordinator.prepareConnection(consoleID: UUID()) == false)
        #expect(await fixture.wakeRecorder.count == 0)
        #expect(await fixture.factory.makeCount == 0)
    }

    @Test("A registration recovery keeps saved console actions blocked even without a separate message", arguments: [false, true])
    func registrationRecoveryBlocksConsoleActions(registrationOnly: Bool) async {
        let console = testConsole()
        let fixture = makeFixture(loader: StartupLoader([
            MacStartupSnapshot(
                consoles: [console],
                recoveryMessage: registrationOnly ? nil : "Finish pairing.",
                registrationRecovery: registrationOnly
                    ? MacRegistrationRecovery(message: "Finish pairing.", target: MacPairingTarget(existingConsoleID: console.id))
                    : nil
            ),
        ]))
        await fixture.coordinator.prepare()
        #expect(fixture.coordinator.phase == .recoveryRequired("Finish pairing."))
        #expect(fixture.coordinator.canStartConsoleAction == false)
        await fixture.coordinator.wake(consoleID: console.id)
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id) == false)
        #expect(await fixture.wakeRecorder.count == 0)
        #expect(await fixture.factory.makeCount == 0)
    }

    @Test("Safe native quit codes retain distinct diagnostics without console details")
    func nativeQuitDiagnosticMessages() {
        let first = MacRemoteSessionSnapshot(state: .failed, displayIsBlocked: false, lastQuitReason: .nativeFailure(code: 3))
        let second = MacRemoteSessionSnapshot(state: .failed, displayIsBlocked: false, lastQuitReason: .nativeFailure(code: 7))
        let remote = MacRemoteSessionSnapshot(state: .disconnected, displayIsBlocked: false, lastQuitReason: .remoteDisconnected)
        #expect(first.failureMessage.contains("code 3"))
        #expect(second.failureMessage.contains("code 7"))
        #expect(first.failureMessage != second.failureMessage)
        #expect(remote.failureMessage.contains("PS5 ended"))
        #expect(first.failureMessage.contains(testConsole().hostAddress) == false)
    }

    @Test("Native failure details survive cleanup and permit a fresh Connect")
    func nativeFailureRetainsSafeCause() async {
        let console = testConsole()
        let session = FakeMacRemotePlaySession(snapshot: .streaming)
        let replacement = FakeMacRemotePlaySession(snapshot: .idle)
        let fixture = makeFixture(console: console, sessions: [session, replacement])
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        session.setSnapshot(state: .failed, displayIsBlocked: false, lastQuitReason: .nativeFailure(code: 3))
        await fixture.coordinator.refreshActiveSession()
        guard case let .failed(message) = fixture.coordinator.phase else {
            Issue.record("Expected the typed failure to remain after cleanup")
            return
        }
        #expect(message.contains("code 3"))
        #expect(fixture.coordinator.canStartConsoleAction)
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await fixture.coordinator.disconnect()
    }

    @Test("An old quit diagnostic cannot overwrite a replacement session")
    func staleQuitDiagnosticIsIgnored() async {
        let console = testConsole()
        let gate = AsyncGate()
        let first = FakeMacRemotePlaySession(snapshot: .idle)
        let replacement = FakeMacRemotePlaySession(snapshot: .idle)
        let fixture = makeFixture(console: console, sessions: [first, replacement])
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        first.setSnapshot(state: .failed, displayIsBlocked: false, lastQuitReason: .nativeFailure(code: 3))
        first.gateNextSnapshot(gate)
        let refresh = Task { await fixture.coordinator.refreshActiveSession() }
        await gate.waitUntilEntered()
        await fixture.coordinator.disconnect()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await gate.open()
        await refresh.value
        #expect(fixture.coordinator.phase == .prepared(console.id))
        #expect(fixture.coordinator.activeSessionID == replacement.id)
        await fixture.coordinator.disconnect()
    }

    @Test("Startup sorts consoles and exposes recoverable registration state")
    func startupAndRecovery() async {
        let alpha = MacConsoleSummary(
            id: UUID(),
            name: "Alpha",
            hostAddress: "192.0.2.10"
        )
        let zulu = MacConsoleSummary(
            id: UUID(),
            name: "Zulu",
            hostAddress: "192.0.2.11"
        )
        let loader = StartupLoader([
            MacStartupSnapshot(
                consoles: [zulu, alpha],
                recoveryMessage: "Finish pairing again."
            ),
            MacStartupSnapshot(consoles: [zulu, alpha]),
        ])
        let fixture = makeFixture(loader: loader)

        await fixture.coordinator.prepare()

        #expect(fixture.coordinator.phase == .recoveryRequired("Finish pairing again."))
        #expect(fixture.coordinator.consoles == [alpha, zulu])
        #expect(fixture.coordinator.controllerConnection == fixture.controller.connection)

        await fixture.coordinator.retryStartup()

        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.consoles == [alpha, zulu])
        #expect(await loader.loadCount == 2)
    }

    @Test("Controller presence stays live on Home without a Remote Play session")
    func liveControllerPresenceWhileIdle() async {
        let controller = FakeMacControllerSource()
        let fixture = makeFixture(controller: controller)

        await fixture.coordinator.prepare()
        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.controllerConnection == .disconnected)

        let connected = MacControllerConnection(
            isConnected: true,
            name: "DualSense Wireless Controller"
        )
        controller.setConnection(connected)

        #expect(
            await eventually {
                fixture.coordinator.controllerConnection == connected
            }
        )
        #expect(fixture.coordinator.hasActiveSession == false)
    }

    @Test("Session start waits for the matching queued-surface callback")
    func surfaceBeforeStart() async throws {
        let console = testConsole()
        let session = FakeMacRemotePlaySession(snapshot: .streaming)
        let fixture = makeFixture(console: console, sessions: [session])
        await fixture.coordinator.prepare()

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        #expect(fixture.coordinator.phase == .prepared(console.id))
        #expect(session.state.startCount == 0)

        #expect(
            await authorizeQueuedSurface(
                fixture.coordinator,
                sessionID: UUID()
            ) == .stale
        )
        #expect(session.state.startCount == 0)

        await authorizeQueuedSurface(fixture.coordinator, sessionID: session.id)
        await fixture.coordinator.waitForConnectionAttempt()

        #expect(session.state.startCount == 1)
        #expect(fixture.coordinator.phase == .streaming(console.id))

        await fixture.coordinator.disconnect()
    }

    @Test("Duplicate Connect and surface callbacks create and start only one session")
    func duplicateConnect() async {
        let console = testConsole()
        let session = FakeMacRemotePlaySession(snapshot: .streaming)
        let fixture = makeFixture(console: console, sessions: [session])
        await fixture.coordinator.prepare()

        let firstPreparation = await fixture.coordinator.prepareConnection(consoleID: console.id)
        let duplicatePreparation = await fixture.coordinator.prepareConnection(consoleID: console.id)

        #expect(firstPreparation)
        #expect(duplicatePreparation == false)
        #expect(await fixture.factory.makeCount == 1)

        await authorizeQueuedSurface(fixture.coordinator, sessionID: session.id)
        await authorizeQueuedSurface(fixture.coordinator, sessionID: session.id)
        await fixture.coordinator.waitForConnectionAttempt()

        #expect(session.state.startCount == 1)
        #expect(fixture.coordinator.activeSessionID == session.id)

        await fixture.coordinator.disconnect()
    }

    @Test("Concurrent Connect while the first factory is suspended creates one session")
    func concurrentConnectWhileFactoryIsSuspended() async {
        let console = testConsole()
        let factoryGate = AsyncGate()
        let session = FakeMacRemotePlaySession(snapshot: .streaming)
        let fixture = makeFixture(
            console: console,
            factoryPlans: [.session(session, gate: factoryGate)]
        )
        await fixture.coordinator.prepare()

        let firstPreparation = Task {
            await fixture.coordinator.prepareConnection(consoleID: console.id)
        }
        await factoryGate.waitUntilEntered()

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id) == false)
        #expect(await fixture.factory.makeCount == 1)

        await factoryGate.open()
        #expect(await firstPreparation.value)
        #expect(fixture.coordinator.activeSessionID == session.id)
        #expect(fixture.coordinator.phase == .prepared(console.id))

        await fixture.coordinator.disconnect()
    }

    @Test("Disconnect during a suspended factory prevents the returned session from installing")
    func disconnectDuringSuspendedFactory() async {
        let console = testConsole()
        let factoryGate = AsyncGate()
        let staleSession = FakeMacRemotePlaySession(snapshot: .idle)
        let fixture = makeFixture(
            console: console,
            factoryPlans: [.session(staleSession, gate: factoryGate)]
        )
        await fixture.coordinator.prepare()

        let preparation = Task {
            await fixture.coordinator.prepareConnection(consoleID: console.id)
        }
        await factoryGate.waitUntilEntered()

        await fixture.coordinator.disconnect()
        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.hasActiveSession == false)

        await factoryGate.open()
        #expect(await preparation.value == false)
        #expect(await eventually { staleSession.state.stopCount == 1 })
        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.hasActiveSession == false)
        #expect(fixture.coordinator.activeSessionID == nil)
    }

    @Test("A stale factory failure cannot clear a replacement preparation")
    func staleFactoryFailureCannotClearReplacement() async {
        let console = testConsole()
        let staleFactoryGate = AsyncGate()
        let replacement = FakeMacRemotePlaySession(snapshot: .idle)
        let fixture = makeFixture(
            console: console,
            factoryPlans: [
                .failure(.noSession, gate: staleFactoryGate),
                .session(replacement, gate: nil),
            ]
        )
        await fixture.coordinator.prepare()

        let stalePreparation = Task {
            await fixture.coordinator.prepareConnection(consoleID: console.id)
        }
        await staleFactoryGate.waitUntilEntered()
        await fixture.coordinator.disconnect()

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        #expect(fixture.coordinator.activeSessionID == replacement.id)
        #expect(fixture.coordinator.phase == .prepared(console.id))

        await staleFactoryGate.open()
        #expect(await stalePreparation.value == false)
        #expect(fixture.coordinator.activeSessionID == replacement.id)
        #expect(fixture.coordinator.phase == .prepared(console.id))
        #expect(await fixture.factory.makeCount == 2)

        await fixture.coordinator.disconnect()
    }

    @Test("A session without a video surface fails closed and is stopped")
    func missingVideoSurfaceFailsClosed() async {
        let console = testConsole()
        let session = FakeMacRemotePlaySession(
            snapshot: .idle,
            videoSurface: nil
        )
        let fixture = makeFixture(console: console, sessions: [session])
        await fixture.coordinator.prepare()

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id) == false)
        #expect(session.state.startCount == 0)
        #expect(session.state.stopCount == 1)
        #expect(fixture.coordinator.hasActiveSession == false)
        #expect(fixture.coordinator.activeSessionID == nil)
        guard case let .failed(message) = fixture.coordinator.phase else {
            Issue.record("Expected missing video surface to fail the connection")
            return
        }
        #expect(message == MacRemotePlayCoordinatorError.missingVideoSurface.localizedDescription)
    }

    @Test("The concrete video surface value is the only availability signal")
    func concreteVideoSurfaceIsAtomic() async {
        let console = testConsole()
        let missingSurface = FakeMacRemotePlaySession(
            snapshot: .idle,
            videoSurface: nil
        )
        let concreteSurface = FakeMacRemotePlaySession(
            snapshot: .idle,
            videoSurface: .testHarness
        )
        let fixture = makeFixture(
            console: console,
            sessions: [missingSurface, concreteSurface]
        )
        await fixture.coordinator.prepare()

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id) == false)
        #expect(missingSurface.state.stopCount == 1)
        #expect(fixture.coordinator.canStartConsoleAction)

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        #expect(fixture.coordinator.activeSessionID == concreteSurface.id)
        #expect(fixture.coordinator.phase == .prepared(console.id))

        await fixture.coordinator.disconnect()
    }

    @Test("Provider snapshots map to Mac phase, restriction, and controller state")
    func snapshotMapping() async {
        let console = testConsole()
        let controller = FakeMacControllerSource(
            connection: MacControllerConnection(isConnected: true, name: "DualSense")
        )
        let audio = PCMAudioPlaybackSnapshot(
            state: .playing,
            activeGeneration: 3,
            negotiatedFormat: nil,
            volume: 0.7,
            isMuted: false,
            queue: AudioQueueSnapshot(
                receivedBuffers: 40,
                renderedBuffers: 38,
                droppedBuffers: 2,
                pendingOverflowDrops: 2,
                sampleRate: 48_000
            ),
            recoveries: 0,
            activationFailures: 0
        )
        let session = FakeMacRemotePlaySession(
            snapshot: .connecting,
            audioSnapshot: audio
        )
        let fixture = makeFixture(
            console: console,
            sessions: [session],
            controller: controller
        )
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))

        session.setSnapshot(state: .connecting, displayIsBlocked: false)
        await fixture.coordinator.refreshActiveSession()
        #expect(fixture.coordinator.phase == .connecting(console.id))

        session.setSnapshot(state: .streaming, displayIsBlocked: true)
        await fixture.coordinator.refreshActiveSession()
        #expect(fixture.coordinator.phase == .streaming(console.id))
        #expect(fixture.coordinator.remoteDisplayIsBlocked)
        #expect(
            fixture.coordinator.controllerConnection ==
                MacControllerConnection(isConnected: true, name: "DualSense")
        )
        #expect(fixture.coordinator.audioPlaybackSnapshot == audio)

        session.setSnapshot(state: .disconnecting, displayIsBlocked: false)
        await fixture.coordinator.refreshActiveSession()
        #expect(fixture.coordinator.phase == .disconnecting)

        session.setSnapshot(state: .disconnected, displayIsBlocked: false)
        await fixture.coordinator.refreshActiveSession()
        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.hasActiveSession == false)
        #expect(fixture.coordinator.activeSessionID == nil)
    }

    @Test("Disconnect stops the session and clears all session-owned state")
    func disconnectCleanup() async {
        let console = testConsole()
        let session = FakeMacRemotePlaySession(
            snapshot: MacRemoteSessionSnapshot(state: .streaming, displayIsBlocked: true)
        )
        let fixture = makeFixture(console: console, sessions: [session])
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await authorizeQueuedSurface(fixture.coordinator, sessionID: session.id)
        await fixture.coordinator.waitForConnectionAttempt()
        await fixture.coordinator.disconnect()

        #expect(session.state.stopCount == 1)
        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.hasActiveSession == false)
        #expect(fixture.coordinator.activeSessionID == nil)
        #expect(fixture.coordinator.activeConsoleID == nil)
        #expect(fixture.coordinator.activeStreamQuality == nil)
        #expect(fixture.coordinator.videoSurface == nil)
        #expect(fixture.coordinator.remoteDisplayIsBlocked == false)
        #expect(fixture.coordinator.audioPlaybackSnapshot == nil)
    }

    @Test("A failed Rest command still stops transport and reports the fallback")
    func restFailureStopsSession() async {
        let console = testConsole()
        let session = FakeMacRemotePlaySession(
            snapshot: .streaming,
            restFailure: .restRejected
        )
        let fixture = makeFixture(console: console, sessions: [session])
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await authorizeQueuedSurface(fixture.coordinator, sessionID: session.id)
        await fixture.coordinator.waitForConnectionAttempt()
        await fixture.coordinator.restAndDisconnect()

        #expect(session.state.restCount == 1)
        #expect(session.state.stopCount == 1)
        #expect(fixture.coordinator.hasActiveSession == false)
        #expect(fixture.coordinator.activeSessionID == nil)
        guard case let .failed(message) = fixture.coordinator.phase else {
            Issue.record("Expected a failed phase after Rest fallback")
            return
        }
        #expect(message.contains("Rest Mode could not be confirmed"))
        #expect(message.contains(FakeFailure.restRejected.localizedDescription))
    }

    @Test("Disconnect tears down the controller delivery loop")
    func controllerLoopTeardown() async {
        let console = testConsole()
        let input = ControllerSnapshot(pressedButtons: [.cross])
        let controller = FakeMacControllerSource(snapshot: input)
        let session = FakeMacRemotePlaySession(snapshot: .streaming)
        let fixture = makeFixture(
            console: console,
            sessions: [session],
            controller: controller,
            controllerDeliveryInterval: .seconds(60)
        )
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await authorizeQueuedSurface(fixture.coordinator, sessionID: session.id)
        await fixture.coordinator.waitForConnectionAttempt()

        #expect(await eventually { session.state.sentInputs.count == 1 })
        #expect(session.state.sentInputs == [input])
        #expect(controller.keyboardControlsAreEnabled)

        await fixture.coordinator.disconnect()
        let sendsAfterDisconnect = session.state.sentInputs.count
        for _ in 0..<20 { await Task.yield() }

        #expect(sendsAfterDisconnect == 1)
        #expect(session.state.sentInputs.count == sendsAfterDisconnect)
        #expect(controller.keyboardControlsAreEnabled == false)
    }

    @Test("Inactive Mac delivery neutralizes, pauses, and resumes the exact session")
    func inactiveDeliveryAndActivationRecovery() async {
        let console = testConsole()
        let input = ControllerSnapshot(pressedButtons: [.cross])
        let controller = FakeMacControllerSource(snapshot: input)
        let session = FakeMacRemotePlaySession(snapshot: .streaming)
        let fixture = makeFixture(
            console: console,
            sessions: [session],
            controller: controller,
            controllerDeliveryInterval: .seconds(60)
        )
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await authorizeQueuedSurface(fixture.coordinator, sessionID: session.id)
        await fixture.coordinator.waitForConnectionAttempt()
        #expect(await eventually { session.state.sentInputs == [input] })

        await fixture.coordinator.applicationWillResignActive()
        #expect(session.state.sentInputs.last == .neutral)
        #expect(controller.keyboardControlsAreEnabled == false)
        let inactiveInputCount = session.state.sentInputs.count
        for _ in 0..<20 { await Task.yield() }
        #expect(session.state.sentInputs.count == inactiveInputCount)

        await fixture.coordinator.applicationDidBecomeActive()
        #expect(session.state.videoRecoveryCount == 1)
        #expect(controller.keyboardControlsAreEnabled)
        #expect(
            await eventually {
                session.state.sentInputs.count == inactiveInputCount + 1
                    && session.state.sentInputs.last == input
            }
        )

        await fixture.coordinator.applicationDidBecomeActive()
        #expect(session.state.videoRecoveryCount == 1)
        await fixture.coordinator.disconnect()
    }

    @Test("Keyboard input requires gameplay focus and is suspended by command alerts")
    func keyboardFocusPreferenceAndAlertGates() async {
        let console = testConsole()
        let controller = FakeMacControllerSource()
        let session = FakeMacRemotePlaySession(
            snapshot: .streaming,
            homeFailure: .commandRejected
        )
        let fixture = makeFixture(console: console, sessions: [session], controller: controller)
        await fixture.coordinator.prepare()
        fixture.coordinator.setKeyboardGameplayFocus(true)
        #expect(controller.keyboardControlsAreEnabled == false)
        #expect(fixture.coordinator.keyboardGameplayIsActive == false)
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await authorizeQueuedSurface(fixture.coordinator, sessionID: session.id)
        await fixture.coordinator.waitForConnectionAttempt()
        #expect(controller.keyboardControlsAreEnabled)
        #expect(fixture.coordinator.keyboardGameplayIsActive)
        fixture.coordinator.setKeyboardGameplayFocus(false)
        #expect(controller.keyboardControlsAreEnabled == false)
        #expect(fixture.coordinator.keyboardGameplayIsActive == false)
        fixture.coordinator.setKeyboardGameplayFocus(true)
        fixture.coordinator.keyboardControlsEnabled = false
        #expect(controller.keyboardControlsAreEnabled == false)
        #expect(fixture.coordinator.keyboardGameplayIsActive == false)
        fixture.coordinator.keyboardControlsEnabled = true
        #expect(controller.keyboardControlsAreEnabled)
        #expect(fixture.coordinator.keyboardGameplayIsActive)
        await fixture.coordinator.goHome()
        #expect(fixture.coordinator.actionErrorMessage != nil)
        #expect(controller.keyboardControlsAreEnabled == false)
        #expect(fixture.coordinator.keyboardGameplayIsActive == false)
        fixture.coordinator.dismissActionError()
        #expect(controller.keyboardControlsAreEnabled)
        #expect(fixture.coordinator.keyboardGameplayIsActive)
        await fixture.coordinator.disconnect()
        #expect(controller.keyboardControlsAreEnabled == false)
        #expect(fixture.coordinator.keyboardGameplayIsActive == false)
    }

    @Test("Session commands remain guarded by the active playback phase")
    func commandGuards() async {
        let console = testConsole()
        let session = FakeMacRemotePlaySession(snapshot: .streaming)
        let fixture = makeFixture(console: console, sessions: [session])
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))

        await fixture.coordinator.goHome()
        await fixture.coordinator.restAndDisconnect()
        #expect(session.state.goHomeCount == 0)
        #expect(session.state.restCount == 0)
        #expect(fixture.coordinator.hasActiveSession)

        await authorizeQueuedSurface(fixture.coordinator, sessionID: session.id)
        await fixture.coordinator.waitForConnectionAttempt()
        await fixture.coordinator.goHome()
        #expect(session.state.goHomeCount == 1)

        await fixture.coordinator.restAndDisconnect()
        #expect(session.state.restCount == 1)
        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.hasActiveSession == false)
    }

    @Test("A surface callback during Disconnect cannot start the session")
    func surfaceCallbackDuringDisconnectCannotStart() async {
        let console = testConsole()
        let stopGate = AsyncGate()
        let session = FakeMacRemotePlaySession(
            snapshot: .idle,
            stopGate: stopGate
        )
        let fixture = makeFixture(console: console, sessions: [session])
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))

        let disconnection = Task {
            await fixture.coordinator.disconnect()
        }
        await stopGate.waitUntilEntered()
        #expect(fixture.coordinator.phase == .disconnecting)

        #expect(
            await authorizeQueuedSurface(
                fixture.coordinator,
                sessionID: session.id
            ) == .stale
        )
        #expect(session.state.startCount == 0)

        await stopGate.open()
        await disconnection.value
        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.hasActiveSession == false)
    }

    @Test("A stale Wake success or failure cannot overwrite a later Connect preparation", arguments: [false, true])
    func staleWakeCompletionCannotOverwriteConnect(fails: Bool) async {
        let console = testConsole()
        let wakeGate = AsyncGate()
        let session = FakeMacRemotePlaySession(snapshot: .idle)
        let fixture = makeFixture(
            console: console,
            sessions: [session],
            wakeGate: wakeGate,
            wakeFailure: fails ? .commandRejected : nil
        )
        await fixture.coordinator.prepare()

        let wake = Task {
            await fixture.coordinator.wake(consoleID: console.id)
        }
        await wakeGate.waitUntilEntered()
        await fixture.coordinator.disconnect()

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        #expect(fixture.coordinator.activeSessionID == session.id)
        #expect(fixture.coordinator.phase == .prepared(console.id))

        await wakeGate.open()
        await wake.value
        #expect(fixture.coordinator.activeSessionID == session.id)
        #expect(fixture.coordinator.phase == .prepared(console.id))

        await fixture.coordinator.disconnect()
    }

    @Test("A failed first Stop retains retry authority and a second Stop completes cleanup")
    func failedStopRetainsRetryAuthority() async {
        let console = testConsole()
        let session = FakeMacRemotePlaySession(
            snapshot: .streaming,
            stopFailuresBeforeSuccess: 1
        )
        let fixture = makeFixture(console: console, sessions: [session])
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await authorizeQueuedSurface(fixture.coordinator, sessionID: session.id)
        await fixture.coordinator.waitForConnectionAttempt()

        await fixture.coordinator.disconnect()

        #expect(session.state.stopCount == 1)
        #expect(fixture.coordinator.hasActiveSession)
        #expect(fixture.coordinator.activeSessionID == session.id)
        guard case let .failed(message) = fixture.coordinator.phase else {
            Issue.record("Expected failed cleanup to retain a retryable session")
            return
        }
        #expect(message.contains("Disconnect again"))
        #expect(fixture.coordinator.canStartConsoleAction == false)
        fixture.coordinator.dismissError()
        #expect(fixture.coordinator.phase == .failed(message))
        await fixture.coordinator.wake(consoleID: console.id)
        #expect(await fixture.wakeRecorder.count == 0)
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id) == false)
        #expect(await fixture.factory.makeCount == 1)

        await fixture.coordinator.disconnect()

        #expect(session.state.stopCount == 2)
        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.hasActiveSession == false)
        #expect(fixture.coordinator.activeSessionID == nil)
    }

    @Test("A suspended stale snapshot cannot overwrite failed Disconnect cleanup")
    func staleSnapshotCannotOverwriteDisconnectFailure() async {
        let console = testConsole()
        let snapshotGate = AsyncGate()
        let session = FakeMacRemotePlaySession(
            snapshot: .streaming,
            stopFailuresBeforeSuccess: 1
        )
        let fixture = makeFixture(console: console, sessions: [session])
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))

        session.gateNextSnapshot(snapshotGate)
        let staleRefresh = Task {
            await fixture.coordinator.refreshActiveSession()
        }
        await snapshotGate.waitUntilEntered()

        await fixture.coordinator.disconnect()
        #expect(session.state.stopCount == 1)
        #expect(fixture.coordinator.hasActiveSession)
        #expect(fixture.coordinator.activeSessionID == session.id)
        guard case .failed = fixture.coordinator.phase else {
            Issue.record("Expected failed cleanup to retain the session")
            return
        }

        await snapshotGate.open()
        await staleRefresh.value

        #expect(session.state.stopCount == 1)
        #expect(fixture.coordinator.hasActiveSession)
        #expect(fixture.coordinator.activeSessionID == session.id)
        guard case .failed = fixture.coordinator.phase else {
            Issue.record("A stale streaming snapshot overwrote failed cleanup state")
            return
        }

        await fixture.coordinator.disconnect()
        #expect(session.state.stopCount == 2)
        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.hasActiveSession == false)
    }

    @Test("Disconnect retains ownership while failed-session cleanup is suspended")
    func disconnectOwnsFailedSessionCleanupOverlap() async {
        let console = testConsole()
        let stopGate = AsyncGate()
        let session = FakeMacRemotePlaySession(
            snapshot: .streaming,
            stopGate: stopGate,
            stopFailuresBeforeSuccess: 2
        )
        let fixture = makeFixture(console: console, sessions: [session])
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await authorizeQueuedSurface(fixture.coordinator, sessionID: session.id)
        await fixture.coordinator.waitForConnectionAttempt()

        session.setSnapshot(state: .failed, displayIsBlocked: false)
        let failedRefresh = Task {
            await fixture.coordinator.refreshActiveSession()
        }
        await stopGate.waitUntilEntered()

        let disconnect = Task {
            await fixture.coordinator.disconnect()
        }
        #expect(await eventually { session.state.stopCount == 2 })

        await stopGate.open()
        await failedRefresh.value
        await disconnect.value

        #expect(session.state.stopCount == 2)
        #expect(fixture.coordinator.hasActiveSession)
        #expect(fixture.coordinator.activeSessionID == session.id)
        guard case let .failed(message) = fixture.coordinator.phase else {
            Issue.record("Expected Disconnect to retain failed cleanup authority")
            return
        }
        #expect(message.contains("clean disconnect"))
        #expect(message.contains("Disconnect again"))

        await fixture.coordinator.disconnect()
        #expect(session.state.stopCount == 3)
        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.hasActiveSession == false)
    }

    @Test("A cancelled start cannot overwrite a replacement session after its await returns")
    func staleStartCompletionCannotReplaceCurrentSession() async {
        let console = testConsole()
        let firstStartGate = AsyncGate()
        let first = FakeMacRemotePlaySession(
            snapshot: .streaming,
            startGate: firstStartGate
        )
        let replacement = FakeMacRemotePlaySession(snapshot: .streaming)
        let fixture = makeFixture(console: console, sessions: [first, replacement])
        await fixture.coordinator.prepare()

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await authorizeQueuedSurface(fixture.coordinator, sessionID: first.id)
        await firstStartGate.waitUntilEntered()

        await fixture.coordinator.cancelConnection()
        #expect(first.state.stopCount == 1)
        #expect(fixture.coordinator.phase == .ready)

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await authorizeQueuedSurface(fixture.coordinator, sessionID: replacement.id)
        await fixture.coordinator.waitForConnectionAttempt()
        #expect(fixture.coordinator.activeSessionID == replacement.id)
        #expect(fixture.coordinator.phase == .streaming(console.id))

        await firstStartGate.open()
        #expect(await eventually { first.state.startReturnCount == 1 })

        #expect(fixture.coordinator.activeSessionID == replacement.id)
        #expect(fixture.coordinator.phase == .streaming(console.id))
        #expect(replacement.state.stopCount == 0)

        await fixture.coordinator.disconnect()
    }

    /// A console that is fully off quits the native session while connect is
    /// still awaiting its start, so the throw carries only "no session". The
    /// recorded quit reason is the useful half and must win.
    @Test("A failed Start reports the native quit reason, not the generic throw")
    func failedStartPrefersTheNativeQuitReason() async {
        let console = testConsole()
        let session = FakeMacRemotePlaySession(
            snapshot: MacRemoteSessionSnapshot(
                state: .disconnected,
                displayIsBlocked: false,
                lastQuitReason: .nativeFailure(code: 2)
            ),
            startFailure: .noSession
        )
        let fixture = makeFixture(console: console, sessions: [session])
        await fixture.coordinator.prepare()

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await authorizeQueuedSurface(fixture.coordinator, sessionID: session.id)
        await fixture.coordinator.waitForConnectionAttempt()

        guard case .failed(let message) = fixture.coordinator.phase else {
            Issue.record("Expected a failed connect to name its native quit reason")
            return
        }
        #expect(message.contains("code 2"))
        #expect(message.contains("lost power"))
        #expect(message.contains("No deterministic session remained.") == false)
        #expect(message.contains(console.hostAddress) == false)
    }

    /// Without a recorded reason there is nothing better to say than the throw.
    @Test("A failed Start with no native quit reason still reports the throw")
    func failedStartWithoutQuitReasonFallsBackToTheThrow() async {
        let console = testConsole()
        let session = FakeMacRemotePlaySession(
            snapshot: MacRemoteSessionSnapshot(
                state: .disconnected,
                displayIsBlocked: false,
                lastQuitReason: nil
            ),
            startFailure: .noSession
        )
        let fixture = makeFixture(console: console, sessions: [session])
        await fixture.coordinator.prepare()

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await authorizeQueuedSurface(fixture.coordinator, sessionID: session.id)
        await fixture.coordinator.waitForConnectionAttempt()

        guard case .failed(let message) = fixture.coordinator.phase else {
            Issue.record("Expected a failed connect to report the throw")
            return
        }
        #expect(message.contains("No deterministic session remained."))
    }

    @Test("A cancelled Start throwing another error cannot mutate its replacement")
    func cancelledStartWithNonCancellationErrorCannotMutateReplacement() async {
        let console = testConsole()
        let firstStartGate = AsyncGate()
        let first = FakeMacRemotePlaySession(
            snapshot: .streaming,
            startFailure: .noSession,
            startGate: firstStartGate
        )
        let replacement = FakeMacRemotePlaySession(snapshot: .streaming)
        let fixture = makeFixture(console: console, sessions: [first, replacement])
        await fixture.coordinator.prepare()

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await authorizeQueuedSurface(fixture.coordinator, sessionID: first.id)
        await firstStartGate.waitUntilEntered()

        await fixture.coordinator.cancelConnection()
        #expect(fixture.coordinator.phase == .ready)
        #expect(first.state.stopCount == 1)

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await authorizeQueuedSurface(fixture.coordinator, sessionID: replacement.id)
        await fixture.coordinator.waitForConnectionAttempt()
        #expect(fixture.coordinator.activeSessionID == replacement.id)
        #expect(fixture.coordinator.phase == .streaming(console.id))

        await firstStartGate.open()
        #expect(await eventually { first.state.startReturnCount == 1 })

        #expect(await eventually { first.state.stopCount == 2 })
        #expect(fixture.coordinator.activeSessionID == replacement.id)
        #expect(fixture.coordinator.phase == .streaming(console.id))
        #expect(replacement.state.stopCount == 0)

        await fixture.coordinator.disconnect()
    }

    @Test("Reconnect replaces the stopped session and rejects stale surface callbacks")
    func reconnectSessionReplacement() async {
        let console = testConsole()
        let first = FakeMacRemotePlaySession(snapshot: .streaming)
        let replacement = FakeMacRemotePlaySession(snapshot: .streaming)
        let fixture = makeFixture(console: console, sessions: [first, replacement])
        await fixture.coordinator.prepare()

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await authorizeQueuedSurface(fixture.coordinator, sessionID: first.id)
        await fixture.coordinator.waitForConnectionAttempt()
        await fixture.coordinator.disconnect()

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        #expect(fixture.coordinator.activeSessionID == replacement.id)

        #expect(
            await authorizeQueuedSurface(
                fixture.coordinator,
                sessionID: first.id
            ) == .stale
        )
        #expect(replacement.state.startCount == 0)

        await authorizeQueuedSurface(fixture.coordinator, sessionID: replacement.id)
        await fixture.coordinator.waitForConnectionAttempt()

        #expect(first.state.startCount == 1)
        #expect(first.state.stopCount == 1)
        #expect(replacement.state.startCount == 1)
        #expect(fixture.coordinator.activeSessionID == replacement.id)
        #expect(fixture.coordinator.phase == .streaming(console.id))
        #expect(await fixture.factory.makeCount == 2)

        await fixture.coordinator.disconnect()
    }

    @Test("A delayed denial cannot disconnect a replacement preparation")
    func staleDenialCannotDisconnectReplacement() async {
        let console = testConsole()
        let first = FakeMacRemotePlaySession(snapshot: .streaming)
        let replacement = FakeMacRemotePlaySession(snapshot: .streaming)
        let fixture = makeFixture(console: console, sessions: [first, replacement])
        await fixture.coordinator.prepare()

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        guard let staleAuthorization = fixture.coordinator.surfaceWasQueued(
            sessionID: first.id
        ) else {
            Issue.record("Expected the first preparation to issue an authorization")
            return
        }
        await fixture.coordinator.disconnect()

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        guard let replacementAuthorization = fixture.coordinator.surfaceWasQueued(
            sessionID: replacement.id
        ) else {
            Issue.record("Expected the replacement to issue an authorization")
            return
        }

        #expect(
            await fixture.coordinator.resolvePreparedSessionStart(
                staleAuthorization,
                isAuthorized: false
            ) == .stale
        )
        #expect(fixture.coordinator.activeSessionID == replacement.id)
        #expect(fixture.coordinator.phase == .prepared(console.id))
        #expect(replacement.state.stopCount == 0)

        #expect(
            await fixture.coordinator.resolvePreparedSessionStart(
                replacementAuthorization,
                isAuthorized: true
            ) == .started
        )
        await fixture.coordinator.waitForConnectionAttempt()
        #expect(replacement.state.startCount == 1)
        await fixture.coordinator.disconnect()
    }

    @Test("A consumed denial cannot interrupt an active stream")
    func consumedDenialCannotInterruptActiveStream() async {
        let console = testConsole()
        let session = FakeMacRemotePlaySession(snapshot: .streaming)
        let fixture = makeFixture(console: console, sessions: [session])
        await fixture.coordinator.prepare()

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        guard let authorization = fixture.coordinator.surfaceWasQueued(
            sessionID: session.id
        ) else {
            Issue.record("Expected the preparation to issue an authorization")
            return
        }
        #expect(
            await fixture.coordinator.resolvePreparedSessionStart(
                authorization,
                isAuthorized: true
            ) == .started
        )
        await fixture.coordinator.waitForConnectionAttempt()

        #expect(
            await fixture.coordinator.resolvePreparedSessionStart(
                authorization,
                isAuthorized: false
            ) == .stale
        )
        #expect(fixture.coordinator.phase == .streaming(console.id))
        #expect(session.state.stopCount == 0)
        await fixture.coordinator.disconnect()
    }

    @Test("Activation requires a fresh authorization for the queued surface")
    func queuedSurfaceRequiresFreshAuthorizationAfterActivation() async {
        let console = testConsole()
        let session = FakeMacRemotePlaySession(snapshot: .streaming)
        let fixture = makeFixture(console: console, sessions: [session])
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))

        guard let preInactiveAuthorization = fixture.coordinator.surfaceWasQueued(
            sessionID: session.id
        ) else {
            Issue.record("Expected the prepared session to issue an authorization")
            return
        }
        await fixture.coordinator.applicationWillResignActive()
        guard let activeAuthorization = await fixture.coordinator.applicationDidBecomeActive() else {
            Issue.record("Expected activation to issue a fresh authorization")
            return
        }

        #expect(
            await fixture.coordinator.resolvePreparedSessionStart(
                preInactiveAuthorization,
                isAuthorized: true
            ) == .stale
        )
        #expect(session.state.startCount == 0)
        #expect(fixture.coordinator.phase == .prepared(console.id))

        #expect(
            await fixture.coordinator.resolvePreparedSessionStart(
                activeAuthorization,
                isAuthorized: true
            ) == .started
        )
        await fixture.coordinator.waitForConnectionAttempt()
        #expect(session.state.startCount == 1)
        #expect(fixture.coordinator.phase == .streaming(console.id))
        await fixture.coordinator.disconnect()
    }

    @Test("A denied activation gate never starts the queued session")
    func deniedActivationGateNeverStartsQueuedSession() async {
        let console = testConsole()
        let session = FakeMacRemotePlaySession(snapshot: .streaming)
        let fixture = makeFixture(console: console, sessions: [session])
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))

        #expect(fixture.coordinator.surfaceWasQueued(sessionID: session.id) != nil)
        await fixture.coordinator.applicationWillResignActive()
        guard let activeAuthorization = await fixture.coordinator.applicationDidBecomeActive() else {
            Issue.record("Expected activation to issue a fresh authorization")
            return
        }

        #expect(
            await fixture.coordinator.resolvePreparedSessionStart(
                activeAuthorization,
                isAuthorized: false
            ) == .denied(consoleID: console.id)
        )
        #expect(session.state.startCount == 0)
        #expect(session.state.stopCount == 1)
        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.hasActiveSession == false)
    }
}

private extension MacRemotePlayCoordinatorTests {
    struct Fixture {
        let coordinator: MacRemotePlayCoordinator
        let factory: SessionFactory
        let controller: FakeMacControllerSource
        let wakeRecorder: WakeRecorder
    }

    @discardableResult
    func authorizeQueuedSurface(
        _ coordinator: MacRemotePlayCoordinator,
        sessionID: UUID
    ) async -> MacPreparedSessionStartResolution {
        coordinator.setKeyboardGameplayFocus(true)
        guard let authorization = coordinator.surfaceWasQueued(
            sessionID: sessionID
        ) else { return .stale }
        return await coordinator.resolvePreparedSessionStart(
            authorization,
            isAuthorized: true
        )
    }

    func makeFixture(
        console: MacConsoleSummary? = nil,
        sessions: [FakeMacRemotePlaySession] = [],
        factoryPlans: [SessionFactory.Plan]? = nil,
        controller: FakeMacControllerSource = FakeMacControllerSource(),
        monitorInterval: Duration = .seconds(60),
        controllerDeliveryInterval: Duration = .seconds(60),
        loader: StartupLoader? = nil,
        wakeGate: AsyncGate? = nil,
        wakeSettlingGate: AsyncGate? = nil,
        wakeFailure: FakeFailure? = nil
    ) -> Fixture {
        let startupLoader = loader ?? StartupLoader([
            MacStartupSnapshot(consoles: console.map { [$0] } ?? []),
        ])
        let factory = SessionFactory(
            plans: factoryPlans ?? sessions.map { .session($0, gate: nil) }
        )
        let wakeRecorder = WakeRecorder()
        let dependencies = MacRemotePlayDependencies(
            loadStartup: {
                try await startupLoader.load()
            },
            wake: { _ in
                await wakeRecorder.record()
                await wakeGate?.wait()
                if let wakeFailure { throw wakeFailure }
            },
            makeSession: { console, profile in
                try await factory.make(console: console, profile: profile)
            },
            controllerSource: controller,
            waitForWakeSettling: {
                await wakeSettlingGate?.wait()
            },
            monitorInterval: monitorInterval,
            controllerDeliveryInterval: controllerDeliveryInterval
        )
        let suiteName = "RemotePlayMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return Fixture(
            coordinator: MacRemotePlayCoordinator(
                dependencies: dependencies,
                defaults: defaults
            ),
            factory: factory,
            controller: controller,
            wakeRecorder: wakeRecorder
        )
    }

    func testConsole() -> MacConsoleSummary {
        MacConsoleSummary(
            id: UUID(),
            name: "Living Room PS5",
            hostAddress: "192.0.2.50"
        )
    }

    func eventually(
        attempts: Int = 200,
        _ condition: () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }
}

private enum FakeFailure: Error, LocalizedError, Sendable {
    case noSession
    case restRejected
    case commandRejected

    var errorDescription: String? {
        switch self {
        case .noSession:
            "No deterministic session remained."
        case .restRejected:
            "The console rejected Rest Mode."
        case .commandRejected:
            "The console rejected the command."
        }
    }
}

private actor WakeRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor StartupLoader {
    private var snapshots: [MacStartupSnapshot]
    private(set) var loadCount = 0

    init(_ snapshots: [MacStartupSnapshot]) {
        self.snapshots = snapshots
    }

    func load() throws -> MacStartupSnapshot {
        loadCount += 1
        guard snapshots.isEmpty == false else { throw FakeFailure.noSession }
        if snapshots.count == 1 { return snapshots[0] }
        return snapshots.removeFirst()
    }
}

private actor SessionFactory {
    enum Plan: Sendable {
        case session(FakeMacRemotePlaySession, gate: AsyncGate?)
        case failure(FakeFailure, gate: AsyncGate?)
    }

    private var plans: [Plan]
    private(set) var makeCount = 0
    private(set) var requestedConsoleIDs: [UUID] = []
    private(set) var requestedProfileIDs: [String] = []

    init(plans: [Plan]) {
        self.plans = plans
    }

    func make(
        console: MacConsoleSummary,
        profile: QualityProfile
    ) async throws -> any MacRemotePlaySession {
        makeCount += 1
        requestedConsoleIDs.append(console.id)
        requestedProfileIDs.append(profile.id)
        guard plans.isEmpty == false else { throw FakeFailure.noSession }
        let plan = plans.removeFirst()
        switch plan {
        case let .session(session, gate):
            await gate?.wait()
            return session
        case let .failure(error, gate):
            await gate?.wait()
            throw error
        }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var hasEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasEntered = true
        let entered = entryWaiters
        entryWaiters.removeAll()
        entered.forEach { $0.resume() }
        guard isOpen == false else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard hasEntered == false else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class FakeMacControllerSource: MacRemotePlayControllerSource, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSnapshot: ControllerSnapshot
    private var storedConnection: MacControllerConnection
    private var keyboardEnabled = false
    private var connectionContinuations: [
        UUID: AsyncStream<MacControllerConnection>.Continuation
    ] = [:]

    init(
        snapshot: ControllerSnapshot = .neutral,
        connection: MacControllerConnection = .disconnected
    ) {
        self.storedSnapshot = snapshot
        self.storedConnection = connection
    }

    var connection: MacControllerConnection {
        lock.withLock { storedConnection }
    }

    var keyboardControlsAreEnabled: Bool {
        lock.withLock { keyboardEnabled }
    }

    func snapshot() -> ControllerSnapshot {
        lock.withLock { storedSnapshot }
    }

    func connectionSnapshot() -> MacControllerConnection {
        lock.withLock { storedConnection }
    }

    func setKeyboardControlsEnabled(_ enabled: Bool) {
        lock.withLock {
            keyboardEnabled = enabled
        }
    }

    func connectionUpdates() -> AsyncStream<MacControllerConnection> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observerID = UUID()
            let initial = lock.withLock {
                connectionContinuations[observerID] = continuation
                return storedConnection
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeConnectionContinuation(observerID)
            }
            continuation.yield(initial)
        }
    }

    private func removeConnectionContinuation(_ observerID: UUID) {
        _ = lock.withLock {
            connectionContinuations.removeValue(forKey: observerID)
        }
    }

    func setConnection(_ connection: MacControllerConnection) {
        let continuations = lock.withLock {
            storedConnection = connection
            return Array(connectionContinuations.values)
        }
        continuations.forEach { $0.yield(connection) }
    }
}

private final class FakeMacRemotePlaySession: MacRemotePlaySession, @unchecked Sendable {
    struct State: Sendable {
        var snapshot: MacRemoteSessionSnapshot
        var audioSnapshot: PCMAudioPlaybackSnapshot?
        var startCount = 0
        var stopCount = 0
        var restCount = 0
        var goHomeCount = 0
        var startReturnCount = 0
        var videoRecoveryCount = 0
        var sentInputs: [ControllerSnapshot] = []
        var volumes: [Float] = []
        var muteValues: [Bool] = []
    }

    let id: UUID
    let videoSurface: MacRemotePlayVideoSurface?

    private let lock = NSLock()
    private var storedState: State
    private let startFailure: FakeFailure?
    private let restFailure: FakeFailure?
    private let homeFailure: FakeFailure?
    private let startGate: AsyncGate?
    private let stopGate: AsyncGate?
    private let stopFailuresBeforeSuccess: Int
    private var nextSnapshotGate: AsyncGate?

    init(
        id: UUID = UUID(),
        snapshot: MacRemoteSessionSnapshot,
        videoSurface: MacRemotePlayVideoSurface? = .testHarness,
        startFailure: FakeFailure? = nil,
        restFailure: FakeFailure? = nil,
        homeFailure: FakeFailure? = nil,
        audioSnapshot: PCMAudioPlaybackSnapshot? = nil,
        startGate: AsyncGate? = nil,
        stopGate: AsyncGate? = nil,
        stopFailuresBeforeSuccess: Int = 0
    ) {
        self.id = id
        self.videoSurface = videoSurface
        self.storedState = State(
            snapshot: snapshot,
            audioSnapshot: audioSnapshot
        )
        self.startFailure = startFailure
        self.restFailure = restFailure
        self.homeFailure = homeFailure
        self.startGate = startGate
        self.stopGate = stopGate
        self.stopFailuresBeforeSuccess = stopFailuresBeforeSuccess
    }

    convenience init(
        id: UUID = UUID(),
        snapshot state: StreamingConnectionState,
        displayIsBlocked: Bool = false,
        videoSurface: MacRemotePlayVideoSurface? = .testHarness,
        startFailure: FakeFailure? = nil,
        restFailure: FakeFailure? = nil,
        homeFailure: FakeFailure? = nil,
        audioSnapshot: PCMAudioPlaybackSnapshot? = nil,
        startGate: AsyncGate? = nil,
        stopGate: AsyncGate? = nil,
        stopFailuresBeforeSuccess: Int = 0
    ) {
        self.init(
            id: id,
            snapshot: MacRemoteSessionSnapshot(
                state: state,
                displayIsBlocked: displayIsBlocked
            ),
            videoSurface: videoSurface,
            startFailure: startFailure,
            restFailure: restFailure,
            homeFailure: homeFailure,
            audioSnapshot: audioSnapshot,
            startGate: startGate,
            stopGate: stopGate,
            stopFailuresBeforeSuccess: stopFailuresBeforeSuccess
        )
    }

    var state: State {
        lock.withLock { storedState }
    }

    func setSnapshot(
        state: StreamingConnectionState,
        displayIsBlocked: Bool,
        lastQuitReason: PlayStationNativeQuitReason? = nil
    ) {
        lock.withLock {
            storedState.snapshot = MacRemoteSessionSnapshot(
                state: state,
                displayIsBlocked: displayIsBlocked,
                lastQuitReason: lastQuitReason
            )
        }
    }

    func gateNextSnapshot(_ gate: AsyncGate) {
        lock.withLock {
            nextSnapshotGate = gate
        }
    }

    func start() async throws {
        lock.withLock { storedState.startCount += 1 }
        await startGate?.wait()
        lock.withLock { storedState.startReturnCount += 1 }
        if let startFailure { throw startFailure }
    }

    func stop() async {
        let attempt = lock.withLock {
            storedState.stopCount += 1
            return storedState.stopCount
        }
        await stopGate?.wait()
        lock.withLock {
            // Teardown never clears the reason in the real coordinator; only the
            // next connect does. A fake that dropped it here hid the fact that a
            // failed connect can still say why.
            storedState.snapshot = MacRemoteSessionSnapshot(
                state: attempt <= stopFailuresBeforeSuccess ? .failed : .disconnected,
                displayIsBlocked: false,
                lastQuitReason: storedState.snapshot.lastQuitReason
            )
        }
    }

    func send(_ input: ControllerSnapshot) async {
        lock.withLock { storedState.sentInputs.append(input) }
    }

    func goHome() async throws {
        lock.withLock { storedState.goHomeCount += 1 }
        if let homeFailure { throw homeFailure }
    }

    func restAndDisconnect() async throws {
        lock.withLock { storedState.restCount += 1 }
        if let restFailure { throw restFailure }
        lock.withLock {
            storedState.snapshot = MacRemoteSessionSnapshot(
                state: .disconnected,
                displayIsBlocked: false
            )
        }
    }

    func snapshot() async -> MacRemoteSessionSnapshot {
        let (snapshot, gate) = lock.withLock {
            let result = (storedState.snapshot, nextSnapshotGate)
            nextSnapshotGate = nil
            return result
        }
        await gate?.wait()
        return snapshot
    }

    func audioSnapshot() async -> PCMAudioPlaybackSnapshot? {
        lock.withLock { storedState.audioSnapshot }
    }

    func recoverVideoAfterInterruption() async {
        lock.withLock { storedState.videoRecoveryCount += 1 }
    }

    func setVolume(_ volume: Float) {
        lock.withLock { storedState.volumes.append(volume) }
    }

    func setMuted(_ isMuted: Bool) {
        lock.withLock { storedState.muteValues.append(isMuted) }
    }
}
