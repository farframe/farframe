/// Names and symbols shared by the real player and its instructional guide.
/// Actions and current state remain in the player/coordinator.
struct VisionPlayerControlReference {
    let title: String
    let symbol: String
    let detail: String
    var assetName: String? = nil

    static let customize = Self(title: "Customize Controls", symbol: "slider.horizontal.3",
        detail: "Choose which buttons are shown. Open Video Settings or reopen this guide here.")
    static let move = Self(title: "Move Controls", symbol: "line.3.horizontal",
        detail: "Pinch and drag this handle to any edge of the picture. It moves the controls, not the window.")
}

extension VisionPlayerControlID {
    var reference: VisionPlayerControlReference {
        switch self {
        case .recordGameplay: VisionPlayerControlReference(title: "Record Game Window", symbol: "record.circle", detail: "Record the game picture and audio to Photos. Tap again to stop. Tap the game picture to hide or show the recording timer.")
        case .immersive:
            .init(title: "Immersive", symbol: "cube.transparent",
                  detail: "Choose Ambient glow or an immersive environment. Dimming is inside Mixed.")
        case .psMenu, .psHome:
            .init(title: "PS Home", symbol: "gamecontroller", detail: "Opens the console control center")
        case .showMain:
            .init(title: "Farframe Home", symbol: "macwindow",
                  detail: "Brings Farframe Home and Settings to the front", assetName: "FARFRAME_FF_Mirror")
        case .streamHUD:
            .init(title: "Stats", symbol: "chart.xyaxis.line", detail: "Shows live video, audio, and controller health")
        case .volume:
            .init(title: "Volume", symbol: "speaker.wave.2.fill", detail: "Tap to mute or unmute. Pinch and drag left or right to adjust.\n\nIn-app volume is separate from headset volume.")
        case .sleep:
            .init(title: "End Session", symbol: "moon.zzz.fill",
                  detail: "Choose Rest and Disconnect, or Disconnect Only to leave the PS5 awake.")
        case .disconnect:
            .init(title: "Disconnect", symbol: "cable.connector.slash", detail: "Disconnects and leaves the console awake")
        case .psOptions:
            .init(title: "Options", symbol: "line.3.horizontal", detail: "Console Options button")
        case .psCreate:
            .init(title: "PS5 Capture Menu", symbol: "camera", detail: "Opens Create on the PS5. Console clips stay on the PS5.")
        case .copyDiagnosis:
            .init(title: "Copy Diagnosis", symbol: "doc.on.doc", detail: "Puts the full stream diagnosis on the clipboard as plain text")
        }
    }
}
