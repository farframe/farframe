import SwiftUI

/// Hosts supply the content, resource bundle, page binding and close behavior.
/// This view never presents a sheet/window, records completion or runs app actions.
public struct HelpGuideView: View {
    public let guide: HelpGuide
    @Binding private var selectedStepID: String
    private let assetBundle: Bundle
    private let onDone: () -> Void

    public init(guide: HelpGuide, selectedStepID: Binding<String>,
                assetBundle: Bundle = .main, onDone: @escaping () -> Void) {
        self.guide = guide
        _selectedStepID = selectedStepID
        self.assetBundle = assetBundle
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(LocalizedStringKey(guide.title), bundle: assetBundle).font(.headline)
                Spacer()
                if let index = guide.index(for: selectedStepID) {
                    Text("\(index + 1) of \(guide.steps.count)")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let index = guide.index(for: selectedStepID) {
                let step = guide.steps[index]
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(LocalizedStringKey(step.title), bundle: assetBundle)
                                .font(.title2.bold())
                                .accessibilityAddTraits(.isHeader)
                                .id("guide-heading")
                            if let message = step.message {
                                Text(LocalizedStringKey(message), bundle: assetBundle)
                                    .foregroundStyle(.secondary)
                            }
                            if let art = step.illustration {
                                Image(art.assetName, bundle: assetBundle)
                                    .resizable().scaledToFit()
                                    .background {
                                        if art.usesDarkBacking {
                                            RoundedRectangle(cornerRadius: 20)
                                                .fill(Color(red: 0.14, green: 0.16, blue: 0.20))
                                        }
                                    }
                                    .accessibilityLabel(Text(LocalizedStringKey(art.accessibleDescription), bundle: assetBundle))
                            }
                            ForEach(step.items) { item in
                                HStack(alignment: .top, spacing: 16) {
                                    Group {
                                        if let asset = item.assetName {
                                            Image(asset, bundle: assetBundle).resizable().scaledToFit()
                                        } else if let symbol = item.systemImage {
                                            Image(systemName: symbol).font(.title2)
                                        }
                                    }
                                    .frame(width: 32, height: 32)
                                    .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(LocalizedStringKey(item.title), bundle: assetBundle).font(.headline)
                                        Text(LocalizedStringKey(item.detail), bundle: assetBundle).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 6)
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: selectedStepID) { _, _ in proxy.scrollTo("guide-heading", anchor: .top) }
                }
                HStack {
                    Button("Back") { move(-1) }.disabled(index == 0)
                    Spacer()
                    if index < guide.steps.count - 1 {
                        Button("Next", systemImage: "arrow.right") { move(1) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Done", action: onDone).buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.large)
            } else {
                Spacer()
                Button("Done", action: onDone).buttonStyle(.borderedProminent)
            }
            if let footer = guide.footer {
                Text(LocalizedStringKey(footer), bundle: assetBundle)
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .padding(24)
    }

    private func move(_ direction: Int) {
        if let next = guide.stepID(from: selectedStepID, offset: direction) { selectedStepID = next }
    }
}
