#if os(visionOS)
    import SwiftUI

    /// Same appearance control in the app and isolated native renderer harness.
    struct VisionArenaExteriorPicker: View {
        @Bindable var exterior: VisionArenaExteriorController
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Picker("View", selection: Binding(get: { exterior.selection }, set: { exterior.select($0) }))
                {
                    ForEach(VisionArenaExteriorStyle.allCases) { style in Text(style.title).tag(style) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("farframe.arena.exterior")
                .accessibilityHint("Changes the scenery while keeping your screen and game in place.")
                if exterior.isLoading {
                    Label("Loading view…", systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = exterior.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
#endif
