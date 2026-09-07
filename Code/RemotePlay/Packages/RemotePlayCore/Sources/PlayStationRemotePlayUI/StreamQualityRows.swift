import ExperienceDomain
import Foundation
import SwiftUI

/// One row of the quality picker, shared by the iPhone/iPad, Mac, and Vision
/// shells so the three cannot drift apart the way the preset enum itself once
/// did.
///
/// The row exists because of a real session: a player chose a preset by its
/// name alone, streamed a whole match at 540p, and only found out from the
/// in-stream HUD afterwards. A picker that shows a name and nothing else moves
/// the consequence of the choice to a place the user reaches too late. So the
/// row carries all three things at once — what it is called, the numbers it
/// resolves to, and one sentence on what it costs.
public struct StreamQualityPresetRow: View {
    private let preset: StreamQualityPreset

    public init(preset: StreamQualityPreset) {
        self.preset = preset
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(preset.displayName)
                if preset.isRecommended {
                    Text("Recommended")
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                }
            }
            Text(preset.detail)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(preset.tradeoff)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        // Three stacked lines are one choice, not three things to swipe past.
        .accessibilityElement(children: .combine)
    }
}
