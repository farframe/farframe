#if os(macOS) || os(iOS)
import Foundation
import GameController
import InputCore
import Testing

@Test("Hardware keyboard bindings produce one atomic controller snapshot")
func keyboardBindingsProduceControllerSnapshot() {
    let snapshot = AppleKeyboardControllerSource.makeSnapshot(
        pressedKeys: [
            .keyW, .keyD, .leftArrow, .upArrow,
            .keyJ, .keyI, .keyQ, .keyC,
            .keyF, .keyH, .F3,
            .returnOrEnter, .keyV, .keyP, .keyT,
        ]
    )

    #expect(snapshot.leftX == 1)
    #expect(snapshot.leftY == 1)
    #expect(snapshot.rightX == -1)
    #expect(snapshot.rightY == 1)
    #expect(snapshot.leftTrigger == 0)
    #expect(snapshot.rightTrigger == 1)
    #expect(
        snapshot.pressedButtons == [
            .cross, .triangle, .leftShoulder, .rightTrigger,
            .leftStick, .rightStick, .dpadUp,
            .options, .create, .playStation, .touchpad,
        ]
    )
}

@Test("Opposing keyboard directions resolve to neutral axes")
func opposingKeyboardDirectionsResolveToNeutral() {
    let snapshot = AppleKeyboardControllerSource.makeSnapshot(
        pressedKeys: [
            .keyW, .keyS, .keyA, .keyD,
            .leftArrow, .rightArrow, .upArrow, .downArrow,
        ]
    )

    #expect(snapshot.leftX == 0)
    #expect(snapshot.leftY == 0)
    #expect(snapshot.rightX == 0)
    #expect(snapshot.rightY == 0)
    #expect(snapshot.pressedButtons.isEmpty)
}

@Test("System shortcut modifiers suppress gameplay input")
func keyboardSystemShortcutsDoNotPressPS5Controls() {
    for modifier in [
        GCKeyCode.leftGUI, .rightGUI, .leftControl, .rightControl, .leftAlt, .rightAlt,
    ] {
        let snapshot = AppleKeyboardControllerSource.makeSnapshot(
            pressedKeys: [.keyW, .keyJ, .keyC, modifier]
        )
        #expect(snapshot == .neutral)
    }
}

@Test("A modifier held before focus cannot leak or resurrect gameplay keys")
@MainActor
func keyboardPreexistingModifierAndFocusReleaseAreSafe() {
    let source = AppleKeyboardControllerSource(notificationCenter: NotificationCenter())
    source.receive(.leftGUI, pressed: true, shortcutIsActive: true)
    source.setEnabled(true)
    source.receive(.keyW, pressed: true, shortcutIsActive: false, lease: UUID())
    #expect(source.snapshot() == .neutral)
    source.receive(.keyJ, pressed: true, shortcutIsActive: true)
    #expect(source.snapshot() == .neutral)
    source.receive(.leftGUI, pressed: false, shortcutIsActive: false)
    #expect(source.snapshot() == .neutral)
    source.receive(.keyJ, pressed: false, shortcutIsActive: false)
    source.receive(.keyJ, pressed: true, shortcutIsActive: false)
    #expect(source.snapshot().pressedButtons == [.cross])
    source.setEnabled(false)
    #expect(source.snapshot() == .neutral)
    source.setEnabled(true)
    #expect(source.snapshot() == .neutral)
}
#endif
