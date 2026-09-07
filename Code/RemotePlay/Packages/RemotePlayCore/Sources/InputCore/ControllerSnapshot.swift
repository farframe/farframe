import ExperienceDomain
import Foundation

public enum ControllerButton: String, Codable, CaseIterable, Sendable {
    case cross
    case circle
    case square
    case triangle
    case dpadUp
    case dpadDown
    case dpadLeft
    case dpadRight
    case leftShoulder
    case rightShoulder
    case leftTrigger
    case rightTrigger
    case leftStick
    case rightStick
    case options
    case create
    case playStation
    case touchpad
}

public struct ControllerSnapshot: Codable, Equatable, Sendable {
    public var pressedButtons: Set<ControllerButton>
    public var leftX: Float
    public var leftY: Float
    public var rightX: Float
    public var rightY: Float
    public var leftTrigger: Float
    public var rightTrigger: Float
    public var touchpadX: Float
    public var touchpadY: Float
    public var touchpadActive: Bool

    public init(
        pressedButtons: Set<ControllerButton> = [],
        leftX: Float = 0,
        leftY: Float = 0,
        rightX: Float = 0,
        rightY: Float = 0,
        leftTrigger: Float = 0,
        rightTrigger: Float = 0,
        touchpadX: Float = 0,
        touchpadY: Float = 0,
        touchpadActive: Bool = false
    ) {
        self.pressedButtons = pressedButtons
        self.leftX = leftX
        self.leftY = leftY
        self.rightX = rightX
        self.rightY = rightY
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.touchpadX = touchpadX
        self.touchpadY = touchpadY
        self.touchpadActive = touchpadActive
    }

    public static let neutral = ControllerSnapshot()

    /// Merges an alternate input surface (for example, mobile touch controls)
    /// with a hardware controller without allowing a neutral alternate value
    /// to erase a held physical control. The alternate source wins per stick
    /// while it is actively displaced; triggers use the stronger value and
    /// digital buttons are additive.
    public func merging(_ alternate: ControllerSnapshot) -> ControllerSnapshot {
        let alternateOwnsLeftStick = abs(alternate.leftX) > 0.001
            || abs(alternate.leftY) > 0.001
        let alternateOwnsRightStick = abs(alternate.rightX) > 0.001
            || abs(alternate.rightY) > 0.001
        let alternateOwnsTouchpad = alternate.touchpadActive

        return ControllerSnapshot(
            pressedButtons: pressedButtons.union(alternate.pressedButtons),
            leftX: alternateOwnsLeftStick ? alternate.leftX : leftX,
            leftY: alternateOwnsLeftStick ? alternate.leftY : leftY,
            rightX: alternateOwnsRightStick ? alternate.rightX : rightX,
            rightY: alternateOwnsRightStick ? alternate.rightY : rightY,
            leftTrigger: max(leftTrigger, alternate.leftTrigger),
            rightTrigger: max(rightTrigger, alternate.rightTrigger),
            touchpadX: alternateOwnsTouchpad ? alternate.touchpadX : touchpadX,
            touchpadY: alternateOwnsTouchpad ? alternate.touchpadY : touchpadY,
            touchpadActive: touchpadActive || alternate.touchpadActive
        )
    }

    public var hasInput: Bool {
        !pressedButtons.isEmpty ||
            abs(leftX) > 0.1 || abs(leftY) > 0.1 ||
            abs(rightX) > 0.1 || abs(rightY) > 0.1 ||
            leftTrigger > 0.1 || rightTrigger > 0.1
    }
}

public enum ControllerPairingSlot: Int, Codable, CaseIterable, Sendable {
    case console = 1
    case vision = 2
    case mobile = 3
    case mac = 4

    public var recommendedOwner: String {
        switch self {
        case .console: "PS5"
        case .vision: RemotePlayPlatform.vision.displayName
        case .mobile: RemotePlayPlatform.mobile.displayName
        case .mac: RemotePlayPlatform.mac.displayName
        }
    }
}
