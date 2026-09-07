import FarframeCommerceUI
import FarframeStorefront
import PlayStationRemotePlay
import SwiftUI

struct MacRemotePlayHomeView: View {
    @Bindable var coordinator: MacRemotePlayCoordinator
    @Bindable var accessStore: FarframeAccessStore
    let onPair: () -> Void
    let onConnect: (UUID) -> Void
    let onShowAccess: () -> Void
    let onReRegister: (MacPairingTarget) -> Void
    let onRemove: (MacConsoleSummary) -> Void
    var onEditAddresses: (MacConsoleSummary) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                operationCard
                consoles
                accessCard
            }
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .navigationTitle("Play")
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            FarframeBrandMark(size: 56)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text("FARFRAME")
                    .font(.title2.weight(.bold))
                    .tracking(1.8)
                Text("Your PS5, on your Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 14) {
                    Image(systemName: "vision.pro")
                    Image(systemName: "macbook")
                    Image(systemName: "ipad")
                    Image(systemName: "iphone")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Farframe for Apple Vision Pro, Mac, iPad, and iPhone")
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var accessCard: some View {
        HStack(spacing: 8) {
            Image(systemName: accessStore.entrySymbol)
                .foregroundStyle(accessStore.allowsConnect ? .green : .orange)
            Text(accessStore.statusTitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            Button {
                onShowAccess()
            } label: {
                Text("Manage Pro")
            }
            .buttonStyle(.link)
            .fixedSize()
            .accessibilityHint("View trial, lifetime unlock, and restore options")
        }
        .font(.caption)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var operationCard: some View {
        switch coordinator.phase {
        case .loading:
            statusCard(
                title: "Loading saved consoles",
                detail: "Finding the consoles paired with this Mac.",
                symbol: "arrow.triangle.2.circlepath",
                showsProgress: true
            )

        case .recoveryRequired(let message):
            if let recovery = coordinator.registrationRecovery {
                messageCard(
                    title: "Finish pairing your PS5",
                    detail: message,
                    symbol: "exclamationmark.shield.fill",
                    tint: .orange,
                    buttonTitle: recovery.target.existingConsoleID == nil
                        ? "Resume Pairing"
                        : "Re-register",
                    action: { onReRegister(recovery.target) }
                )
            } else {
                messageCard(
                    title: "Finish pairing your PS5",
                    detail: message,
                    symbol: "exclamationmark.shield.fill",
                    tint: .orange,
                    buttonTitle: "Retry",
                    action: { Task { await coordinator.retryStartup() } }
                )
            }

        case .waking(let consoleID):
            statusCard(
                title: coordinator.wakeRequestWasSent
                    ? "Waiting briefly for PS5"
                    : "Sending wake request",
                detail: coordinator.wakeStatusMessage
                    ?? "Sending a request to \(consoleName(consoleID)) at its saved address.",
                symbol: "power",
                showsProgress: true
            )

        case .prepared, .connecting:
            statusCard(
                title: "Opening Remote Play",
                detail: "Getting your picture, sound, and controls ready.",
                symbol: "antenna.radiowaves.left.and.right",
                showsProgress: true
            )

        case .disconnecting:
            statusCard(
                title: "Ending Remote Play",
                detail: "Closing the session safely.",
                symbol: "xmark.circle",
                showsProgress: true
            )

        case .failed(let message):
            messageCard(
                title: "Remote Play needs attention",
                detail: message + "\n\n" + connectionGuidance,
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                buttonTitle: coordinator.startupRecoveryIsResolved ? "Dismiss" : "Check Again",
                action: {
                    if coordinator.startupRecoveryIsResolved {
                        coordinator.dismissError()
                    } else {
                        Task { await coordinator.retryStartup() }
                    }
                }
            )

        case .ready:
            if let message = coordinator.wakeStatusMessage {
                statusCard(
                    title: "Wake request sent",
                    detail: message + " Try Connect when the console is ready.",
                    symbol: "paperplane",
                    showsProgress: false
                )
            }
        case .streaming:
            EmptyView()
        }
    }

    private var connectionGuidance: String {
        "Farframe connects directly to the address saved for this route. At home, use the Home route on your Wi-Fi. Away from home, first configure access to your home network separately, then add the reachable PS5 address from the console menu and choose Away. Farframe does not provide a VPN. To switch devices, Disconnect on the other device without Rest, then connect here."
    }

    @ViewBuilder
    private var consoles: some View {
        if coordinator.phase == .loading {
            EmptyView()
        } else if coordinator.consoles.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "playstation.logo")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Let’s connect your PS5")
                            .font(.title3.weight(.semibold))
                        Text("Pair your console to start playing on this Mac.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 12) {
                    Button("Pair a PS5", action: onPair)
                        .buttonStyle(.glassProminent)
                        .disabled(coordinator.canPresentPairing == false)
                    Button("Check Again") {
                        Task { await coordinator.retryStartup() }
                    }
                    .buttonStyle(.glass)
                }

                Text("Your console registration credentials stay in this Mac’s Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Your consoles")
                            .font(.title2.weight(.semibold))
                        Text("Choose a PS5 to start playing.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Pair another PS5", action: onPair)
                        .buttonStyle(.glass)
                        .disabled(coordinator.canPresentPairing == false)
                }

                ForEach(coordinator.consoles) { console in
                    consoleCard(console)
                }
            }
        }
    }

    private func consoleCard(_ console: MacConsoleSummary) -> some View {
        HStack(spacing: 18) {
            Image(systemName: "playstation.logo")
                .font(.title)
                .foregroundStyle(.blue)
                .frame(width: 52, height: 52)
                .background(.blue.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(console.name)
                    .font(.headline)
                HStack(spacing: 6) {
                    if console.hasAwayAddress {
                        Text(console.connectionRoute.title.uppercased())
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                console.connectionRoute == .away
                                    ? Color.orange.opacity(0.18)
                                    : Color.blue.opacity(0.14),
                                in: Capsule()
                            )
                    }
                    Text(console.activeHostAddress)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 20)

            Button {
                Task { await coordinator.wake(consoleID: console.id) }
            } label: {
                Label("Wake", systemImage: "power")
            }
            .buttonStyle(.glass)
            .disabled(coordinator.canStartConsoleAction == false)

            Button {
                onConnect(console.id)
            } label: {
                Label(
                    accessStore.allowsConnect ? "Connect" : "Unlock & Connect",
                    systemImage: accessStore.allowsConnect ? "play.fill" : "lock.open.fill"
                )
            }
            .buttonStyle(.glassProminent)
            .disabled(coordinator.canStartConsoleAction == false)

            Menu {
                Button("Connection Addresses…") {
                    onEditAddresses(console)
                }
                if console.hasAwayAddress {
                    Button(
                        console.connectionRoute == .away
                            ? "Switch to Home Route"
                            : "Switch to Away Route"
                    ) {
                        Task {
                            try? await coordinator.updateConnectionAddresses(
                                consoleID: console.id,
                                hostAddress: console.hostAddress,
                                awayHostAddress: console.awayHostAddress,
                                connectionRoute: console.connectionRoute == .away ? .home : .away
                            )
                        }
                    }
                }
                Divider()
                Button("Re-register…") {
                    onReRegister(
                        MacPairingTarget(
                            existingConsoleID: console.id,
                            displayName: console.name,
                            hostAddress: console.hostAddress
                        )
                    )
                }
                Divider()
                Button("Remove…", role: .destructive) {
                    onRemove(console)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .disabled(coordinator.canPresentPairing == false)
        }
        .padding(18)
        .background(
            .quaternary.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
    }

    private func statusCard(
        title: String,
        detail: String,
        symbol: String,
        showsProgress: Bool
    ) -> some View {
        HStack(spacing: 14) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func messageCard(
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button(buttonTitle, action: action)
        }
        .padding(16)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
    }

    private func consoleName(_ id: UUID) -> String {
        coordinator.consoles.first(where: { $0.id == id })?.name ?? "your PS5"
    }
}
