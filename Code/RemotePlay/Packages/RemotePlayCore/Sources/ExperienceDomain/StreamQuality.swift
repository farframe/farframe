import Foundation

public enum StreamResolution: String, Codable, CaseIterable, Identifiable, Sendable {
    case p360 = "360p"
    case p540 = "540p"
    case p720 = "720p"
    case p1080 = "1080p"

    public var id: String { rawValue }

    public var width: Int {
        switch self {
        case .p360: 640
        case .p540: 960
        case .p720: 1_280
        case .p1080: 1_920
        }
    }

    public var height: Int {
        switch self {
        case .p360: 360
        case .p540: 540
        case .p720: 720
        case .p1080: 1_080
        }
    }
}

public enum StreamFrameRate: Int, Codable, CaseIterable, Identifiable, Sendable {
    case fps30 = 30
    case fps60 = 60

    public var id: Int { rawValue }
}

public enum StreamBitratePreset: Int, Codable, CaseIterable, Identifiable, Sendable {
    case balanced = 12_000
    case high = 15_000
    case maximum = 30_000

    public var id: Int { rawValue }
    public var targetBitrateKbps: Int { rawValue }

    public var displayName: String {
        switch self {
        case .balanced: "Balanced"
        case .high: "High"
        case .maximum: "Maximum"
        }
    }
}

public enum StreamDynamicRange: String, Codable, CaseIterable, Sendable {
    case sdr
    case hdr
}

/// Client-side spatial reconstruction of the decoded picture. The console's
/// encode is fixed at 1080p by the Remote Play protocol, so this is the only
/// resolution lever the app has, and it is presentation-side only: the stream,
/// the bitrate, and the console are untouched.
///
/// User-facing wording is deliberately "Video Enhancement" rather than
/// "upscaling" or any resolution number. Naming an output resolution would
/// imply the console is sending more than it is.
public enum StreamUpscaling: String, Codable, CaseIterable, Identifiable, Sendable {
    /// No GPU pass. The frame reaches the display exactly as decoded.
    case off
    /// Runs only while the video is being magnified enough for the work to be
    /// visible. Small windows keep the GPU idle, which is also the defense
    /// against sustained thermal load on a headset.
    case automatic
    /// Runs on every frame regardless of how large the video is drawn.
    case enhanced

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .automatic: "Automatic"
        case .enhanced: "Enhanced"
        }
    }

    public var detail: String {
        switch self {
        case .off: "The picture is shown exactly as the console sends it."
        case .automatic: "Enhances only when the video is enlarged enough to benefit."
        case .enhanced: "Always enhances, including in small windows."
        }
    }

    /// The one-line explanation that has to sit next to the control. It is the
    /// honest description and it keeps the feature from reading as a 4K claim.
    public static let settingFootnote =
        "Sharpens the stream using your device's GPU. The console still sends 1080p."
}

/// The quality presets the settings picker offers on every platform.
///
/// `detail` is derived from the profile this preset resolves to rather than
/// restated as prose. That matters: each shell used to carry a byte-identical
/// copy of this enum with the bitrate written out by hand, so raising Maximum
/// from 20 to 30 Mbps meant editing the real constant plus three display
/// strings, and nothing checked that the four agreed. Now the number lives in
/// `StreamBitratePreset` only and the label cannot drift from it.
///
/// Raw values are the strings the shells have always persisted, so an existing
/// user's stored preference is read back unchanged.
///
/// The names carry their resolution because the picker collapses to a single
/// line on iOS and visionOS, and that line is often the only thing a user
/// reads. The previous name for the lowest preset, "Performance 60", promised
/// a frame-rate advantage that does not exist — every preset here streams at
/// 60 FPS — while quietly halving the resolution to 540p. A name that flatters
/// a downgrade is worse than no name at all, so the resolution now leads.
public enum StreamQualityPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    // Declaration order is the picker's order and it is the ladder, run best
    // first: the resolution never rises and the bitrate never rises as you
    // read down. Reading down gives up detail and buys network headroom, with
    // nothing else moving.
    //
    // Sharpest-first inverts the Low-to-Ultra convention every game menu uses,
    // and it is deliberate. The convention assumes a careless pick is cheap.
    // Here it was not: an owner took the top item, played a full session at
    // 540p, and only learned from the in-stream HUD afterwards. Leading with
    // the floor puts the worst outcome one careless tap away, while leading
    // with the ceiling makes the careless pick the good-looking one and leaves
    // stutter — which announces itself immediately and is one tap to fix — as
    // the failure mode instead of a session quietly played at half resolution.
    // The trade is real: this order asks more of the network by default. The
    // footnote and the recommendation below are what carry a user down it.
    case maximum
    case high
    case balanced
    case stability
    case performance

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .performance: "540p Minimum"
        case .stability: "720p Low"
        case .balanced: "1080p Standard"
        case .high: "1080p High"
        case .maximum: "1080p Maximum"
        }
    }

    /// What this preset buys and what it costs, in one sentence, shown next to
    /// the numbers at the moment of choosing. The numbers alone do not tell a
    /// user whether 4 Mbps is a sensible choice for them; this does.
    public var tradeoff: String {
        switch self {
        case .performance:
            "The softest picture Farframe can send. Only worth choosing when the network cannot hold anything better, such as a phone hotspot."
        case .stability:
            "Gives up visible sharpness to keep the stream moving on a busy or distant Wi-Fi network."
        case .balanced:
            "Full resolution at a bitrate most home Wi-Fi networks can hold. Land here if the ones above stutter."
        case .high:
            "Holds detail better when the camera whips around. Wants a strong 5 GHz network without much else on it."
        case .maximum:
            "The sharpest picture Remote Play can send. It is also the quickest to stutter if the network dips."
        }
    }

    /// The one preset the app puts its name behind. It is the same profile a
    /// fresh install already selects.
    ///
    /// It stays on 1080p Standard now that the ladder runs sharpest-first, and
    /// the marker matters more in this order rather than less. Position and the
    /// badge now make two different claims and both are true: the top of the
    /// list is the most picture, and this is where most home networks actually
    /// settle. Without the badge, position would once again be the only signal,
    /// and it would be pointing at the highest network demand in the app.
    ///
    /// Moving it to 1080p Maximum was considered and rejected: the app would
    /// then recommend a preset a fresh install does not select, and changing
    /// which preset a fresh install selects is a tuning decision with device
    /// evidence attached, not a presentation one.
    public var isRecommended: Bool { self == .balanced }

    public var profile: QualityProfile {
        switch self {
        case .performance:
            .performance
        case .stability:
            .stability
        case .balanced:
            .default
        case .high:
            QualityProfile(
                id: rawValue,
                displayName: displayName,
                resolution: .p1080,
                frameRate: .fps60,
                bitratePreset: .high,
                dynamicRange: .sdr
            )
        case .maximum:
            QualityProfile(
                id: rawValue,
                displayName: displayName,
                resolution: .p1080,
                frameRate: .fps60,
                bitratePreset: .maximum,
                dynamicRange: .sdr
            )
        }
    }

    /// The one-line summary under the preset's name, e.g. "1080p · 60 FPS ·
    /// 30 Mbps". Every part of it is read off `profile`.
    public var detail: String {
        let resolved = profile
        return "\(resolved.resolution.rawValue) · \(resolved.framesPerSecond) FPS · \(resolved.formattedTargetBitrate)"
    }

    /// Sits under the picker. It kills the misconception the old naming
    /// created — that a preset might trade resolution for a higher frame rate,
    /// which none of them do — and it states which way the list runs, because
    /// sharpest-first is not the order a game menu trains people to expect.
    /// The last clause is the important one: it gives a user with a stuttering
    /// stream something to do rather than a list to interpret.
    public static let ladderFootnote =
        "Every preset streams at 60 FPS. What changes is how much detail the console sends, and how much network that needs. The list starts with the sharpest picture; if the stream stutters, work down it."

    /// What a quality change means *right now*. "Quality changes apply on the
    /// next connection" states a rule without stating its consequence: a user
    /// who changes this mid-session is still watching the old stream and has
    /// no way to tell. This names both halves.
    public static func changeNotice(
        selected: StreamQualityPreset,
        active: StreamQualityPreset?
    ) -> String {
        guard let active else {
            return "Quality is chosen when a connection starts."
        }
        guard active != selected else {
            return "This session is streaming at \(selected.detail)."
        }
        return """
        This session stays at \(active.displayName) (\(active.detail)). \
        \(selected.displayName) starts the next time you connect.
        """
    }
}

/// A one-tap answer to a question a player can actually answer — what are you
/// playing — mapped onto the two settings that decide how the stream feels but
/// that nobody can reason about cold.
///
/// Deliberately an action rather than a stored mode. Applying one writes the
/// same preferences the direct controls write, so the controls below stay the
/// single source of truth, nothing has to be migrated, and there is no
/// "Custom" state to drift out of sync the moment a user nudges a knob. The
/// only thing the app remembers about the question is that it was asked.
///
/// The set is four because four is how many genuinely different answers the two
/// underlying settings can give. Working backwards from the settings rather
/// than forwards from genre names is the only way to keep the promise that
/// picking a different option changes something: a fifth "kind of game" would
/// have to resolve to a profile one of these four already owns, and an option
/// that changes nothing is worse than no option, because it teaches the user
/// that the question is decoration.
public enum StreamPlayStyle: String, CaseIterable, Identifiable, Sendable {
    // Declaration order is the order the first-run step and every Settings
    // section show, and it is the owner's, chosen from seeing the step on a
    // device.
    //
    // Unlike the quality ladder above, this is not sorted by network demand and
    // must not be. The bitrates read 30, 12, 15, 8: Online multiplayer sits
    // below "A bit of everything" while asking for more network than it. These
    // are categories a person picks by recognising themselves, not rungs to
    // climb, so they run from the answer that fits the most people to the one
    // that fits the fewest, with the fallback for a thin link last. Sorting by
    // bitrate would promote the specialist answer and buy nothing, because
    // every card already shows its own numbers.

    /// Picture first. The only style that asks for the full 30 Mbps.
    case story
    /// The app's own recommendation, and the honest answer to "a bit of
    /// everything". Without it no one-tap path reaches the preset the quality
    /// ladder recommends and a fresh install already uses, which would leave
    /// the first-run question quietly disagreeing with the rest of the app.
    case everything
    /// Reaction first. The only style that turns smooth motion off.
    case competitive
    /// Favors stream stability on a busy or weak network.
    /// The persisted identifier remains unchanged for existing settings.
    case awayFromHome

    public var id: String { rawValue }

    /// The question these answer. Kept here so all three shells and the
    /// first-run step ask it in exactly the same words.
    public static let question = "What are you playing?"

    /// The one line under the question. It has to say that this is a shortcut
    /// rather than a mode, or a user will go looking for a way to turn it off.
    public static let questionDetail = """
    Pick the closest one. It sets your picture quality and how the stream handles a busy network. \
    Nothing is locked in — you can change either by hand, or come back and pick a different one.
    """

    public var displayName: String {
        switch self {
        case .story: "Story and RPG"
        case .everything: "A bit of everything"
        case .competitive: "Online multiplayer"
        case .awayFromHome: "Busy network"
        }
    }

    /// The preset this style selects.
    ///
    /// Online multiplayer stops at 1080p High rather than Maximum on purpose:
    /// on a shared home network the extra 15 Mbps buys detail the player is not
    /// looking at during a firefight, and buys it with congestion, which is
    /// the thing most likely to cost them the fight.
    public var quality: StreamQualityPreset {
        switch self {
        case .story: .maximum
        case .everything: .balanced
        case .competitive: .high
        case .awayFromHome: .stability
        }
    }

    /// Smooth motion holds frames before showing them, so it trades input lag
    /// for steadiness. That is the right trade for a cutscene and the wrong
    /// one for a duel.
    public var smoothMotionEnabled: Bool {
        switch self {
        case .story, .everything, .awayFromHome: true
        case .competitive: false
        }
    }

    /// The one style the app puts its name behind, for the same reason the
    /// quality ladder marks one: without it, position is the only cue, and the
    /// person who does not see themselves in any of the specific answers needs
    /// somewhere safe to land that is not the Skip button.
    public var isRecommended: Bool { self == .everything }

    public var symbolName: String {
        switch self {
        case .story: "book.pages"
        case .everything: "gamecontroller"
        case .competitive: "scope"
        case .awayFromHome: "wifi.exclamationmark"
        }
    }

    /// Which games this actually means. The owner's complaint about the old
    /// quality picker was that "Stability versus Balanced" is not a question a
    /// person can answer; naming real genres is what makes this one answerable.
    public var examples: String {
        switch self {
        case .story: "RPGs, adventures, anything with cutscenes and a lot of reading"
        case .everything: "A mixed library on ordinary home Wi-Fi"
        case .competitive: "Shooters, fighting games, anything ranked"
        case .awayFromHome: "Shared home Wi-Fi or a weaker connection"
        }
    }

    /// Why someone would pick this, in the terms they think in. One sentence:
    /// four of these are read one after another on a phone, and a paragraph
    /// each turns a question into a document.
    public var rationale: String {
        switch self {
        case .story:
            "The sharpest picture Remote Play can send, because a held frame costs you nothing when nobody is shooting back."
        case .everything:
            "Full resolution at a bitrate most home networks carry without complaint. Land here if the sharper one stutters."
        case .competitive:
            "Nothing is held between your thumb and the game, and it leaves network headroom rather than chasing the last of it."
        case .awayFromHome:
            "Gives up sharpness to keep the session alive, which is all that matters when the link is thin."
        }
    }

    /// The numbers this style resolves to, read straight off the preset so the
    /// row cannot advertise a stream different from the one applying it writes.
    /// This is the "list the stats under each one" half of the question: the
    /// user compares outcomes rather than trusting four labels.
    public var detail: String {
        "\(quality.detail) · Smooth motion \(smoothMotionEnabled ? "on" : "off")"
    }

    /// The named preset this style lands on, so someone who opens the quality
    /// ladder afterwards recognises the row that is now selected.
    public var qualityName: String { quality.displayName }

    /// The style whose settings these already are, if any.
    ///
    /// This is how a style can be shown as "current" without storing one.
    /// Nothing matches after a user nudges quality or smooth motion by hand,
    /// which is the correct answer: they are no longer on a style, and the
    /// direct controls remain the record of what is set.
    public static func matching(
        quality: StreamQualityPreset,
        smoothMotionEnabled: Bool
    ) -> StreamPlayStyle? {
        allCases.first {
            $0.quality == quality && $0.smoothMotionEnabled == smoothMotionEnabled
        }
    }

    /// Shown after applying. Smooth motion takes effect on the live stream and
    /// quality does not, and a user who is told "applied" without being told
    /// that will reasonably believe both landed.
    public func appliedNotice(hasActiveSession: Bool) -> String {
        let smoothMotion = smoothMotionEnabled ? "on" : "off"
        guard hasActiveSession else {
            return "\(displayName) set. Quality is \(qualityName) (\(quality.detail)), smooth motion \(smoothMotion)."
        }
        return """
        \(displayName) set. Smooth motion is \(smoothMotion) now; \
        \(qualityName) (\(quality.detail)) starts the next time you connect.
        """
    }
}

/// A resolved connect-time profile. Codec choice remains provider-specific.
public struct QualityProfile: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let resolution: StreamResolution
    public let frameRate: StreamFrameRate
    public let targetBitrateKbps: Int
    public let dynamicRange: StreamDynamicRange

    public init(
        id: String,
        displayName: String,
        resolution: StreamResolution,
        frameRate: StreamFrameRate,
        targetBitrateKbps: Int,
        dynamicRange: StreamDynamicRange
    ) {
        self.id = id
        self.displayName = displayName
        self.resolution = resolution
        self.frameRate = frameRate
        self.targetBitrateKbps = targetBitrateKbps
        self.dynamicRange = dynamicRange
    }

    public init(
        id: String,
        displayName: String,
        resolution: StreamResolution,
        frameRate: StreamFrameRate,
        bitratePreset: StreamBitratePreset,
        dynamicRange: StreamDynamicRange
    ) {
        self.init(
            id: id,
            displayName: displayName,
            resolution: resolution,
            frameRate: frameRate,
            targetBitrateKbps: bitratePreset.targetBitrateKbps,
            dynamicRange: dynamicRange
        )
    }

    public var width: Int { resolution.width }
    public var height: Int { resolution.height }
    public var framesPerSecond: Int { frameRate.rawValue }
    public var targetBitrateMbps: Double { Double(targetBitrateKbps) / 1_000.0 }

    /// The bitrate as a user-facing string, e.g. "30 Mbps". Whole values lose
    /// the decimal point; anything else keeps one place rather than rounding
    /// away a difference the user chose.
    public var formattedTargetBitrate: String {
        let mbps = targetBitrateMbps
        let amount = mbps == mbps.rounded()
            ? String(Int(mbps))
            : String(format: "%.1f", mbps)
        return "\(amount) Mbps"
    }

    public static let lowBandwidth = QualityProfile(
        id: "low-bandwidth",
        displayName: "Low-Bandwidth",
        resolution: .p720,
        frameRate: .fps30,
        targetBitrateKbps: 6_000,
        dynamicRange: .sdr
    )

    public static let stability = QualityProfile(
        id: "stability",
        displayName: "720p Low",
        resolution: .p720,
        frameRate: .fps60,
        targetBitrateKbps: 8_000,
        dynamicRange: .sdr
    )

    /// The floor. Half resolution and a third of the standard bitrate, for a
    /// network that cannot carry more — a hotspot, a hotel, a link that is
    /// already stuttering at 720p.
    ///
    /// This profile was originally added to answer a high-frame-rate question
    /// and was named for that framing, which was a mistake worth recording:
    /// it does not buy frames. Every preset in `StreamQualityPreset` runs at
    /// 60 FPS, so the only thing 540p buys is headroom, and the only thing it
    /// costs is the picture. Nothing here synthesizes frames or makes a
    /// 120/240 FPS claim; the PS5 Remote Play stream is 60 FPS throughout.
    public static let performance = QualityProfile(
        id: "performance",
        displayName: "540p Minimum",
        resolution: .p540,
        frameRate: .fps60,
        targetBitrateKbps: 4_000,
        dynamicRange: .sdr
    )

    public static let `default` = QualityProfile(
        id: "default",
        displayName: "Default",
        resolution: .p1080,
        frameRate: .fps60,
        bitratePreset: .balanced,
        dynamicRange: .sdr
    )
}
