import ExperienceDomain
import Foundation
import Testing

@Test
func streamResolutionsPreserveKnownGoodDimensions() {
    #expect(StreamResolution.p360.width == 640)
    #expect(StreamResolution.p360.height == 360)
    #expect(StreamResolution.p540.width == 960)
    #expect(StreamResolution.p540.height == 540)
    #expect(StreamResolution.p720.width == 1_280)
    #expect(StreamResolution.p720.height == 720)
    #expect(StreamResolution.p1080.width == 1_920)
    #expect(StreamResolution.p1080.height == 1_080)
}

@Test
func bitratePresetsPreserveKnownGoodConnectTimeValues() {
    #expect(StreamBitratePreset.balanced.targetBitrateKbps == 12_000)
    #expect(StreamBitratePreset.high.targetBitrateKbps == 15_000)
    #expect(StreamBitratePreset.maximum.targetBitrateKbps == 30_000)
}

@Test
func namedProfilesPreserveKnownGoodResolvedValues() {
    #expect(QualityProfile.lowBandwidth.resolution == .p720)
    #expect(QualityProfile.lowBandwidth.frameRate == .fps30)
    #expect(QualityProfile.lowBandwidth.targetBitrateKbps == 6_000)
    #expect(QualityProfile.lowBandwidth.dynamicRange == .sdr)

    #expect(QualityProfile.stability.resolution == .p720)
    #expect(QualityProfile.stability.frameRate == .fps60)
    #expect(QualityProfile.stability.targetBitrateKbps == 8_000)
    #expect(QualityProfile.stability.dynamicRange == .sdr)

    #expect(QualityProfile.performance.resolution == .p540)
    #expect(QualityProfile.performance.frameRate == .fps60)
    #expect(QualityProfile.performance.targetBitrateKbps == 4_000)
    #expect(QualityProfile.performance.dynamicRange == .sdr)

    #expect(QualityProfile.default.resolution == .p1080)
    #expect(QualityProfile.default.frameRate == .fps60)
    #expect(QualityProfile.default.targetBitrateKbps == 12_000)
    #expect(QualityProfile.default.dynamicRange == .sdr)
    #expect(QualityProfile.default.targetBitrateMbps == 12)
}

/// The whole point of hoisting the preset out of the three shells: the string
/// the user reads is generated from the bitrate that is actually requested, so
/// the two cannot disagree. A hand-written label could, and did, go stale when
/// Maximum moved from 20 to 30 Mbps.
@Test
func everyPresetDetailStringIsDerivedFromTheProfileItActuallyRequests() {
    for preset in StreamQualityPreset.allCases {
        let profile = preset.profile
        #expect(preset.detail.contains(profile.resolution.rawValue))
        #expect(preset.detail.contains("\(profile.framesPerSecond) FPS"))
        #expect(preset.detail.contains(profile.formattedTargetBitrate))
        // The label must quote the connect-time bitrate, not a rounded or
        // remembered one.
        #expect(profile.formattedTargetBitrate
            == "\(profile.targetBitrateKbps / 1_000) Mbps")
    }
}

@Test
func presetDetailStringsReadExactlyAsTheSettingsPickerShowsThem() {
    #expect(StreamQualityPreset.performance.detail == "540p · 60 FPS · 4 Mbps")
    #expect(StreamQualityPreset.stability.detail == "720p · 60 FPS · 8 Mbps")
    #expect(StreamQualityPreset.balanced.detail == "1080p · 60 FPS · 12 Mbps")
    #expect(StreamQualityPreset.high.detail == "1080p · 60 FPS · 15 Mbps")
    #expect(StreamQualityPreset.maximum.detail == "1080p · 60 FPS · 30 Mbps")
}

@Test
func presetRawValuesStayTheStringsTheShellsAlreadyPersisted() {
    // Renaming any of these would silently orphan an existing user's stored
    // quality preference and drop them back to the default. Reordering them
    // does not: every shell reads a raw value or a bitrate and falls back to an
    // explicit default, never to a position in this list.
    #expect(Set(StreamQualityPreset.allCases.map(\.rawValue))
        == ["performance", "stability", "balanced", "high", "maximum"])
    #expect(StreamQualityPreset(rawValue: "maximum") == .maximum)
    #expect(StreamQualityPreset(rawValue: "performance") == .performance)
}

/// The incident this naming exists to prevent: a user picked the top preset,
/// read a name that promised frame rate, and played a whole session at 540p
/// without ever being told. Every name now leads with the resolution it
/// actually delivers, so even the collapsed one-line picker row is honest.
@Test
func everyPresetNameLeadsWithTheResolutionItActuallyDelivers() {
    for preset in StreamQualityPreset.allCases {
        #expect(preset.displayName.hasPrefix(preset.profile.resolution.rawValue))
    }
    #expect(StreamQualityPreset.performance.displayName == "540p Minimum")
    #expect(StreamQualityPreset.stability.displayName == "720p Low")
    #expect(StreamQualityPreset.balanced.displayName == "1080p Standard")
    #expect(StreamQualityPreset.high.displayName == "1080p High")
    #expect(StreamQualityPreset.maximum.displayName == "1080p Maximum")
}

/// "Performance 60" implied the frame rate was the variable. It never was.
@Test
func noPresetNamePromisesAFrameRateAdvantageOverAnyOther() {
    let frameRates = Set(StreamQualityPreset.allCases.map(\.profile.framesPerSecond))
    #expect(frameRates == [60])
    for preset in StreamQualityPreset.allCases {
        #expect(preset.displayName.contains("60") == false)
        #expect(preset.displayName.lowercased().contains("performance") == false)
        #expect(preset.displayName.lowercased().contains("fps") == false)
    }
}

/// The list has to teach the trade by itself: read down and the picture can
/// only get softer, and the network cost can only fall. A preset inserted out
/// of order would make position meaningless again.
///
/// The ladder runs sharpest-first, which inverts the Low-to-Ultra convention on
/// purpose. A careless pick here is not cheap — an owner took the top item and
/// played a full session at 540p — so the top item is now the good-looking one,
/// and stutter, which announces itself and is one tap to fix, is the failure
/// mode instead of a session quietly played at half resolution.
@Test
func presetOrderIsAMonotonicLadderRunningSharpestFirst() {
    let profiles = StreamQualityPreset.allCases.map(\.profile)
    let heights = profiles.map(\.height)
    let bitrates = profiles.map(\.targetBitrateKbps)
    #expect(heights == heights.sorted(by: >))
    #expect(bitrates == bitrates.sorted(by: >))
    #expect(bitrates == Array(Set(bitrates)).sorted(by: >))
    #expect(StreamQualityPreset.allCases.first == .maximum)
    #expect(StreamQualityPreset.allCases.last == .performance)
    #expect(
        StreamQualityPreset.allCases
            == [.maximum, .high, .balanced, .stability, .performance]
    )
}

/// Exactly one preset carries the app's recommendation, and it is the one a
/// fresh install already selects.
///
/// The marker matters more in the sharpest-first order rather than less.
/// Position and the badge now make two different claims and both are true: the
/// top of the list is the most picture, and this is where most home networks
/// settle. Without the badge, position would again be the only signal, and it
/// would point at the highest network demand in the app.
@Test
func exactlyOnePresetIsRecommendedAndItIsTheFullResolutionDefault() {
    let recommended = StreamQualityPreset.allCases.filter(\.isRecommended)
    #expect(recommended == [.balanced])
    #expect(StreamQualityPreset.balanced.profile.resolution == .p1080)
    // Not the first item. The recommendation has to be a separate signal from
    // position, or inverting the list would have silently deleted it.
    #expect(StreamQualityPreset.allCases.first?.isRecommended == false)
}

/// The footnote has to say which way the list runs. Sharpest-first is not the
/// order a game menu trains people to expect, and a user whose stream stutters
/// needs to be told what to do rather than left to interpret a list.
@Test
func theLadderFootnoteStatesTheOrderAndWhatToDoWhenTheStreamStutters() {
    let footnote = StreamQualityPreset.ladderFootnote
    #expect(footnote.contains("60 FPS"))
    #expect(footnote.contains("sharpest"))
    #expect(footnote.contains("work down"))
}

/// Numbers do not tell a user whether 4 Mbps is a sensible choice for them.
@Test
func everyPresetCarriesATradeoffSentenceDistinctFromItsNumbers() {
    var sentences: Set<String> = []
    for preset in StreamQualityPreset.allCases {
        #expect(preset.tradeoff.isEmpty == false)
        #expect(preset.tradeoff.hasSuffix("."))
        #expect(preset.tradeoff != preset.detail)
        #expect(sentences.insert(preset.tradeoff).inserted)
    }
}

/// "Applies on the next connection" states a rule without its consequence.
/// Mid-session, the notice has to name what the user is still watching.
@Test
func changeNoticeNamesTheStreamTheUserIsActuallyWatching() {
    let idle = StreamQualityPreset.changeNotice(selected: .maximum, active: nil)
    #expect(idle == "Quality is chosen when a connection starts.")

    let unchanged = StreamQualityPreset.changeNotice(selected: .maximum, active: .maximum)
    #expect(unchanged.contains("1080p · 60 FPS · 30 Mbps"))

    let pending = StreamQualityPreset.changeNotice(selected: .maximum, active: .performance)
    #expect(pending.contains("540p Minimum"))
    #expect(pending.contains("540p · 60 FPS · 4 Mbps"))
    #expect(pending.contains("1080p Maximum"))
    #expect(pending.contains("next time you connect"))
}

/// Play styles are macros over the existing controls, so their advertised
/// result must be exactly what applying them writes.
@Test
func playStyleDetailMatchesTheSettingsApplyingItWouldWrite() {
    for style in StreamPlayStyle.allCases {
        #expect(style.detail == "\(style.quality.detail) · Smooth motion \(style.smoothMotionEnabled ? "on" : "off")")
        #expect(style.qualityName == style.quality.displayName)
        #expect(style.rationale.isEmpty == false)
        #expect(style.examples.isEmpty == false)
        #expect(style.symbolName.isEmpty == false)
    }
}

/// The owner's ask was "we just list the stats under each one". A style row
/// that shows only a preset name repeats the failure that cost a Destiny 2
/// session: the numbers have to be on screen at the moment of choosing, and
/// they have to be the preset's own numbers rather than a second copy that can
/// drift away from them.
@Test
func playStyleDetailCarriesResolutionFrameRateBitrateAndSmoothMotion() {
    let competitive = StreamPlayStyle.competitive
    #expect(competitive.detail == "1080p · 60 FPS · 15 Mbps · Smooth motion off")

    let away = StreamPlayStyle.awayFromHome
    #expect(away.detail == "720p · 60 FPS · 8 Mbps · Smooth motion on")

    for style in StreamPlayStyle.allCases {
        let profile = style.quality.profile
        #expect(style.detail.contains(profile.resolution.rawValue))
        #expect(style.detail.contains("\(profile.framesPerSecond) FPS"))
        #expect(style.detail.contains(profile.formattedTargetBitrate))
    }
}

/// The whole point of asking what someone is playing: the answers have to pull
/// the settings in genuinely different directions, or the question is theatre.
@Test
func playStylesResolveToDistinctSettingsAcrossTheLatencyAxis() {
    #expect(StreamPlayStyle.competitive.smoothMotionEnabled == false)
    #expect(StreamPlayStyle.story.smoothMotionEnabled)
    #expect(StreamPlayStyle.everything.smoothMotionEnabled)
    #expect(StreamPlayStyle.awayFromHome.smoothMotionEnabled)

    #expect(StreamPlayStyle.competitive.quality == .high)
    #expect(StreamPlayStyle.story.quality == .maximum)
    #expect(StreamPlayStyle.everything.quality == .balanced)
    #expect(StreamPlayStyle.awayFromHome.quality == .stability)

    // No style routes anyone to the 540p floor. It is a fallback a user opts
    // into knowingly, never something a one-tap button hands them.
    #expect(StreamPlayStyle.allCases.contains { $0.quality == .performance } == false)

    let qualities = Set(StreamPlayStyle.allCases.map(\.quality))
    #expect(qualities.count == StreamPlayStyle.allCases.count)
}

/// The order the owner chose after seeing the step on a device, and the order
/// the first-run step and all three Settings sections show.
///
/// It is deliberately **not** a ladder. The bitrates read 30, 12, 15, 8, and
/// Online multiplayer sits below "A bit of everything" despite asking for more
/// network. That is correct: these are categories a person picks by recognising
/// themselves, not rungs to climb, so they are ordered by how many people each
/// answer fits. Sorting them by bitrate would put the specialist answer second
/// and buy nothing, because every card shows its own numbers.
///
/// This test exists to stop a future reader from "fixing" the order into
/// something monotonic on the assumption that it was meant to be.
@Test
func playStyleOrderIsTheOwnersAndIsNotSortedByNetworkDemand() {
    #expect(
        StreamPlayStyle.allCases == [.story, .everything, .competitive, .awayFromHome]
    )

    let bitrates = StreamPlayStyle.allCases.map(\.quality.profile.targetBitrateKbps)
    #expect(bitrates == [30_000, 12_000, 15_000, 8_000])
    #expect(bitrates != bitrates.sorted(by: >))

    // The two ends still have to make sense: the most picture leads, and the
    // fallback for a thin link is last.
    #expect(StreamPlayStyle.allCases.first == .story)
    #expect(StreamPlayStyle.allCases.first?.quality == .maximum)
    #expect(StreamPlayStyle.allCases.last == .awayFromHome)
}

/// A first-run question whose options do not include the app's own
/// recommendation is a question that disagrees with the rest of the app.
@Test
func exactlyOnePlayStyleIsRecommendedAndItIsTheRecommendedPreset() {
    let recommended = StreamPlayStyle.allCases.filter(\.isRecommended)
    #expect(recommended.count == 1)
    #expect(recommended.first == .everything)
    #expect(recommended.first?.quality.isRecommended == true)
}

/// A style is shown as current by deriving it from the two settings, never by
/// storing one. That is what keeps the feature free of a "Custom" state: nudge
/// a knob by hand and the answer is simply that no style matches.
@Test
func currentPlayStyleIsDerivedFromTheSettingsRatherThanStored() {
    for style in StreamPlayStyle.allCases {
        #expect(
            StreamPlayStyle.matching(
                quality: style.quality,
                smoothMotionEnabled: style.smoothMotionEnabled
            ) == style
        )
    }

    // The 540p floor belongs to no style, and neither does a hand-edited
    // combination that flips smooth motion away from what a style writes.
    #expect(StreamPlayStyle.matching(quality: .performance, smoothMotionEnabled: true) == nil)
    #expect(StreamPlayStyle.matching(quality: .maximum, smoothMotionEnabled: false) == nil)
}

/// Applying a style mid-session lands one half now and one half on reconnect.
/// Saying "applied" without saying that is the same failure as before.
@Test
func playStyleAppliedNoticeSeparatesWhatLandsNowFromWhatWaitsForReconnect() {
    let idle = StreamPlayStyle.competitive.appliedNotice(hasActiveSession: false)
    #expect(idle.contains("1080p High"))
    #expect(idle.contains("1080p · 60 FPS · 15 Mbps"))
    #expect(idle.contains("next time you connect") == false)

    let live = StreamPlayStyle.competitive.appliedNotice(hasActiveSession: true)
    #expect(live.contains("Smooth motion is off now"))
    #expect(live.contains("1080p High"))
    #expect(live.contains("next time you connect"))
}

/// The question is asked in one set of words by every shell and by the
/// first-run step, so that "come back to Settings and change it" points at a
/// section the user recognises as the same thing they answered.
@Test
func playStyleQuestionCopyIsSharedAndNamesTheChoiceAsChangeable() {
    #expect(StreamPlayStyle.question == "What are you playing?")
    #expect(StreamPlayStyle.questionDetail.contains("change"))
}

@Test
func bitrateFormattingKeepsAFractionalMegabitRatherThanRoundingItAway() {
    let profile = QualityProfile(
        id: "fractional",
        displayName: "Fractional",
        resolution: .p720,
        frameRate: .fps30,
        targetBitrateKbps: 4_500,
        dynamicRange: .sdr
    )
    #expect(profile.formattedTargetBitrate == "4.5 Mbps")
}

@Test
func qualityProfileCodableRoundTripPreservesResolvedProfile() throws {
    let profile = QualityProfile(
        id: "hdr-test",
        displayName: "HDR Test",
        resolution: .p1080,
        frameRate: .fps60,
        bitratePreset: .maximum,
        dynamicRange: .hdr
    )

    let encoded = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(QualityProfile.self, from: encoded)
    #expect(decoded == profile)
}
