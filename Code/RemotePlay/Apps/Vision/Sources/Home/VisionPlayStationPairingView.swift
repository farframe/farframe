import Foundation
import PlayStationRemotePlay
import PlayStationRemotePlayUI
import SwiftUI

struct VisionPlayStationPairingView: View {
    private enum PairingStatus: Equatable {
        case editing
        case pairing
        case saving
        case canceling
        case savePending(message: String)
        case paired(name: String, consoleID: UUID)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Bindable var coordinator: VisionRemotePlayCoordinator
    let target: VisionPairingTarget
    let onContinueToAccess: () -> Void

    @State private var displayName: String
    @State private var hostAddress: String
    @State private var accountID = ""
    @State private var signedInIdentity: PlayStationRemotePlayAccountIdentity?
    @State private var isAcquiringAccount = false
    @State private var linkDevicePIN = ""
    @State private var manualAccountEntryIsExpanded = false
    @State private var accountHelpIsPresented = false
    @State private var controllerSetupIsPresented = false
    @State private var controllerIsConnected = false
    @State private var controllerName: String?
    @State private var status: PairingStatus = .editing
    @State private var errorMessage: String?
    @State private var pairingTask: Task<Void, Never>?
    @State private var localNetworkPreparationCompleted = false

    init(
        coordinator: VisionRemotePlayCoordinator,
        target: VisionPairingTarget,
        onContinueToAccess: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.target = target
        self.onContinueToAccess = onContinueToAccess
        _displayName = State(initialValue: target.displayName)
        _hostAddress = State(initialValue: target.hostAddress)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isPaired {
                    if controllerSetupIsPresented {
                        controllerSetup
                    } else {
                        pairedConfirmation
                    }
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
            .navigationTitle(navigationTitle)
            .toolbar {
                if !isPaired {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(cancelButtonTitle) {
                            cancel()
                        }
                        .disabled(status == .canceling)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        confirmationButton
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 620)
        .interactiveDismissDisabled(
            status == .pairing
                || status == .saving
                || status == .canceling
                || isSecureSavePending
        )
        .onDisappear {
            pairingTask?.cancel()
            pairingTask = nil
        }
        .task {
            guard !Task.isCancelled, !localNetworkPreparationCompleted else { return }
            _ = await PlayStationLocalNetworkPreflight().requestAccess()
            // A completed best-effort preparation is not permission proof.
            // A cancelled presentation may retry when it appears again.
            guard !Task.isCancelled else { return }
            localNetworkPreparationCompleted = true
        }
        .sheet(isPresented: $accountHelpIsPresented) {
            FarframeAccountIDHelpView()
                .frame(minWidth: 560, minHeight: 620)
        }
        // The sign-in sheet must stack on this pairing sheet; a root-level
        // presenter cannot show it while this sheet is up.
        .playStationWebSignInSheet(coordinator.webSignInAcquirer)
    }

    private var introSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Link this app to your PS5")
                        .font(.headline)
                    Text("Keep your PS5 and Vision Pro on the same network during pairing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "gamecontroller")
                    .foregroundStyle(.blue)
            }
        }
    }

    private var consoleSection: some View {
        Section("1. Enter your PS5 address") {
            TextField("Console IP address", text: $hostAddress)
                .accessibilityLabel("Console IP address")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(inputsAreEditable == false)
            Text("On PS5, open Settings > Network > Connection Status > View Connection Status. Enter the IPv4 Address shown there.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("An IPv4 address has four numbers separated by dots. Example format: 192.0.2.10. Use your PS5’s address, not this example.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var accountSection: some View {
        Section("2. PlayStation account") {
            if let signedInIdentity {
                Label(
                    signedInIdentity.displayName.map { "Account ready: \($0)" } ?? "Account ready",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            } else {
                Button {
                    acquireAccountIdentity()
                } label: {
                    if isAcquiringAccount {
                        Label("Opening PlayStation sign-in…", systemImage: "person.crop.circle")
                    } else {
                        Label("Continue with PlayStation", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputsAreEditable == false || isAcquiringAccount)
                Text("Sign in on Sony’s page to get your Remote Play Account ID for pairing. Farframe does not store your Sony password, and discards the temporary sign-in session afterward.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Help with PlayStation sign-in", systemImage: "questionmark.circle") {
                openWindow(id: VisionWindowID.signInHelp, value: VisionWindowID.signInHelp)
            }

            DisclosureGroup(
                "Advanced: enter Remote Play Account ID",
                isExpanded: $manualAccountEntryIsExpanded
            ) {
                TextField("Console name (optional)", text: $displayName)
                    .disabled(inputsAreEditable == false)
                manualAccountFields
                Button("How to find your Account ID") {
                    accountHelpIsPresented = true
                }
            }
        }
    }

    @ViewBuilder
    private var manualAccountFields: some View {
        TextField("Numeric, base64, or hexadecimal Account ID", text: $accountID)
            .accessibilityLabel("Remote Play Account ID")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(inputsAreEditable == false)
        Text("This identifier is used only for the local PS5 registration attempt and is cleared from the form afterward. Never enter your PlayStation password here.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if accountID.isEmpty == false, validAccountID == false {
            Label("That Account ID is not valid.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
        }
    }

    private var linkDeviceSection: some View {
        Section("3. Link Device code") {
            TextField("8-digit code", text: $linkDevicePIN)
                .accessibilityLabel("Eight-digit Link Device code")
                .keyboardType(.numberPad)
                .disabled(inputsAreEditable == false)
                .onChange(of: linkDevicePIN) { _, value in
                    let digits = String(
                        decoding: value.utf8
                            .filter { $0 >= 48 && $0 <= 57 }
                            .prefix(8),
                        as: UTF8.self
                    )
                    if digits != value { linkDevicePIN = digits }
                }
            Text("On PS5, open Settings > System > Remote Play > Link Device and leave the code visible. Enter that 8-digit code here, not the number from Sony’s sign-in page.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Pair PS5") { pair() }
                .buttonStyle(.borderedProminent)
                .disabled(!canPair)
                .accessibilityIdentifier("farframe.pairing.submitBesideCode")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch status {
        case .editing:
            if let errorMessage {
                Section("Try again") {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Review the message, correct any details, and try again. Request a fresh Link Device code if the previous code expired or was rejected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .pairing:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pairing securely…")
                            .font(.headline)
                        Text("Contacting the PS5, exchanging registration, and saving it to this device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .saving:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Saving securely…")
                            .font(.headline)
                        Text("The PS5 is already paired. Verifying its registration on this device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .canceling:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Stopping pairing safely…")
                        .foregroundStyle(.secondary)
                }
            }
        case let .savePending(message):
            Section("Finish secure save") {
                Label(message, systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Text("Do not request another Link Device code. Retry the secure save below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .paired:
            EmptyView()
        }
    }

    @ViewBuilder
    private var confirmationButton: some View {
        switch status {
        case .editing:
            Button("Pair PS5") { pair() }
                .disabled(canPair == false)
        case .pairing, .saving:
            ProgressView()
        case .canceling:
            ProgressView()
        case .savePending:
            Button("Retry Secure Save") { retrySecureSave() }
        case .paired:
            EmptyView()
        }
    }

    private var isPaired: Bool {
        if case .paired = status { return true }
        return false
    }

    private var navigationTitle: LocalizedStringKey {
        if isPaired { return controllerSetupIsPresented ? "Controller" : "PS5 paired" }
        return target.existingConsoleID == nil ? "Pair a PS5" : "Re-register PS5"
    }

    private var pairedConfirmation: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Your PS5 is paired.")
                    .font(.largeTitle.bold())
                Text("Your registration was verified and saved securely. You won’t need this code for normal reconnects.")
                    .foregroundStyle(.secondary)
                Text("Next, connect your controller to Vision Pro.")
                    .font(.headline)
                Button("Connect my controller", systemImage: "gamecontroller") {
                    controllerSetupIsPresented = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Finish later", action: continueToAccess)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
            .padding(32)
        }
    }

    private var controllerSetup: some View {
        VStack(spacing: 12) {
            VisionControllerHelpView(
                isConnected: controllerIsConnected,
                controllerName: controllerName,
                doneTitle: "Continue",
                canContinue: controllerIsConnected,
                onDone: continueToAccess
            )
            Button("Finish later", action: continueToAccess)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .task {
            while !Task.isCancelled {
                let connection = coordinator.controllerSource.connectionSnapshot()
                controllerIsConnected = connection.isConnected
                controllerName = connection.name
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
            }
        }
    }

    private func continueToAccess() {
        guard isPaired else { return }
        onContinueToAccess()
        dismiss()
    }

    private var validAccountID: Bool {
        (try? PlayStationAccountID(manualValue: accountID)) != nil
    }

    /// The signed-in identity wins; the manual field is the Advanced fallback.
    private var resolvedAccountID: PlayStationAccountID? {
        if let signedInIdentity { return signedInIdentity.accountID }
        return try? PlayStationAccountID(manualValue: accountID)
    }

    private var inputsAreEditable: Bool {
        status == .editing
    }

    private var canPair: Bool {
        status == .editing
            && isAcquiringAccount == false
            && hostAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && resolvedAccountID != nil
            && (try? PlayStationLinkDevicePIN(linkDevicePIN)) != nil
    }

    private func acquireAccountIdentity() {
        guard isAcquiringAccount == false, inputsAreEditable else { return }
        isAcquiringAccount = true
        errorMessage = nil
        Task {
            do {
                let identity = try await coordinator.acquirePairingAccountIdentity()
                signedInIdentity = identity
                manualAccountEntryIsExpanded = false
            } catch is CancellationError {
                // Dismissed; nothing to report.
            } catch {
                errorMessage = error.localizedDescription
            }
            isAcquiringAccount = false
        }
    }

    private var isSecureSavePending: Bool {
        if case .savePending = status { return true }
        return false
    }

    private var cancelButtonTitle: String {
        isSecureSavePending ? "Save & Close" : "Cancel"
    }

    private func pair() {
        guard canPair, let resolvedAccountID else { return }
        status = .pairing
        errorMessage = nil
        pairingTask?.cancel()
        pairingTask = Task {
            do {
                let console = try await coordinator.pairConsole(
                    existingConsoleID: target.existingConsoleID,
                    hostAddress: hostAddress,
                    fallbackDisplayName: displayName,
                    accountID: resolvedAccountID,
                    linkDevicePIN: linkDevicePIN
                )
                guard Task.isCancelled == false else {
                    status = .editing
                    pairingTask = nil
                    dismiss()
                    return
                }
                status = .paired(name: console.displayName, consoleID: console.id)
                accountID = ""
                signedInIdentity = nil
                linkDevicePIN = ""
                pairingTask = nil
            } catch is CancellationError {
                status = .editing
                pairingTask = nil
                dismiss()
            } catch {
                if PlayStationPairingError.isSecureSavePending(error) {
                    status = .savePending(message: error.localizedDescription)
                    accountID = ""
                    signedInIdentity = nil
                    linkDevicePIN = ""
                } else {
                    status = .editing
                    errorMessage = error.localizedDescription
                    linkDevicePIN = ""
                }
                pairingTask = nil
            }
        }
    }

    private func retrySecureSave() {
        status = .saving
        errorMessage = nil
        pairingTask = Task {
            do {
                let console = try await coordinator.retryPendingPairingSave()
                guard Task.isCancelled == false else {
                    status = .editing
                    pairingTask = nil
                    dismiss()
                    return
                }
                status = .paired(name: console.displayName, consoleID: console.id)
                pairingTask = nil
            } catch is CancellationError {
                status = .editing
                pairingTask = nil
                dismiss()
            } catch {
                if PlayStationPairingError.isSecureSavePending(error) {
                    status = .savePending(message: error.localizedDescription)
                } else {
                    status = .editing
                    errorMessage = error.localizedDescription
                }
                pairingTask = nil
            }
        }
    }

    private func cancel() {
        if case .savePending = status {
            finishSecureSaveAndClose()
            return
        }
        guard status == .pairing || status == .saving else {
            pairingTask?.cancel()
            dismiss()
            return
        }
        status = .canceling
        pairingTask?.cancel()
    }

    private func finishSecureSaveAndClose() {
        status = .saving
        pairingTask = Task {
            do {
                _ = try await coordinator.retryPendingPairingSave()
                pairingTask = nil
                dismiss()
            } catch {
                status = .savePending(message: error.localizedDescription)
                pairingTask = nil
            }
        }
    }
}
