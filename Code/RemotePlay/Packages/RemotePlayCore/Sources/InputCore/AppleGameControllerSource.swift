import Foundation
import GameController

/// GameController objects are not `Sendable`, but the framework is safe to
/// touch from another thread; this carries one across an isolation boundary.
struct SendableGameController: @unchecked Sendable {
    let value: GCController
}

/// Non-input controller presence exposed to platform shells.
///
/// This is deliberately separate from `ControllerSnapshot`: connection UI
/// should react to Game Controller notifications even while no Remote Play
/// session is active, without starting an input-delivery polling loop.
public struct ControllerConnectionSnapshot: Equatable, Sendable {
    public let isConnected: Bool
    public let name: String?

    public init(isConnected: Bool, name: String?) {
        self.isConnected = isConnected
        self.name = name
    }
}

/// Thread-safe Game Controller adapter shared by the Apple platform shells.
/// It maps the printed DualSense controls to provider-neutral snapshots; the
/// streaming provider owns delivery cadence and native protocol translation.
public final class AppleGameControllerSource: @unchecked Sendable {
    private let lock = NSLock()
    private var state = ControllerSnapshot.neutral
    private var injectedSnapshot = ControllerSnapshot.neutral
    private var injectedButtons: Set<ControllerButton> = []
    private var connected = false
    private var connectedName: String?
    // Handler closures can already be queued when their controller disconnects.
    // Only the currently installed controller may mutate physical input state.
    private var controllerLease: UUID?
    private let notificationCenter: NotificationCenter
    private var connectionContinuations: [
        UUID: AsyncStream<ControllerConnectionSnapshot>.Continuation
    ] = [:]

    @MainActor private var notificationTokens: [NSObjectProtocol] = []
    @MainActor private weak var controller: GCController?
    @MainActor private var feedbackSink: AppleControllerFeedbackSink?
    @MainActor private let connectedControllers: @MainActor () -> [GCController]

    @MainActor
    public convenience init(notificationCenter: NotificationCenter = .default) {
        self.init(
            notificationCenter: notificationCenter,
            connectedControllers: { GCController.controllers() }
        )
    }

    @MainActor
    init(
        notificationCenter: NotificationCenter,
        connectedControllers: @escaping @MainActor () -> [GCController]
    ) {
        self.notificationCenter = notificationCenter
        self.connectedControllers = connectedControllers
        notificationTokens = [
            notificationCenter.addObserver(
                forName: .GCControllerDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let controller = notification.object as? GCController else { return }
                let controllerBox = SendableGameController(value: controller)
                Task { @MainActor [weak self, controllerBox] in
                    self?.install(controllerBox.value)
                }
            },
            notificationCenter.addObserver(
                forName: .GCControllerDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let controller = notification.object as? GCController else { return }
                let controllerBox = SendableGameController(value: controller)
                Task { @MainActor [weak self, controllerBox] in
                    self?.remove(controllerBox.value)
                }
            },
        ]

        if let controller = connectedControllers().first(where: {
            $0.extendedGamepad != nil
        }) {
            install(controller)
        }
    }

    deinit {
        let tokens = notificationTokens
        let notificationCenter = notificationCenter
        let continuations = lock.withLock {
            let values = Array(connectionContinuations.values)
            connectionContinuations.removeAll()
            return values
        }
        continuations.forEach { $0.finish() }
        Task { @MainActor in
            for token in tokens {
                notificationCenter.removeObserver(token)
            }
        }
    }

    public func snapshot() -> ControllerSnapshot {
        lock.withLock {
            var current = state.merging(injectedSnapshot)
            current.pressedButtons.formUnion(injectedButtons)
            return current
        }
    }

    public func connectionSnapshot() -> ControllerConnectionSnapshot {
        lock.withLock {
            ControllerConnectionSnapshot(
                isConnected: connected,
                name: connectedName
            )
        }
    }

    /// A bounded, notification-driven connection feed for Home, Settings, and
    /// player chrome. Each observer receives the current value immediately,
    /// then only the newest connect/disconnect state. Input samples continue
    /// to use the dedicated high-frequency snapshot path.
    public func connectionUpdates() -> AsyncStream<ControllerConnectionSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observerID = UUID()
            let initial = lock.withLock {
                connectionContinuations[observerID] = continuation
                return ControllerConnectionSnapshot(
                    isConnected: connected,
                    name: connectedName
                )
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeConnectionContinuation(observerID)
            }
            continuation.yield(initial)
        }
    }

    /// Routes console feedback to whichever controller this source currently
    /// owns, so rumble and the light bar follow controller swaps for free. The
    /// sink is optional; a shell that never attaches one simply has no output
    /// path, and input is unaffected either way.
    @MainActor
    public func attachFeedbackSink(_ sink: AppleControllerFeedbackSink?) {
        feedbackSink?.setController(nil)
        feedbackSink = sink
        sink?.setController(controller)
    }

    /// Used by the Vision control rail for short PS/Home/Options/Create pulses.
    /// Physical state and injected state are merged, so a pulse cannot erase a
    /// held stick, trigger, or face button.
    public func setInjected(_ button: ControllerButton, pressed: Bool) {
        lock.withLock {
            if pressed {
                injectedButtons.insert(button)
            } else {
                injectedButtons.remove(button)
            }
        }
    }

    /// Replaces the alternate controller surface atomically. Mobile uses this
    /// for a complete on-screen controller; physical input remains live and is
    /// merged at snapshot time.
    public func setInjectedSnapshot(_ snapshot: ControllerSnapshot) {
        lock.withLock { injectedSnapshot = snapshot }
    }

    @MainActor
    private func install(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        guard self.controller !== controller else { return }
        let previousController = self.controller
        let lease = UUID()
        self.controller = controller
        lock.withLock {
            controllerLease = lease
            connected = true
            connectedName = controller.vendorName ?? "Game Controller"
            state = .neutral
        }
        if let previousController {
            clearInputHandlers(previousController)
        }
        publishConnectionSnapshot()
        configureSystemGestureHandling(gamepad)

        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.set(.cross, pressed: pressed, lease: lease)
        }
        gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.set(.circle, pressed: pressed, lease: lease)
        }
        gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.set(.square, pressed: pressed, lease: lease)
        }
        gamepad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.set(.triangle, pressed: pressed, lease: lease)
        }
        gamepad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.set(.leftShoulder, pressed: pressed, lease: lease)
        }
        gamepad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.set(.rightShoulder, pressed: pressed, lease: lease)
        }
        gamepad.leftThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.set(.leftStick, pressed: pressed, lease: lease)
        }
        gamepad.rightThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.set(.rightStick, pressed: pressed, lease: lease)
        }

        gamepad.leftTrigger.valueChangedHandler = { [weak self] _, value, pressed in
            self?.update(lease: lease) { snapshot in
                snapshot.leftTrigger = value
                snapshot.set(.leftTrigger, pressed: pressed)
            }
        }
        gamepad.rightTrigger.valueChangedHandler = { [weak self] _, value, pressed in
            self?.update(lease: lease) { snapshot in
                snapshot.rightTrigger = value
                snapshot.set(.rightTrigger, pressed: pressed)
            }
        }
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.update(lease: lease) {
                $0.leftX = x
                $0.leftY = y
            }
        }
        gamepad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.update(lease: lease) {
                $0.rightX = x
                $0.rightY = y
            }
        }
        gamepad.dpad.valueChangedHandler = { [weak self] _, x, y in
            self?.update(lease: lease) { snapshot in
                snapshot.set(.dpadLeft, pressed: x < -0.5)
                snapshot.set(.dpadRight, pressed: x > 0.5)
                snapshot.set(.dpadDown, pressed: y < -0.5)
                snapshot.set(.dpadUp, pressed: y > 0.5)
            }
        }

        // Apple's names describe generic controller roles, not the printed
        // DualSense labels: buttonMenu is right-side Options and
        // buttonOptions is left-side Create.
        gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.set(.options, pressed: pressed, lease: lease)
        }
        gamepad.buttonOptions?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.set(.create, pressed: pressed, lease: lease)
        }
        gamepad.buttonHome?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.set(.playStation, pressed: pressed, lease: lease)
        }

        if let dualSense = gamepad as? GCDualSenseGamepad {
            dualSense.touchpadButton.pressedChangedHandler = { [weak self] _, _, pressed in
                self?.set(.touchpad, pressed: pressed, lease: lease)
            }
            // GameController reports the finger in -1...1 with (0, 0) both at
            // the pad center and when no finger is down. Treating every report
            // as an active touch left a phantom finger parked at the top-left
            // corner after each lift, which games read as endless swipe-up
            // gestures. Only a non-zero report is a touch, and the snapshot
            // carries pad-normalized 0...1 coordinates with y down.
            dualSense.touchpadPrimary.valueChangedHandler = { [weak self] _, x, y in
                let touching = abs(x) > 0.0001 || abs(y) > 0.0001
                self?.update(lease: lease) {
                    $0.touchpadActive = touching
                    $0.touchpadX = touching ? (x + 1) / 2 : 0
                    $0.touchpadY = touching ? (1 - y) / 2 : 0
                }
            }
        }

        controller.motion?.sensorsActive = true
        controller.playerIndex = .index1
        feedbackSink?.setController(controller)
    }

    @MainActor
    private func remove(_ controller: GCController) {
        guard self.controller === controller else { return }
        self.controller = nil
        feedbackSink?.setController(nil)
        lock.withLock {
            controllerLease = nil
            connected = false
            connectedName = nil
            state = .neutral
            injectedButtons.removeAll()
        }
        clearInputHandlers(controller)
        publishConnectionSnapshot()

        if let fallback = connectedControllers().first(where: {
            $0 !== controller && $0.extendedGamepad != nil
        }) {
            install(fallback)
        }
    }

    @MainActor
    private func clearInputHandlers(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        for button in [
            gamepad.buttonA, gamepad.buttonB, gamepad.buttonX, gamepad.buttonY,
            gamepad.leftShoulder, gamepad.rightShoulder,
            gamepad.leftThumbstickButton, gamepad.rightThumbstickButton,
            gamepad.buttonMenu, gamepad.buttonOptions, gamepad.buttonHome,
        ].compactMap({ $0 }) {
            button.pressedChangedHandler = nil
        }
        gamepad.leftTrigger.valueChangedHandler = nil
        gamepad.rightTrigger.valueChangedHandler = nil
        gamepad.leftThumbstick.valueChangedHandler = nil
        gamepad.rightThumbstick.valueChangedHandler = nil
        gamepad.dpad.valueChangedHandler = nil
        if let dualSense = gamepad as? GCDualSenseGamepad {
            dualSense.touchpadButton.pressedChangedHandler = nil
            dualSense.touchpadPrimary.valueChangedHandler = nil
        }
    }

    @MainActor
    /// `.disabled` keeps the press in the app. `.alwaysReceive` hands it to
    /// the system as well, which on macOS 26 and iOS 26 opens the Game
    /// Overlay every time the PS button is pressed mid-game.
    private func configureSystemGestureHandling(_ gamepad: GCExtendedGamepad) {
        gamepad.buttonMenu.preferredSystemGestureState = .disabled
        gamepad.buttonOptions?.preferredSystemGestureState = .disabled
        gamepad.buttonHome?.preferredSystemGestureState = .disabled
        (gamepad as? GCDualSenseGamepad)?.touchpadButton.preferredSystemGestureState = .disabled
    }

    private func set(_ button: ControllerButton, pressed: Bool, lease: UUID) {
        update(lease: lease) { $0.set(button, pressed: pressed) }
    }

    private func update(lease: UUID, _ mutation: (inout ControllerSnapshot) -> Void) {
        lock.withLock {
            guard controllerLease == lease else { return }
            mutation(&state)
        }
    }

    private func publishConnectionSnapshot() {
        let (snapshot, continuations) = lock.withLock {
            (
                ControllerConnectionSnapshot(
                    isConnected: connected,
                    name: connectedName
                ),
                Array(connectionContinuations.values)
            )
        }
        continuations.forEach { $0.yield(snapshot) }
    }

    private func removeConnectionContinuation(_ observerID: UUID) {
        _ = lock.withLock {
            connectionContinuations.removeValue(forKey: observerID)
        }
    }
}

private extension ControllerSnapshot {
    mutating func set(_ button: ControllerButton, pressed: Bool) {
        if pressed {
            pressedButtons.insert(button)
        } else {
            pressedButtons.remove(button)
        }
    }
}
