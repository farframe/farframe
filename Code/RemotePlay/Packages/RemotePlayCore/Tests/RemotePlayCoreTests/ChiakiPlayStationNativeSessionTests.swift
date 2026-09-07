import ChiakiNative
import Foundation
import InputCore
@testable import PlayStationRemotePlay
import Testing

@Test
func chiakiSessionEventMappingDoesNotClaimDecodedPlayback() {
    #expect(
        ChiakiSessionEventMapping.map(
            eventType: Int32(RP_CHIAKI_SESSION_EVENT_TRANSPORT_READY.rawValue),
            detailCode: 0
        ) == .transportReady
    )
    #expect(
        ChiakiSessionEventMapping.map(
            eventType: Int32(RP_CHIAKI_SESSION_EVENT_QUIT.rawValue),
            detailCode: 1
        ) == .quit(.normal)
    )
    #expect(
        ChiakiSessionEventMapping.map(
            eventType: Int32(RP_CHIAKI_SESSION_EVENT_QUIT.rawValue),
            detailCode: 11
        ) == .quit(.remoteDisconnected)
    )
    #expect(
        ChiakiSessionEventMapping.map(
            eventType: Int32(RP_CHIAKI_SESSION_EVENT_QUIT.rawValue),
            detailCode: 8
        ) == .quit(.nativeFailure(code: 8))
    )
    #expect(ChiakiSessionEventMapping.map(eventType: 999, detailCode: 0) == nil)
}

@Test
func chiakiNativeSessionFactoryCanCloseAnIdleOpaqueHandle() async throws {
    let session = try await ChiakiPlayStationNativeSessionFactory().makeSession()
    try await session.stop()
    try await session.join()
}

@Test
func chiakiControllerMappingPreservesButtonsAndKnownGoodAxisSemantics() {
    let snapshot = ControllerSnapshot(
        pressedButtons: [
            .cross,
            .dpadLeft,
            .leftShoulder,
            .rightStick,
            .options,
            .create,
            .playStation,
            .touchpad,
            .leftTrigger,
            .rightTrigger,
        ],
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

    let native = ChiakiControllerStateMapping.map(snapshot)
    let expectedButtons = UInt32(RP_CHIAKI_CONTROLLER_BUTTON_CROSS) |
        UInt32(RP_CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT) |
        UInt32(RP_CHIAKI_CONTROLLER_BUTTON_L1) |
        UInt32(RP_CHIAKI_CONTROLLER_BUTTON_R3) |
        UInt32(RP_CHIAKI_CONTROLLER_BUTTON_OPTIONS) |
        UInt32(RP_CHIAKI_CONTROLLER_BUTTON_CREATE) |
        UInt32(RP_CHIAKI_CONTROLLER_BUTTON_PS) |
        UInt32(RP_CHIAKI_CONTROLLER_BUTTON_TOUCHPAD) |
        UInt32(RP_CHIAKI_CONTROLLER_BUTTON_L2) |
        UInt32(RP_CHIAKI_CONTROLLER_BUTTON_R2)

    #expect(native.buttons == expectedButtons)
    #expect(native.l2_state == 51)
    #expect(native.r2_state == 229)
    #expect(native.left_x == -24_575)
    #expect(native.left_y == -8_191)
    #expect(native.right_x == 16_383)
    #expect(native.right_y == 16_383)
    #expect(native.touch_active == 1)
    #expect(native.touch_x == 633)
    #expect(native.touch_y == 621)
}

@Test
func chiakiControllerMappingClampsAndSanitizesUntrustedAnalogValues() {
    let native = ChiakiControllerStateMapping.map(
        ControllerSnapshot(
            leftX: -.infinity,
            leftY: 2,
            rightX: .nan,
            rightY: -2,
            leftTrigger: -.infinity,
            rightTrigger: 2,
            touchpadX: .nan,
            touchpadY: 4,
            touchpadActive: true
        )
    )

    #expect(native.left_x == 0)
    #expect(native.left_y == -32_767)
    #expect(native.right_x == 0)
    #expect(native.right_y == 32_767)
    #expect(native.l2_state == 0)
    #expect(native.r2_state == 255)
    #expect(native.touch_x == 0)
    #expect(native.touch_y == UInt16(RP_CHIAKI_TOUCHPAD_HEIGHT))
}

@Test
func chiakiControlsFailClosedBeforeNativeSessionStart() async throws {
    let session = try ChiakiPlayStationNativeSession()
    let invalidState = RP_CHIAKI_BRIDGE_INVALID_STATE.rawValue

    await #expect(
        throws: ChiakiPlayStationNativeSessionError.controllerStateFailed(code: invalidState)
    ) {
        try await session.sendControllerSnapshot(.neutral)
    }
    await #expect(
        throws: ChiakiPlayStationNativeSessionError.goHomeFailed(code: invalidState)
    ) {
        try await session.goHome()
    }
    await #expect(
        throws: ChiakiPlayStationNativeSessionError.goToBedFailed(code: invalidState)
    ) {
        try await session.goToBed()
    }

    try await session.join()
}
