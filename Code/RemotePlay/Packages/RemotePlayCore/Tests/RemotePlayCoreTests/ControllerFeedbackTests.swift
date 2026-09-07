import Foundation
import InputCore
import Testing

/// Re-encodes an effect into the PlayStation wire format exactly the way the
/// console does, so the decoder is proven against a real round trip rather than
/// against hand-copied bytes. The packing mirrors the DualSense output report:
/// a ten-bit active-zone mask, then three bits of strength per zone, both
/// little endian, with a stored strength one less than its real value.
private enum TriggerEffectEncoder {
    static let off: [UInt8] = Array(repeating: 0, count: 10)

    static func positional(
        values: [Int],
        frequency: UInt8 = 0
    ) -> [UInt8] {
        var activeZones: UInt16 = 0
        var packed: UInt32 = 0
        for (zone, value) in values.enumerated() where value > 0 {
            activeZones |= UInt16(1) << UInt16(zone)
            packed |= UInt32((value - 1) & 0x07) << (3 * UInt32(zone))
        }

        var parameters = [UInt8](repeating: 0, count: 10)
        parameters[0] = UInt8(activeZones & 0xff)
        parameters[1] = UInt8((activeZones >> 8) & 0xff)
        for offset in 0..<4 {
            parameters[2 + offset] = UInt8((packed >> (8 * UInt32(offset))) & 0xff)
        }
        parameters[8] = frequency
        return parameters
    }

    static func weapon(
        startZone: Int,
        endZone: Int,
        strength: Int
    ) -> [UInt8] {
        let mask = (UInt16(1) << UInt16(startZone)) | (UInt16(1) << UInt16(endZone))
        var parameters = [UInt8](repeating: 0, count: 10)
        parameters[0] = UInt8(mask & 0xff)
        parameters[1] = UInt8((mask >> 8) & 0xff)
        parameters[2] = UInt8(strength - 1)
        return parameters
    }

    static func simple(_ values: [UInt8]) -> [UInt8] {
        var parameters = [UInt8](repeating: 0, count: 10)
        for (index, value) in values.enumerated() {
            parameters[index] = value
        }
        return parameters
    }
}

@Test("Rumble bytes normalize to 0...1 and report silence")
func rumbleBytesNormalize() {
    let full = ControllerRumble(lowFrequencyByte: 255, highFrequencyByte: 0)
    #expect(full.lowFrequency == 1)
    #expect(full.highFrequency == 0)
    #expect(full.isSilent == false)
    #expect(ControllerRumble.silent.isSilent)
    #expect(ControllerRumble(lowFrequencyByte: 0, highFrequencyByte: 0).isSilent)
}

@Test("Rumble clamps out-of-range and non-finite input")
func rumbleClampsInvalidInput() {
    let clamped = ControllerRumble(lowFrequency: 4, highFrequency: -2)
    #expect(clamped.lowFrequency == 1)
    #expect(clamped.highFrequency == 0)

    // A non-finite value is garbage, not a loud one. Both fail to silence
    // rather than pinning a motor at full strength.
    let invalid = ControllerRumble(
        lowFrequency: .nan,
        highFrequency: .infinity
    )
    #expect(invalid.isSilent)
}

@Test("Rumble scales by the console's global intensity")
func rumbleScalesByIntensity() {
    let rumble = ControllerRumble(lowFrequency: 1, highFrequency: 0.5)
    let scaled = rumble.scaled(by: ControllerEffectIntensity.weak.scale)
    #expect(abs(scaled.lowFrequency - 0.35) < 0.0001)
    #expect(abs(scaled.highFrequency - 0.175) < 0.0001)
    #expect(rumble.scaled(by: 0).isSilent)
}

@Test("Light bar bytes normalize to 0...1")
func lightBarBytesNormalize() {
    let color = ControllerLightBarColor(redByte: 255, greenByte: 128, blueByte: 0)
    #expect(color.red == 1)
    #expect(abs(color.green - 0.50196) < 0.0001)
    #expect(color.blue == 0)

    let clamped = ControllerLightBarColor(red: 2, green: .nan, blue: -1)
    #expect(clamped.red == 1)
    #expect(clamped.green == 0)
    #expect(clamped.blue == 0)
}

/// The console's intensity values are ordered strongest-first, so a naive
/// numeric read of the wire value would invert the scale.
@Test("Effect intensity wire values are not a monotonic scale")
func effectIntensityWireValuesAreNotMonotonic() {
    #expect(ControllerEffectIntensity(wireValue: 0) == .off)
    #expect(ControllerEffectIntensity(wireValue: 1) == .strong)
    #expect(ControllerEffectIntensity(wireValue: 2) == .medium)
    #expect(ControllerEffectIntensity(wireValue: 3) == .weak)
    #expect(ControllerEffectIntensity(wireValue: 4) == nil)

    #expect(ControllerEffectIntensity.off.scale == 0)
    #expect(ControllerEffectIntensity.strong.scale == 1)
    #expect(ControllerEffectIntensity.weak.scale < ControllerEffectIntensity.medium.scale)
    #expect(ControllerEffectIntensity.medium.scale < ControllerEffectIntensity.strong.scale)
}

@Test("Unknown and empty trigger effects decode to off, never to a guess")
func unknownTriggerEffectsDecodeToOff() {
    #expect(
        ControllerTriggerEffectDecoder.decode(
            type: 0x05,
            parameters: TriggerEffectEncoder.off
        ) == .off
    )
    #expect(
        ControllerTriggerEffectDecoder.decode(
            type: 0x00,
            parameters: TriggerEffectEncoder.off
        ) == .off
    )
    // Unofficial effects the DualSense accepts but Apple cannot express.
    for unsupported: UInt8 in [0x22, 0x23, 0x27, 0xfc, 0xfd, 0xfe] {
        #expect(
            ControllerTriggerEffectDecoder.decode(
                type: unsupported,
                parameters: TriggerEffectEncoder.off
            ) == .off
        )
    }
    // A wrong parameter count is never trusted.
    #expect(ControllerTriggerEffectDecoder.decode(type: 0x21, parameters: []) == .off)
    #expect(
        ControllerTriggerEffectDecoder.decode(
            type: 0x21,
            parameters: [UInt8](repeating: 0, count: 9)
        ) == .off
    )
}

@Test("Positional feedback round-trips every zone strength")
func positionalFeedbackRoundTrips() {
    let strengths = [0, 1, 2, 3, 4, 5, 6, 7, 8, 0]
    let decoded = ControllerTriggerEffectDecoder.decode(
        type: 0x21,
        parameters: TriggerEffectEncoder.positional(values: strengths)
    )
    guard case let .positionalFeedback(resistiveStrengths) = decoded else {
        Issue.record("Expected positional feedback, got \(decoded)")
        return
    }

    #expect(resistiveStrengths.count == ControllerTriggerEffectDecoder.zoneCount)
    for (zone, strength) in strengths.enumerated() {
        let expected = strength == 0 ? Float(0) : Float(strength) / 8
        #expect(abs(resistiveStrengths[zone] - expected) < 0.0001)
    }
}

@Test("An all-zero positional feedback block is off, not a silent effect")
func silentPositionalFeedbackIsOff() {
    #expect(
        ControllerTriggerEffectDecoder.decode(
            type: 0x21,
            parameters: TriggerEffectEncoder.positional(
                values: Array(repeating: 0, count: 10)
            )
        ) == .off
    )
}

@Test("Weapon effects recover start, end, and strength from the zone mask")
func weaponEffectRoundTrips() {
    let decoded = ControllerTriggerEffectDecoder.decode(
        type: 0x25,
        parameters: TriggerEffectEncoder.weapon(
            startZone: 2,
            endZone: 8,
            strength: 8
        )
    )
    guard case let .weapon(start, end, strength) = decoded else {
        Issue.record("Expected weapon, got \(decoded)")
        return
    }

    // Ten zones, so a position is its zone index over nine.
    #expect(abs(start - 2.0 / 9.0) < 0.0001)
    #expect(abs(end - 8.0 / 9.0) < 0.0001)
    #expect(strength == 1)
}

@Test("A weapon effect without a usable range decodes to off")
func degenerateWeaponEffectIsOff() {
    // Only one zone bit set: no range to resist over.
    var parameters = [UInt8](repeating: 0, count: 10)
    parameters[0] = 0b0000_0100
    parameters[2] = 7
    #expect(ControllerTriggerEffectDecoder.decode(type: 0x25, parameters: parameters) == .off)
    // No zone bits at all.
    #expect(
        ControllerTriggerEffectDecoder.decode(
            type: 0x25,
            parameters: TriggerEffectEncoder.off
        ) == .off
    )
}

@Test("Positional vibration round-trips amplitudes and frequency")
func positionalVibrationRoundTrips() {
    let amplitudes = [8, 0, 0, 0, 4, 0, 0, 0, 0, 1]
    let decoded = ControllerTriggerEffectDecoder.decode(
        type: 0x26,
        parameters: TriggerEffectEncoder.positional(
            values: amplitudes,
            frequency: 255
        )
    )
    guard case let .positionalVibration(values, frequency) = decoded else {
        Issue.record("Expected positional vibration, got \(decoded)")
        return
    }

    #expect(frequency == 1)
    #expect(values[0] == 1)
    #expect(values[1] == 0)
    #expect(abs(values[4] - 0.5) < 0.0001)
    #expect(abs(values[9] - 0.125) < 0.0001)
}

@Test("Vibration without a frequency is off, because it cannot cycle")
func vibrationWithoutFrequencyIsOff() {
    #expect(
        ControllerTriggerEffectDecoder.decode(
            type: 0x26,
            parameters: TriggerEffectEncoder.positional(
                values: [8, 8, 8, 8, 8, 8, 8, 8, 8, 8],
                frequency: 0
            )
        ) == .off
    )
}

@Test("Simple effects decode from their unpacked parameters")
func simpleEffectsDecode() {
    let feedback = ControllerTriggerEffectDecoder.decode(
        type: 0x01,
        parameters: TriggerEffectEncoder.simple([9, 8])
    )
    guard case let .feedback(start, strength) = feedback else {
        Issue.record("Expected feedback, got \(feedback)")
        return
    }
    #expect(start == 1)
    #expect(strength == 1)

    let weapon = ControllerTriggerEffectDecoder.decode(
        type: 0x02,
        parameters: TriggerEffectEncoder.simple([0, 9, 4])
    )
    guard case let .weapon(weaponStart, weaponEnd, weaponStrength) = weapon else {
        Issue.record("Expected weapon, got \(weapon)")
        return
    }
    #expect(weaponStart == 0)
    #expect(weaponEnd == 1)
    #expect(abs(weaponStrength - 0.5) < 0.0001)

    // Simple vibration orders its parameters frequency, amplitude, position.
    let vibration = ControllerTriggerEffectDecoder.decode(
        type: 0x06,
        parameters: TriggerEffectEncoder.simple([255, 8, 9])
    )
    guard case let .vibration(position, amplitude, frequency) = vibration else {
        Issue.record("Expected vibration, got \(vibration)")
        return
    }
    #expect(position == 1)
    #expect(amplitude == 1)
    #expect(frequency == 1)
}

@Test("A simple effect with no strength decodes to off")
func simpleEffectWithoutStrengthIsOff() {
    #expect(
        ControllerTriggerEffectDecoder.decode(
            type: 0x01,
            parameters: TriggerEffectEncoder.simple([5, 0])
        ) == .off
    )
    #expect(
        ControllerTriggerEffectDecoder.decode(
            type: 0x02,
            parameters: TriggerEffectEncoder.simple([2, 6, 0])
        ) == .off
    )
    #expect(
        ControllerTriggerEffectDecoder.decode(
            type: 0x06,
            parameters: TriggerEffectEncoder.simple([30, 0, 5])
        ) == .off
    )
}

@Test("Decoded strengths and positions always stay inside Apple's 0...1 range")
func decodedValuesStayNormalized() {
    // Deliberately out-of-spec bytes: the console is trusted for shape, not
    // for range, and Apple rejects anything outside 0...1.
    let hostile = TriggerEffectEncoder.simple([255, 255, 255])
    for type: UInt8 in [0x01, 0x02, 0x06, 0x11, 0x12] {
        switch ControllerTriggerEffectDecoder.decode(type: type, parameters: hostile) {
        case .off:
            continue
        case let .feedback(start, strength):
            #expect((0...1).contains(start))
            #expect((0...1).contains(strength))
        case let .weapon(start, end, strength):
            #expect((0...1).contains(start))
            #expect((0...1).contains(end))
            #expect((0...1).contains(strength))
        case let .vibration(start, amplitude, frequency):
            #expect((0...1).contains(start))
            #expect((0...1).contains(amplitude))
            #expect((0...1).contains(frequency))
        case let .positionalFeedback(values):
            #expect(values.allSatisfy { (0...1).contains($0) })
        case let .positionalVibration(values, frequency):
            #expect(values.allSatisfy { (0...1).contains($0) })
            #expect((0...1).contains(frequency))
        }
    }
}

@Test("Every packed zone strength decodes inside Apple's range")
func packedZoneStrengthsStayNormalized() {
    // Every possible three-bit stored value in every zone.
    for stored in 1...8 {
        let parameters = TriggerEffectEncoder.positional(
            values: Array(repeating: stored, count: 10)
        )
        let decoded = ControllerTriggerEffectDecoder.decode(
            type: 0x21,
            parameters: parameters
        )
        guard case let .positionalFeedback(values) = decoded else {
            Issue.record("Expected positional feedback for stored \(stored)")
            return
        }
        #expect(values.allSatisfy { (0...1).contains($0) })
        #expect(values.allSatisfy { abs($0 - Float(stored) / 8) < 0.0001 })
    }
}
