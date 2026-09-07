import ChiakiNative
import Foundation
import InputCore
@testable import PlayStationRemotePlay
import Testing

private func makeFeedback(
    type: RPChiakiControllerFeedbackType
) -> RPChiakiControllerFeedback {
    var feedback = RPChiakiControllerFeedback()
    feedback.type = UInt32(type.rawValue)
    return feedback
}

@Test("The native bridge exposes controller feedback at the pinned ABI")
func nativeBridgeAdvertisesControllerFeedback() {
    let runtime = rp_chiaki_runtime_info()
    #expect(runtime.abi_version == RP_CHIAKI_NATIVE_ABI_VERSION)
    #expect(runtime.capability_mask & RP_CHIAKI_CAPABILITY_CONTROLLER_FEEDBACK != 0)
    #expect(RP_CHIAKI_TRIGGER_EFFECT_PARAMETER_SIZE == 10)
}

@Test("Rumble maps both actuators from their console bytes")
func rumbleFeedbackMaps() {
    var feedback = makeFeedback(type: RP_CHIAKI_CONTROLLER_FEEDBACK_RUMBLE)
    feedback.rumble_left = 255
    feedback.rumble_right = 0

    #expect(
        ChiakiControllerFeedbackMapping.map(feedback)
            == .rumble(ControllerRumble(lowFrequency: 1, highFrequency: 0))
    )
}

@Test("The light bar maps its three console bytes in order")
func lightBarFeedbackMaps() {
    var feedback = makeFeedback(type: RP_CHIAKI_CONTROLLER_FEEDBACK_LIGHT_BAR)
    feedback.light_bar_red = 0
    feedback.light_bar_green = 255
    feedback.light_bar_blue = 0

    #expect(
        ChiakiControllerFeedbackMapping.map(feedback)
            == .lightBar(ControllerLightBarColor(red: 0, green: 1, blue: 0))
    )
}

@Test("Haptic and trigger intensity map to their own events")
func intensityFeedbackMaps() {
    var rumbleIntensity = makeFeedback(
        type: RP_CHIAKI_CONTROLLER_FEEDBACK_HAPTIC_INTENSITY
    )
    rumbleIntensity.intensity = UInt8(RP_CHIAKI_EFFECT_INTENSITY_MEDIUM.rawValue)
    #expect(
        ChiakiControllerFeedbackMapping.map(rumbleIntensity)
            == .rumbleIntensity(.medium)
    )

    var triggerIntensity = makeFeedback(
        type: RP_CHIAKI_CONTROLLER_FEEDBACK_TRIGGER_INTENSITY
    )
    triggerIntensity.intensity = UInt8(RP_CHIAKI_EFFECT_INTENSITY_STRONG.rawValue)
    #expect(
        ChiakiControllerFeedbackMapping.map(triggerIntensity)
            == .triggerIntensity(.strong)
    )

    // An intensity the bridge does not define is dropped, not guessed.
    var unknown = makeFeedback(type: RP_CHIAKI_CONTROLLER_FEEDBACK_HAPTIC_INTENSITY)
    unknown.intensity = 9
    #expect(ChiakiControllerFeedbackMapping.map(unknown) == nil)
}

@Test("Player index maps straight through")
func playerIndexFeedbackMaps() {
    var feedback = makeFeedback(type: RP_CHIAKI_CONTROLLER_FEEDBACK_PLAYER_INDEX)
    feedback.player_index = 2
    #expect(ChiakiControllerFeedbackMapping.map(feedback) == .playerIndex(2))
}

@Test("Trigger effects decode both triggers independently")
func triggerEffectFeedbackMaps() {
    var feedback = makeFeedback(type: RP_CHIAKI_CONTROLLER_FEEDBACK_TRIGGER_EFFECTS)
    // Left: weapon over zones two through eight at full strength.
    feedback.trigger_effect_type_left = 0x25
    feedback.trigger_effect_left.0 = 0b0000_0100
    feedback.trigger_effect_left.1 = 0b0000_0001
    feedback.trigger_effect_left.2 = 7
    // Right: off.
    feedback.trigger_effect_type_right = 0x05

    guard case let .triggerEffects(effects)? =
        ChiakiControllerFeedbackMapping.map(feedback) else {
        Issue.record("Expected trigger effects")
        return
    }

    guard case let .weapon(start, end, strength) = effects.left else {
        Issue.record("Expected a weapon effect on the left trigger")
        return
    }
    #expect(abs(start - 2.0 / 9.0) < 0.0001)
    #expect(abs(end - 8.0 / 9.0) < 0.0001)
    #expect(strength == 1)
    #expect(effects.right == .off)
}

@Test("An unknown feedback type is dropped rather than misread")
func unknownFeedbackTypeIsDropped() {
    var feedback = RPChiakiControllerFeedback()
    feedback.type = 0
    #expect(ChiakiControllerFeedbackMapping.map(feedback) == nil)
    feedback.type = 99
    #expect(ChiakiControllerFeedbackMapping.map(feedback) == nil)
}
