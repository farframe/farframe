import FarframeCommerceUI
import FarframeStorefront
import PlayStationRemotePlay
import SwiftUI

struct MobileRemotePlayHomeView: View {
    @Bindable var coordinator: MobileRemotePlayCoordinator
    @Bindable var accessStore: FarframeAccessStore
    let reconnectConsole: MobileConsoleSummary?
    let onConnect: (UUID) -> Void
    let onShowAccess: () -> Void
    let onPair: () -> Void
    let onReRegister: (MobilePairingTarget) -> Void
    let onRemove: (MobileConsoleSummary) -> Void
    var onEditAddresses: (MobileConsoleSummary) -> Void = { _ in }

    /// The readable column every non-hero section sits in. The hero is
    /// deliberately outside it, because its whole job is to run edge to edge.
    private static let readableWidth: CGFloat = 1_080

    /// How far the hero's colour reaches above the top of the scroll content.
    ///
    /// Enough to cover a status bar plus whichever bar the platform puts at the
    /// top — an iPhone navigation bar, or the iPad floating tab bar — with room
    /// to spare, so the colour is already there rather than starting at a line
    /// just below the chrome.
    private static let heroOverscan: CGFloat = 240

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero
                VStack(alignment: .leading, spacing: 22) {
                    accessBanner
                    if let reconnectConsole, coordinator.hasActiveSession == false {
                        reconnectCard(reconnectConsole)
                    }
                    operationCard
                    consoleContent
                }
                .frame(maxWidth: Self.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 18)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        // The bar says which tab you are in; the hero says whose app this is.
        // They used to both say FARFRAME, which on an iPhone stacked the same
        // word twice within eighty points. The iPad cannot show a navigation
        // title at all beside the floating tab bar, so the wordmark has to live
        // in the hero, and it is the bar that gives way.
        .navigationTitle("Play")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                controllerBadge
            }
        }
    }

    /// The first thing anyone sees, and the app's weakest moment until now.
    ///
    /// It began as a flat material card floating in a column with grey on both
    /// sides, then became a full-bleed colour field. Full-bleed fixed the sides
    /// and left the real problem, which the owner named on hardware: "you just
    /// see a big stripe that doesn't blend in with the rest". A band of colour
    /// that starts under the top bar and stops on a hard horizontal line is a
    /// banner stuck onto a page, not the top of one.
    ///
    /// Two things fix that, and both are about the edges rather than the colour:
    ///
    /// 1. **It reaches up.** The wash is the hero's background, offset above the
    ///    top of the scroll content, so the colour is already behind the status
    ///    bar and the top bar instead of beginning below them.
    /// 2. **It never ends on a line.** The wash is masked with a vertical fade
    ///    and dissolves into the page's own background, so there is no boundary
    ///    to notice.
    ///
    /// The chrome went down with it. The four device glyphs and the two lines of
    /// Family Sharing copy that used to sit here are the purchase surface's
    /// argument, made twice as loudly there now, and repeating them above the
    /// fold sold nothing to somebody who had already installed the app. What
    /// stays is who this is and what to do first.
    ///
    /// `backgroundExtensionEffect()` was tried here and removed. The modifier
    /// mirrors and blurs a view's edges into surrounding safe area, and Apple's
    /// stated use is a hero in the detail column of a `NavigationSplitView` so
    /// it continues under a sidebar or inspector. Neither condition holds, and
    /// the app has no sidebar at all any more. An explicit offset is what
    /// actually reaches past the top inset from inside a `ScrollView`.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                FarframeBrandMark(size: 58)
                VStack(alignment: .leading, spacing: 5) {
                    Text("FARFRAME").font(.title2.bold()).tracking(1.5)
                    Text("Your PS5. Your favorite screen.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text("Pair once on your home Wi-Fi, then play at home or away with touch or a DualSense.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 22)
        .padding(.bottom, 34)
        .frame(maxWidth: Self.readableWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .background(heroWash)
    }

    /// The brand colour behind the hero, with neither of a banner's two edges.
    ///
    /// A `GeometryReader` rather than negative padding because the fade has to
    /// be measured against the whole washed area including the overscan, and a
    /// mask applied after a negative pad is sized to the unpadded frame and
    /// erases the overhang it was supposed to soften.
    private var heroWash: some View {
        GeometryReader { proxy in
            FarframeBrandBackdrop(fillsBackground: false)
                .frame(height: proxy.size.height + Self.heroOverscan)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.55),
                            .init(color: .black.opacity(0), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .offset(y: -Self.heroOverscan)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Keeps the trial and Lifetime Unlock offer one tap from Home instead of
    /// buried in Settings, and shows how much trial time is left.
    @ViewBuilder
    private var accessBanner: some View {
        switch accessStore.state {
        case .loading, .lifetimeUnlocked:
            EmptyView()
        case .trialEligible:
            accessBannerCard(
                title: "Try Farframe free for 3 days",
                detail: "Then keep it forever with a one-time Lifetime Unlock. No subscription.",
                symbol: "clock.badge.checkmark",
                tint: .blue,
                actionTitle: "Start Free 3-Day Trial"
            )
        case .trialActive(_, let expiresAt):
            TimelineView(.periodic(from: .now, by: 60)) { context in
                accessBannerCard(
                    title: "3-Day Trial · \(Self.trialTimeRemaining(until: expiresAt, now: context.date))",
                    detail: "Unlock Farframe for life on every Apple device, for your whole family.",
                    symbol: "clock.fill",
                    tint: .green,
                    actionTitle: "Upgrade to Pro"
                )
            }
        case .trialExpired:
            accessBannerCard(
                title: "Your 3-Day Trial has ended",
                detail: "Upgrade to Farframe Pro to keep connecting and playing.",
                symbol: "lock.fill",
                tint: .orange,
                actionTitle: "Upgrade to Pro"
            )
        }
    }

    /// The trial and Lifetime Unlock offer, in whichever of two shapes the
    /// available width can actually hold.
    ///
    /// It was one `HStack`. The call to action is `fixedSize()` in that row,
    /// because a button that wraps its own title is worse than one that does
    /// not, so on an iPhone the button took the width it needed and the words
    /// took what was left — about a hundred points. "Try Farframe free for 3
    /// days" came out as five lines with "Far-frame" hyphenated across two of
    /// them, on the first screen of the app.
    ///
    /// `ViewThatFits` keeps the row while the row's unwrapped width fits and
    /// takes the stack otherwise. Measured against the space there is, never
    /// against the device: an iPad in Slide Over gets the phone's answer, which
    /// is the correct one for the width it has.
    ///
    /// The call to action is also a real button, and must stay one. It was once
    /// a `Text` with a solid capsule fill inside an outer plain button. A solid
    /// fill is opaque by construction, so it could not tint, lens or respond to
    /// the system's Liquid Glass setting the way every other primary action in
    /// the app does, and it read as a control that was not one.
    private func accessBannerCard(
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        actionTitle: String
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                accessBannerGlyph(symbol, tint: tint)
                accessBannerText(title: title, detail: detail)
                Spacer(minLength: 8)
                accessBannerButton(actionTitle, tint: tint)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    accessBannerGlyph(symbol, tint: tint)
                    accessBannerText(title: title, detail: detail)
                    Spacer(minLength: 0)
                }
                accessBannerButton(actionTitle, tint: tint, fillsWidth: true)
            }
        }
        .padding(16)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func accessBannerGlyph(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.title3.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(tint.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }

    private func accessBannerText(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func accessBannerButton(
        _ actionTitle: String,
        tint: Color,
        fillsWidth: Bool = false
    ) -> some View {
        Button(action: onShowAccess) {
            Text(actionTitle)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.glassProminent)
        .tint(tint)
        .fixedSize(horizontal: fillsWidth == false, vertical: false)
    }

    static func trialTimeRemaining(until expiresAt: Date, now: Date) -> String {
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return "ending" }
        if remaining >= 60 * 60 {
            let totalHours = Int(remaining / (60 * 60))
            let days = totalHours / 24
            let hours = totalHours % 24
            return days > 0 ? "\(days)d \(hours)h left" : "\(hours)h left"
        }
        return "\(max(1, Int((remaining / 60).rounded(.up))))m left"
    }

    @ViewBuilder
    private var operationCard: some View {
        switch coordinator.phase {
        case .loading:
            statusCard(
                title: "Loading saved consoles",
                detail: "Checking this device's private Remote Play registration.",
                symbol: "arrow.triangle.2.circlepath",
                progress: true
            )
        case .recoveryRequired(let message):
            messageCard(
                title: "Pairing recovery required",
                detail: message,
                symbol: "exclamationmark.shield.fill",
                buttonTitle: coordinator.registrationRecovery == nil ? "Retry" : "Resume"
            ) {
                if let recovery = coordinator.registrationRecovery {
                    onReRegister(recovery.target)
                } else {
                    Task { await coordinator.retryStartup() }
                }
            }
        case .waking(let consoleID):
            statusCard(
                title: coordinator.wakeRequestWasSent ? "Wake request sent" : "Sending wake request",
                detail: coordinator.wakeRequestWasSent
                    ? "Waiting briefly before Connect becomes available. \(consoleName(consoleID)) has not confirmed it is awake."
                    : "Sending a wake request to \(consoleName(consoleID)).",
                symbol: "power",
                progress: true
            )
        case .prepared, .connecting:
            statusCard(
                title: "Opening Remote Play",
                detail: "Preparing video, audio, and DualSense delivery.",
                symbol: "antenna.radiowaves.left.and.right",
                progress: true
            )
        case .disconnecting:
            statusCard(
                title: "Ending Remote Play",
                detail: "Closing the native session safely.",
                symbol: "xmark.circle",
                progress: true
            )
        case .failed(let message):
            messageCard(
                title: "Remote Play needs attention",
                detail: message + "\n\nFarframe connects directly to the address saved for this route. At home, use the Home route on your Wi-Fi. Away from home, first configure access to your home network separately, then add the reachable PS5 address from the console menu and choose Away. Farframe does not provide a VPN.",
                symbol: "exclamationmark.triangle.fill",
                buttonTitle: coordinator.requiresStartupRecovery ? "Check Again" : "Dismiss",
                shareURL: coordinator.requiresStartupRecovery
                    ? nil : coordinator.latestConnectionReportURL
            ) {
                if coordinator.requiresStartupRecovery {
                    Task { await coordinator.retryStartup() }
                } else {
                    coordinator.dismissError()
                }
            }
        case .ready:
            if let message = coordinator.wakeStatusMessage {
                statusCard(
                    title: "Wake request sent",
                    detail: message,
                    symbol: "power",
                    progress: false
                )
            }
        case .streaming:
            EmptyView()
        }
    }

    @ViewBuilder
    private var consoleContent: some View {
        if coordinator.phase == .loading {
            EmptyView()
        } else if coordinator.consoles.isEmpty {
            ContentUnavailableView {
                Label("No PS5 saved here", systemImage: "playstation.logo")
            } description: {
                Text("Pair directly with your PS5 to start playing. Leave the console on or in rest mode on this network and this device will find it. Registration credentials stay on this device.")
            } actions: {
                Button("Pair a PS5", action: onPair)
                    .buttonStyle(.glassProminent)
                    .disabled(coordinator.canPresentPairing == false)
                Button("Check Again") {
                    Task { await coordinator.retryStartup() }
                }
                .buttonStyle(.glass)
            }
            // Its own measure, not the column's. `ContentUnavailableView`
            // centres its content, so at the full 1,080-point readable width a
            // 13-inch iPad ran the description as one line across the whole
            // span. This is the first screen a new install shows and the only
            // instruction on it, so it is worth a comfortable line length.
            .frame(maxWidth: 520)
            // And its own height. Left at its natural size it sat at the top of
            // roughly half a screen of nothing, which reads as a page that
            // failed to load rather than a page with nothing on it yet. Taking
            // the space and centring in it is the difference between stranded
            // and placed.
            .containerRelativeFrame(.vertical, alignment: .center) { height, _ in
                max(320, height * 0.55)
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Your consoles")
                            .font(.title2.weight(.semibold))
                        Text("Saved privately on this device")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Pair Another", action: onPair)
                        .buttonStyle(.glass)
                        .disabled(coordinator.canPresentPairing == false)
                }

                // Most people own one PS5. A single card in a grid of adaptive
                // columns is 500 points of card floating in a 1080-point
                // column, which on a large screen is mostly nothing. One
                // console therefore gets the whole column and a bigger
                // Connect; several keep the grid. Driven by how many consoles
                // there are, so a phone and a 13-inch screen get the same
                // answer for the same content.
                if coordinator.consoles.count == 1, let console = coordinator.consoles.first {
                    consoleCard(console, isPrimary: true)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 285, maximum: 500), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(coordinator.consoles) { console in
                            consoleCard(console, isPrimary: false)
                        }
                    }
                }
            }
        }
    }

    private func consoleCard(_ console: MobileConsoleSummary, isPrimary: Bool) -> some View {
        VStack(alignment: .leading, spacing: isPrimary ? 22 : 18) {
            HStack(spacing: 14) {
                Image(systemName: "playstation.logo")
                    .font(isPrimary ? .title : .title2)
                    .foregroundStyle(.blue)
                    .frame(width: isPrimary ? 58 : 48, height: isPrimary ? 58 : 48)
                    .background(.blue.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(console.name)
                        .font(isPrimary ? .title2.weight(.semibold) : .headline)
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
                        Text(console.activeHostAddress)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
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
                                    connectionRoute: console.connectionRoute == .away
                                        ? .home
                                        : .away
                                )
                            }
                        }
                    }
                    Divider()
                    Button("Re-register") {
                        onReRegister(
                            MobilePairingTarget(
                                existingConsoleID: console.id,
                                displayName: console.name,
                                hostAddress: console.hostAddress
                            )
                        )
                    }
                    Button("Remove", role: .destructive) {
                        onRemove(console)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                // A custom menu label gets no pointer treatment of its own,
                // unlike the standard buttons beside it.
                .hoverEffect(.highlight)
                .disabled(coordinator.canPresentPairing == false)
            }

            HStack(spacing: 12) {
                Button {
                    onConnect(console.id)
                } label: {
                    Label("Connect", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(connectActionsAreDisabled)

                Button {
                    Task { await coordinator.wake(consoleID: console.id) }
                } label: {
                    Label("Wake", systemImage: "power")
                }
                .buttonStyle(.glass)
                .disabled(connectActionsAreDisabled)
            }
            .controlSize(isPrimary ? .large : .regular)
        }
        .padding(isPrimary ? 22 : 18)
        // A console card is content, not navigation, and Apple reserves Liquid
        // Glass for the layer that floats above content. The card stays a solid
        // grouped background; the buttons inside it are the glass.
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
    }

    private func reconnectCard(_ console: MobileConsoleSummary) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text("Session paused in the background")
                    .font(.headline)
                Text("Reconnect to \(console.name) when you're ready.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Reconnect") { onConnect(console.id) }
                .buttonStyle(.glassProminent)
                .disabled(connectActionsAreDisabled)
        }
        .padding(16)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }

    private func statusCard(
        title: String,
        detail: String,
        symbol: String,
        progress: Bool
    ) -> some View {
        HStack(spacing: 14) {
            if progress {
                ProgressView()
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }

    private func messageCard(
        title: String,
        detail: String,
        symbol: String,
        buttonTitle: String,
        shareURL: URL? = nil,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Label("Share Connection Report", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.glass)
                }
                Button(buttonTitle, action: action)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(16)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }

    private var controllerBadge: some View {
        Label(
            coordinator.controllerConnection.isConnected
                ? coordinator.controllerConnection.name ?? "Controller"
                : "No Controller",
            systemImage: coordinator.controllerConnection.isConnected
                ? "gamecontroller.fill"
                : "gamecontroller"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(coordinator.controllerConnection.isConnected ? .green : .secondary)
    }

    private var connectActionsAreDisabled: Bool {
        coordinator.canStartConsoleAction == false
    }

    private func consoleName(_ id: UUID) -> String {
        coordinator.consoles.first(where: { $0.id == id })?.name ?? "your PS5"
    }
}
