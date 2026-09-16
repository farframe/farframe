# Native arena render harness

Isolated visionOS simulator app. Its XcodeGen spec compiles the exact production exterior, materials, lighting, screen rig and picker files by reference. It has no provider, decoder, account or commerce code and is not a Farframe app target. Production entry and signed-access checks remain unchanged.

From the repository root, generate and build outside Git:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
ARENA_LAB_ROOT=$(mktemp -d /tmp/FarframeArenaLab.XXXXXX)
ARENA_LAB_SOURCE="$PWD/Code/RemotePlay/Tests/Vision/ArenaRenderHarness"
mkdir -p "$ARENA_LAB_ROOT/project"
xcodegen generate --quiet --spec "$ARENA_LAB_SOURCE/project.yml" --project "$ARENA_LAB_ROOT/project"
# XcodeGen resolves this root source relative to the external project directory.
ln -s "$ARENA_LAB_SOURCE/ArenaRenderHarness.swift" "$ARENA_LAB_ROOT/project/ArenaRenderHarness.swift"
xcodebuild -quiet -jobs 6 -project "$ARENA_LAB_ROOT/project/FarframeArenaRenderHarness.xcodeproj" \
  -scheme FarframeArenaRenderHarness -configuration Debug \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath "$ARENA_LAB_ROOT/build" CODE_SIGNING_ALLOWED=NO build
```

Use `xcrun simctl` to install only on a dedicated, booted visionOS simulator. Bundle ID: `com.unshackledpursuit.farframe.arena-render-harness`. Launch with `--style quietHorizon`, `orbitalTerrace` or `lightSculpture`. Optional `--view left/right` rotates the whole root ±0.50 radians relative to the fixed native viewpoint for an oblique geometry/material comparison; this is not tracked head movement. The labelled fixture panel remains part of every capture.

`Documents/render-metrics.json` is written after the selected exterior mounts. Wait for the current launch's timestamp and style before capturing with `simctl io <simulator-UDID> screenshot <output.png>`. Metrics count scene entities/models and the screen; they do not measure frame rate or GPU memory.

These renders prove only the static components shown, not customer access, live video, device comfort, picker gestures or performance. Controller switching/failure/cancellation tests run through the canonical integration verifier. Physical acceptance remains separate.


Architectural Wrap: `--wrap` selects the new coverage, `--off` checks the original fallback; `--palette black|white|purple|split` selects synthetic linear-color fixtures. Without `--palette`, the existing landscape remains visible. Cinema is the starting position; `--seated` selects the old near position. Original pillars are the default; `--pillars` enables reactive replacements. `--view side` captures the side bays. `--small` exercises the minimum screen size. This harness validates eight exact opaque partitions, absence of all fixed wash panels, screen-following wide glow and black-frame clearing, twenty original/replacement restoration cycles and an invalid-asset fallback before writing metrics. The production state/UI check source is `../VisionArenaWrapStateChecks.swift`; run it from an isolated tablet fixture containing production Vision sources, never a shipping app target.
