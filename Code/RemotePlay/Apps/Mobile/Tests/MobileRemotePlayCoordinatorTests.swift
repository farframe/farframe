import AppleMediaCore
import ExperienceDomain
import Foundation
import InputCore
import PlayStationRemotePlay
import Testing
@testable import RemotePlayMobile

@Suite("Mobile Remote Play coordinator", .serialized)
@MainActor
struct MobileRemotePlayCoordinatorTests {
    /// Private-range fixtures are assembled from octets so no private address
    /// literal appears in published test source.
    private static func privateAddress(_ octets: [Int]) -> String {
        octets.map(String.init).joined(separator: ".")
    }

    @Test("Connection endpoint classification never retains the source address")
    func connectionEndpointClassification() {
        #expect(MobileConnectionEndpointClass.classify(Self.privateAddress([10, 0, 0, 1])) == .privateIPv4)
        #expect(MobileConnectionEndpointClass.classify(Self.privateAddress([172, 31, 4, 8])) == .privateIPv4)
        #expect(MobileConnectionEndpointClass.classify(Self.privateAddress([192, 168, 1, 9])) == .privateIPv4)
        #expect(MobileConnectionEndpointClass.classify(Self.privateAddress([169, 254, 10, 1])) == .linkLocalIPv4)
        #expect(MobileConnectionEndpointClass.classify("127.0.0.1") == .loopback)
        #expect(MobileConnectionEndpointClass.classify("203.0.113.8") == .publicIPv4)
        #expect(MobileConnectionEndpointClass.classify("ps5.example.test") == .hostname)
        #expect(MobileConnectionEndpointClass.classify("") == .invalid)
    }

    @Test("A pre-stream native failure creates a shareable redacted connection report")
    func failedConnectionCreatesRedactedReport() async throws {
        let console = MobileConsoleSummary(
            id: UUID(),
            name: "Living Room PS5",
            hostAddress: Self.privateAddress([10, 0, 0, 2])
        )
        let first = FakeMobileRemotePlaySession(snapshot: .idle)
        let replacement = FakeMobileRemotePlaySession(snapshot: .idle)
        let network = MobileConnectionNetworkSnapshot(
            status: "satisfied",
            interface: "cellular",
            isExpensive: true,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true,
            supportsDNS: true
        )
        let fixture = makeFixture(
            console: console,
            sessions: [first, replacement],
            connectionNetworkSnapshot: network
        )
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await authorizeQueuedSurface(fixture.coordinator, sessionID: first.id)
        await fixture.coordinator.waitForConnectionAttempt()
        first.setSnapshot(
            state: .failed,
            displayIsBlocked: false,
            lastQuitReason: .nativeFailure(code: 2)
        )

        await fixture.coordinator.refreshActiveSession()

        let reportURL = try #require(fixture.coordinator.latestConnectionReportURL)
        let data = try Data(contentsOf: reportURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(MobileConnectionAttemptReport.self, from: data)
        let encodedText = try #require(String(data: data, encoding: .utf8))
        #expect(report.outcome == "failed")
        #expect(report.failureCategory == "native-session-failed")
        #expect(report.nativeQuitCode == 2)
        #expect(report.nativeQuitCategory == "session-request-unknown")
        #expect(report.endpointClass == .privateIPv4)
        #expect(report.network == network)
        #expect(report.events.map(\.stage) == [
            .requested, .sessionPrepared, .surfaceQueued,
            .nativeStartRequested, .nativeStartReturned, .failed,
        ])
        #expect(encodedText.contains(console.hostAddress) == false)
        #expect(encodedText.contains(console.name) == false)
        #expect(fixture.coordinator.connectionReportStatusMessage?.contains("ready") == true)

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        #expect(fixture.coordinator.latestConnectionReportURL == nil)
        await fixture.coordinator.disconnect()
    }

    @Test("Disconnect retains the last audio sample without presenting it as a new live session")
    func lastAudioDiagnosticsSurviveDisconnect() async {
        let console = testConsole()
        let first = FakeMobileRemotePlaySession(snapshot: .streaming)
        let second = FakeMobileRemotePlaySession(snapshot: .streaming)
        let sample = PCMAudioPlaybackSnapshot(
            state: .playing, activeGeneration: 1, negotiatedFormat: nil,
            volume: 0.8, isMuted: false, queue: AudioQueueSnapshot(),
            recoveries: 2, activationFailures: 0
        )
        first.setAudioSnapshot(sample)
        let fixture = makeFixture(console: console, sessions: [first, second])
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await authorizeQueuedSurface(fixture.coordinator, sessionID: first.id)
        await fixture.coordinator.waitForConnectionAttempt()
        await fixture.coordinator.refreshActiveSession()
        #expect(fixture.coordinator.audioPlaybackSnapshot == sample)
        await fixture.coordinator.disconnect()
        #expect(fixture.coordinator.audioPlaybackSnapshot == nil)
        #expect(fixture.coordinator.lastSessionAudioSnapshot == sample)
        #expect(fixture.coordinator.hasActiveSession == false)

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        #expect(fixture.coordinator.hasActiveSession)
        #expect(fixture.coordinator.audioPlaybackSnapshot == nil)
        #expect(fixture.coordinator.lastSessionAudioSnapshot == sample)
        await fixture.coordinator.disconnect()
        // An empty canceled preparation is not a newer measured session.
        #expect(fixture.coordinator.lastSessionAudioSnapshot == sample)
    }

    @Test("Startup sorts consoles and exposes recoverable registration state")
    func startupAndRecovery() async {
        let alpha = MobileConsoleSummary(
            id: UUID(),
            name: "Alpha",
            hostAddress: "192.0.2.10"
        )
        let zulu = MobileConsoleSummary(
            id: UUID(),
            name: "Zulu",
            hostAddress: "192.0.2.11"
        )
        let loader = StartupLoader([
            MobileStartupSnapshot(
                consoles: [zulu, alpha],
                recoveryMessage: "Finish pairing again."
            ),
            MobileStartupSnapshot(consoles: [zulu, alpha]),
        ])
        let fixture = makeFixture(loader: loader)

        await fixture.coordinator.prepare()

        #expect(fixture.coordinator.phase == .recoveryRequired("Finish pairing again."))
        #expect(fixture.coordinator.consoles == [alpha, zulu])
        #expect(fixture.coordinator.controllerConnection == fixture.controller.connection)
        #expect(fixture.coordinator.canStartConsoleAction == false)
        await fixture.coordinator.wake(consoleID: alpha.id)
        #expect(await fixture.wake.callCount == 0)
        #expect(await fixture.coordinator.prepareConnection(consoleID: alpha.id) == false)

        await fixture.coordinator.retryStartup()

        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.consoles == [alpha, zulu])
        #expect(await loader.loadCount == 2)
        #expect(fixture.coordinator.canStartConsoleAction)
    }

    @Test("Controller presence stays live on Home without a Remote Play session")
    func liveControllerPresenceWhileIdle() async {
        let controller = FakeMobileControllerSource()
        let fixture = makeFixture(controller: controller)

        await fixture.coordinator.prepare()
        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.controllerConnection == .disconnected)

        let connected = MobileControllerConnection(
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
        let session = FakeMobileRemotePlaySession(snapshot: .streaming)
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
        let session = FakeMobileRemotePlaySession(snapshot: .streaming)
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
        let session = FakeMobileRemotePlaySession(snapshot: .streaming)
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
        let staleSession = FakeMobileRemotePlaySession(snapshot: .idle)
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
        let replacement = FakeMobileRemotePlaySession(snapshot: .idle)
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
        let session = FakeMobileRemotePlaySession(
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
        #expect(message == MobileRemotePlayCoordinatorError.missingVideoSurface.localizedDescription)
    }

    @Test("The concrete video surface value is the only availability signal")
    func concreteVideoSurfaceIsAtomic() async {
        let console = testConsole()
        let missingSurface = FakeMobileRemotePlaySession(
            snapshot: .idle,
            videoSurface: nil
        )
        let concreteSurface = FakeMobileRemotePlaySession(
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
        fixture.coordinator.dismissError()

        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        #expect(fixture.coordinator.activeSessionID == concreteSurface.id)
        #expect(fixture.coordinator.phase == .prepared(console.id))

        await fixture.coordinator.disconnect()
    }

    @Test("Provider snapshots map to Mobile phase, restriction, and controller state")
    func snapshotMapping() async {
        let console = testConsole()
        let controller = FakeMobileControllerSource(
            connection: MobileControllerConnection(isConnected: true, name: "DualSense")
        )
        let session = FakeMobileRemotePlaySession(snapshot: .connecting)
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
                MobileControllerConnection(isConnected: true, name: "DualSense")
        )

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
        let session = FakeMobileRemotePlaySession(
            snapshot: MobileRemoteSessionSnapshot(state: .streaming, displayIsBlocked: true)
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
    }

    @Test("A failed Rest command still stops transport and reports the fallback")
    func restFailureStopsSession() async {
        let console = testConsole()
        let session = FakeMobileRemotePlaySession(
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
        let controller = FakeMobileControllerSource(snapshot: input)
        let session = FakeMobileRemotePlaySession(snapshot: .streaming)
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

        await fixture.coordinator.disconnect()
        let sendsAfterDisconnect = session.state.sentInputs.count
        for _ in 0..<20 { await Task.yield() }

        #expect(sendsAfterDisconnect == 1)
        #expect(session.state.sentInputs.count == sendsAfterDisconnect)
    }

    @Test("Touch input is injected only while on-screen controls are enabled")
    func touchControllerInjectionLifecycle() {
        let fixture = makeFixture()
        let touchInput = ControllerSnapshot(
            pressedButtons: [.cross, .rightTrigger],
            leftX: 0.75,
            rightTrigger: 1
        )

        fixture.coordinator.setTouchControllerSnapshot(touchInput)
        #expect(fixture.controller.injectedSnapshot == .neutral)

        fixture.coordinator.setTouchControlsEnabled(true)
        fixture.coordinator.setTouchControllerSnapshot(touchInput)
        #expect(fixture.coordinator.touchControlsAreEnabled)
        #expect(fixture.controller.injectedSnapshot == touchInput)

        fixture.coordinator.setTouchControlsEnabled(false)
        #expect(fixture.coordinator.touchControlsAreEnabled == false)
        #expect(fixture.controller.injectedSnapshot == .neutral)
    }

    @Test("Session commands remain guarded by the active playback phase")
    func commandGuards() async {
        let console = testConsole()
        let session = FakeMobileRemotePlaySession(snapshot: .streaming)
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
        let session = FakeMobileRemotePlaySession(
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

        await authorizeQueuedSurface(fixture.coordinator, sessionID: session.id)
        await Task.yield()
        #expect(session.state.startCount == 0)

        await stopGate.open()
        await disconnection.value
        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.hasActiveSession == false)
    }

    @Test("A stale Wake completion cannot overwrite a later Connect preparation")
    func staleWakeCompletionCannotOverwriteConnect() async {
        let console = testConsole()
        let wakeGate = AsyncGate()
        let session = FakeMobileRemotePlaySession(snapshot: .idle)
        let fixture = makeFixture(
            console: console,
            sessions: [session],
            wakeGate: wakeGate
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
        #expect(fixture.coordinator.wakeStatusMessage == nil)

        await fixture.coordinator.disconnect()
    }

    @Test("Failed Connect can immediately retry Connect or Wake without Dismiss", arguments: [false, true])
    func failedConnectCanRetry(wakeInstead: Bool) async {
        let console = testConsole()
        let first = FakeMobileRemotePlaySession(snapshot: .idle, startFailure: .noSession)
        let replacement = FakeMobileRemotePlaySession(snapshot: .idle)
        let fixture = makeFixture(console: console, sessions: [first, replacement])
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await authorizeQueuedSurface(fixture.coordinator, sessionID: first.id)
        await fixture.coordinator.waitForConnectionAttempt()
        #expect(fixture.coordinator.canStartConsoleAction)
        #expect(first.state.stopCount == 1)

        if wakeInstead {
            await fixture.coordinator.wake(consoleID: console.id)
            #expect(await fixture.wake.callCount == 1)
            #expect(fixture.coordinator.wakeStatusMessage?.contains("not confirmed") == true)
        } else {
            #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
            #expect(await fixture.factory.makeCount == 2)
            #expect(fixture.coordinator.activeSessionID == replacement.id)
        }
        await fixture.coordinator.disconnect()
    }

    @Test("Failed Wake publishes no success and permits Connect without Dismiss")
    func failedWakeCanConnect() async {
        let console = testConsole()
        let session = FakeMobileRemotePlaySession(snapshot: .idle)
        let fixture = makeFixture(console: console, sessions: [session], wakeFailure: .noSession)
        await fixture.coordinator.prepare()
        await fixture.coordinator.wake(consoleID: console.id)
        #expect(fixture.coordinator.canStartConsoleAction)
        #expect(fixture.coordinator.wakeRequestWasSent == false)
        #expect(fixture.coordinator.wakeStatusMessage == nil)
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await fixture.coordinator.disconnect()
    }

    @Test("Wake distinguishes send from settling and blocks duplicates through both")
    func wakeSettlingAndPersistentConfirmation() async {
        let console = testConsole()
        let sendGate = AsyncGate()
        let settlingGate = AsyncGate()
        let fixture = makeFixture(console: console, wakeGate: sendGate, wakeSettlingGate: settlingGate)
        await fixture.coordinator.prepare()
        let wake = Task { await fixture.coordinator.wake(consoleID: console.id) }
        await sendGate.waitUntilEntered()
        #expect(fixture.coordinator.wakeRequestWasSent == false)
        #expect(fixture.coordinator.wakeStatusMessage == nil)
        #expect(fixture.coordinator.canStartConsoleAction == false)
        await fixture.coordinator.wake(consoleID: console.id)
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id) == false)
        #expect(await fixture.wake.callCount == 1)

        await sendGate.open()
        await settlingGate.waitUntilEntered()
        #expect(fixture.coordinator.wakeRequestWasSent)
        #expect(fixture.coordinator.canStartConsoleAction == false)
        #expect(fixture.coordinator.wakeStatusMessage?.contains("not confirmed") == true)
        await fixture.coordinator.wake(consoleID: console.id)
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id) == false)
        #expect(await fixture.wake.callCount == 1)

        await settlingGate.open()
        await wake.value
        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.canStartConsoleAction)
        #expect(fixture.coordinator.wakeStatusMessage?.contains("not confirmed") == true)
        await fixture.coordinator.disconnect()
        #expect(fixture.coordinator.wakeStatusMessage == nil)
    }

    @Test("Cancelled Wake clears status and leaves a retryable state", arguments: [false, true])
    func cancelledWakeDoesNotClaimSuccess(duringSettling: Bool) async {
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
        #expect(fixture.coordinator.wakeRequestWasSent == false)
    }

    @Test("Background invalidates settling and its late completion cannot replace a session")
    func staleWakeSettlingCannotOverwriteReplacement() async {
        let console = testConsole()
        let gate = AsyncGate()
        let session = FakeMobileRemotePlaySession(snapshot: .idle)
        let fixture = makeFixture(console: console, sessions: [session], wakeSettlingGate: gate)
        await fixture.coordinator.prepare()
        let wake = Task { await fixture.coordinator.wake(consoleID: console.id) }
        await gate.waitUntilEntered()
        await fixture.coordinator.applicationDidEnterBackground()
        await fixture.coordinator.applicationDidBecomeActive()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await gate.open()
        await wake.value
        #expect(fixture.coordinator.activeSessionID == session.id)
        #expect(fixture.coordinator.phase == .prepared(console.id))
        #expect(fixture.coordinator.wakeStatusMessage == nil)
        await fixture.coordinator.disconnect()
    }

    @Test("Dismissing startup failure cannot bypass required recovery")
    func failedStartupBlocksConsoleActions() async {
        let fixture = makeFixture(loader: StartupLoader([]))
        await fixture.coordinator.prepare()
        fixture.coordinator.dismissError()
        #expect(fixture.coordinator.requiresStartupRecovery)
        #expect(fixture.coordinator.canStartConsoleAction == false)
        #expect(await fixture.coordinator.prepareConnection(consoleID: UUID()) == false)
        await fixture.coordinator.wake(consoleID: UUID())
        #expect(await fixture.wake.callCount == 0)
        #expect(await fixture.factory.makeCount == 0)
    }

    @Test("Typed native quit reasons remain visible after cleanup", arguments: [
        PlayStationNativeQuitReason.nativeFailure(code: 17), .remoteDisconnected,
    ])
    func nativeQuitReasonSurvivesCleanup(reason: PlayStationNativeQuitReason) async {
        let console = testConsole()
        let session = FakeMobileRemotePlaySession(snapshot: .idle)
        let fixture = makeFixture(console: console, sessions: [session])
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        session.setSnapshot(
            state: reason == .remoteDisconnected ? .disconnected : .failed,
            displayIsBlocked: false,
            lastQuitReason: reason
        )
        await fixture.coordinator.refreshActiveSession()
        guard case .failed(let message) = fixture.coordinator.phase else {
            Issue.record("Expected a safe typed quit reason after cleanup")
            return
        }
        #expect(message.contains(reason == .remoteDisconnected ? "PS5 ended" : "code 17"))
        #expect(message.contains(console.hostAddress) == false)
        #expect(fixture.coordinator.hasActiveSession == false)
        #expect(fixture.coordinator.canStartConsoleAction)
    }

    /// A console that is fully off quits the native session while connect is
    /// still awaiting its start, so the throw carries only "no session". The
    /// recorded quit reason is the useful half and must win.
    @Test("A failed Start reports the native quit reason, not the generic throw")
    func failedStartPrefersTheNativeQuitReason() async {
        let console = testConsole()
        let session = FakeMobileRemotePlaySession(
            snapshot: MobileRemoteSessionSnapshot(
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
        #expect(message.contains(console.hostAddress) == false)
    }

    @Test("An old session's typed failure cannot overwrite a replacement")
    func staleQuitReasonCannotOverwriteReplacement() async {
        let console = testConsole()
        let gate = AsyncGate()
        let first = FakeMobileRemotePlaySession(snapshot: .idle)
        let replacement = FakeMobileRemotePlaySession(snapshot: .idle)
        let fixture = makeFixture(console: console, sessions: [first, replacement])
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        first.setSnapshot(state: .failed, displayIsBlocked: false, lastQuitReason: .nativeFailure(code: 17))
        first.gateNextSnapshot(gate)
        let refresh = Task { await fixture.coordinator.refreshActiveSession() }
        await gate.waitUntilEntered()
        await fixture.coordinator.disconnect()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await gate.open()
        await refresh.value
        #expect(fixture.coordinator.activeSessionID == replacement.id)
        #expect(fixture.coordinator.phase == .prepared(console.id))
        #expect(replacement.state.stopCount == 0)
        await fixture.coordinator.disconnect()
    }

    @Test("Registration and its pending secure save block console actions")
    func registrationAndSecureSaveBlockConsoleActions() async throws {
        let console = testConsole()
        let gate = AsyncGate()
        let pairing = MobilePlayStationPairingDependencies(
            identityCapability: .unavailable,
            requestLocalNetworkAccess: { false },
            acquireAccountIdentity: { throw PlayStationAccountIdentityAcquisitionError.unavailable },
            pair: { _ in
                await gate.wait()
                throw PlayStationPairingError.secureSavePending
            },
            retryPendingSecureSave: { throw PlayStationPairingError.secureSavePending },
            removeConsole: { _ in }
        )
        let fixture = makeFixture(console: console, pairing: pairing)
        await fixture.coordinator.prepare()
        let request = try PlayStationPairingRequest(
            hostAddress: console.hostAddress,
            accountID: PlayStationAccountID(bytes: Data(repeating: 0, count: 8)),
            pin: PlayStationLinkDevicePIN("00000000")
        )
        let registration = Task { try? await fixture.coordinator.pairConsole(request) }
        await gate.waitUntilEntered()
        #expect(fixture.coordinator.registrationOperationIsActive)
        #expect(fixture.coordinator.canStartConsoleAction == false)
        await fixture.coordinator.wake(consoleID: console.id)
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id) == false)
        await gate.open()
        _ = await registration.value
        #expect(fixture.coordinator.pairingSecureSaveIsPending)
        #expect(fixture.coordinator.canStartConsoleAction == false)
        await fixture.coordinator.wake(consoleID: console.id)
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id) == false)
        #expect(await fixture.wake.callCount == 0)
        #expect(await fixture.factory.makeCount == 0)
    }

    @Test("A failed first Stop retains retry authority and a second Stop completes cleanup")
    func failedStopRetainsRetryAuthority() async {
        let console = testConsole()
        let session = FakeMobileRemotePlaySession(
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
        #expect(fixture.coordinator.canStartConsoleAction == false)
        await fixture.coordinator.wake(consoleID: console.id)
        #expect(await fixture.wake.callCount == 0)
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id) == false)

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
        let session = FakeMobileRemotePlaySession(
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
        let session = FakeMobileRemotePlaySession(
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
        let first = FakeMobileRemotePlaySession(
            snapshot: .streaming,
            startGate: firstStartGate
        )
        let replacement = FakeMobileRemotePlaySession(snapshot: .streaming)
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

    @Test("A cancelled Start throwing another error cannot mutate its replacement")
    func cancelledStartWithNonCancellationErrorCannotMutateReplacement() async {
        let console = testConsole()
        let firstStartGate = AsyncGate()
        let first = FakeMobileRemotePlaySession(
            snapshot: .streaming,
            startFailure: .noSession,
            startGate: firstStartGate
        )
        let replacement = FakeMobileRemotePlaySession(snapshot: .streaming)
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
        let first = FakeMobileRemotePlaySession(snapshot: .streaming)
        let replacement = FakeMobileRemotePlaySession(snapshot: .streaming)
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
        let first = FakeMobileRemotePlaySession(snapshot: .streaming)
        let replacement = FakeMobileRemotePlaySession(snapshot: .streaming)
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
        let session = FakeMobileRemotePlaySession(snapshot: .streaming)
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

    @Test("Inactive delivery sends neutral, pauses, and recovers exactly once")
    func inactiveDeliveryAndForegroundRecovery() async {
        let console = testConsole()
        let input = ControllerSnapshot(pressedButtons: [.cross])
        let controller = FakeMobileControllerSource(snapshot: input)
        let session = FakeMobileRemotePlaySession(snapshot: .streaming)
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
        let inactiveInputCount = session.state.sentInputs.count
        for _ in 0..<20 { await Task.yield() }
        #expect(session.state.sentInputs.count == inactiveInputCount)

        await fixture.coordinator.applicationDidBecomeActive()
        #expect(session.state.videoRecoveryCount == 1)
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

    @Test("Activation requires a fresh authorization for the queued surface")
    func queuedSurfaceRequiresFreshAuthorizationAfterActivation() async {
        let console = testConsole()
        let session = FakeMobileRemotePlaySession(snapshot: .streaming)
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
        let session = FakeMobileRemotePlaySession(snapshot: .streaming)
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

    @Test("Entering the background confirms transport teardown")
    func backgroundDisconnectsTransport() async {
        let console = testConsole()
        let session = FakeMobileRemotePlaySession(snapshot: .streaming)
        let fixture = makeFixture(console: console, sessions: [session])
        await fixture.coordinator.prepare()
        #expect(await fixture.coordinator.prepareConnection(consoleID: console.id))
        await authorizeQueuedSurface(fixture.coordinator, sessionID: session.id)
        await fixture.coordinator.waitForConnectionAttempt()

        await fixture.coordinator.applicationDidEnterBackground()

        #expect(session.state.stopCount == 1)
        #expect(fixture.coordinator.phase == .ready)
        #expect(fixture.coordinator.hasActiveSession == false)
        await fixture.coordinator.applicationDidBecomeActive()
        #expect(session.state.videoRecoveryCount == 0)
    }
}

private extension MobileRemotePlayCoordinatorTests {
    struct Fixture {
        let coordinator: MobileRemotePlayCoordinator
        let factory: SessionFactory
        let controller: FakeMobileControllerSource
        let wake: WakeRecorder
    }

    @discardableResult
    func authorizeQueuedSurface(
        _ coordinator: MobileRemotePlayCoordinator,
        sessionID: UUID
    ) async -> MobilePreparedSessionStartResolution {
        guard let authorization = coordinator.surfaceWasQueued(
            sessionID: sessionID
        ) else { return .stale }
        return await coordinator.resolvePreparedSessionStart(
            authorization,
            isAuthorized: true
        )
    }

    func makeFixture(
        console: MobileConsoleSummary? = nil,
        sessions: [FakeMobileRemotePlaySession] = [],
        factoryPlans: [SessionFactory.Plan]? = nil,
        controller: FakeMobileControllerSource = FakeMobileControllerSource(),
        monitorInterval: Duration = .seconds(60),
        controllerDeliveryInterval: Duration = .seconds(60),
        loader: StartupLoader? = nil,
        wakeGate: AsyncGate? = nil,
        wakeFailure: FakeFailure? = nil,
        wakeSettlingGate: AsyncGate? = nil,
        pairing: MobilePlayStationPairingDependencies = .unavailable,
        connectionNetworkSnapshot: MobileConnectionNetworkSnapshot = .unavailable
    ) -> Fixture {
        let startupLoader = loader ?? StartupLoader([
            MobileStartupSnapshot(consoles: console.map { [$0] } ?? []),
        ])
        let factory = SessionFactory(
            plans: factoryPlans ?? sessions.map { .session($0, gate: nil) }
        )
        let wake = WakeRecorder()
        let dependencies = MobileRemotePlayDependencies(
            loadStartup: {
                try await startupLoader.load()
            },
            wake: { _ in
                try await wake.send(gate: wakeGate, failure: wakeFailure)
            },
            makeSession: { console, profile in
                try await factory.make(console: console, profile: profile)
            },
            controllerSource: controller,
            pairing: pairing,
            monitorInterval: monitorInterval,
            controllerDeliveryInterval: controllerDeliveryInterval,
            waitForWakeSettling: {
                await wakeSettlingGate?.wait()
                try Task.checkCancellation()
            },
            connectionNetworkSnapshot: { connectionNetworkSnapshot }
        )
        let suiteName = "RemotePlayMobileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return Fixture(
            coordinator: MobileRemotePlayCoordinator(
                dependencies: dependencies,
                defaults: defaults
            ),
            factory: factory,
            controller: controller,
            wake: wake
        )
    }

    func testConsole() -> MobileConsoleSummary {
        MobileConsoleSummary(
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

    var errorDescription: String? {
        switch self {
        case .noSession:
            "No deterministic session remained."
        case .restRejected:
            "The console rejected Rest Mode."
        }
    }
}

private actor StartupLoader {
    private var snapshots: [MobileStartupSnapshot]
    private(set) var loadCount = 0

    init(_ snapshots: [MobileStartupSnapshot]) {
        self.snapshots = snapshots
    }

    func load() throws -> MobileStartupSnapshot {
        loadCount += 1
        guard snapshots.isEmpty == false else { throw FakeFailure.noSession }
        if snapshots.count == 1 { return snapshots[0] }
        return snapshots.removeFirst()
    }
}

private actor WakeRecorder {
    private(set) var callCount = 0

    func send(gate: AsyncGate?, failure: FakeFailure?) async throws {
        callCount += 1
        await gate?.wait()
        if let failure { throw failure }
    }
}

private actor SessionFactory {
    enum Plan: Sendable {
        case session(FakeMobileRemotePlaySession, gate: AsyncGate?)
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
        console: MobileConsoleSummary,
        profile: QualityProfile
    ) async throws -> any MobileRemotePlaySession {
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

private final class FakeMobileControllerSource: MobileRemotePlayControllerSource, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSnapshot: ControllerSnapshot
    private var storedInjectedSnapshot = ControllerSnapshot.neutral
    private var storedConnection: MobileControllerConnection
    private var connectionContinuations: [
        UUID: AsyncStream<MobileControllerConnection>.Continuation
    ] = [:]

    init(
        snapshot: ControllerSnapshot = .neutral,
        connection: MobileControllerConnection = .disconnected
    ) {
        self.storedSnapshot = snapshot
        self.storedConnection = connection
    }

    var connection: MobileControllerConnection {
        lock.withLock { storedConnection }
    }

    var injectedSnapshot: ControllerSnapshot {
        lock.withLock { storedInjectedSnapshot }
    }

    func snapshot() -> ControllerSnapshot {
        lock.withLock { storedSnapshot }
    }

    func setInjectedSnapshot(_ snapshot: ControllerSnapshot) {
        lock.withLock { storedInjectedSnapshot = snapshot }
    }

    func connectionSnapshot() -> MobileControllerConnection {
        lock.withLock { storedConnection }
    }

    func connectionUpdates() -> AsyncStream<MobileControllerConnection> {
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

    func setConnection(_ connection: MobileControllerConnection) {
        let continuations = lock.withLock {
            storedConnection = connection
            return Array(connectionContinuations.values)
        }
        continuations.forEach { $0.yield(connection) }
    }
}

private final class FakeMobileRemotePlaySession: MobileRemotePlaySession, @unchecked Sendable {
    struct State: Sendable {
        var snapshot: MobileRemoteSessionSnapshot
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
    let videoSurface: MobileRemotePlayVideoSurface?

    private let lock = NSLock()
    private var storedState: State
    private let startFailure: FakeFailure?
    private let restFailure: FakeFailure?
    private let startGate: AsyncGate?
    private let stopGate: AsyncGate?
    private let stopFailuresBeforeSuccess: Int
    private var nextSnapshotGate: AsyncGate?

    init(
        id: UUID = UUID(),
        snapshot: MobileRemoteSessionSnapshot,
        videoSurface: MobileRemotePlayVideoSurface? = .testHarness,
        startFailure: FakeFailure? = nil,
        restFailure: FakeFailure? = nil,
        startGate: AsyncGate? = nil,
        stopGate: AsyncGate? = nil,
        stopFailuresBeforeSuccess: Int = 0
    ) {
        self.id = id
        self.videoSurface = videoSurface
        self.storedState = State(snapshot: snapshot)
        self.startFailure = startFailure
        self.restFailure = restFailure
        self.startGate = startGate
        self.stopGate = stopGate
        self.stopFailuresBeforeSuccess = stopFailuresBeforeSuccess
    }

    convenience init(
        id: UUID = UUID(),
        snapshot state: StreamingConnectionState,
        displayIsBlocked: Bool = false,
        videoSurface: MobileRemotePlayVideoSurface? = .testHarness,
        startFailure: FakeFailure? = nil,
        restFailure: FakeFailure? = nil,
        startGate: AsyncGate? = nil,
        stopGate: AsyncGate? = nil,
        stopFailuresBeforeSuccess: Int = 0
    ) {
        self.init(
            id: id,
            snapshot: MobileRemoteSessionSnapshot(
                state: state,
                displayIsBlocked: displayIsBlocked
            ),
            videoSurface: videoSurface,
            startFailure: startFailure,
            restFailure: restFailure,
            startGate: startGate,
            stopGate: stopGate,
            stopFailuresBeforeSuccess: stopFailuresBeforeSuccess
        )
    }

    var state: State {
        lock.withLock { storedState }
    }

    func setAudioSnapshot(_ snapshot: PCMAudioPlaybackSnapshot) {
        lock.withLock { storedState.audioSnapshot = snapshot }
    }

    func audioSnapshot() async -> PCMAudioPlaybackSnapshot? {
        lock.withLock { storedState.audioSnapshot }
    }

    func setSnapshot(
        state: StreamingConnectionState,
        displayIsBlocked: Bool,
        lastQuitReason: PlayStationNativeQuitReason? = nil
    ) {
        lock.withLock {
            storedState.snapshot = MobileRemoteSessionSnapshot(
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
            storedState.snapshot = MobileRemoteSessionSnapshot(
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
    }

    func restAndDisconnect() async throws {
        lock.withLock { storedState.restCount += 1 }
        if let restFailure { throw restFailure }
        lock.withLock {
            storedState.snapshot = MobileRemoteSessionSnapshot(
                state: .disconnected,
                displayIsBlocked: false
            )
        }
    }

    func snapshot() async -> MobileRemoteSessionSnapshot {
        let (snapshot, gate) = lock.withLock {
            let result = (storedState.snapshot, nextSnapshotGate)
            nextSnapshotGate = nil
            return result
        }
        await gate?.wait()
        return snapshot
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
