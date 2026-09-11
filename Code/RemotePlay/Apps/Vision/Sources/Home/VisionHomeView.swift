import FarframeCommerceUI
import Foundation
import PlayStationRemotePlay
import SwiftUI

/// A replaceable Vision Home surface. It renders immutable presentation state
/// and emits intents; it never reaches into a repository or streaming session.
struct VisionHomeView: View {
    let state: VisionHomeState
    let send: (VisionHomeAction) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var trialStatusCycleStart = Date()

    /// The FF mark's purple-to-blue sweep, used for every Pro accent on Home.
    private let brandGradient = LinearGradient(
        colors: [
            Color(red: 0.56, green: 0.36, blue: 1.0),
            Color(red: 0.24, green: 0.60, blue: 1.0),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    hero
                    if state.showsWhatsNewPrompt {
                        whatsNewPrompt
                    }
                    if let notice = state.accessNotice {
                        Text(notice)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    phaseContent
                    consoleContent
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
            }
            .navigationTitle("FARFRAME")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let trialExpiry = activeTrialExpiry {
                        activeTrialStatusPill(expiresAt: trialExpiry)
                    }

                    accessHeaderControls

                    Button {
                        send(.openSettings)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Open Settings")
                }
            }
        }
    }

    @ViewBuilder
    private var accessHeaderControls: some View {
        HStack(spacing: 10) {
            switch state.accessPresentation {
            case .checking:
                Button {} label: {
                    headerActionLabel("Unlock Farframe", symbol: "play.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(.blue.opacity(0.78), in: Capsule())
                .padding(7)
                .glassBackgroundEffect(in: Capsule())
                .disabled(true)

            case .trialEligible:
                Button {
                    send(.startTrial)
                } label: {
                    headerActionLabel("Unlock Farframe", symbol: "play.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(.blue.opacity(0.78), in: Capsule())
                .padding(7)
                .glassBackgroundEffect(in: Capsule())
                .hoverEffect(.highlight)

            case .startingTrial:
                Button {} label: {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Starting Your Trial…")
                    }
                    .font(.headline)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(.blue.opacity(0.78), in: Capsule())
                .padding(7)
                .glassBackgroundEffect(in: Capsule())
                .disabled(true)

            case .trialActive, .trialExpired:
                Button {
                    send(.openAccess)
                } label: {
                    headerActionLabel("Upgrade to PRO")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(brandGradient, in: Capsule())
                .padding(7)
                .glassBackgroundEffect(in: Capsule())
                .fixedSize(horizontal: true, vertical: false)
                .hoverEffect(.highlight)

            case .lifetimeUnlocked:
                Label("FARFRAME PRO Active", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(brandGradient)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .glassBackgroundEffect(in: Capsule())
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var activeTrialExpiry: Date? {
        guard case let .trialActive(expiresAt) = state.accessPresentation else {
            return nil
        }
        return expiresAt
    }

    private func headerActionLabel(_ title: String, symbol: String? = nil) -> some View {
        HStack(spacing: 7) {
            if let symbol {
                Image(systemName: symbol)
            }
            Text(title)
        }
        .font(.headline)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func activeTrialStatusPill(expiresAt: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let phase = trialStatusPhase(at: context.date)

            ZStack {
                switch phase {
                case .remaining:
                    Text(trialTimeRemaining(until: expiresAt, now: context.date))
                        .accessibilityLabel(
                            "3-Day Trial, \(trialTimeRemainingForAccessibility(until: expiresAt, now: context.date))"
                        )
                        .transition(.opacity)
                case .lifetimeUnlock:
                    Text("Lifetime Unlock")
                        .accessibilityLabel("Lifetime Unlock")
                        .transition(.opacity)
                case .oneTimePurchase:
                    Text("One-time purchase")
                        .accessibilityLabel("One-time purchase")
                        .transition(.opacity)
                }
            }
            .frame(width: 170)
            .lineLimit(1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: phase)
        }
        .font(.callout.monospacedDigit().weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassBackgroundEffect(in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    private func trialTimeRemaining(until expiresAt: Date, now: Date) -> String {
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return "Trial ending" }

        if remaining >= 60 * 60 {
            let totalHours = Int(remaining / (60 * 60))
            let days = totalHours / 24
            let hours = totalHours % 24
            return days > 0 ? "\(days)d \(hours)h left" : "\(hours)h left"
        }

        return "\(max(1, Int(ceil(remaining / 60))))m left"
    }

    private func trialTimeRemainingForAccessibility(until expiresAt: Date, now: Date) -> String {
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return "ending now" }

        if remaining >= 60 * 60 {
            let totalHours = Int(remaining / (60 * 60))
            let days = totalHours / 24
            let hours = totalHours % 24
            return days > 0
                ? "\(days) days and \(hours) hours remaining"
                : "\(hours) hours remaining"
        }

        return "\(max(1, Int(ceil(remaining / 60)))) minutes remaining"
    }

    private func trialStatusPhase(at date: Date) -> TrialStatusPhase {
        let elapsed = max(0, date.timeIntervalSince(trialStatusCycleStart))
        switch Int(elapsed) % 20 {
        case 10..<15:
            return .lifetimeUnlock
        case 15..<20:
            return .oneTimePurchase
        default:
            return .remaining
        }
    }

    private enum TrialStatusPhase: Equatable {
        case remaining
        case lifetimeUnlock
        case oneTimePurchase
    }

    private var whatsNewPrompt: some View {
        HStack(spacing: 14) {
            Button {
                send(.openWhatsNew)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.cyan)
                        .frame(width: 42, height: 42)
                        .background(.cyan.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Welcome to Farframe")
                            .font(.headline)
                        Text("See what you can do in version \(FarframeWhatsNewContent.currentReleaseVersion).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("What's New in Farframe")

            Button {
                send(.dismissWhatsNewPrompt)
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide What's New for this version")
        }
        .padding(16)
        .background(.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var hero: some View {
        VStack(spacing: 18) {
            HStack(spacing: 16) {
                FarframeBrandMark(size: 64)

                // The wordmark already sits in the window title, so the card
                // carries the offer instead of repeating the name.
                Text("Play at home.\nPay once.")
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 8) {
                    phaseBadge
                    controllerBadge
                }
            }

            FarframeSupportedDevices()

            Text("Play your PS5 on your home network. Automatic Away Play is not yet available.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch state.phase {
        case .recoveryFailed(let message):
            recoveryErrorCard(message: message)

        case let .registrationRequired(message, consoleID, displayName, hostAddress):
            registrationRequiredCard(
                message: message,
                consoleID: consoleID,
                displayName: displayName,
                hostAddress: hostAddress
            )

        case .connecting(let consoleID):
            operationCard(
                title: "Connecting",
                detail: consoleName(for: consoleID).map { "Opening Remote Play on \($0)…" }
                    ?? "Opening Remote Play…",
                symbol: "antenna.radiowaves.left.and.right",
                cancelAction: .cancelConnection
            )

        case .waking:
            // Shown inline on the console card so the list does not jump.
            EmptyView()

        case .streaming(let consoleID):
            HStack(spacing: 14) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Remote Play is active")
                        .font(.headline)
                    Text(consoleName(for: consoleID).map { "Playing on \($0)." }
                        ?? "Your PS5 stream is playing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
            }
            .padding(16)
            .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)

        case .removing(let consoleID):
            operationCard(
                title: "Removing PS5",
                detail: consoleName(for: consoleID).map { "Securely removing \($0) from this app…" }
                    ?? "Securely removing the saved PS5 from this app…",
                symbol: "trash"
            )

        case .disconnecting:
            operationCard(
                title: "Ending Remote Play",
                detail: "Closing the current session safely…",
                symbol: "xmark.circle"
            )

        case .failed(let message):
            errorCard(message: message)

        case .loading, .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var consoleContent: some View {
        if state.phase == .loading {
            loadingView
        } else if state.phase.hidesConsoleContent {
            EmptyView()
        } else if state.consoles.isEmpty {
            emptyView
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Your consoles")
                        .font(.headline)
                    Spacer()
                    Button {
                        send(.pairConsole)
                    } label: {
                        Label("Pair another", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.phase.isOperationInFlight)
                    .accessibilityLabel("Pair another PlayStation 5")
                }

                ForEach(state.consoles) { console in
                    consoleCard(console)
                }
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Loading saved consoles…")
                .font(.headline)
            Text("Your registration stays on this device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .accessibilityElement(children: .combine)
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("Pair your PS5", systemImage: "playstation.logo")
        } description: {
            Text("Link a console once, then return here to Wake or Connect.")
        } actions: {
            Button {
                send(.pairConsole)
            } label: {
                Label("Pair a PS5", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func consoleCard(_ console: VisionHomeConsoleSummary) -> some View {
        let isConnecting = state.phase == .connecting(consoleID: console.id)
        let isWaking = state.phase == .waking(consoleID: console.id)
        let isStreaming = state.phase == .streaming(consoleID: console.id)
        let operationInFlight = state.phase.isOperationInFlight

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "playstation.logo")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 42, height: 42)
                    .background(.blue.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(console.name)
                        .font(.headline)
                        .lineLimit(1)
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
                        // The address stays under Connection Addresses so a
                        // screenshot or recording never shows the network.
                        Text(console.connectionRoute == .away ? "Away route" : "Home network")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)

                Menu {
                    Button {
                        send(.editAddresses(consoleID: console.id))
                    } label: {
                        Label("Connection Addresses…", systemImage: "network")
                    }

                    if console.hasAwayAddress {
                        Button {
                            send(.toggleRoute(consoleID: console.id))
                        } label: {
                            Label(
                                console.connectionRoute == .away
                                    ? "Switch to Home Route"
                                    : "Switch to Away Route",
                                systemImage: console.connectionRoute == .away
                                    ? "house"
                                    : "antenna.radiowaves.left.and.right"
                            )
                        }
                    }

                    Divider()

                    Button {
                        send(.reRegister(consoleID: console.id))
                    } label: {
                        Label("Re-register", systemImage: "arrow.triangle.2.circlepath")
                    }

                    Button(role: .destructive) {
                        send(.remove(consoleID: console.id))
                    } label: {
                        Label("Remove from Remote Play", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 32, height: 32)
                }
                .disabled(operationInFlight)
                .accessibilityLabel("More options for \(console.name)")
            }

            HStack(spacing: 12) {
                Button {
                    send(.connect(consoleID: console.id))
                } label: {
                    if isStreaming {
                        Label("Playing", systemImage: "checkmark.circle.fill")
                    } else if isConnecting {
                        Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right")
                    } else if state.accessAllowsConnect == false {
                        Label("Unlock to Connect", systemImage: "lock.fill")
                    } else {
                        Label("Connect", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(operationInFlight || isStreaming)
                .accessibilityLabel(
                    isStreaming
                        ? "Playing on \(console.name)"
                        : isConnecting
                            ? "Connecting to \(console.name)"
                            : state.accessAllowsConnect
                                ? "Connect to \(console.name)"
                                : "Unlock Farframe to connect to \(console.name)"
                )

                Button {
                    send(.wake(consoleID: console.id))
                } label: {
                    if isWaking {
                        Label("Wake sent", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("Wake", systemImage: "power")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!console.canWake || operationInFlight || isStreaming)
                .accessibilityLabel(isWaking ? "Wake signal sent to \(console.name)" : "Wake \(console.name)")
            }

            if isWaking {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Wake signal sent. Give \(console.name) about ten seconds, then tap Connect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func operationCard(
        title: String,
        detail: String,
        symbol: String,
        cancelAction: VisionHomeAction? = nil
    ) -> some View {
        HStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let cancelAction {
                Button("Cancel") {
                    send(cancelAction)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn’t complete that action")
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }

            Button("Return to Home") {
                send(.dismissError)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func registrationRequiredCard(
        message: String,
        consoleID: UUID?,
        displayName: String,
        hostAddress: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "link.badge.plus")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Finish PS5 pairing")
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }

            Button(consoleID == nil ? "Pair a PS5" : "Re-register PS5") {
                send(.resumeRegistration(
                    consoleID: consoleID,
                    displayName: displayName,
                    hostAddress: hostAddress
                ))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func recoveryErrorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Finish restoring saved PS5 data")
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Remote Play will not change pairing data until recovery completes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }

            Button("Try Recovery Again") {
                send(.retry)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var phaseBadge: some View {
        Label(state.phase.badgeText, systemImage: state.phase.badgeSymbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.phase.badgeColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(state.phase.badgeColor.opacity(0.12), in: Capsule())
            .fixedSize()
    }

    private var controllerBadge: some View {
        Label(
            state.controllerIsConnected
                ? state.controllerName ?? "Controller"
                : "No controller",
            systemImage: "gamecontroller.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(state.controllerIsConnected ? Color.green : Color.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            (state.controllerIsConnected ? Color.green : Color.secondary).opacity(0.12),
            in: Capsule()
        )
        .fixedSize()
        .accessibilityLabel(
            state.controllerIsConnected
                ? "Controller connected: \(state.controllerName ?? "Controller")"
                : "No controller connected"
        )
    }

    private func consoleName(for id: UUID) -> String? {
        state.consoles.first(where: { $0.id == id })?.name
    }
}

private extension VisionHomePhase {
    var isOperationInFlight: Bool {
        switch self {
        case .waking, .connecting, .streaming, .disconnecting, .removing:
            true
        case .loading, .recoveryFailed, .registrationRequired,
             .ready, .failed:
            false
        }
    }

    var hidesConsoleContent: Bool {
        switch self {
        case .recoveryFailed, .registrationRequired:
            true
        case .loading, .ready, .waking, .connecting, .streaming,
             .disconnecting, .removing, .failed:
            false
        }
    }

    var badgeText: String {
        switch self {
        case .loading: "Loading"
        case .recoveryFailed: "Recovery Needed"
        case .registrationRequired: "Pairing Needed"
        case .ready: "Ready"
        case .waking: "Waking"
        case .connecting: "Connecting"
        case .streaming: "Playing"
        case .disconnecting: "Disconnecting"
        case .removing: "Removing"
        case .failed: "Needs Attention"
        }
    }

    var badgeSymbol: String {
        switch self {
        case .loading: "arrow.triangle.2.circlepath"
        case .recoveryFailed: "externaldrive.badge.exclamationmark"
        case .registrationRequired: "link.badge.plus"
        case .ready: "checkmark.circle.fill"
        case .waking: "power"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .streaming: "play.circle.fill"
        case .disconnecting: "xmark.circle"
        case .removing: "trash"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var badgeColor: Color {
        switch self {
        case .loading, .waking, .connecting, .disconnecting, .removing: .blue
        case .ready, .streaming: .green
        case .recoveryFailed, .registrationRequired, .failed: .orange
        }
    }
}
