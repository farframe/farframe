import Foundation
import SwiftUI

/// Explains the Advanced manual Account ID path. Sign-in is the normal route;
/// this screen exists for people who already have the ID from another Remote
/// Play app. It deliberately links to no third-party lookup service: those
/// services come and go, and sending users to them looked untrustworthy.
struct FarframeAccountIDHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text("The easiest way is to tap Continue with PlayStation on the pairing screen and sign in. Farframe reads your Remote Play Account ID from that sign-in and keeps only the ID. You never need to type it.")
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .foregroundStyle(.blue)
                    }
                }

                Section("If you already have your Account ID") {
                    Text("If you already have this value from an earlier Remote Play setup, paste it in the Advanced field. Farframe accepts the numeric, base64, and 16-character hexadecimal forms.")
                    Text("It is a 64-bit number tied to your PlayStation account. It is not your Online ID, your email address, or your password.")
                        .foregroundStyle(.secondary)
                }

                Section("Then finish pairing") {
                    step(1, "Make sure this device and the PS5 are on the same home Wi-Fi. Pairing works only on the local network; playing does not have that limit.")
                    step(2, "On PS5, open Settings > System > Remote Play > Link Device and leave the eight-digit code on screen.")
                    step(3, "Enter the code in Farframe and tap Pair. The code expires in a few minutes, so request a fresh one if it fails.")
                }

                Section("Safety") {
                    Label(
                        "Enter your password and two-factor code only on Sony’s sign-in page. Never paste them, cookies, or access tokens into the manual Account ID field.",
                        systemImage: "lock.shield.fill"
                    )
                    Text("Farframe keeps the Account ID and Link Device code only for the pairing attempt. The saved console registration lives in this device's Keychain and is not synchronized anywhere.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Remote Play Account ID")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.blue)
            Text(text)
        }
    }
}
