import GuidedHelp

/// Shared product content; authentication and presentation belong to platform hosts.
enum FarframeHelpGuides {
    static let playStationSignIn = HelpGuide(
        id: "farframe.playstation-sign-in", revision: 1, title: "Sign-in help",
        footer: "Illustrated reference · Use your own email and code",
        steps: [
            HelpGuideStep(id: "email", title: "Enter your email and sign in.",
                illustration: HelpGuideIllustration(assetName: "SignInGuideEmail",
                    accessibleDescription: "Enter your email in Sign-In ID, tap Next, then choose Sign In with Passkey. The illustrated email address is an example.", usesDarkBacking: true)),
            HelpGuideStep(id: "code-and-email", title: "Keep the code. Send the email.",
                message: "If Sony shows a QR code:",
                illustration: HelpGuideIllustration(assetName: "SignInGuideCodeAndEmail",
                    accessibleDescription: "Keep the number below the QR code in the original window. You will need it in step 5. Tap Send Sign-In Email and keep this window open. The illustrated number is an example; use your own code.", usesDarkBacking: true)),
            HelpGuideStep(id: "open-email", title: "Open Sony’s email. Tap Sign In.",
                illustration: HelpGuideIllustration(assetName: "SignInGuideOpenEmail",
                    accessibleDescription: "Open the email titled Request to Sign In with Passkey, then tap its Sign In button.", usesDarkBacking: true)),
            HelpGuideStep(id: "passkey", title: "Finish signing in with your passkey.",
                illustration: HelpGuideIllustration(assetName: "SignInGuidePasskey",
                    accessibleDescription: "In Safari, confirm your email and tap Next if asked. Choose Sign In with Passkey, then confirm Use Passkey in the system dialog.", usesDarkBacking: true)),
            HelpGuideStep(id: "enter-code", title: "Enter your code, then tap OK.",
                illustration: HelpGuideIllustration(assetName: "SignInGuideEnterCode",
                    accessibleDescription: "Read your number below the QR code in the original window. Enter the same number in Safari, then tap OK. Use your own code, not the illustrated example. Return to Farframe to finish pairing.", usesDarkBacking: true)),
        ]
    )
}
