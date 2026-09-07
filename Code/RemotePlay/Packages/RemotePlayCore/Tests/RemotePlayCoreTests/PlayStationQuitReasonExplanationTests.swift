import Testing

@testable import PlayStationRemotePlay

/// The numbering is the pinned chiaki-ng `ChiakiQuitReason` declaration order
/// (`a75d628`). If the source lock moves and the enum is reordered, this test is
/// the thing that has to be re-derived from the header, not guessed.
@Test("Every pinned native quit code reads back as its own stage")
func nativeQuitCodesMapToDistinctStages() {
    let expected: [Int32: String] = [
        0: "none",
        1: "stopped",
        2: "session-request-unknown",
        3: "session-request-refused",
        4: "remote-play-in-use",
        5: "remote-play-crashed",
        6: "version-mismatch",
        7: "control-unknown",
        8: "control-connect-failed",
        9: "control-connection-refused",
        10: "stream-connection-unknown",
        11: "remote-disconnected",
        12: "remote-shutdown",
        13: "psn-registration-failed",
    ]

    for (code, identifier) in expected {
        let explanation = PlayStationQuitReasonExplanation.forCode(code)
        #expect(explanation.code == code)
        #expect(explanation.identifier == identifier)
    }

    let identifiers = Set(expected.keys.map {
        PlayStationQuitReasonExplanation.forCode($0).identifier
    })
    #expect(identifiers.count == expected.count)
}

/// The owner hit this after a storm cut mains power: the PS5 was fully off, not
/// in rest, so no amount of Wake could reach it. Waiting longer and checking the
/// network are both useless advice in that case, so the text has to name it.
@Test("The code that ended the owner's connect names the powered-off console")
func sessionRequestUnknownIsReadable() {
    let explanation = PlayStationQuitReasonExplanation
        .forCode(PlayStationNativeQuitCode.sessionRequestUnknown)
    #expect(explanation.code == 2)
    #expect(explanation.identifier == "session-request-unknown")
    #expect(explanation.summary.contains("did not answer"))
    #expect(explanation.message.contains("code 2"))
    // The case the user cannot fix by waiting has to be stated, not implied.
    #expect(explanation.guidance.contains("rest mode"))
    #expect(explanation.guidance.contains("lost power"))
    #expect(explanation.guidance.contains("by hand"))
    // The two recoverable conditions still have to be there beside it.
    #expect(explanation.guidance.contains("ten seconds"))
    #expect(explanation.guidance.contains("same network"))
}

@Test("An unmapped code degrades to an honest sentence rather than a number")
func unmappedCodeStaysHonest() {
    let explanation = PlayStationQuitReasonExplanation.forCode(9_999)
    #expect(explanation.identifier == "unclassified-native-failure")
    #expect(explanation.message.contains("code 9999"))
    #expect(explanation.summary.contains("does not recognize"))
}

@Test("Quit reasons carry their explanation without changing classification")
func quitReasonsExposeExplanations() {
    #expect(PlayStationNativeQuitReason.normal.explanation.identifier == "stopped")
    #expect(
        PlayStationNativeQuitReason.remoteDisconnected.explanation.identifier
            == "remote-disconnected"
    )
    #expect(
        PlayStationNativeQuitReason.nativeFailure(code: 4).explanation.identifier
            == "remote-play-in-use"
    )
}

/// A shell shows `message`, so it has to survive being read aloud: one summary
/// sentence, one guidance sentence, and the code last.
@Test("Every explanation message is a complete, code-bearing sentence")
func explanationMessagesAreWellFormed() {
    for code in Int32(0)...Int32(14) {
        let explanation = PlayStationQuitReasonExplanation.forCode(code)
        #expect(explanation.summary.hasSuffix("."))
        #expect(explanation.guidance.hasSuffix("."))
        #expect(explanation.message.hasSuffix("(code \(code))"))
        #expect(explanation.message.contains("\n") == false)
    }
}
