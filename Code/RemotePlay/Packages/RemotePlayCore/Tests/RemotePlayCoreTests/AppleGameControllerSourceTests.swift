import Foundation
import GameController
@testable import InputCore
import Testing

@Suite(.timeLimit(.minutes(1)))
struct AppleGameControllerSourceTests {
    @Test("Replaced controllers cannot mutate the current controller snapshot")
    @MainActor
    func replacedControllerCallbacksAreFenced() async throws {
        let center = NotificationCenter()
        let previous = GCController.withExtendedGamepad()
        let current = GCController.withExtendedGamepad()
        let source = AppleGameControllerSource(
            notificationCenter: center,
            connectedControllers: { [previous] }
        )
        let previousPad = try #require(previous.extendedGamepad)
        let staleButton = try #require(previousPad.buttonA.pressedChangedHandler)
        let staleStick = try #require(previousPad.leftThumbstick.valueChangedHandler)
        let staleTrigger = try #require(previousPad.rightTrigger.valueChangedHandler)
        staleButton(previousPad.buttonA, 1, true)
        #expect(source.snapshot().pressedButtons == [.cross])

        var updates = source.connectionUpdates().makeAsyncIterator()
        _ = await updates.next()
        center.post(name: .GCControllerDidConnect, object: current)
        let connection = await updates.next()
        #expect(connection?.isConnected == true)
        #expect(source.snapshot() == .neutral)
        #expect(previousPad.buttonA.pressedChangedHandler == nil)
        #expect(previousPad.leftThumbstick.valueChangedHandler == nil)
        #expect(previousPad.rightTrigger.valueChangedHandler == nil)

        let currentPad = try #require(current.extendedGamepad)
        currentPad.buttonA.pressedChangedHandler?(currentPad.buttonA, 1, true)
        currentPad.leftThumbstick.valueChangedHandler?(currentPad.leftThumbstick, 0.25, -0.5)
        currentPad.rightTrigger.valueChangedHandler?(currentPad.rightTrigger, 0.75, true)
        let expected = source.snapshot()
        #expect(expected.pressedButtons == [.cross, .rightTrigger])
        #expect(expected.leftX == 0.25)
        #expect(expected.leftY == -0.5)
        #expect(expected.rightTrigger == 0.75)

        // Saved closures model callbacks already queued before handler removal.
        staleButton(previousPad.buttonA, 0, false)
        staleStick(previousPad.leftThumbstick, -1, 1)
        staleTrigger(previousPad.rightTrigger, 0, false)
        #expect(source.snapshot() == expected)

        // A reconnect of the same object is a new ownership lease, not merely
        // a controller identity check that would reactivate old closures.
        center.post(name: .GCControllerDidConnect, object: previous)
        _ = await updates.next()
        previousPad.buttonB.pressedChangedHandler?(previousPad.buttonB, 1, true)
        staleButton(previousPad.buttonA, 1, true)
        staleStick(previousPad.leftThumbstick, -1, 1)
        #expect(source.snapshot() == ControllerSnapshot(pressedButtons: [.circle]))
    }

    @Test("Disconnect revokes input callbacks without erasing the touch surface")
    @MainActor
    func disconnectedControllerCallbacksAreFenced() async throws {
        let center = NotificationCenter()
        let controller = GCController.withExtendedGamepad()
        let source = AppleGameControllerSource(
            notificationCenter: center,
            connectedControllers: { [controller] }
        )
        let gamepad = try #require(controller.extendedGamepad)
        let staleButton = try #require(gamepad.buttonB.pressedChangedHandler)
        let staleDpad = try #require(gamepad.dpad.valueChangedHandler)
        let alternate = ControllerSnapshot(pressedButtons: [.square], leftX: 0.5)
        source.setInjectedSnapshot(alternate)
        staleButton(gamepad.buttonB, 1, true)

        var updates = source.connectionUpdates().makeAsyncIterator()
        _ = await updates.next()
        center.post(name: .GCControllerDidDisconnect, object: controller)
        let connection = await updates.next()
        #expect(connection?.isConnected == false)
        #expect(source.connectionSnapshot().isConnected == false)
        #expect(source.snapshot() == alternate)
        #expect(gamepad.buttonB.pressedChangedHandler == nil)
        #expect(gamepad.dpad.valueChangedHandler == nil)

        staleButton(gamepad.buttonB, 1, true)
        staleDpad(gamepad.dpad, 1, 1)
        #expect(source.snapshot() == alternate)
    }

    @Test("Disconnect selects a supported fallback with a fresh input lease")
    @MainActor
    func disconnectInstallsSupportedFallback() async throws {
        let center = NotificationCenter()
        let previous = GCController.withExtendedGamepad()
        let fallback = GCController.withExtendedGamepad()
        let unsupported = GCController.withMicroGamepad()
        let source = AppleGameControllerSource(
            notificationCenter: center,
            connectedControllers: { [previous, unsupported, fallback] }
        )
        let previousPad = try #require(previous.extendedGamepad)
        let staleButton = try #require(previousPad.buttonY.pressedChangedHandler)
        var updates = source.connectionUpdates().makeAsyncIterator()
        _ = await updates.next()
        center.post(name: .GCControllerDidDisconnect, object: previous)
        // The bounded feed may deliver disconnect first or coalesce straight
        // to fallback connection; either sequence must finish connected.
        while let connection = await updates.next() {
            if connection.isConnected { break }
        }
        #expect(source.connectionSnapshot().isConnected)
        #expect(source.snapshot() == .neutral)

        let fallbackPad = try #require(fallback.extendedGamepad)
        fallbackPad.buttonX.pressedChangedHandler?(fallbackPad.buttonX, 1, true)
        staleButton(previousPad.buttonY, 1, true)
        #expect(source.snapshot().pressedButtons == [.square])
    }

    @Test("Observer cleanup uses the same injected notification center")
    @MainActor
    func observersAreRemovedFromInjectedCenter() async throws {
        let center = ObserverTrackingNotificationCenter()
        var source: AppleGameControllerSource? = AppleGameControllerSource(
            notificationCenter: center,
            connectedControllers: { [] }
        )
        weak let releasedSource = source
        var removals = center.removals.makeAsyncIterator()
        source = nil
        #expect(releasedSource == nil)
        _ = try #require(await removals.next())
        _ = try #require(await removals.next())
    }
}

private final class ObserverTrackingNotificationCenter: NotificationCenter, @unchecked Sendable {
    let removals: AsyncStream<Void>
    private let removalContinuation: AsyncStream<Void>.Continuation

    override init() {
        let stream = AsyncStream<Void>.makeStream()
        removals = stream.stream
        removalContinuation = stream.continuation
        super.init()
    }

    override func removeObserver(_ observer: Any) {
        super.removeObserver(observer)
        removalContinuation.yield(())
    }

    deinit {
        removalContinuation.finish()
    }
}
