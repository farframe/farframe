# Farframe

Your PS5, on the screen you actually want to use.

Farframe is a native PlayStation Remote Play client for Apple Vision Pro,
iPhone, iPad, and Mac. One shared engine, three SwiftUI shells, and a stubborn
set of rules about what stays on your device. It is the app we wanted to exist,
so we built it, and because its streaming core descends from the AGPL-licensed
[chiaki-ng](https://github.com/streetpea/chiaki-ng) project, the complete
source for every App Store build lives here too.

## What it does

- Pairs with your PS5 once, on your home network, using PlayStation's own
  sign-in page. Farframe keeps only the Remote Play Account ID it needs.
- Wakes, connects, streams video and audio, and hands your DualSense (or any
  Apple-compatible controller, or on-screen touch controls) to the console.
- Plays from home over Wi-Fi, or away through an address you own, such as a
  VPN or a port forward you configured yourself.
- Shows honest stream-health numbers and lets you save a privacy-bounded
  diagnostics report when something feels off.

## What it refuses to do

- Sync PlayStation credentials, Account IDs, tokens, cookies, console secrets,
  private-network addresses, or device identifiers through iCloud or anywhere
  else. Pairing lives in each device's own Keychain.
- See or store your PlayStation password. Sign-in happens in an ephemeral web
  view and the session is discarded.
- Phone home. There is no analytics upload path. Diagnostics stay on the device
  unless you choose to share a file.

Farframe offers a three-day trial and a one-time Lifetime Unlock on the App Store. The StoreKit code is
in this tree because the license asks for the whole program, not because you
need it to build and run your own copy.

## Build it yourself

The next Vision build requires visionOS 27.0 and Xcode 27.0 (currently tested
with beta build `27A5252f`). Mobile and Mac retain their OS 26.0 minimum. Use
Xcode 26.6 (build `17F113`) for the native runtime, Mobile, Mac and shared tests,
then select Xcode 27 for the Vision shell. Beta compilation is development
evidence, not App Store release validation. You also need
[XcodeGen](https://github.com/yonaskolb/XcodeGen),
CMake, Ninja, and a Python 3 with the `protobuf` module for the native
reconstruction step. Set `DEVELOPER_DIR` to your Xcode if it is not the
default one.

1. Rebuild the native runtime. The script downloads checksum-locked sources,
   applies the tracked patches, builds every Apple slice, runs the bridge and
   ABI smoke tests, and writes the ignored package input
   `Code/RemotePlay/Packages/RemotePlayCore/Binaries/ChiakiNative.xcframework`.

   ```sh
   cd Code/RemotePlay
   RP_BUILD_JOBS=6 Native/Scripts/build-xcframework.sh --workspace /tmp/FarframeNativeBuild
   ```

2. Generate the project and run the package tests.

   ```sh
   xcodegen generate
   xcrun swift test --package-path Packages/RemotePlayCore
   ```

3. Build a shell. Unsigned builds prove compilation; to pair with a real
   console, pick your own development team in Xcode and keep the entitlements
   enabled, because the Data Protection Keychain needs a signed app.

   ```sh
   xcodebuild -project RemotePlay.xcodeproj -scheme RemotePlayMobile \
     -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
   xcodebuild -project RemotePlay.xcodeproj -scheme RemotePlayVision \
     -destination 'generic/platform=visionOS' CODE_SIGNING_ALLOWED=NO build
   xcodebuild -project RemotePlay.xcodeproj -scheme RemotePlayMac \
     -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
   ```

`Code/RemotePlay/Native/README.md` explains the native boundary, patch
provenance, and the offline-cache option in detail.

## What is in here

```text
Code/RemotePlay/
├── Apps/
│   ├── Vision/      visionOS shell
│   ├── Mobile/      adaptive iPhone and iPad shell
│   ├── Mac/         native macOS shell
│   └── Shared/      shared resources, notices, and help
├── Packages/RemotePlayCore/   Swift packages: provider, media, audio, input,
│                              security, diagnostics, commerce, and their tests
├── Native/          reproducible native source locks, patches, bridge, scripts
└── project.yml      XcodeGen source of truth
```

The generated Xcode project and the XCFramework are build artifacts and are not
committed.

## About this repository

This is a history-free export of one reviewed commit from a private engineering
repository, produced by an audited script that refuses signing material,
credentials, private addresses, and device identifiers. Each App Store build
maps to one tag here. Pull requests are welcome and are read carefully; accepted
changes are folded into the private tree and reappear in the next export, so
history looks flatter than it really is. For bug reports and pairing help, use
[Farframe support](https://unshackledpursuit.com/farframe#support). This repository
does not use GitHub issues or discussions.

Security problems go through `SECURITY.md`, not the issue tracker.

## License and thanks

Farframe is published under the GNU Affero General Public License, version 3
(see `LICENSE`). The native runtime is derived from chiaki-ng, which is
AGPL-3.0, so the combined work carries the same terms. Every third-party notice
ships inside the app and under `Code/RemotePlay/Apps/Vision/Resources/Licenses`.

Thank you to the chiaki and chiaki-ng communities, who worked out how Remote
Play actually speaks long before we showed up with a headset.

Farframe is an independent application. It is not affiliated with, endorsed by,
or sponsored by Sony Interactive Entertainment. PlayStation, PS5, DualSense, and
PlayStation Network are trademarks of their respective owners and are used only
to describe compatibility with equipment you own.
