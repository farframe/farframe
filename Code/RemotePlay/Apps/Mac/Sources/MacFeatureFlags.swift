/// Compile-time product switches for the Mac shell.
///
/// The code behind an off switch stays in the codebase and keeps compiling;
/// only its user-facing surface is withheld from the shipping build.
enum MacFeatureFlags {
    /// Keyboard gameplay exists but is not a supported 1.0 input path, so its
    /// toolbar button, sheet, status text, and Settings toggle are hidden.
    /// Flip this on to resume keyboard work without re-plumbing the views.
    static let keyboardGameplayUI = false
}
