import Foundation

/// Console-driven controller output: rumble, the light bar, and the DualSense
/// adaptive triggers. This is the mirror of `ControllerSnapshot`, which carries
/// input in the other direction. Both are provider-neutral; the streaming
/// provider owns protocol translation and the platform shell owns delivery to
/// real hardware.
public enum ControllerFeedbackEvent: Equatable, Sendable {
    case rumble(ControllerRumble)
    case lightBar(ControllerLightBarColor)
    case triggerEffects(ControllerTriggerEffects)
    /// The console's global scale for rumble strength.
    case rumbleIntensity(ControllerEffectIntensity)
    /// The console's global scale for adaptive trigger strength.
    case triggerIntensity(ControllerEffectIntensity)
    case playerIndex(Int)
}

/// Both DualSense actuators, normalized to 0...1. The PlayStation names these
/// by frequency rather than by side: `lowFrequency` is the heavier left-hand
/// actuator and `highFrequency` the lighter right-hand one.
public struct ControllerRumble: Equatable, Sendable {
    public let lowFrequency: Float
    public let highFrequency: Float

    public init(lowFrequency: Float, highFrequency: Float) {
        self.lowFrequency = Self.normalized(lowFrequency)
        self.highFrequency = Self.normalized(highFrequency)
    }

    public init(lowFrequencyByte: UInt8, highFrequencyByte: UInt8) {
        self.init(
            lowFrequency: Float(lowFrequencyByte) / 255,
            highFrequency: Float(highFrequencyByte) / 255
        )
    }

    public static let silent = ControllerRumble(lowFrequency: 0, highFrequency: 0)

    public var isSilent: Bool {
        lowFrequency <= 0 && highFrequency <= 0
    }

    /// Scales both actuators by a console-supplied global intensity.
    public func scaled(by scale: Float) -> ControllerRumble {
        ControllerRumble(
            lowFrequency: lowFrequency * scale,
            highFrequency: highFrequency * scale
        )
    }

    private static func normalized(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

public struct ControllerLightBarColor: Equatable, Sendable {
    public let red: Float
    public let green: Float
    public let blue: Float

    public init(red: Float, green: Float, blue: Float) {
        self.red = Self.normalized(red)
        self.green = Self.normalized(green)
        self.blue = Self.normalized(blue)
    }

    public init(redByte: UInt8, greenByte: UInt8, blueByte: UInt8) {
        self.init(
            red: Float(redByte) / 255,
            green: Float(greenByte) / 255,
            blue: Float(blueByte) / 255
        )
    }

    private static func normalized(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

/// The console's global effect scale. The wire values are ordered
/// strongest-first and are deliberately not a monotonic scale, so the raw value
/// is preserved and the usable multiplier is exposed separately.
public enum ControllerEffectIntensity: UInt8, Equatable, Sendable, CaseIterable {
    case off = 0
    case strong = 1
    case medium = 2
    case weak = 3

    public init?(wireValue: UInt8) {
        self.init(rawValue: wireValue)
    }

    /// A 0...1 multiplier to apply to effect strength.
    public var scale: Float {
        switch self {
        case .off: 0
        case .weak: 0.35
        case .medium: 0.7
        case .strong: 1
        }
    }
}

public struct ControllerTriggerEffects: Equatable, Sendable {
    public let left: ControllerTriggerEffect
    public let right: ControllerTriggerEffect

    public init(left: ControllerTriggerEffect, right: ControllerTriggerEffect) {
        self.left = left
        self.right = right
    }

    public static let off = ControllerTriggerEffects(left: .off, right: .off)
}

/// A DualSense adaptive trigger effect expressed the way Apple's
/// `GCDualSenseAdaptiveTrigger` accepts it: normalized 0...1 positions,
/// strengths, and frequencies. The PlayStation wire format is decoded into this
/// shape by `ControllerTriggerEffectDecoder`.
public enum ControllerTriggerEffect: Equatable, Sendable {
    case off
    /// Constant resistance from `startPosition` onward.
    case feedback(startPosition: Float, resistiveStrength: Float)
    /// Resistance per trigger zone; always ten values.
    case positionalFeedback(resistiveStrengths: [Float])
    /// Resistance from `startPosition` that releases past `endPosition`.
    case weapon(startPosition: Float, endPosition: Float, resistiveStrength: Float)
    /// Vibration from `startPosition` onward.
    case vibration(startPosition: Float, amplitude: Float, frequency: Float)
    /// Vibration amplitude per trigger zone; always ten values.
    case positionalVibration(amplitudes: [Float], frequency: Float)

    public var isOff: Bool {
        self == .off
    }
}

/// Decodes the PlayStation's adaptive trigger wire format into Apple's
/// semantic trigger modes.
///
/// The console sends one effect type byte plus ten parameter bytes per trigger,
/// intended for a DualSense HID output report. Apple exposes no raw HID path,
/// so the bytes have to be decoded into `GCDualSenseAdaptiveTrigger` modes.
/// The quantization is fixed by the hardware and is what Apple's own normalized
/// API rounds to: ten trigger zones, so a position is `zone / 9`; nine strength
/// steps, so a strength is `value / 8`; and a single frequency byte, so a
/// frequency is `byte / 255`.
///
/// An unrecognized effect type decodes to `.off` rather than a guess. A wrong
/// effect feels worse than no effect, and the console re-sends the current
/// effect whenever it changes.
public enum ControllerTriggerEffectDecoder {
    public static let zoneCount = 10
    public static let parameterCount = 10

    private enum EffectType: UInt8 {
        case none = 0x00
        case simpleFeedback = 0x01
        case simpleWeapon = 0x02
        case off = 0x05
        case simpleVibration = 0x06
        case limitedFeedback = 0x11
        case limitedWeapon = 0x12
        case feedback = 0x21
        case weapon = 0x25
        case vibration = 0x26
    }

    /// Ten zones with one active bit each, then three strength bits per zone.
    private static let maximumPosition = Float(zoneCount - 1)
    private static let maximumStrength: Float = 8
    private static let maximumFrequency: Float = 255

    public static func decode(
        type: UInt8,
        parameters: [UInt8]
    ) -> ControllerTriggerEffect {
        guard parameters.count == parameterCount,
              let effect = EffectType(rawValue: type) else {
            return .off
        }

        switch effect {
        case .none, .off:
            return .off

        case .simpleFeedback, .limitedFeedback:
            // Parameters are the raw position and strength, unpacked.
            let strength = strengthScale(parameters[1])
            guard strength > 0 else { return .off }
            return .feedback(
                startPosition: positionScale(parameters[0]),
                resistiveStrength: strength
            )

        case .simpleWeapon, .limitedWeapon:
            let strength = strengthScale(parameters[2])
            let start = positionScale(parameters[0])
            let end = positionScale(parameters[1])
            guard strength > 0, end > start else { return .off }
            return .weapon(
                startPosition: start,
                endPosition: end,
                resistiveStrength: strength
            )

        case .simpleVibration:
            // The simple vibration effect orders its parameters differently
            // from the other simple effects: frequency, amplitude, position.
            let amplitude = strengthScale(parameters[1])
            let frequency = Float(parameters[0]) / maximumFrequency
            guard amplitude > 0, frequency > 0 else { return .off }
            return .vibration(
                startPosition: positionScale(parameters[2]),
                amplitude: amplitude,
                frequency: frequency
            )

        case .feedback:
            let strengths = unpackZoneValues(parameters)
            guard strengths.contains(where: { $0 > 0 }) else { return .off }
            return .positionalFeedback(resistiveStrengths: strengths)

        case .weapon:
            return decodeWeapon(parameters)

        case .vibration:
            let amplitudes = unpackZoneValues(parameters)
            let frequency = Float(parameters[8]) / maximumFrequency
            guard frequency > 0, amplitudes.contains(where: { $0 > 0 }) else {
                return .off
            }
            return .positionalVibration(amplitudes: amplitudes, frequency: frequency)
        }
    }

    /// The weapon effect marks its start and end as the low and high set bits of
    /// a ten-zone mask, and carries one strength value.
    private static func decodeWeapon(_ parameters: [UInt8]) -> ControllerTriggerEffect {
        let mask = UInt16(parameters[0]) | (UInt16(parameters[1]) << 8)
        var zones: [Int] = []
        for zone in 0..<zoneCount where mask & (1 << UInt16(zone)) != 0 {
            zones.append(zone)
        }
        guard let start = zones.first, let end = zones.last, end > start else {
            return .off
        }

        let strength = Float((parameters[2] & 0x07) + 1) / maximumStrength
        return .weapon(
            startPosition: Float(start) / maximumPosition,
            endPosition: Float(end) / maximumPosition,
            resistiveStrength: strength
        )
    }

    /// Zone values are a ten-bit active mask followed by three bits of strength
    /// per zone, both little endian. A stored strength is one less than the
    /// value it represents, so an active zone is never silent.
    private static func unpackZoneValues(_ parameters: [UInt8]) -> [Float] {
        let activeZones = UInt16(parameters[0]) | (UInt16(parameters[1]) << 8)
        var packedValues: UInt32 = 0
        for offset in 0..<4 {
            packedValues |= UInt32(parameters[2 + offset]) << (8 * UInt32(offset))
        }

        return (0..<zoneCount).map { zone in
            guard activeZones & (1 << UInt16(zone)) != 0 else { return Float(0) }
            let stored = (packedValues >> (3 * UInt32(zone))) & 0x07
            return Float(stored + 1) / maximumStrength
        }
    }

    private static func positionScale(_ value: UInt8) -> Float {
        min(1, Float(value) / maximumPosition)
    }

    private static func strengthScale(_ value: UInt8) -> Float {
        min(1, Float(value) / maximumStrength)
    }
}
