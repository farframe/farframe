import Foundation
import PlayStationRemotePlay

/// Non-secret console information prepared by the Vision composition layer for
/// display on the Home surface.
struct VisionHomeConsoleSummary: Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let hostAddress: String
    let canWake: Bool
    let awayHostAddress: String?
    let connectionRoute: PlayStationConnectionRoute

    init(
        id: UUID,
        name: String,
        hostAddress: String,
        canWake: Bool = true,
        awayHostAddress: String? = nil,
        connectionRoute: PlayStationConnectionRoute = .home
    ) {
        self.id = id
        self.name = name
        self.hostAddress = hostAddress
        self.canWake = canWake
        self.awayHostAddress = awayHostAddress
        self.connectionRoute = connectionRoute
    }

    /// The address Wake and Connect currently target.
    var activeHostAddress: String {
        connectionRoute == .away ? (awayHostAddress ?? hostAddress) : hostAddress
    }

    var hasAwayAddress: Bool { awayHostAddress != nil }
}

/// The complete operation state needed to render Vision Home. Transport and
/// repository types deliberately do not cross this boundary.
enum VisionHomePhase: Equatable, Sendable {
    case loading
    case recoveryFailed(message: String)
    case registrationRequired(
        message: String,
        consoleID: UUID?,
        displayName: String,
        hostAddress: String
    )
    case ready
    case waking(consoleID: UUID)
    case connecting(consoleID: UUID)
    case streaming(consoleID: UUID)
    case disconnecting
    case removing(consoleID: UUID)
    case failed(message: String)
}

struct VisionHomeState: Equatable, Sendable {
    var phase: VisionHomePhase
    var consoles: [VisionHomeConsoleSummary]
    var controllerIsConnected: Bool
    var controllerName: String?
    var showsWhatsNewPrompt: Bool
    var accessAllowsConnect: Bool
    var accessPresentation: VisionHomeAccessPresentation
    var accessNotice: String?

    init(
        phase: VisionHomePhase = .loading,
        consoles: [VisionHomeConsoleSummary] = [],
        controllerIsConnected: Bool = false,
        controllerName: String? = nil,
        showsWhatsNewPrompt: Bool = false,
        accessAllowsConnect: Bool = false,
        accessPresentation: VisionHomeAccessPresentation = .checking,
        accessNotice: String? = nil
    ) {
        self.phase = phase
        self.consoles = consoles
        self.controllerIsConnected = controllerIsConnected
        self.controllerName = controllerName
        self.showsWhatsNewPrompt = showsWhatsNewPrompt
        self.accessAllowsConnect = accessAllowsConnect
        self.accessPresentation = accessPresentation
        self.accessNotice = accessNotice
    }
}

enum VisionHomeAccessPresentation: Equatable, Sendable {
    case checking
    case trialEligible
    case startingTrial
    case trialActive(expiresAt: Date)
    case trialExpired
    case lifetimeUnlocked
}

/// Intent-only messages from Vision Home. A coordinator decides how each
/// action maps to repository, provider, session, and window behavior.
enum VisionHomeAction: Equatable, Sendable {
    case connect(consoleID: UUID)
    case wake(consoleID: UUID)
    case cancelConnection
    case pairConsole
    case resumeRegistration(
        consoleID: UUID?,
        displayName: String,
        hostAddress: String
    )
    case reRegister(consoleID: UUID)
    case editAddresses(consoleID: UUID)
    case toggleRoute(consoleID: UUID)
    case remove(consoleID: UUID)
    case startTrial
    case openAccess
    case openSettings
    case openWhatsNew
    case dismissWhatsNewPrompt
    case retry
    case dismissError
}
