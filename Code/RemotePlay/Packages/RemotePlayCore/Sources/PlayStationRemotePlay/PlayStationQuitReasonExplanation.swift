import Foundation

/// A native quit code read back in the user's language.
///
/// `PlayStationNativeQuitReason` carries a bare `Int32` for every reason the
/// session mapping does not classify, which is how a real connect failure
/// reached the owner's headset as "The Remote Play session ended unexpectedly."
/// The number is meaningful — it names the exact stage the handshake stopped at
/// — but only against the native enum, which no shell can read.
///
/// This type is the translation, and nothing else: it changes no state, gates
/// no path, and is never consulted while connecting. Adding a code here can
/// only change what a failure is called.
public struct PlayStationQuitReasonExplanation: Equatable, Hashable, Sendable {
    /// The native quit code, kept so a report or a log line stays greppable
    /// against the table below and against the pinned native source.
    public let code: Int32
    /// Stable key for reports and logs. Safe to match on across versions.
    public let identifier: String
    /// What happened, in the user's terms. One sentence.
    public let summary: String
    /// What to do about it, cheapest and most likely to help first.
    public let guidance: String

    public init(code: Int32, identifier: String, summary: String, guidance: String) {
        self.code = code
        self.identifier = identifier
        self.summary = summary
        self.guidance = guidance
    }

    /// The full sentence a shell shows. The code stays at the end so a support
    /// conversation can still name the exact stage without leading with a
    /// number the reader cannot interpret.
    public var message: String {
        "\(summary) \(guidance) (code \(code))"
    }
}

extension PlayStationNativeQuitReason {
    /// Plain-English reading of this quit reason.
    ///
    /// `.remoteDisconnected` covers two native codes (11 and 12); the mapping
    /// that produced it has already discarded which one, so this reports the
    /// shared meaning under 11.
    public var explanation: PlayStationQuitReasonExplanation {
        switch self {
        case .normal:
            PlayStationQuitReasonExplanation.forCode(PlayStationNativeQuitCode.stopped)
        case .remoteDisconnected:
            PlayStationQuitReasonExplanation.forCode(PlayStationNativeQuitCode.remoteDisconnected)
        case let .nativeFailure(code):
            PlayStationQuitReasonExplanation.forCode(code)
        }
    }
}

/// The pinned `ChiakiQuitReason` values.
///
/// Source of truth is `lib/include/chiaki/session.h` in chiaki-ng at the
/// revision recorded in `Native/Manifest/sources.lock`
/// (`a75d628ffb4b6e33126e3830b4fb32796e5cc005`). The enum there is unnumbered,
/// so these are its declaration order. Re-read that header whenever the source
/// lock moves; a reordered enum would silently retitle every failure.
public enum PlayStationNativeQuitCode {
    public static let none: Int32 = 0
    public static let stopped: Int32 = 1
    public static let sessionRequestUnknown: Int32 = 2
    public static let sessionRequestConnectionRefused: Int32 = 3
    public static let sessionRequestRemotePlayInUse: Int32 = 4
    public static let sessionRequestRemotePlayCrash: Int32 = 5
    public static let sessionRequestVersionMismatch: Int32 = 6
    public static let controlChannelUnknown: Int32 = 7
    public static let controlChannelConnectFailed: Int32 = 8
    public static let controlChannelRefused: Int32 = 9
    public static let streamConnectionUnknown: Int32 = 10
    public static let remoteDisconnected: Int32 = 11
    public static let remoteShutdown: Int32 = 12
    public static let accountRegistrationFailed: Int32 = 13
}

extension PlayStationQuitReasonExplanation {
    /// The table. Every arm names the console-side stage the handshake reached,
    /// because that is what tells the user whether to wait, to look at the PS5,
    /// or to look at the network.
    public static func forCode(_ code: Int32) -> PlayStationQuitReasonExplanation {
        switch code {
        case PlayStationNativeQuitCode.none:
            PlayStationQuitReasonExplanation(
                code: code,
                identifier: "none",
                summary: "Remote Play ended without reporting a reason.",
                guidance: "Try Connect again. If it keeps happening, restart the PS5."
            )

        case PlayStationNativeQuitCode.stopped:
            PlayStationQuitReasonExplanation(
                code: code,
                identifier: "stopped",
                summary: "Remote Play ended normally.",
                guidance: "Connect again whenever you are ready."
            )

        case PlayStationNativeQuitCode.sessionRequestUnknown:
            PlayStationQuitReasonExplanation(
                code: code,
                identifier: "session-request-unknown",
                summary: "The PS5 did not answer the request to start Remote Play.",
                // The console being fully off leads, because it is the one case
                // the user cannot fix by waiting and the one Wake cannot reach:
                // Wake only works from rest mode, which keeps the network
                // interface powered. A PS5 that lost mains power is off, and
                // every Wake after that is a datagram into nothing.
                guidance: """
                    The console is usually off, still waking, or unreachable. \
                    Wake only works from rest mode, so a PS5 that lost power is \
                    fully off and has to be turned on by hand. Otherwise give it \
                    about ten seconds after Wake and check that both devices are \
                    on the same network.
                    """
            )

        case PlayStationNativeQuitCode.sessionRequestConnectionRefused:
            PlayStationQuitReasonExplanation(
                code: code,
                identifier: "session-request-refused",
                summary: "The PS5 refused the request to start Remote Play.",
                guidance: """
                    Check that Remote Play is still enabled in the PS5's \
                    settings and that this device is still linked to it, then \
                    Connect again.
                    """
            )

        case PlayStationNativeQuitCode.sessionRequestRemotePlayInUse:
            PlayStationQuitReasonExplanation(
                code: code,
                identifier: "remote-play-in-use",
                summary: "The PS5 is already running Remote Play for another device.",
                guidance: """
                    Disconnect Remote Play on that device without putting the \
                    PS5 into rest, then Connect again.
                    """
            )

        case PlayStationNativeQuitCode.sessionRequestRemotePlayCrash:
            PlayStationQuitReasonExplanation(
                code: code,
                identifier: "remote-play-crashed",
                summary: "Remote Play crashed on the PS5.",
                guidance: "Restart the PS5, then Connect again."
            )

        case PlayStationNativeQuitCode.sessionRequestVersionMismatch:
            PlayStationQuitReasonExplanation(
                code: code,
                identifier: "version-mismatch",
                summary: "The PS5 uses a Remote Play version this build cannot speak.",
                guidance: """
                    Install the latest PS5 system software and the latest \
                    Farframe, then Connect again.
                    """
            )

        case PlayStationNativeQuitCode.controlChannelUnknown:
            PlayStationQuitReasonExplanation(
                code: code,
                identifier: "control-unknown",
                summary: """
                    The PS5 accepted the session and then the control channel \
                    failed.
                    """,
                guidance: """
                    Connect again. If it repeats, restart the PS5 and move this \
                    device closer to the router.
                    """
            )

        case PlayStationNativeQuitCode.controlChannelConnectFailed:
            PlayStationQuitReasonExplanation(
                code: code,
                identifier: "control-connect-failed",
                summary: "Farframe could not open the control channel to the PS5.",
                guidance: """
                    Check that both devices are on the same network and that the \
                    router does not isolate them from each other, then Connect \
                    again.
                    """
            )

        case PlayStationNativeQuitCode.controlChannelRefused:
            PlayStationQuitReasonExplanation(
                code: code,
                identifier: "control-connection-refused",
                summary: "The PS5 refused the control channel.",
                guidance: """
                    Restart the PS5 and Connect again. If it persists, link this \
                    device to the PS5 again.
                    """
            )

        case PlayStationNativeQuitCode.streamConnectionUnknown:
            PlayStationQuitReasonExplanation(
                code: code,
                identifier: "stream-connection-unknown",
                summary: """
                    The PS5 accepted the session and then the video and audio \
                    stream failed to start.
                    """,
                guidance: """
                    Connect again. If it repeats, choose a lower Stream quality \
                    in Settings and check the network between this device and \
                    the PS5.
                    """
            )

        case PlayStationNativeQuitCode.remoteDisconnected:
            PlayStationQuitReasonExplanation(
                code: code,
                identifier: "remote-disconnected",
                summary: "The PS5 ended this Remote Play connection.",
                guidance: """
                    If Farframe is connected on another device, disconnect there \
                    without Rest, then Connect again.
                    """
            )

        case PlayStationNativeQuitCode.remoteShutdown:
            PlayStationQuitReasonExplanation(
                code: code,
                identifier: "remote-shutdown",
                summary: "The PS5 shut down or went into rest while streaming.",
                guidance: "Wake the PS5, wait about ten seconds, then Connect again."
            )

        case PlayStationNativeQuitCode.accountRegistrationFailed:
            PlayStationQuitReasonExplanation(
                code: code,
                identifier: "psn-registration-failed",
                summary: "The PS5 rejected this device's saved registration.",
                guidance: "Link this device to the PS5 again, then Connect again."
            )

        default:
            PlayStationQuitReasonExplanation(
                code: code,
                identifier: "unclassified-native-failure",
                summary: "Remote Play ended with a reason Farframe does not recognize.",
                guidance: "Try Connect again, and send a Farframe report if it repeats."
            )
        }
    }
}
