# GuidedHelp

A standalone SwiftUI package for instructional guides on iPhone, iPad, Mac and visionOS. It has no dependencies on Farframe, streaming, accounts, commerce or native console libraries.

The host supplies `HelpGuide` content, a resource/localization bundle, a binding to a stable step ID, and the Done action. The host owns window/sheet presentation, initial and minimum sizes, progress persistence, and whether a guide appears automatically. The package owns only rendering and bounded Back/Next navigation. It handles a missing or removed step ID by showing the first step, and an empty guide by offering Done.

Content models are Codable and Sendable. Another app can supply its own text, SF Symbols and illustrations without changing this package. Another UI stack can consume an exported content document but must implement its own renderer. SwiftUI code is not an Android/Meta renderer.

Use `HelpGuideView(guide:selectedStepID:assetBundle:onDone:)`. Keep actual business actions outside instructions; Done closes help and must not imply that pairing, a purchase or authentication succeeded. Credentials and live codes never belong in guide state.

For compact phone layouts, author portrait or segmented artwork using the same content IDs, or use native text/items; shrinking a desktop reference image is not sufficient proof of readable phone onboarding. Platform adapters may supply alternate steps or assets under the same guide identity. Review accessibility descriptions whenever artwork changes. Localized content keys resolve in the host's supplied bundle; artwork localization and chrome localization remain explicit integration work.

Validation: `swift test --package-path .`. This package is currently adopted inside Farframe; use in unrelated products remains a reuse candidate until each consumer's build and device checks pass.

## Integration recipe

1. Add a local Swift Package dependency pointing to `Packages/GuidedHelp` and add the `GuidedHelp` product to the consuming target. It can be versioned/extracted as an independent package later; it is not currently a separately published library.
2. Define one stable guide ID, a revision, and stable step IDs. Use a revision for an intentional first-use change; do not reset customer progress for every app build. Keep live credentials/codes out of the model.
3. Put content and assets in the product's shared layer. Include its asset catalog in each consuming target, or pass that product's resource bundle. Include readable accessibility descriptions and localized text keys. The package does not own product artwork or translations.
4. Write a thin platform presenter. It owns dismissal, size, current-page binding and optional first-use state. Reuse the renderer, not a copied Vision window or coordinator.
5. Check navigation, all resource names, accessibility, long text and compact/large layouts on each selected platform. Compilation alone does not approve a phone screenshot layout.

```swift
import GuidedHelp
import SwiftUI

struct ProductGuideSheet: View {
    let guide: HelpGuide
    @Environment(\.dismiss) private var dismiss
    @State private var stepID = "start"

    var body: some View {
        HelpGuideView(guide: guide, selectedStepID: $stepID) { dismiss() }
    }
}
```

A phone/iPad host presents that wrapper with its existing sheet/full-screen flow. A Mac or Vision host uses its own window role and closes only that role. `VisionSonySignInGuide` and `VisionPlayerControlsGuide` demonstrate the latter. There is no global singleton, automatic analytics, network call, or global completion state in the package.

## Current consumers and limits

| Consumer | Content | Presentation / proof |
| --- | --- | --- |
| Farframe sign-in help | `Apps/Shared/Sources/FarframeHelpGuides.swift`; five sample-only illustrations | Vision independent window; owner accepted the pre-extraction 1.4 (3) flow; refactored targets compile |
| Farframe player reference | `Apps/Vision/Sources/Player/VisionPlayerControlsGuide.swift`; native rows from `VisionPlayerControlReference` | Vision first streaming session per guide revision, plus Customize Controls → Controls guide; device check remains open |
| Farframe iPhone/iPad and Mac | Shared sign-in content and catalog are target inputs | Compile-verified foundation only; platform presenters and compact artwork review remain to be selected |
| Other products | Their own guide definitions/assets | Reuse candidate; no unrelated app was changed or certified |
| Non-Swift platforms | Codable content schema | Requires another renderer and platform-specific content; no Meta/Android runtime supplied |

The current new instructions and artwork use English fallback. Existing app translations are preserved. Localization of instruction content and image text is a separate explicit content task; adding a package does not translate artwork.
