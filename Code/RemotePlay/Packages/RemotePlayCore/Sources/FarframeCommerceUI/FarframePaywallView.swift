import CommerceCore
import FarframeStorefront
import StoreKit
import SwiftUI

/// One adaptive StoreKit surface for Farframe on iPhone, iPad, Mac, and
/// Apple Vision Pro. Its geometry responds to available space rather than
/// checking device names or model families.
public struct FarframePaywallView: View {
    @Bindable private var accessStore: FarframeAccessStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.purchase) private var purchase

    private let proTint = Color(red: 0.04, green: 0.48, blue: 0.94)

    public init(accessStore: FarframeAccessStore) {
        self.accessStore = accessStore
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    valueProposition
                    purchaseControls

                    if showsCatalogMessage {
                        catalogMessage
                    }

                    if let notice = accessStore.notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .accessibilityLabel(notice)
                    }

                    accessStatus
                    benefits

                    #if DEBUG
                    debugAccessSection
                    #endif
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle("Farframe Pro")
            .farframeCompactNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onChange(of: accessStore.allowsConnect) { _, allowsConnect in
            if allowsConnect { dismiss() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                FarframeBrandMark(size: 56)
                    .accessibilityHidden(true)

                Text("Play everywhere.\nPay once.")
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Try three full days free before you decide.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The two claims that are actually worth money, said first and said large.
    ///
    /// Both of them used to be here. One was a row of glyphs over two lines of
    /// 12-point grey caption; the other was the first item in a footnote list.
    /// Both sat *below* the buttons, so the argument for buying arrived after
    /// the decision, and between them they said the platform promise twice and
    /// the family promise twice. The owner's note was blunt — "all that
    /// information is great sales material… make that a bigger line… I think
    /// that should be at the top" — and the numbers agree with him: the nearest
    /// competitor asks more than this for one platform and no family licence.
    ///
    /// They are tinted panels rather than Liquid Glass on purpose. Glass is the
    /// control layer on this sheet and the buttons below own it; making the
    /// argument out of the same material would flatten the difference between
    /// what you read and what you press.
    private var valueProposition: some View {
        VStack(spacing: 12) {
            valuePanel(
                headline: "One purchase. Four platforms.",
                detail: "Apple Vision Pro, Mac, iPad, and iPhone."
            ) {
                HStack(spacing: 22) {
                    ForEach(["vision.pro", "macbook", "ipad", "iphone"], id: \.self) { symbol in
                        Image(systemName: symbol)
                            .font(.title2)
                            .frame(minWidth: 26, minHeight: 26)
                    }
                }
                .foregroundStyle(proTint.gradient)
            }

            valuePanel(
                headline: "One payment for your whole family.",
                detail: "Lifetime Unlock is shared through Family Sharing."
            ) {
                Image(systemName: "person.2.fill")
                    .font(.title2)
                    .foregroundStyle(proTint.gradient)
                    .frame(minWidth: 26, minHeight: 26)
            }
        }
    }

    private func valuePanel(
        headline: String,
        detail: String,
        @ViewBuilder glyphs: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            glyphs()
                .accessibilityHidden(true)
            Text(headline)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            proTint.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline) \(detail)")
    }

    /// What is left once the two headline claims are made above: the things
    /// worth knowing, none of which is said twice on this sheet any more.
    private var benefits: some View {
        VStack(alignment: .leading, spacing: 8) {
            benefit("Touch controls on iPhone and iPad. Compatible controllers across devices.", symbol: "gamecontroller")
            benefit("No subscription. No recurring charge.", symbol: "infinity")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func benefit(_ title: String, symbol: String) -> some View {
        Label {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(proTint)
                .accessibilityHidden(true)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var accessStatus: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: accessStatusSymbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accessStatusTint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(accessStore.statusTitle)
                    .font(.subheadline.weight(.semibold))
                Text(accessStore.statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .farframeGlassSurface(cornerRadius: 16)
    }

    @ViewBuilder
    private var purchaseControls: some View {
        #if os(visionOS)
        purchaseActionStack
        #else
        GlassEffectContainer(spacing: 12) {
            purchaseActionStack
        }
        #endif
    }

    private var purchaseActionStack: some View {
        VStack(spacing: 12) {
            if showsTrialOption {
                trialAction
            }
            if showsLifetimeOption {
                lifetimeAction
            }
            restoreAction
        }
    }

    private var trialAction: some View {
        VStack(spacing: 6) {
            Button {
                Task {
                    await accessStore.purchaseTrial { product in
                        try await purchase(product)
                    }
                }
            } label: {
                if accessStore.purchaseInProgressID == FarframeProductID.trial {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Starting 3-Day Trial")
                } else {
                    Label("Start Free 3-Day Trial", systemImage: "clock")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
            }
            .farframePrimaryButtonStyle(tint: proTint)
            .controlSize(.large)
            .disabled(
                accessStore.trialProduct == nil
                    || accessStore.purchaseInProgressID != nil
                    || accessStore.isRestoring
            )

            Text("Starts when you choose. No automatic charge.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var lifetimeAction: some View {
        VStack(spacing: 6) {
            Button {
                Task {
                    await accessStore.purchaseLifetime { product in
                        try await purchase(product)
                    }
                }
            } label: {
                if accessStore.purchaseInProgressID == FarframeProductID.lifetime {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Completing Lifetime Unlock purchase")
                } else if let price = accessStore.lifetimeDisplayPrice {
                    Label("Lifetime Unlock · \(price)", systemImage: "lock.open.fill")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Lifetime Unlock · Price Unavailable", systemImage: "lock.open.fill")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
            }
            .farframePrimaryButtonStyle(tint: proTint)
            .controlSize(.large)
            .disabled(
                accessStore.lifetimeProduct == nil
                    || accessStore.purchaseInProgressID != nil
                    || accessStore.isRestoring
            )

            Text("One-time purchase. Yours to keep.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var restoreAction: some View {
        Button {
            Task { await accessStore.restorePurchases() }
        } label: {
            if accessStore.isRestoring {
                Label("Restoring Purchases…", systemImage: "arrow.clockwise")
            } else {
                Label("Restore Purchases", systemImage: "arrow.clockwise")
            }
        }
        .farframeSecondaryButtonStyle()
        .controlSize(.large)
        .disabled(accessStore.isRestoring || accessStore.purchaseInProgressID != nil)
    }

    private var catalogMessage: some View {
        HStack(spacing: 8) {
            if accessStore.isLoadingProducts {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            }

            Text(accessStore.catalogError ?? "Loading purchase options…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if accessStore.isLoadingProducts == false {
                Button("Retry") {
                    Task { await accessStore.loadProducts() }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    #if DEBUG
    private var debugAccessSection: some View {
        VStack(spacing: 8) {
            Divider()
            Text("Testing")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Button("Enable PRO for Testing") {
                accessStore.enableDebugProAccess()
                dismiss()
            }
            .farframeSecondaryButtonStyle()
            Text("Debug builds only. This bypass is not compiled into the App Store build.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    #endif

    private var showsTrialOption: Bool {
        switch accessStore.state {
        case .loading, .trialEligible:
            true
        case .trialActive, .trialExpired, .lifetimeUnlocked:
            false
        }
    }

    private var showsLifetimeOption: Bool {
        accessStore.state.isLifetimeUnlocked == false
    }

    private var showsCatalogMessage: Bool {
        (showsTrialOption && accessStore.trialProduct == nil)
            || (showsLifetimeOption && accessStore.lifetimeProduct == nil)
    }

    private var accessStatusSymbol: String {
        switch accessStore.state {
        case .loading: "arrow.triangle.2.circlepath"
        case .trialEligible: "clock.badge.checkmark"
        case .trialActive: "checkmark.circle.fill"
        case .trialExpired: "lock.fill"
        case .lifetimeUnlocked(let ownership):
            ownership == .familyShared ? "person.2.fill" : "checkmark.seal.fill"
        }
    }

    private var accessStatusTint: Color {
        switch accessStore.state {
        case .loading: .secondary
        case .trialEligible: .blue
        case .trialActive, .lifetimeUnlocked: .green
        case .trialExpired: .orange
        }
    }
}

private extension View {
    @ViewBuilder
    func farframeCompactNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder
    func farframeGlassSurface(cornerRadius: CGFloat) -> some View {
        #if os(visionOS)
        background(
            .thinMaterial,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        #else
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        #endif
    }

    @ViewBuilder
    func farframePrimaryButtonStyle(tint: Color) -> some View {
        #if os(visionOS)
        buttonStyle(.borderedProminent)
            .tint(tint)
        #else
        buttonStyle(.glassProminent)
            .tint(tint)
        #endif
    }

    @ViewBuilder
    func farframeSecondaryButtonStyle() -> some View {
        #if os(visionOS)
        buttonStyle(.bordered)
        #else
        buttonStyle(.glass)
        #endif
    }
}
