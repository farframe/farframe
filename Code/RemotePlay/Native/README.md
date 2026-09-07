# Native Runtime Inputs

This directory owns the reproducible native boundary required by `CORE-100 / PSR-100`.

`Patches/` contains byte-for-byte source snapshots. The two `known-good-*` patches are the complete tracked working-tree diffs captured by the immutable baseline archive. The four `2026-06-22` component patches are earlier research inputs retained for reconciliation. A dated hardening patch is integrated only when `fetch-sources.sh` applies it and `verify-source-lock.sh` locks its checksum.

`Manifest/sources.lock` pins ten downloadable source archives by URL, revision, and SHA-256, including the exact Mbed TLS framework submodule. `Scripts/fetch-sources.sh` reconstructs and patches a clean source tree outside this repository. It never copies the legacy hidden libraries.

Farframe configures the upstream `CHIAKI_ENABLE_RUDP` switch `OFF`. The source-lock patch `chiaki-ng-local-only-holepunch-2026-08-29.patch` makes that switch effective for the native library: the Sony account/session-manager and UDP hole-punch implementation is replaced by an endpoint-free, fail-closed compatibility shim. The local LAN registration, Wake, Connect, media, and controller path retains the same opaque ABI and `ChiakiSession` layout.

## Reproduce the XCFramework

The complete Xcode 26.6 pipeline is:

```bash
RP_BUILD_JOBS=6 Code/RemotePlay/Native/Scripts/build-xcframework.sh \
  --workspace /tmp/RemotePlayNativeFresh
```

Add `--offline` after the checksum-verified archives are present in the local cache. The pipeline builds distinct visionOS, visionOS Simulator, iOS, iOS Simulator, macOS arm64, and macOS x86_64 variants with minimum OS 26.0. Only the two macOS architectures are combined with `lipo`; `xcodebuild -create-xcframework` keeps platforms separate.

The generated package input lives under `Packages/RemotePlayCore/Binaries/` and is intentionally ignored until the Chiaki/AGPL distribution decision is complete. The build also runs a linked macOS ABI smoke test through the opaque session handle, compiles the production Wake and Connect lifecycle bridge against deterministic no-network Chiaki contracts, audits bridge-only public headers, and writes per-slice SHA-256 values.

The XCFramework exposes only `RemotePlayChiakiBridge.h` and its module map. Chiaki headers remain private build inputs and must not leak into Swift or the packaged artifact.

ABI 4 keeps the exact PS5 Connect lifecycle and adds one atomic per-handle callback table for transport events, HEVC Annex-B samples, decoded interleaved S16 PCM, audio format, and display-blocked state. The handle owns Chiaki's Opus decoder and requires all five native callback slots (`0x1F`) before start. Callback buffers are valid only until callback return, so consumers must copy synchronously and enqueue without blocking the Chiaki thread. Normal teardown remains stop, join, session finalization, Opus finalization, callback release, and handle destruction; a failed stop or join retains all ownership so the same teardown can be retried safely.

## First implementation slice

1. Pin Chiaki and every native dependency revision.
2. Build separate visionOS device/simulator, iOS device/simulator, and macOS variants with minimum OS 26.0.
3. Expose an opaque C session handle instead of importing the unstable `ChiakiSession` struct layout into Swift.
4. Replace process-global callbacks with per-session callback ownership.
5. Package the result as `ChiakiNative.xcframework` without using `lipo` across platforms.
6. Add init, ABI, callback, link, and not-connected smoke tests.
7. Record licenses, source URLs, checksums, and clean-clone reproduction.

Do not copy ignored legacy libraries or mutate dependency source during a normal app build. Two legacy patches were reported not to reverse-apply cleanly during audit; the build recipe must verify and reconcile patch state explicitly.

Patch SHA-256 values:

- `c9275adcbfb956abc70a1049e5aac98665ed0cb07dd97a79dd3ad56b4408875d` — complete known-good curl working-tree diff
- `4845559153486a1b306e04262a4738307a873c7116aa0747137d70b0a1b3097b` — complete known-good Chiaki working-tree diff
- `985b284fecb1aaaa5794785003cfcf5f6bdd6ee4274d4343432778e0d88c60ba` — session runtime callbacks
- `f57b9c463598defe0c3b39247f7b412b71ce4f1f390393ccc04d071c8916a4a7` — Takion receive buffer
- `b7cdca0948df044672069413053e9f247a8243510ce118882a66f1a9a11bf314` — video receiver callback proof
- `b84ab1aad72cffd02af4eef01bfe5aadc8f122f3aa88ad1c0761a39faa3d1d76` — visionOS no-DF stream
- `74fcd463a819902d40cf3000f1f1c38cd31149b0fbf172bbe0da6a5146d8d97c` — local-only fail-closed hole-punch removal
