/// Compile-time product switches for the iPhone and iPad shell.
///
/// The code behind an off switch stays in the codebase and keeps compiling and
/// testing; only its user-facing surface is withheld from the shipping build.
/// This mirrors `MacFeatureFlags` deliberately, so the two shells can be turned
/// on together when the same proof arrives.
enum MobileFeatureFlags {
    /// Keyboard gameplay: a hardware keyboard mapped onto the virtual
    /// controller. Hidden, and the input path is closed with it.
    ///
    /// **Why it is off.** The owner's instruction is that it must not be listed
    /// unless it demonstrably works, and nobody has ever pressed a key on a
    /// physical iPhone or iPad with this build. The Mac has shipped the same
    /// adapter behind `MacFeatureFlags.keyboardGameplayUI = false` since 1.0,
    /// which is exactly why a keyboard did nothing there when it was tried: the
    /// toolbar button, the sheet, the status text and the Settings toggle are
    /// all withheld and `setKeyboardGameplayFocus` is passed a hard `false`.
    /// Widening the adapter to iOS gave iPhone and iPad a *visible* toggle for
    /// a path with no more proof behind it than the Mac's, which is the one
    /// thing that must not ship.
    ///
    /// **What is already established.** The mapping is the only mechanism
    /// available: the pinned bridge exposes exactly one input entry point,
    /// `rp_chiaki_session_set_controller_state`, and no keyboard channel at
    /// all, so the console can never see a keyboard as a keyboard — only as
    /// controller buttons. The snapshot a keyboard produces is merged into the
    /// same `ControllerSnapshot` a DualSense produces and travels the same
    /// delivery loop, which is `DEVICE VERIFIED` on iPhone. `GCKeyboard` is
    /// available on iPadOS, and the adapter and its mapping are unit-tested.
    ///
    /// **What is not established, and is all that is missing.** That iPadOS
    /// actually delivers key events to `keyChangedHandler` while a stream is
    /// running rather than consuming them itself, and that the result feels
    /// like a controller. Both need a Magic Keyboard and one session. When they
    /// are observed, flip this to `true`, flip `MacFeatureFlags` with it, and
    /// nothing else has to change.
    static let keyboardGameplayUI = false
}
