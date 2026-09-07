import CommerceCore
import ExperienceDomain
import FarframeCommerceUI
import FarframeStorefront
import PlayStationRemotePlay
import PlayStationRemotePlayUI
import StoreKit
import SwiftUI

struct VisionHomeContainerView: View {
    @Bindable var coordinator: VisionRemotePlayCoordinator
    @Bindable var accessStore: FarframeAccessStore

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.purchase) private var purchase
    @Environment(\.scenePhase) private var scenePhase
    @State private var accessIsPresented = false
    @State private var settingsArePresented = false
    @State private var whatsNewIsPresented = false
    @AppStorage(FarframeWhatsNewContent.dismissedVersionKey) private var dismissedWhatsNewVersion = ""
    @State private var pairingTarget: VisionPairingTarget?
    @State private var pendingConnectAfterPairingID: UUID?
    @State private var consolePendingRemoval: VisionHomeConsoleSummary?
    @State private var addressesTarget: PlayStationConsoleAddressesTarget?
    @State private var controllerIsConnected = false
    @State private var controllerName: String?
    @State private var instanceID = UUID()
    @State private var playStyleOnboardingIsPresented = false
    /// Records only that the question has been asked, never the answer. The
    /// answer is the quality and smooth-motion preferences a style writes.
    @AppStorage(FarframePlayStyleOnboarding.hasBeenAskedKey)
    private var playStyleWasAsked = false

    var body: some View {
        VisionHomeView(state: homeState, send: handle)
            .task {
                await coordinator.prepare()
            }
            .task {
                await observeControllerConnection()
            }
            .task {
                await accessStore.prepare()
                // Somebody who already has access — a returning install, a
                // restore, a family member covered by somebody else's Lifetime
                // Unlock — has no purchase decision to make, so there is
                // nothing for the question to wait behind.
                askPlayStyleIfEntitledAndUnasked()
            }
            .onAppear {
                coordinator.claimSetupWindow(instanceID)
            }
            .onDisappear {
                coordinator.resignSetupWindow(instanceID)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await accessStore.refresh() }
            }
            .sheet(
                isPresented: $accessIsPresented,
                onDismiss: askPlayStyleIfEntitledAndUnasked
            ) {
                FarframePaywallView(accessStore: accessStore)
            }
            .sheet(isPresented: $settingsArePresented) {
                VisionRemotePlaySettingsView(
                    coordinator: coordinator,
                    accessStore: accessStore
                )
            }
            .sheet(isPresented: $whatsNewIsPresented) {
                FarframeWhatsNewView()
            }
            // Marking the question asked on dismissal — not on choosing — is
            // what makes Skip and a swipe-away equally final. It can never nag.
            .sheet(
                isPresented: $playStyleOnboardingIsPresented,
                onDismiss: { playStyleWasAsked = true }
            ) {
                FarframePlayStyleOnboardingView(
                    currentStyle: StreamPlayStyle.matching(
                        quality: coordinator.streamQuality,
                        smoothMotionEnabled: coordinator.smoothMotionEnabled
                    ),
                    onChoose: { style in
                        coordinator.apply(style)
                        playStyleOnboardingIsPresented = false
                    },
                    onSkip: { playStyleOnboardingIsPresented = false }
                )
            }
            .sheet(item: $pairingTarget, onDismiss: connectAfterPairingIfNeeded) { target in
                VisionPlayStationPairingView(
                    coordinator: coordinator,
                    target: target,
                    onConnect: { consoleID in
                        pendingConnectAfterPairingID = consoleID
                    }
                )
            }
            .sheet(item: $addressesTarget) { target in
                PlayStationConsoleAddressesView(target: target) { host, away, route in
                    try await coordinator.updateConnectionAddresses(
                        consoleID: target.id,
                        hostAddress: host,
                        awayHostAddress: away,
                        connectionRoute: route
                    )
                }
            }
            .confirmationDialog(
                consolePendingRemoval.map { "Remove \($0.name)?" } ?? "Remove PS5?",
                isPresented: Binding(
                    get: { consolePendingRemoval != nil },
                    set: { if $0 == false { consolePendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove from Remote Play", role: .destructive) {
                    guard let consoleID = consolePendingRemoval?.id else { return }
                    consolePendingRemoval = nil
                    Task {
                        do {
                            try await coordinator.removeConsole(consoleID)
                        } catch {
                            if coordinator.phase.isBusy == false {
                                coordinator.reportError(error)
                            }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    consolePendingRemoval = nil
                }
            } message: {
                Text("This removes the saved registration from this app. It does not put the PS5 in Rest Mode or revoke other Remote Play devices.")
            }
    }

    private var homeState: VisionHomeState {
        let homePhase: VisionHomePhase
        switch coordinator.phase {
        case .loading:
            homePhase = .loading
        case .recoveryFailed(let message):
            homePhase = .recoveryFailed(message: message)
        case let .registrationRequired(message, consoleID, displayName, hostAddress):
            homePhase = .registrationRequired(
                message: message,
                consoleID: consoleID,
                displayName: displayName,
                hostAddress: hostAddress
            )
        case .waking(let consoleID):
            homePhase = .waking(consoleID: consoleID)
        case .prepared(let consoleID), .connecting(let consoleID):
            homePhase = .connecting(consoleID: consoleID)
        case .streaming(let consoleID):
            homePhase = .streaming(consoleID: consoleID)
        case .removing(let consoleID):
            homePhase = .removing(consoleID: consoleID)
        case .disconnecting:
            homePhase = .disconnecting
        case .failed(let message):
            homePhase = .failed(message: message)
        case .ready:
            homePhase = .ready
        }

        return VisionHomeState(
            phase: homePhase,
            consoles: coordinator.consoles.map {
                VisionHomeConsoleSummary(
                    id: $0.id,
                    name: $0.displayName,
                    hostAddress: $0.hostAddress,
                    awayHostAddress: $0.awayHostAddress,
                    connectionRoute: $0.connectionRoute
                )
            },
            controllerIsConnected: controllerIsConnected,
            controllerName: controllerName,
            showsWhatsNewPrompt:
                dismissedWhatsNewVersion != FarframeWhatsNewContent.currentReleaseVersion,
            accessAllowsConnect: accessStore.allowsConnect,
            accessPresentation: homeAccessPresentation,
            accessNotice: accessStore.notice
        )
    }

    private var homeAccessPresentation: VisionHomeAccessPresentation {
        if accessStore.purchaseInProgressID == FarframeProductID.trial {
            return .startingTrial
        }

        switch accessStore.state {
        case .loading:
            return .checking
        case .trialEligible:
            return .trialEligible
        case .trialActive(_, let expiresAt):
            return .trialActive(expiresAt: expiresAt)
        case .trialExpired:
            return .trialExpired
        case .lifetimeUnlocked:
            return .lifetimeUnlocked
        }
    }

    private func observeControllerConnection() async {
        while Task.isCancelled == false {
            let connection = coordinator.controllerSource.connectionSnapshot()
            controllerIsConnected = connection.isConnected
            controllerName = connection.name
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
        }
    }

    private func handle(_ action: VisionHomeAction) {
        switch action {
        case .connect(let consoleID):
            connect(consoleID)
        case .wake(let consoleID):
            Task { await coordinator.wake(consoleID: consoleID) }
        case .cancelConnection:
            Task { await coordinator.cancelConnection() }
        case .openSettings:
            settingsArePresented = true
        case .openWhatsNew:
            whatsNewIsPresented = true
        case .dismissWhatsNewPrompt:
            dismissedWhatsNewVersion = FarframeWhatsNewContent.currentReleaseVersion
        case .pairConsole:
            pairingTarget = VisionPairingTarget()
        case let .resumeRegistration(consoleID, displayName, hostAddress):
            pairingTarget = VisionPairingTarget(
                existingConsoleID: consoleID,
                displayName: displayName,
                hostAddress: hostAddress
            )
        case .reRegister(let consoleID):
            guard let console = coordinator.consoles.first(where: { $0.id == consoleID }) else {
                return
            }
            pairingTarget = VisionPairingTarget(
                existingConsoleID: console.id,
                displayName: console.displayName,
                hostAddress: console.hostAddress
            )
        case .editAddresses(let consoleID):
            guard let console = coordinator.consoles.first(where: { $0.id == consoleID }) else {
                return
            }
            addressesTarget = PlayStationConsoleAddressesTarget(
                id: console.id,
                consoleName: console.displayName,
                hostAddress: console.hostAddress,
                awayHostAddress: console.awayHostAddress,
                connectionRoute: console.connectionRoute
            )
        case .toggleRoute(let consoleID):
            guard let console = coordinator.consoles.first(where: { $0.id == consoleID }),
                  console.hasAwayAddress else { return }
            Task {
                do {
                    try await coordinator.updateConnectionAddresses(
                        consoleID: console.id,
                        hostAddress: console.hostAddress,
                        awayHostAddress: console.awayHostAddress,
                        connectionRoute: console.connectionRoute == .away ? .home : .away
                    )
                } catch {
                    coordinator.reportError(error)
                }
            }
        case .remove(let consoleID):
            consolePendingRemoval = homeState.consoles.first(where: { $0.id == consoleID })
        case .startTrial:
            // The header pill opens the full Farframe Pro surface so the trial
            // and Lifetime Unlock offers are always chosen from the same page.
            accessIsPresented = true
        case .openAccess:
            accessIsPresented = true
        case .retry:
            Task { await coordinator.retryAfterError() }
        case .dismissError:
            coordinator.clearError()
        }
    }

    /// Asks what they play, once, and only once there is access to play with.
    ///
    /// The question used to fire at launch, before sign-in and before any
    /// commitment. The owner's objection on hardware was that somebody asked
    /// to pick a streaming profile "right off the bat" has no context for the
    /// answer, and he is right: the question is about how to spend a
    /// connection nobody has decided to buy yet. One rule replaces the timing
    /// on every platform — never ask before there is something to play.
    ///
    /// Presented from the purchase sheet's dismissal rather than from a change
    /// in entitlement, because two sheets cannot be presented from one
    /// presenter and the paywall is still on screen at the moment access is
    /// granted.
    private func askPlayStyleIfEntitledAndUnasked() {
        guard accessStore.allowsConnect, playStyleWasAsked == false else { return }
        playStyleOnboardingIsPresented = true
    }

    private func connect(_ consoleID: UUID) {
        guard accessStore.allowsConnect else {
            accessIsPresented = true
            return
        }
        Task {
            guard await coordinator.prepareConnection(consoleID: consoleID),
                  coordinator.phase == .prepared(consoleID),
                  coordinator.videoSurface != nil else { return }
            guard accessStore.allowsConnect else {
                await coordinator.disconnect()
                accessIsPresented = true
                return
            }
            // The player hides Home itself once video is streaming; dismissing
            // here left the user staring at nothing while Connect was pending.
            openWindow(id: VisionWindowID.player)
        }
    }

    private func connectAfterPairingIfNeeded() {
        guard let consoleID = pendingConnectAfterPairingID else { return }
        pendingConnectAfterPairingID = nil
        connect(consoleID)
    }
}

struct VisionPairingTarget: Identifiable {
    let id = UUID()
    let existingConsoleID: UUID?
    let displayName: String
    let hostAddress: String

    init(
        existingConsoleID: UUID? = nil,
        displayName: String = "PlayStation 5",
        hostAddress: String = ""
    ) {
        self.existingConsoleID = existingConsoleID
        self.displayName = displayName
        self.hostAddress = hostAddress
    }
}
