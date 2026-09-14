/// Startup breadcrumbs contain only closed, app-defined values. Native log
/// strings, addresses and authentication material never cross this boundary.
public enum PlayStationConnectionStage: Int32, Equatable, Sendable {
    case requestingSession = 1
    case requestSent = 2
    case sessionAccepted = 3
    case startingControl = 4
    case measuringNetwork = 5
    case networkChecked = 6
    case streamHandshake = 7
    case streamAccepted = 8
    case streamInfo = 9
    case requestConnectFailed = 101
    case requestSendFailed = 102
    case responseMissing = 103
    case responseInvalid = 104
    case nonceInvalid = 105
    case streamReplyMissing = 106

    public var summary: String {
        switch self {
        case .requestingSession: "Requesting a session"
        case .requestSent: "Waiting for the console response"
        case .sessionAccepted: "Console accepted the session"
        case .startingControl: "Opening the control channel"
        case .measuringNetwork: "Checking the network path"
        case .networkChecked: "Preparing the stream"
        case .streamHandshake: "Negotiating the stream"
        case .streamAccepted: "Waiting for stream information"
        case .streamInfo: "Stream information received"
        case .requestConnectFailed: "Could not reach the console service"
        case .requestSendFailed: "Could not send the session request"
        case .responseMissing: "No session response received"
        case .responseInvalid: "Console response was unreadable"
        case .nonceInvalid: "Console response could not be verified"
        case .streamReplyMissing: "No stream handshake response"
        }
    }
}
