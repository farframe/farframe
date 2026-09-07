import Foundation
import GameController

// GCKeyboard is a Mac and iOS/iPadOS API. An iPad in a keyboard case is the
// most common hardware-keyboard configuration this app will meet, so the
// adapter is shared rather than duplicated. visionOS is excluded: it has no
// attached keyboard posture this maps onto.
#if os(macOS) || os(iOS)
private struct SendableKeyboard: @unchecked Sendable {
    let value: GCKeyboard
}

/// A held-state hardware-keyboard adapter for controller-free Remote Play. It
/// is explicitly enabled only while the gameplay surface is active; disabling
/// it immediately emits neutral state so focus changes cannot leave a PS5 input
/// held. Custom binding UI can replace `makeSnapshot` without changing the
/// provider-facing controller contract.
public final class AppleKeyboardControllerSource: @unchecked Sendable {
    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private static let shortcutModifiers: Set<GCKeyCode> = [
        .leftGUI, .rightGUI, .leftControl, .rightControl, .leftAlt, .rightAlt,
    ]
    private var pressedKeys: Set<GCKeyCode> = []
    private var state = ControllerSnapshot.neutral
    private var enabled = false
    private var keyboardLease: UUID?

    @MainActor private var notificationTokens: [NSObjectProtocol] = []
    @MainActor private weak var keyboard: GCKeyboard?

    @MainActor
    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        notificationTokens = [
            notificationCenter.addObserver(
                forName: .GCKeyboardDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let keyboard = notification.object as? GCKeyboard else { return }
                let keyboardBox = SendableKeyboard(value: keyboard)
                Task { @MainActor [weak self, keyboardBox] in
                    self?.install(keyboardBox.value)
                }
            },
            notificationCenter.addObserver(
                forName: .GCKeyboardDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let keyboard = notification.object as? GCKeyboard else { return }
                let keyboardBox = SendableKeyboard(value: keyboard)
                Task { @MainActor [weak self, keyboardBox] in
                    self?.remove(keyboardBox.value)
                }
            },
        ]

        if let keyboard = GCKeyboard.coalesced {
            install(keyboard)
        }
    }

    deinit {
        let tokens = notificationTokens
        let notificationCenter = notificationCenter
        Task { @MainActor in
            for token in tokens {
                notificationCenter.removeObserver(token)
            }
        }
    }

    public func snapshot() -> ControllerSnapshot {
        lock.withLock { enabled ? state : .neutral }
    }

    public func setEnabled(_ enabled: Bool) {
        lock.withLock {
            self.enabled = enabled
            if enabled == false {
                pressedKeys.removeAll()
                state = .neutral
            }
        }
    }

    @MainActor
    private func install(_ keyboard: GCKeyboard) {
        guard self.keyboard !== keyboard else { return }
        let previousKeyboard = self.keyboard
        let lease = UUID()
        self.keyboard = keyboard
        lock.withLock {
            keyboardLease = lease
            pressedKeys.removeAll()
            state = .neutral
        }
        previousKeyboard?.keyboardInput?.keyChangedHandler = nil
        keyboard.keyboardInput?.keyChangedHandler = { [weak self] input, _, keyCode, pressed in
            // Modifiers may already be held when gameplay gains focus. Read
            // the live keyboard profile instead of relying on earlier events
            // which the disabled adapter deliberately ignored.
            let shortcutIsActive = Self.shortcutModifiers.contains {
                input.button(forKeyCode: $0)?.isPressed == true
            }
            self?.receive(
                keyCode, pressed: pressed,
                shortcutIsActive: shortcutIsActive, lease: lease
            )
        }
    }

    @MainActor
    private func remove(_ keyboard: GCKeyboard) {
        guard self.keyboard === keyboard else { return }
        self.keyboard = nil
        lock.withLock {
            keyboardLease = nil
            pressedKeys.removeAll()
            state = .neutral
        }
        keyboard.keyboardInput?.keyChangedHandler = nil
    }

    package func receive(
        _ keyCode: GCKeyCode,
        pressed: Bool,
        shortcutIsActive: Bool,
        lease: UUID? = nil
    ) {
        lock.withLock {
            guard enabled else { return }
            if let lease, keyboardLease != lease { return }
            guard shortcutIsActive == false else {
                // Releasing Command/Control/Option must not resurrect a key
                // that belonged to a shortcut. Require a fresh gameplay press.
                pressedKeys.removeAll()
                state = .neutral
                return
            }
            if pressed {
                pressedKeys.insert(keyCode)
            } else {
                pressedKeys.remove(keyCode)
            }
            state = Self.makeSnapshot(pressedKeys: pressedKeys)
        }
    }

    package static func makeSnapshot(
        pressedKeys: Set<GCKeyCode>
    ) -> ControllerSnapshot {
        // System and assistive shortcuts must never also press PS5 controls.
        // Shift remains available for future gameplay bindings.
        guard pressedKeys.isDisjoint(with: shortcutModifiers) else {
            return .neutral
        }

        func axis(negative: GCKeyCode, positive: GCKeyCode) -> Float {
            let negativeValue: Float = pressedKeys.contains(negative) ? -1 : 0
            let positiveValue: Float = pressedKeys.contains(positive) ? 1 : 0
            return negativeValue + positiveValue
        }

        var buttons: Set<ControllerButton> = []
        let digitalBindings: [(GCKeyCode, ControllerButton)] = [
            (.keyJ, .cross),
            (.keyK, .circle),
            (.keyU, .square),
            (.keyI, .triangle),
            (.keyQ, .leftShoulder),
            (.keyE, .rightShoulder),
            (.keyZ, .leftTrigger),
            (.keyC, .rightTrigger),
            (.keyF, .leftStick),
            (.keyH, .rightStick),
            (.F1, .dpadLeft),
            (.F2, .dpadDown),
            (.F3, .dpadUp),
            (.F4, .dpadRight),
            (.returnOrEnter, .options),
            (.keyV, .create),
            (.keyP, .playStation),
            (.keyT, .touchpad),
        ]
        for (key, button) in digitalBindings where pressedKeys.contains(key) {
            buttons.insert(button)
        }

        return ControllerSnapshot(
            pressedButtons: buttons,
            leftX: axis(negative: .keyA, positive: .keyD),
            leftY: axis(negative: .keyS, positive: .keyW),
            rightX: axis(negative: .leftArrow, positive: .rightArrow),
            rightY: axis(negative: .downArrow, positive: .upArrow),
            leftTrigger: pressedKeys.contains(.keyZ) ? 1 : 0,
            rightTrigger: pressedKeys.contains(.keyC) ? 1 : 0
        )
    }
}
#endif
