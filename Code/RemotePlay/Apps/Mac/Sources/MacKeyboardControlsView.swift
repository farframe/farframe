import SwiftUI

/// A reference sheet, not an input surface: gameplay stays unfocused until the
/// player handles the explicit focus request after this sheet has dismissed.
struct MacKeyboardControlsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var keyboardControlsEnabled: Bool
    let canFocusGameplay: Bool
    let onEnableAndFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Keyboard controls", systemImage: "keyboard")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.blue)

            Toggle("Enable keyboard gameplay", isOn: $keyboardControlsEnabled)
                .toggleStyle(.switch)
                .accessibilityIdentifier("remoteplay.mac.keyboard-enabled")

            Text("Keyboard gameplay is paused while this sheet is open. Click the video to focus it, or use the button below. Escape releases focus.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 9) {
                        mapping("W A S D", "Left stick · move")
                        mapping("← ↓ ↑ →", "Right stick · look", spokenKeys: "Arrow keys")
                        mapping("J / K / U / I", "Cross / Circle / Square / Triangle")
                        mapping("Q / E", "L1 / R1")
                        mapping("Z / C", "L2 / R2")
                        mapping("F / H", "L3 / R3 · stick clicks")
                        mapping("F1 / F2 / F3 / F4", "D-pad left / down / up / right")
                        mapping("Return", "Options")
                        mapping("V", "Create")
                        mapping("P", "PlayStation button")
                        mapping("T", "Touchpad click only")
                        mapping("Escape", "Release keyboard focus")
                    }

                    Text("For F1–F4, you may need to hold Fn or Globe on your Mac keyboard. Command, Control, and Option shortcuts do not send PS5 input.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Label("Mouse gameplay is not implemented. Mouse movement and clicks do not control the PS5; clicking the video only gives keyboard focus.", systemImage: "computermouse")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }

            if !canFocusGameplay {
                Text("Connect to your PS5 before focusing keyboard gameplay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Close") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Enable & Focus Gameplay") {
                    keyboardControlsEnabled = true
                    onEnableAndFocus()
                }
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .disabled(!canFocusGameplay)
                .accessibilityIdentifier("remoteplay.mac.keyboard-focus-gameplay")
            }
        }
        .padding(24)
        .frame(minWidth: 440, idealWidth: 520, maxWidth: 620, minHeight: 480, idealHeight: 570)
    }

    private func mapping(_ keys: String, _ action: String, spokenKeys: String? = nil) -> some View {
        GridRow(alignment: .top) {
            Text(keys)
                .font(.callout.monospaced())
                .fixedSize(horizontal: true, vertical: false)
            Text(action)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spokenKeys ?? keys): \(action)")
    }
}
