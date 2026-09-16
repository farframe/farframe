import SwiftUI

enum FarframeWhatsNewContent {
    static let dismissedVersionKey = "farframe.whatsNew.dismissedVersion"
    static let currentReleaseVersion = "1.3"
    static let contentID = "1.3-ambient-glow-rail"
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
                        title: "Play at home",
                        subtitle: "Wake your console, place the screen, and play.",
                        features: [
                            .init(icon: "play.rectangle.fill", tint: .blue, title: "Your game, in your space", detail: "Wake your console on your home network, connect, and put the screen where it feels comfortable."),
                            .init(icon: "arrow.up.left.and.arrow.down.right", tint: .cyan, title: "Place and resize freely", detail: "Move the window and make the picture as large or as small as you want."),
                            .init(icon: "rectangle.landscape.rotate", tint: .mint, title: "Move the controls", detail: "Drag the control rail to any side of the game."),
                            .init(icon: "gamecontroller.fill", tint: .green, title: "Pair your controller with Vision Pro", detail: "Turn the controller off, hold PS and Create until the light flashes, then choose it in Settings, Bluetooth. Pair it with Vision Pro, not the console.")
                        ]
                    )
                    featureSection(
                        title: "New in 1.3",
                        subtitle: "Ambient glow in shared space, plus immersive rooms when you want them.",
                        features: [
                            .init(icon: "sparkles", tint: .purple, title: "Ambient glow in your space", detail: "Color from the game around the window while you stay in shared space. This is the highlight of 1.3."),
                            .init(icon: "cube.transparent", tint: .orange, title: "Immersive environments", detail: "Mixed and Glass Arena add immersive glow and room options around your game when you want a full environment.")
                        ]
                    )
                }
                .padding(24)
            }
            .navigationTitle("What's New")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hide until next update") {
                        dismissedVersion = FarframeWhatsNewContent.contentID
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
            Text("Wake your console, place the screen, and play. Version 1.3 adds ambient glow around the window in your space.")
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
