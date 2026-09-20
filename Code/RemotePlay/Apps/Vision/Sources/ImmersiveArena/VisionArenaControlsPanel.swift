#if os(visionOS)
import SwiftUI

/// The native tablet shares one layout for presets, adjustments and room options.
struct VisionArenaControlsPanel<Content: View>: View {
    @Binding var movable: Bool
    @Binding var partialImmersion: Bool
    var selectedPreset: VisionArenaScreenPlacement.Preset?
    @Binding var size: Float
    @Binding var distance: Float
    @Binding var tilt: Float
    @Binding var keepFacing: Bool
    let selectPreset: (VisionArenaScreenPlacement.Preset) -> Void
    var savedScreens: [VisionArenaSavedScreen] = []
    var selectedSavedScreenID: UUID? = nil
    var saveScreen: ((String) -> Bool)? = nil
    var recallScreen: (UUID) -> Void = { _ in }
    var removeScreen: (UUID) -> Void = { _ in }
    @State private var screenName = ""
    @State private var removingScreen: VisionArenaSavedScreen?
    @State private var saveFailed = false
    let reset: () -> Void
    let exit: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content()
                Divider()
                Text("Screen · Cinema & Positions").font(.headline)
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
                    ForEach(VisionArenaScreenPlacement.Preset.allCases) { preset in
                        Button { selectPreset(preset) } label: {
                            Text(preset.localizedTitle)
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .tint(selectedPreset == preset ? .accentColor : .white.opacity(0.12))
                        .accessibilityIdentifier("farframe.arena.preset.\(preset.rawValue)")
                        .accessibilityAddTraits(selectedPreset == preset ? [.isSelected] : [])
                    }
                }
                adjustment("Size", value: $size, range: VisionArenaScreenPlacement.scaleRange,
                    detail: "\(Int((size * 100).rounded()))%", identifier: "size", step: 0.05)
                adjustment("Distance", value: $distance, range: 0.5...12,
                    detail: String(format: "%.1f m", distance), identifier: "distance", step: 0.25)
                adjustment("Tilt", value: $tilt, range: -30...90,
                    detail: "\(Int(tilt.rounded()))°", identifier: "tilt", step: 1)
                Toggle("Move Screen", isOn: $movable)
                    .accessibilityIdentifier("farframe.arena.moveScreen")
                Toggle("Keep Facing Me", isOn: $keepFacing)
                    .accessibilityIdentifier("farframe.arena.keepFacing")
                if movable {
                    Text(keepFacing
                        ? "Pinch and drag to move. The screen faces you when you place it."
                        : "Pinch and drag to move. Use both hands to resize or rotate freely.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(action: reset) {
                    Label("Reset Screen", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .accessibilityIdentifier("farframe.arena.resetScreen")
                if saveScreen != nil { savedPositions }
                Divider()
                Toggle("Partial Immersion", isOn: $partialImmersion)
                if partialImmersion {
                    Text("Turn the Digital Crown to adjust your surroundings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(action: exit) {
                    Label("Exit Room", systemImage: "rectangle.on.rectangle")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .accessibilityHint("Returns to your window without disconnecting.")
                .accessibilityIdentifier("farframe.arena.exit")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .confirmationDialog("Remove saved position?", isPresented: Binding(
            get: { removingScreen != nil }, set: { if !$0 { removingScreen = nil } }),
            titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let removingScreen { removeScreen(removingScreen.id) }
                    removingScreen = nil
                }
            }
    }

    private var savedPositions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved Positions").font(.headline)
            ForEach(savedScreens) { screen in
                HStack(spacing: 10) {
                    Button { recallScreen(screen.id) } label: {
                        Label(screen.name, systemImage: selectedSavedScreenID == screen.id ? "checkmark" : "bookmark")
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    }
                    .tint(selectedSavedScreenID == screen.id ? .accentColor : .white.opacity(0.12))
                    .accessibilityIdentifier("farframe.arena.saved.\(screen.name)")
                    Button { removingScreen = screen } label: {
                        Image(systemName: "trash").frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Remove \(screen.name)")
                }
            }
            if savedScreens.count < VisionArenaSavedScreens.limit {
                TextField("Position name", text: $screenName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("farframe.arena.positionName")
                    .onChange(of: screenName) { _, value in
                        screenName = String(value.prefix(32))
                        saveFailed = false
                    }
                Button {
                    if saveScreen?(screenName) == true { screenName = ""; saveFailed = false }
                    else { saveFailed = true }
                } label: {
                    Label("Save Current Position", systemImage: "bookmark")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .disabled(screenName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("farframe.arena.savePosition")
            }
            Text(saveFailed ? "Couldn’t save this position." : "Saved on this device. Select a position to place and lock the screen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func adjustment(_ title: String, value: Binding<Float>, range: ClosedRange<Float>,
                            detail: String, identifier: String, step: Float) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(detail).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - step) } label: {
                    Image(systemName: "minus").frame(width: 28, height: 28)
                }
                .disabled(value.wrappedValue <= range.lowerBound + 0.0001)
                .accessibilityLabel("Decrease \(title)")
                Slider(value: value, in: range) { Text(title) }
                    .accessibilityIdentifier("farframe.arena.\(identifier)")
                Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + step) } label: {
                    Image(systemName: "plus").frame(width: 28, height: 28)
                }
                .disabled(value.wrappedValue >= range.upperBound - 0.0001)
                .accessibilityLabel("Increase \(title)")
            }
        }
    }
}
#endif
