import Foundation
import Observation
import PlayStationRemotePlay

enum MacPlayStationPairingStatus: Equatable {
    case editing
    case acquiringAccount
    case pairing
    case saving
    case canceling
    case savePending(String)
    case paired(name: String, consoleID: UUID)
}

/// The success surface needs only the saved name and the existing Connect target.
/// Account identity, Link Device code, and console address stay out of this value.
struct MacPlayStationPairingSuccess: Equatable {
    let consoleName: String
    let consoleID: UUID
}

@MainActor
@Observable
final class MacPlayStationPairingModel {
    let target: MacPairingTarget

    var displayName: String
    var hostAddress: String
    var linkDevicePIN: String = "" {
        didSet {
            let filtered = Self.filteredPIN(linkDevicePIN)
            if filtered != linkDevicePIN {
                linkDevicePIN = filtered
            }
        }
    }

    private(set) var status: MacPlayStationPairingStatus = .editing
    private(set) var accountDisplayName: String?
    private(set) var localNetworkPreflightCompleted = false
    /// The trigger syscall's outcome, not an authorization-state query.
    /// Pairing is gated on completion regardless of this value.
    private(set) var localNetworkPreflightSucceeded = false
    private(set) var errorMessage: String?

    var manualAccountID = "" {
        didSet {
            guard manualAccountID != oldValue else { return }
            // Editing a prepared ID must never pair using the previous value.
            accountIdentity = nil
            accountDisplayName = nil
            errorMessage = nil
        }
    }
    var manualAccountDisplayName = ""

    private let coordinator: MacRemotePlayCoordinator
    private var accountIdentity: PlayStationRemotePlayAccountIdentity?
    private var preflightDidStart = false
    private var preflightOperationID: UUID?
    private var operationID: UUID?
    private var operationTask: Task<Void, Never>?

    init(
        coordinator: MacRemotePlayCoordinator,
        target: MacPairingTarget
    ) {
        self.coordinator = coordinator
        self.target = target
        self.displayName = target.displayName
        self.hostAddress = target.hostAddress
    }

    var accountIdentityCapability: PlayStationAccountIdentityAcquisitionCapability {
        coordinator.accountIdentityCapability
    }

    var hasAccountIdentity: Bool { accountIdentity != nil }

    var successConfirmation: MacPlayStationPairingSuccess? {
        guard case let .paired(name, consoleID) = status else { return nil }
        return MacPlayStationPairingSuccess(consoleName: name, consoleID: consoleID)
    }

    var inputsAreEditable: Bool {
        status == .editing
    }

    var operationIsActive: Bool {
        switch status {
        case .acquiringAccount, .pairing, .saving, .canceling:
            true
        case .editing, .savePending, .paired:
            false
        }
    }

    var secureSaveIsPending: Bool {
        if case .savePending = status { return true }
        return false
    }

    var canPair: Bool {
        guard status == .editing,
              operationTask == nil,
              localNetworkPreflightCompleted,
              accountIdentity != nil,
              hostAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              (try? PlayStationLinkDevicePIN(linkDevicePIN)) != nil else {
            return false
        }
        return true
    }

    /// Coalesces Local Network preparation for this pairing presentation.
    /// Repeated callbacks await the same attempt. Interrupted preparation may
    /// retry when the view returns; completed attempts remain exact-once.
    func prepareLocalNetwork() async {
        guard Task.isCancelled == false else { return }
        if let existingTask = preflightTask {
            await existingTask.value
            return
        }
        guard preflightDidStart == false else { return }
        preflightDidStart = true
        let requestID = UUID()
        preflightOperationID = requestID
        let task = Task { [weak self] in
            guard let self,
                  Task.isCancelled == false,
                  self.preflightOperationID == requestID else { return }
            let succeeded = await coordinator.requestLocalNetworkPairingAccess()
            guard Task.isCancelled == false,
                  preflightOperationID == requestID else { return }
            localNetworkPreflightSucceeded = succeeded
            localNetworkPreflightCompleted = true
            preflightTask = nil
        }
        preflightTask = task
        await task.value
    }

    func acquireAccountIdentity() async {
        guard status == .editing, operationTask == nil else { return }
        guard accountIdentityCapability.isAvailable else {
            errorMessage = PlayStationAccountIdentityAcquisitionError
                .unavailable.localizedDescription
            return
        }

        let requestID = beginOperation(status: .acquiringAccount)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let identity = try await coordinator.acquirePairingAccountIdentity()
                try Task.checkCancellation()
                guard operationIsCurrent(requestID) else { return }
                manualAccountID = ""
                manualAccountDisplayName = ""
                accountIdentity = identity
                accountDisplayName = identity.displayName
                finishOperation(requestID, status: .editing)
            } catch {
                guard operationIsCurrent(requestID) else { return }
                finishOperation(requestID, status: .editing)
                if (error is CancellationError) == false {
                    errorMessage = error.localizedDescription
                }
            }
        }
        operationTask = task
        await task.value
    }

    func pair() async {
        guard canPair, let accountIdentity else { return }

        let request: PlayStationPairingRequest
        do {
            request = try PlayStationPairingRequest(
                existingConsoleID: target.existingConsoleID,
                hostAddress: hostAddress,
                fallbackDisplayName: displayName,
                accountID: accountIdentity.accountID,
                pin: PlayStationLinkDevicePIN(linkDevicePIN)
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let requestID = beginOperation(status: .pairing)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let console = try await coordinator.pairConsole(request)
                try Task.checkCancellation()
                guard operationIsCurrent(requestID) else { return }
                clearSensitiveInputs()
                finishOperation(
                    requestID,
                    status: .paired(name: console.name, consoleID: console.id)
                )
            } catch {
                guard operationIsCurrent(requestID) else { return }
                if PlayStationPairingError.isSecureSavePending(error) {
                    clearSensitiveInputs()
                    finishOperation(
                        requestID,
                        status: .savePending(error.localizedDescription)
                    )
                } else {
                    linkDevicePIN = ""
                    finishOperation(requestID, status: .editing)
                    if (error is CancellationError) == false {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
        operationTask = task
        await task.value
    }

    func retryPendingSecureSave() async {
        guard secureSaveIsPending, operationTask == nil else { return }

        let requestID = beginOperation(status: .saving)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let console = try await coordinator.retryPendingPairingSave()
                try Task.checkCancellation()
                guard operationIsCurrent(requestID) else { return }
                clearSensitiveInputs()
                finishOperation(
                    requestID,
                    status: .paired(name: console.name, consoleID: console.id)
                )
            } catch {
                guard operationIsCurrent(requestID) else { return }
                clearSensitiveInputs()
                if coordinator.pairingSecureSaveIsPending {
                    finishOperation(
                        requestID,
                        status: .savePending(error.localizedDescription)
                    )
                } else {
                    finishOperation(requestID, status: .editing)
                    if (error is CancellationError) == false {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
        operationTask = task
        await task.value
    }

    /// The Cancel button awaits native cancellation before the sheet is
    /// dismissed. This avoids starting a new registration while Chiaki is
    /// still joining and destroying the previous registration client.
    @discardableResult
    func cancelAndWait() async -> Bool {
        guard secureSaveIsPending == false else { return false }
        let task = operationTask
        operationID = nil
        status = .canceling
        task?.cancel()
        await task?.value
        operationTask = nil
        clearSensitiveInputs()
        cancelPreflight()
        if coordinator.pairingSecureSaveIsPending {
            status = .savePending(
                PlayStationPairingError.secureSavePending.localizedDescription
            )
            return false
        }
        status = .editing
        return true
    }

    func presentationDidDisappear() {
        operationID = nil
        operationTask?.cancel()
        operationTask = nil
        cancelPreflight()
        clearSensitiveInputs()
    }

    /// Source-safe local pairing path for a user who already knows the exact
    /// Remote Play Account ID. It creates a transient identity in memory; the
    /// text is cleared when pairing finishes or the presentation closes.
    func applyManualAccountID() {
        guard inputsAreEditable else { return }
        do {
            let accountID = try PlayStationAccountID(manualValue: manualAccountID)
            let displayName = manualAccountDisplayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = PlayStationRemotePlayAccountIdentity(
                accountID: accountID,
                displayName: displayName.isEmpty ? nil : displayName
            )
            accountIdentity = identity
            accountDisplayName = identity.displayName ?? "Manual account"
            errorMessage = nil
        } catch {
            accountIdentity = nil
            accountDisplayName = nil
            errorMessage = error.localizedDescription
        }
    }

    private var preflightTask: Task<Void, Never>?

    private func beginOperation(status: MacPlayStationPairingStatus) -> UUID {
        let requestID = UUID()
        operationID = requestID
        errorMessage = nil
        self.status = status
        return requestID
    }

    private func operationIsCurrent(_ requestID: UUID) -> Bool {
        operationID == requestID
    }

    private func finishOperation(
        _ requestID: UUID,
        status: MacPlayStationPairingStatus
    ) {
        guard operationID == requestID else { return }
        operationID = nil
        operationTask = nil
        self.status = status
    }

    private func cancelPreflight() {
        preflightOperationID = nil
        preflightTask?.cancel()
        preflightTask = nil
        if localNetworkPreflightCompleted == false {
            preflightDidStart = false
        }
    }

    private func clearSensitiveInputs() {
        accountIdentity = nil
        accountDisplayName = nil
        linkDevicePIN = ""
        manualAccountID = ""
        manualAccountDisplayName = ""
    }

    private static func filteredPIN(_ value: String) -> String {
        String(
            decoding: value.utf8
                .filter { $0 >= 48 && $0 <= 57 }
                .prefix(8),
            as: UTF8.self
        )
    }
}
