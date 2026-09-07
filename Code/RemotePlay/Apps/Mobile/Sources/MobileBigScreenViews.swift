import FarframeCommerceUI
import SwiftUI

/// What a connected display shows.
///
/// When the game is here it is the only thing here: full-bleed video on black,
/// no chrome, no glass, nothing floating over it. The display is declared
/// non-interactive, so anything that looked like a control would be a lie, and
/// the person's eyes are on the game rather than on the app.
///
/// When there is no game it says why, once, in the middle of the screen.
struct MobileBigScreenRootView: View {
    private let host = MobileBigScreenHost.shared
    @AppStorage("RemotePlayMobile.videoContentMode")
    private var videoModeRaw = MobileVideoContentMode.fit.rawValue

    var body: some View {
        ZStack {
            Color.black
            if host.routing.state.bigScreenIsShowingVideo,
               let coordinator = host.coordinator,
               let surface = coordinator.videoSurface,
               let sessionID = coordinator.activeSessionID {
                MobileSampleBufferDisplayView(
                    sessionID: sessionID,
                    videoSurface: surface,
                    // The first surface to queue an attachment is what releases
                    // a prepared session, and on a connected display that is
                    // this one. It resolves through the same entitlement gate
                    // the in-app player uses; there is no second path.
                    onSurfaceQueued: { host.startGate?.surfaceQueued(sessionID: sessionID) },
                    contentMode: MobileVideoContentMode(rawValue: videoModeRaw) ?? .fit
                )
                .ignoresSafeArea()
            } else {
                idleCard
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
    }

    private var idleCard: some View {
        ZStack {
            FarframeBrandBackdrop(intensity: 1.15)
            VStack(spacing: 18) {
                FarframeBrandMark(size: 96)
                Text("FARFRAME")
                    .font(.system(size: 44, weight: .bold))
                    .tracking(8)
                Text(host.routing.state.externalIdleMessage ?? "Ready when you are.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(48)
            .frame(maxWidth: 900)
        }
        .ignoresSafeArea()
    }
}

/// What the device shows in place of the picture while the game is on a
/// connected display.
///
/// The touch controls, the session strip and the stream-health panel are all
/// still there and unchanged — this replaces only the video, which is the one
/// thing that cannot be in two places at once. It is a large floating panel,
/// which is the case where Liquid Glass genuinely earns its place.
struct MobileBigScreenDevicePanel: View {
    let title: String
    let sizeDescription: String?
    let health: MobileStreamHealthAssessment
    let bringItBack: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tv.badge.wifi")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if let sizeDescription {
                Text(sizeDescription)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("Your controls, your stats and the session actions stay here. Everything below still plays the game.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Circle()
                    .fill(health.level.color)
                    .frame(width: 10, height: 10)
                Text("Stream health · \(health.level.title)")
                    .font(.caption.weight(.semibold))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Stream health: \(health.level.title)")
            Button("Bring the Game Back Here", action: bringItBack)
                .buttonStyle(.glass)
        }
        .farframePlayerPanel()
        .foregroundStyle(.white)
    }
}
