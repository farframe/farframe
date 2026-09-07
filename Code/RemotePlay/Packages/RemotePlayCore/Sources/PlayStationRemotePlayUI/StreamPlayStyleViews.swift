import ExperienceDomain
import Foundation
import SwiftUI

// MARK: - Shared content

/// The colour a style is drawn in. It lives here rather than in the domain
/// because a `Color` is a presentation concern and `ExperienceDomain` has no
/// SwiftUI dependency. The switch is exhaustive on purpose: adding a play style
/// should not compile until someone has decided what it looks like.
extension StreamPlayStyle {
    var accent: Color {
        switch self {
        case .story: .purple
        case .everything: .blue
        case .competitive: .orange
        case .awayFromHome: .teal
        }
    }
}

/// The four things every presentation of a play style shows, in one place so a
/// Settings row and the first-run card can never say different things about the
/// same option.
///
/// The third line is the point of the whole feature. The owner's ask was "we
/// just list the stats under each one", because a label like "Balanced" tells a
/// player nothing they can act on, while `1080p · 60 FPS · 15 Mbps` is a
/// comparison they can make for themselves. That line is read off the preset
/// rather than written out here, so what the row advertises is exactly what
/// tapping it writes.
struct StreamPlayStyleSummary: View {
    let style: StreamPlayStyle
    let isCurrent: Bool
    var titleFont: Font = .headline
    var bodyFont: Font = .caption
    var statsFont: Font = .caption

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // The badge gets its own line rather than sharing one with the
            // title. "A bit of everything" wraps on an iPhone, and a badge
            // beside a wrapping title lands in the middle of it.
            if style.isRecommended {
                Text("Recommended")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(style.accent)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(style.displayName)
                    .font(titleFont)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isCurrent {
                    Label("Current", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(style.accent)
                }
            }

            Text(style.examples)
                .font(bodyFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(style.detail)
                .font(statsFont.monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(style.rationale)
                .font(bodyFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // One choice, not four things to swipe past.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [style.displayName]
        if style.isRecommended { parts.append("Recommended") }
        if isCurrent { parts.append("Currently selected") }
        parts.append(style.examples)
        parts.append(style.detail)
        parts.append(style.rationale)
        return parts.joined(separator: ". ")
    }
}

// MARK: - Settings row

/// One play-style row for a `Form`, shared by all three shells.
///
/// `isCurrent` is derived from the two settings a style writes, never stored.
/// Nothing is marked once a user nudges quality or smooth motion by hand, which
/// is the honest answer — they are no longer on a style — and it is why the
/// feature needs no "Custom" state and no migration.
public struct StreamPlayStyleRow: View {
    private let style: StreamPlayStyle
    private let isCurrent: Bool

    public init(style: StreamPlayStyle, isCurrent: Bool = false) {
        self.style = style
        self.isCurrent = isCurrent
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StreamPlayStyleGlyph(style: style, isCurrent: isCurrent, size: 34)
            StreamPlayStyleSummary(style: style, isCurrent: isCurrent)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// The tinted symbol badge. Small in a Settings row, large on a first-run card,
/// identical in meaning, so the option a user picked at first run is visually
/// the same object when they come back to change it.
struct StreamPlayStyleGlyph: View {
    let style: StreamPlayStyle
    let isCurrent: Bool
    let size: CGFloat

    var body: some View {
        Image(systemName: style.symbolName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(style.accent)
            .frame(width: size, height: size)
            .background(style.accent.opacity(isCurrent ? 0.28 : 0.14), in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - First-run card

/// The large, tappable version of a play style, used by the first-run step.
///
/// A settings row is a thing you read; this is a thing you choose between. It
/// gets the extra weight because it is the first screen a new user sees, and
/// the owner's standing note on the app's settings is that they are "basic,
/// super boring, boilerplate". Liquid Glass is used for the surface a finger
/// lands on and nowhere else, which is what keeps it a control rather than
/// decoration.
public struct StreamPlayStyleCard: View {
    private let style: StreamPlayStyle
    private let isCurrent: Bool
    private let action: () -> Void

    public init(
        style: StreamPlayStyle,
        isCurrent: Bool = false,
        action: @escaping () -> Void
    ) {
        self.style = style
        self.isCurrent = isCurrent
        self.action = action
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    public var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                StreamPlayStyleGlyph(style: style, isCurrent: isCurrent, size: 46)
                StreamPlayStyleSummary(
                    style: style,
                    isCurrent: isCurrent,
                    titleFont: .headline,
                    bodyFont: .subheadline,
                    statsFont: .footnote
                )
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .playStyleCardSurface(shape: shape, accent: style.accent, isCurrent: isCurrent)
            .overlay {
                shape.strokeBorder(
                    isCurrent ? style.accent.opacity(0.65) : .clear,
                    lineWidth: 2
                )
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        #if !os(macOS)
        .hoverEffect(.highlight)
        #endif
        .accessibilityHint("Sets quality to \(style.qualityName) and smooth motion \(style.smoothMotionEnabled ? "on" : "off")")
    }
}

private extension View {
    /// Liquid Glass where a glass surface is the native idiom, and a plain
    /// material on visionOS, where the sheet itself is already a glass panel
    /// and stacking a second layer on it reads as haze rather than depth.
    @ViewBuilder
    func playStyleCardSurface(
        shape: RoundedRectangle,
        accent: Color,
        isCurrent: Bool
    ) -> some View {
        #if os(visionOS)
        background(
            isCurrent ? AnyShapeStyle(accent.opacity(0.22)) : AnyShapeStyle(.thinMaterial),
            in: shape
        )
        #else
        glassEffect(
            isCurrent
                ? .regular.tint(accent.opacity(0.28)).interactive()
                : .regular.interactive(),
            in: shape
        )
        #endif
    }
}

// MARK: - First-run step

/// Where the app records that it has asked the question.
///
/// Only the fact that it was asked is stored. The answer is not: applying a
/// style writes the quality and smooth-motion preferences, and those stay the
/// single record of what is set. That is the same decision that keeps play
/// styles free of a "Custom" state, carried through to first run.
public enum FarframePlayStyleOnboarding {
    public static let hasBeenAskedKey = "farframe.playStyle.firstRunAsked"
}

/// The one first-run question: what are you playing?
///
/// It exists because "Stability versus Balanced" is not a question a person can
/// answer, and getting it wrong is expensive — a full Destiny 2 session was
/// played at 540p because a quality picker said nothing about consequences.
/// This asks something a player already knows the answer to, shows the numbers
/// each answer resolves to so they can judge rather than trust, and gets out of
/// the way. Skipping leaves every setting exactly as a fresh install had it.
public struct FarframePlayStyleOnboardingView: View {
    private let currentStyle: StreamPlayStyle?
    private let onChoose: (StreamPlayStyle) -> Void
    private let onSkip: () -> Void

    public init(
        currentStyle: StreamPlayStyle? = nil,
        onChoose: @escaping (StreamPlayStyle) -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.currentStyle = currentStyle
        self.onChoose = onChoose
        self.onSkip = onSkip
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    cards
                    footnote
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Welcome to Farframe")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip", action: onSkip)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityHint("Leave the stream settings as they are")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 600, idealHeight: 720)
        #elseif os(visionOS)
        .frame(minWidth: 600, idealWidth: 680, minHeight: 620)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(StreamPlayStyle.question)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text(StreamPlayStyle.questionDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var cards: some View {
        let stack = VStack(spacing: 12) {
            ForEach(StreamPlayStyle.allCases) { style in
                StreamPlayStyleCard(
                    style: style,
                    isCurrent: style == currentStyle
                ) {
                    onChoose(style)
                }
            }
        }

        #if os(visionOS)
        stack
        #else
        GlassEffectContainer(spacing: 12) { stack }
        #endif
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(StreamQualityPreset.ladderFootnote)
            Text("You can change this any time in Settings, under \(StreamPlayStyle.question)")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Play style first run") {
    FarframePlayStyleOnboardingView(
        currentStyle: nil,
        onChoose: { _ in },
        onSkip: {}
    )
}

#Preview("Play style first run, already set") {
    FarframePlayStyleOnboardingView(
        currentStyle: .everything,
        onChoose: { _ in },
        onSkip: {}
    )
}

#Preview("Play style rows") {
    Form {
        Section(StreamPlayStyle.question) {
            ForEach(StreamPlayStyle.allCases) { style in
                StreamPlayStyleRow(style: style, isCurrent: style == .competitive)
            }
        }
    }
}
