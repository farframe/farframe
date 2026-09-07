import PlayStationRemotePlay
import PlayStationRemotePlayUI
import SwiftUI

struct MobilePlayStationPairingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: MobilePlayStationPairingModel
    @State private var accountHelpIsPresented = false
    private let webSignInAcquirer: PlayStationWebAccountIdentityAcquirer?
    let onConnect: (UUID) -> Void

    init(
        coordinator: MobileRemotePlayCoordinator,
        target: MobilePairingTarget,
        onConnect: @escaping (UUID) -> Void
    ) {
        _model = State(
            initialValue: MobilePlayStationPairingModel(
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
                if case let .paired(name, consoleID) = model.status {
                    successPresentation(name: name, consoleID: consoleID)
                } else {
                    Form {
                        introSection
                        consoleSection
                        accountSection
                        linkDeviceSection
                        statusSection
                    }
                }
            }
            .navigationTitle(
                model.target.existingConsoleID == nil ? "Pair a PS5" : "Re-register PS5"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelTitle) {
                        cancel()
                    }
                    .disabled(model.status == .canceling)
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmationButton
                }
            }
        }
        .interactiveDismissDisabled(model.operationIsActive || model.secureSaveIsPending)
        .task {
            await model.prepareLocalNetwork()
        }
        .onDisappear {
            model.presentationDidDisappear()
        }
        .sheet(isPresented: $accountHelpIsPresented) {
            FarframeAccountIDHelpView()
                .presentationSizing(.page)
        }
        // The sign-in sheet must stack on this pairing sheet; a root-level
        // presenter cannot show it while this sheet is up.
        .modifier(MobileWebSignInPresentation(acquirer: webSignInAcquirer))
    }

    /// Pairing success replaces the form so Connect is the first thing on
    /// screen instead of a status row below the fold.
    private func successPresentation(name: String, consoleID: UUID) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("PS5 paired")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(name)
                        .font(.headline)
                    Label("Saved securely on this device", systemImage: "lock.shield")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Connect now to start playing, or choose Done to return to your consoles.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    Button {
                        onConnect(consoleID)
                        dismiss()
                    } label: {
                        Label("Connect Now", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .controlSize(.large)

                    Button("Done") { dismiss() }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                }
                .frame(maxWidth: 320)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }

    private var introSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pair this device with your PS5")
                        .font(.headline)
                    Text("Three steps, once, on your home Wi-Fi. After that you can play from home or away.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.localNetworkPreflightCompleted == false {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Preparing local network access…")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    }
                }
            } icon: {
                Image(systemName: "playstation.logo")
                    .foregroundStyle(.blue)
            }
        }
    }

    private var accountSection: some View {
        Section("2. PlayStation account") {
            if model.hasAccountIdentity {
                Label(
                    model.accountDisplayName.map { "Account ready: \($0)" } ?? "Account ready",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            } else if model.accountIdentityCapability.isAvailable {
                Button {
                    Task { await model.acquireAccountIdentity() }
                } label: {
                    Label("Continue with PlayStation", systemImage: "person.crop.circle.badge.checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(model.inputsAreEditable == false)
                Text("Sign in on Sony’s page to get your Remote Play Account ID for pairing. Farframe does not store your Sony password, and discards the temporary sign-in session afterward.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Sign-in is unavailable in this build", systemImage: "person.text.rectangle")
                Text("Enter your Remote Play Account ID under Advanced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(
                "Advanced: I already have my Account ID",
                isExpanded: $model.advancedAccountEntryIsExpanded
            ) {
                TextField("Numeric, base64, or hexadecimal Account ID", text: $model.manualAccountID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Display name (optional)", text: $model.manualAccountDisplayName)
                Button("Use This Account ID") {
                    model.applyManualAccountID()
                }
                .buttonStyle(.glass)
                .disabled(
                    model.inputsAreEditable == false
                        || model.manualAccountID.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                )
                Text("This identifier is used only for the local PS5 registration attempt and is cleared from the form afterward. Never enter your PlayStation password here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("How to find your Account ID") {
                    accountHelpIsPresented = true
                }
            }
        }
    }

    private var consoleSection: some View {
        Section("1. PS5 address") {
            TextField("PS5 IP address", text: $model.hostAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .disabled(model.inputsAreEditable == false)
            TextField("Console name (optional)", text: $model.displayName)
                .disabled(model.inputsAreEditable == false)
            Text("On PS5: Settings > Network > Connection Status. You can add an Away address later from the console menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var linkDeviceSection: some View {
        Section("3. Link Device code") {
            TextField("8-digit code", text: $model.linkDevicePIN)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .disabled(model.inputsAreEditable == false)
            Text("On PS5: Settings > System > Remote Play > Link Device. The code is used only for this pairing attempt.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section("Status") {
            switch model.status {
            case .editing:
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("Complete steps 1 to 3, then tap Pair.")
                        .foregroundStyle(.secondary)
                }
            case .acquiringAccount:
                progressLabel("Preparing account identity…")
            case .pairing:
                progressLabel("Pairing with PS5…")
            case .saving:
                progressLabel("Saving registration securely…")
            case .canceling:
                progressLabel("Canceling safely…")
            case .savePending(let message):
                Label(message, systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Button("Finish Secure Save") {
                    Task { await model.retryPendingSecureSave() }
                }
                .buttonStyle(.glassProminent)
            case .paired(let name, let consoleID):
                Label("\(name) is paired", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Connect Now") {
                    onConnect(consoleID)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
            }
        }
    }

    @ViewBuilder
    private var confirmationButton: some View {
        if case .paired = model.status {
            Button("Done") { dismiss() }
        } else {
            Button("Pair") {
                Task { await model.pair() }
            }
            .disabled(model.canPair == false)
        }
    }

    private func progressLabel(_ title: String) -> some View {
        HStack {
            ProgressView()
            Text(title)
        }
    }

    private var cancelTitle: String {
        model.secureSaveIsPending ? "Close After Save" : "Cancel"
    }

    private func cancel() {
        Task {
            if model.secureSaveIsPending {
                await model.retryPendingSecureSave()
                if model.secureSaveIsPending == false { dismiss() }
                return
            }
            if await model.cancelAndWait() {
                dismiss()
            }
        }
    }
}
