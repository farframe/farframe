import PlayStationRemotePlayUI
import SwiftUI

struct MacPlayStationPairingView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var model: MacPlayStationPairingModel
    @State private var accountHelpIsPresented = false
    private let webSignInAcquirer: PlayStationWebAccountIdentityAcquirer?
    private let onConnect: (UUID) -> Void

    init(
        coordinator: MacRemotePlayCoordinator,
        target: MacPairingTarget,
        onConnect: @escaping (UUID) -> Void
    ) {
        _model = State(
            initialValue: MacPlayStationPairingModel(
                coordinator: coordinator,
                target: target
            )
        )
        webSignInAcquirer = coordinator.webSignInAcquirer
        self.onConnect = onConnect
    }

    var body: some View {
        NavigationStack {
            Group {
                if let confirmation = model.successConfirmation {
                    successPresentation(confirmation)
                } else {
                    Form {
                        introduction
                        consoleAddress
                        accountIdentity
                        linkDeviceCode
                        status
                    }
                    .formStyle(.grouped)
                    .textFieldStyle(.roundedBorder)
                }
            }
            .navigationTitle(
                model.successConfirmation != nil
                    ? "Pairing Complete"
                    : (model.target.existingConsoleID == nil ? "Pair a PS5" : "Re-register PS5")
            )
            .toolbar {
                if model.successConfirmation == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(cancelButtonTitle) {
                            Task {
                                if await model.cancelAndWait() {
                                    dismiss()
                                }
                            }
                        }
                        .disabled(
                            model.status == .canceling || model.secureSaveIsPending
                        )
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        confirmationButton
                    }
                }
            }
        }
        .frame(
            minWidth: model.successConfirmation == nil ? 570 : 460,
            idealWidth: model.successConfirmation == nil ? 600 : 500,
            minHeight: model.successConfirmation == nil ? 660 : 400,
            idealHeight: model.successConfirmation == nil ? 700 : 440
        )
        .interactiveDismissDisabled(
            model.operationIsActive || model.secureSaveIsPending
        )
        .task {
            await model.prepareLocalNetwork()
        }
        .onDisappear {
            model.presentationDidDisappear()
        }
        .sheet(isPresented: $accountHelpIsPresented) {
            FarframeAccountIDHelpView()
                .frame(minWidth: 520, idealWidth: 580, minHeight: 540, idealHeight: 620)
        }
        // The sign-in sheet must stack on this pairing sheet; a root-level
        // presenter cannot show it while this sheet is up.
        .modifier(MacWebSignInPresentation(acquirer: webSignInAcquirer))
    }

    private func successPresentation(
        _ confirmation: MacPlayStationPairingSuccess
    ) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("PS5 paired")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(confirmation.consoleName)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("Saved securely on this Mac", systemImage: "lock.shield")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Connect when you're ready to play, or choose Done to return to your consoles.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)

                GlassEffectContainer(spacing: 12) {
                    VStack(spacing: 12) {
                        Button {
                            onConnect(confirmation.consoleID)
                            dismiss()
                        } label: {
                            Label("Connect", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.blue)
                        .controlSize(.large)
                        .accessibilityIdentifier("remoteplay.mac.pairing-success-connect")

                        Button("Done") { dismiss() }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityHint("Return to your saved consoles")
                    }
                }
                .frame(maxWidth: 280)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("remoteplay.mac.pairing-success")
    }

    private var introduction: some View {
        Section {
            Text("Keep your Mac and PS5 on the same network. Enter the three details below to pair them.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var consoleAddress: some View {
        Section("1. PS5 address") {
            TextField("PS5 IP address or host name", text: $model.hostAddress)
                .accessibilityIdentifier("remoteplay.mac.console-address")
                .disabled(model.inputsAreEditable == false)

            TextField("Console name (optional)", text: $model.displayName)
                .disabled(model.inputsAreEditable == false)

            Text("On PS5, open Settings > Network > Connection Status to find its local IP address.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var accountIdentity: some View {
        Section("2. PlayStation account") {
            if model.hasAccountIdentity {
                Label(
                    "Account ready: \(model.accountDisplayName ?? "PlayStation account")",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            } else if model.accountIdentityCapability.isAvailable {
                Button {
                    Task { await model.acquireAccountIdentity() }
                } label: {
                    Label("Continue with PlayStation", systemImage: "person.crop.circle.badge.checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.inputsAreEditable == false)

                Text("Sign in on Sony’s page to get your Remote Play Account ID for pairing. Farframe does not store your Sony password, and discards the temporary sign-in session afterward. Already have the ID? Paste it below instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Enter Remote Play Account ID")
                    .font(.subheadline.weight(.medium))
                TextField(
                    "Remote Play Account ID",
                    text: $model.manualAccountID,
                    prompt: Text("Paste your Account ID here")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Remote Play Account ID")
                .accessibilityIdentifier("remoteplay.mac.manual-account-id")
                .disabled(model.inputsAreEditable == false)
                .onSubmit {
                    if canApplyAccountID { model.applyManualAccountID() }
                }

                HStack {
                    Button("Use This Account ID") {
                        model.applyManualAccountID()
                    }
                    .accessibilityIdentifier("remoteplay.mac.use-account-id")
                    .disabled(canApplyAccountID == false)

                    Spacer()
                    Button("Find my Account ID") {
                        accountHelpIsPresented = true
                    }
                    .buttonStyle(.link)
                }

                Text("This is not your PSN username or password. Numeric, base64, and hexadecimal IDs work. Cleared when this pairing form closes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var canApplyAccountID: Bool {
        model.inputsAreEditable
            && model.manualAccountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    @ViewBuilder
    private var linkDeviceCode: some View {
        Section("3. Link Device code") {
            if model.localNetworkPreflightCompleted {
                TextField("8-digit code", text: $model.linkDevicePIN)
                    .accessibilityIdentifier("remoteplay.mac.link-device-code")
                    .textContentType(.oneTimeCode)
                    .disabled(model.inputsAreEditable == false)

                Text("On PS5, open Settings > System > Remote Play > Link Device and keep the eight-digit code visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label(
                    "If asked, allow Farframe to access your local network.",
                    systemImage: "network"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing Local Network access before you request a short-lived code…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let errorMessage = model.errorMessage,
           model.status == .editing {
            Section("Try again") {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Correct the details and request a fresh Link Device code if the previous code expired or was rejected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        switch model.status {
        case .editing:
            EmptyView()
        case .acquiringAccount:
            progressSection("Preparing the PlayStation account flow…")
        case .pairing:
            progressSection("Pairing with your PS5 and verifying its device-local secure save…")
        case .saving:
            progressSection("Retrying the device-local secure save…")
        case .canceling:
            progressSection("Canceling the native pairing session safely…")
        case .savePending(let message):
            Section("Secure save needs attention") {
                Label(message, systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                Text("Do not request another Link Device code. Retry the secure save below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .paired:
            EmptyView()
        }
    }

    private func progressSection(_ message: String) -> some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var confirmationButton: some View {
        switch model.status {
        case .editing:
            Button(model.target.existingConsoleID == nil ? "Pair" : "Re-register") {
                Task { await model.pair() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.canPair == false)
        case .savePending:
            Button("Retry Secure Save") {
                Task { await model.retryPendingSecureSave() }
            }
            .buttonStyle(.borderedProminent)
        case .paired, .acquiringAccount, .pairing, .saving, .canceling:
            EmptyView()
        }
    }

    private var cancelButtonTitle: String {
        switch model.status {
        case .paired:
            "Done"
        case .acquiringAccount, .pairing, .saving:
            "Cancel Pairing"
        case .editing, .canceling, .savePending:
            "Cancel"
        }
    }
}
