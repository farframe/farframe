import Foundation
import InputCore
import Testing

@Test
func neutralControllerSnapshotHasNoInput() {
    #expect(ControllerSnapshot.neutral.hasInput == false)
    #expect(ControllerButton.allCases.count == 18)
}

@Test
func controllerInputThresholdMatchesKnownGoodBoundary() {
    #expect(ControllerSnapshot(leftX: 0.1).hasInput == false)
    #expect(ControllerSnapshot(leftX: -0.1).hasInput == false)
    #expect(ControllerSnapshot(leftX: 0.100_001).hasInput)
    #expect(ControllerSnapshot(rightY: -0.100_001).hasInput)
    #expect(ControllerSnapshot(leftTrigger: 0.1).hasInput == false)
    #expect(ControllerSnapshot(rightTrigger: 0.100_001).hasInput)
}

@Test(arguments: ControllerButton.allCases)
func everyControllerButtonCountsAsInput(_ button: ControllerButton) {
    #expect(ControllerSnapshot(pressedButtons: [button]).hasInput)
}

@Test("Alternate controller input merges without erasing hardware state")
func alternateControllerInputMergesWithHardware() {
    let hardware = ControllerSnapshot(
        pressedButtons: [.leftShoulder],
        leftX: 0.75,
        rightY: -0.5,
        leftTrigger: 0.4,
        touchpadX: -0.25,
        touchpadY: 0.5,
        touchpadActive: true
    )
    let touch = ControllerSnapshot(
        pressedButtons: [.cross],
        rightX: -0.8,
        rightY: 0.2,
        leftTrigger: 0.9,
        rightTrigger: 0.6
    )

    let merged = hardware.merging(touch)

    #expect(merged.pressedButtons == [.leftShoulder, .cross])
    #expect(merged.leftX == 0.75)
    #expect(merged.leftY == 0)
    #expect(merged.rightX == -0.8)
    #expect(merged.rightY == 0.2)
    #expect(merged.leftTrigger == 0.9)
    #expect(merged.rightTrigger == 0.6)
    #expect(merged.touchpadActive)
    #expect(merged.touchpadX == -0.25)
    #expect(merged.touchpadY == 0.5)
}

@Test
func controllerSnapshotCodableRoundTripPreservesTouchpadAndAnalogState() throws {
    let snapshot = ControllerSnapshot(
        pressedButtons: [.cross, .rightTrigger, .touchpad],
        leftX: -0.75,
        leftY: 0.25,
        rightX: 0.5,
        rightY: -0.5,
        leftTrigger: 0.2,
        rightTrigger: 0.9,
        touchpadX: 0.33,
        touchpadY: 0.66,
        touchpadActive: true
    )

    let encoded = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(ControllerSnapshot.self, from: encoded)
    #expect(decoded == snapshot)
}
