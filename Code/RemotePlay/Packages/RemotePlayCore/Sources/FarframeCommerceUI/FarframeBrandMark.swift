import SwiftUI

/// The existing Farframe app artwork, shared by every platform's in-app branding.
public struct FarframeBrandMark: View {
    private let size: CGFloat

    public init(size: CGFloat = 48) {
        self.size = size
    }

    public var body: some View {
        Image("FarframeBrandMark", bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Current platform availability on Home and the purchase surface.
public struct FarframeSupportedDevices: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 24) {
                ForEach(["vision.pro", "macbook", "ipad", "iphone"], id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.title3.weight(.regular))
                        .frame(minWidth: 24, minHeight: 24)
                }
            }
            .foregroundStyle(Color.blue.gradient)
            .accessibilityHidden(true)
            Text("Available now on visionOS. Working on iOS, iPadOS, and macOS.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Shared with your whole family through Family Sharing.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
