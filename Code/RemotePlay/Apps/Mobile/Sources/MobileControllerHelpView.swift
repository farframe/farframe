import SwiftUI

/// Displays the coordinator's live controller state. Bluetooth pairing remains
/// in system Settings; opening this sheet never starts or stops a connection.
struct MobileControllerHelpView: View {
    let connection: MobileControllerConnection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.isConnected
                                ? connection.name ?? "Controller" : "No controller connected")
                                .font(.headline)
                            Text(connection.isConnected ? "Connected · Ready to play" : "Touch controls still work.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: connection.isConnected ? "gamecontroller.fill" : "gamecontroller")
                            .foregroundStyle(connection.isConnected ? Color.green : Color.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }

                Section {
                    if connection.isConnected {
                        DisclosureGroup("Pair another controller") {
                            pairingSteps
                        }
                    } else {
                        pairingSteps
                    }
                } header: {
                    if !connection.isConnected { Text("Connect via Bluetooth") }
                }

                Section {
                    DisclosureGroup("Using a DualShock 4?") {
                        Text("Hold PS + SHARE until the light flashes, then select the controller in Settings → Bluetooth. SHARE is left of the touchpad.")
                    }
                    DisclosureGroup("Already paired?") {
                        Text("Press the PS button, then select your controller in Settings → Bluetooth. If it won’t reconnect, repeat the pairing steps above.")
                        Link("More pairing help", destination: URL(string: "https://support.apple.com/en-gb/111100")!)
                    }
                }
            }
            .navigationTitle("Controller")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder private var pairingSteps: some View {
        Text("1. Turn the controller off and unplug its USB cable.")
        Text("2. Hold PS + Create until the light flashes.")
        ControllerPairingDiagram()
        Text("Create is left of the touchpad, opposite Options.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        Text("3. Open Settings → Bluetooth and select your controller.")
    }
}

/// A simplified, original button map, with labels rather than proprietary art.
private struct ControllerPairingDiagram: View {
    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 6) {
                    Text("Create").fontWeight(.semibold)
                    Capsule().fill(.blue).frame(width: 9, height: 24)
                }
                RoundedRectangle(cornerRadius: 10)
                    .fill(.secondary.opacity(0.12))
                    .overlay { Text("Touchpad").foregroundStyle(.secondary) }
                    .frame(maxWidth: 150, minHeight: 56)
                VStack(spacing: 6) {
                    Text("Options").foregroundStyle(.secondary)
                    Capsule().fill(.secondary.opacity(0.4)).frame(width: 9, height: 24)
                }
            }
            Text("PS")
                .fontWeight(.bold)
                .frame(width: 38, height: 38)
                .background(.blue.opacity(0.2), in: Circle())
                .overlay { Circle().stroke(.blue, lineWidth: 2) }
        }
        .font(.caption)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Button guide: Create is left of the touchpad; Options is on the right. The PS button is below the touchpad. Hold Create and PS together.")
        .accessibilityIdentifier("controller.pairingDiagram")
    }
}
