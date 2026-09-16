#if os(visionOS)
import SwiftUI

struct VisionArenaCoveragePicker: View {
    @Binding var selection: VisionArenaLightCoverage
    @Binding var pillarGlow: Bool
    var available: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Light Coverage").font(.subheadline.weight(.semibold))
            Picker("Light Coverage", selection: Binding(get: { available ? selection : .screen }, set: { selection = $0 })) {
                Text("Screen").tag(VisionArenaLightCoverage.screen)
                Text("Architectural Wrap").tag(VisionArenaLightCoverage.architecturalWrap)
                    .disabled(!available)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("farframe.arena.lightCoverage")
            .disabled(!available)
            if available && selection == .architecturalWrap {
                Toggle("Pillar Glow", isOn: $pillarGlow)
                    .accessibilityIdentifier("farframe.arena.pillarGlow")
            }
            if !available {
                Text("Architectural Wrap is unavailable. Screen lighting still works.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
