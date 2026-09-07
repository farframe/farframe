import SwiftUI

enum FarframeWhatsNewContent {
    static let dismissedVersionKey = "farframe.whatsNew.dismissedVersion"

    static var currentReleaseVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
    }
}

struct FarframeWhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FarframeWhatsNewContent.dismissedVersionKey) private var dismissedVersion = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    featureSection(
                        title: "Play in your space",
                        subtitle: "A focused PS5 Remote Play experience built for Apple Vision Pro.",
                        features: [
                            .init(icon: "play.rectangle.fill", tint: .blue, title: "A spatial PS5 screen", detail: "Wake a saved PS5, connect, and place a responsive 1080p game screen wherever it feels comfortable."),
                            .init(icon: "gamecontroller.fill", tint: .green, title: "DualSense controls", detail: "Use the standard PS5 button layout with PS Menu, Home, Options, Create, and controller status close at hand."),
                            .init(icon: "waveform", tint: .cyan, title: "Clear, adjustable audio", detail: "Mute with a tap or drag the pinned volume control while the stream keeps the game in focus.")
                        ]
                    )
                    featureSection(
                        title: "Built for long sessions",
                        subtitle: "Farframe keeps controls available without leaving them in the way.",
                        features: [
                            .init(icon: "slider.horizontal.3", tint: .purple, title: "Customizable control rail", detail: "Pin the controls you use, let the rail fade while you play, and open Stats when you want a closer look."),
                            .init(icon: "gauge.with.dots.needle.67percent", tint: .orange, title: "Set up by what you play", detail: "Answer what you're playing and Farframe sets the quality for it, with the resolution, frame rate, and bitrate shown under every option before you choose."),
                            .init(icon: "power", tint: .mint, title: "Wake, disconnect, or rest", detail: "Manage the PS5 session directly and choose whether closing the player leaves the console awake or puts it in Rest Mode.")
                        ]
                    )
                }
                .padding(24)
            }
            .navigationTitle("What's New")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismissedVersion = FarframeWhatsNewContent.currentReleaseVersion
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 650)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Version \(FarframeWhatsNewContent.currentReleaseVersion)", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.cyan)
            Text("Welcome to Farframe")
                .font(.largeTitle.bold())
            Text("Bring your PS5 into your space with a clean screen, familiar controls, and quick session management.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func featureSection(
        title: String,
        subtitle: String,
        features: [FarframeFeature]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: feature.icon)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(feature.tint)
                            .frame(width: 40, height: 40)
                            .background(feature.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(feature.title)
                                .font(.headline)
                            Text(feature.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(14)

                    if index < features.count - 1 {
                        Divider().padding(.leading, 68)
                    }
                }
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct FarframeFeature: Identifiable {
    var id: String { title }
    let icon: String
    let tint: Color
    let title: String
    let detail: String
}
