import Foundation
import SwiftUI

struct FarframeThirdPartyNoticesView: View {
    struct Component: Identifiable {
        let id: String
        let name: String
        let version: String
        let license: String
        let licenseResource: String
        let sourceURL: URL
    }

    private let components = [
        Component(
            id: "chiaki-ng",
            name: "Chiaki / chiaki-ng",
            version: "a75d628ffb4b6e33126e3830b4fb32796e5cc005",
            license: "GNU Affero General Public License 3.0",
            licenseResource: "Chiaki-AGPL-3.0",
            sourceURL: URL(string: "https://github.com/streetpea/chiaki-ng")!
        ),
        Component(
            id: "curl",
            name: "curl",
            version: "b1ef0e1a01c0bb6ee5367bd9c186a603bde3615a",
            license: "curl license",
            licenseResource: "curl-COPYING",
            sourceURL: URL(string: "https://github.com/curl/curl")!
        ),
        Component(
            id: "gf-complete",
            name: "GF-Complete",
            version: "fa54a4670a5705c84abf6c24b92b0cd479625478",
            license: "BSD-style license",
            licenseResource: "GF-Complete-COPYING",
            sourceURL: URL(string: "https://git.sr.ht/~thestr4ng3r/gf-complete")!
        ),
        Component(
            id: "jerasure",
            name: "Jerasure",
            version: "505ccb4bc69eee8d7ea40a6089a056b99671134f",
            license: "BSD-style license",
            licenseResource: "Jerasure-COPYING",
            sourceURL: URL(string: "https://git.sr.ht/~thestr4ng3r/jerasure")!
        ),
        Component(
            id: "nanopb",
            name: "nanopb",
            version: "cad3c18ef15a663e30e3e43e3a752b66378adec1",
            license: "zlib license",
            licenseResource: "nanopb-LICENSE",
            sourceURL: URL(string: "https://github.com/nanopb/nanopb")!
        ),
        Component(
            id: "mbedtls",
            name: "Mbed TLS",
            version: "2ca6c285a0dd3f33982dd57299012dacab1ff206",
            license: "Apache License 2.0 or GPL 2.0-or-later",
            licenseResource: "MbedTLS-LICENSE",
            sourceURL: URL(string: "https://github.com/Mbed-TLS/mbedtls")!
        ),
        Component(
            id: "mbedtls-framework",
            name: "Mbed TLS framework",
            version: "750634d3a51eb9d61b59fd5d801546927c946588",
            license: "Apache License 2.0 or GPL 2.0-or-later",
            licenseResource: "MbedTLS-Framework-LICENSE",
            sourceURL: URL(string: "https://github.com/Mbed-TLS/mbedtls-framework")!
        ),
        Component(
            id: "json-c",
            name: "json-c",
            version: "json-c-0.17-20230812",
            license: "MIT License",
            licenseResource: "json-c-COPYING",
            sourceURL: URL(string: "https://github.com/json-c/json-c")!
        ),
        Component(
            id: "miniupnpc",
            name: "miniupnpc",
            version: "2.2.8",
            license: "BSD 3-Clause License",
            licenseResource: "miniupnpc-LICENSE",
            sourceURL: URL(string: "https://miniupnp.tuxfamily.org/")!
        ),
        Component(
            id: "opus",
            name: "Opus",
            version: "1.4",
            license: "BSD 3-Clause License",
            licenseResource: "Opus-COPYING",
            sourceURL: URL(string: "https://opus-codec.org/")!
        ),
    ]

    var body: some View {
        List {
            Section("Components") {
                ForEach(components) { component in
                    NavigationLink {
                        FarframeLicenseTextView(component: component)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(component.name)
                            Text(component.license)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Farframe source") {
                Text("Farframe includes a modified Chiaki-derived Remote Play engine and is published under the GNU Affero General Public License 3.0. The complete corresponding source for this exact version, including every native patch and the build scripts, is available from the Farframe website. The release tag matching this build is named in the release notes.")
                Link(
                    "Source & Build Materials",
                    destination: FarframeSourceOffer.websiteURL
                )
                Text("Farframe modifies the upstream engine for Apple-platform builds, session and media delivery, receive-buffer behavior, and safe console-registration shutdown.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Farframe's app name, icon, and other brand assets are not granted for use merely because source code is available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Independent product") {
                Text("Farframe is an independent application. It is not affiliated with, endorsed by, or sponsored by Sony Group Corporation, Sony Interactive Entertainment, PlayStation, PlayStation Network, or any of their affiliates. PlayStation, PS5, and PlayStation Network are trademarks or registered trademarks of their respective owners and are used only to describe compatibility with user-owned equipment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Third-Party Notices")
    }
}

private struct FarframeLicenseTextView: View {
    let component: FarframeThirdPartyNoticesView.Component

    var body: some View {
        List {
            Section {
                LabeledContent("Component", value: component.name)
                LabeledContent("Version", value: component.version)
                LabeledContent("License", value: component.license)
                Link("Upstream Source", destination: component.sourceURL)
            }

            Section("License text") {
                Text(licenseText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(component.name)
    }

    private var licenseText: String {
        guard let url = Bundle.main.url(
            forResource: component.licenseResource,
            withExtension: "txt"
        ), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The bundled license text could not be loaded. Contact support@unshackledpursuit.com."
        }
        return text
    }
}


/// The in-app source offer points at the Farframe website, which links to the
/// public AGPL repository (owner decision 2026-09-04: one deliberate hop, not a
/// direct repository link inside the app). The website page must always carry
/// the current repository link and release tags; see Docs/AGPL_RELEASE_PROTOCOL.md.
enum FarframeSourceOffer {
    static let websiteURL = URL(string: "https://unshackledpursuit.com/farframe#faq")!
}
