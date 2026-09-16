import SwiftUI

struct VisionScreenGlowStyle: Equatable {
    enum Extent: Equatable {
        case tight
        case room
    }

    var isActive = false
    var extent: Extent = .tight
    var widthScale: CGFloat = 1
    var strength: CGFloat = 1
}

enum VisionScreenGlowMetrics {
    static let outerCorner: CGFloat = 28
    static let pictureCorner: CGFloat = 18
    static let paletteFade: Double = 0.30
    static let tightOpacity: Double = 0.82
    static let roomOpacity: Double = 0.72
    static func edgeGap(for extent: VisionScreenGlowStyle.Extent) -> CGFloat {
        switch extent {
        case .tight: 40
        case .room: 72
        }
    }

    static func fadeGutter(style: VisionScreenGlowStyle) -> CGFloat {
        switch style.extent {
        case .tight:
            return min(50, max(28, 32 * max(0.7, style.widthScale)))
        case .room:
            return min(72, max(48, 52 * max(0.7, style.widthScale)))
        }
    }

    static func padding(style: VisionScreenGlowStyle) -> CGFloat {
        fadeGutter(style: style) + edgeGap(for: style.extent)
    }
}

struct VisionScreenGlowPalette: Equatable {
    var top: Color
    var right: Color
    var bottom: Color
    var left: Color

    static let black = Self(top: .black, right: .black, bottom: .black, left: .black)

    static let signature = Self(
        top: Color(red: 0.62, green: 0.12, blue: 0.92),
        right: Color(red: 1, green: 0.32, blue: 0.06),
        bottom: Color(red: 0.12, green: 0.78, blue: 0.28),
        left: Color(red: 0.02, green: 0.64, blue: 0.96)
    )

    init(top: Color, right: Color, bottom: Color, left: Color) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    init(edgeColors: VisionArenaLiveColorPolicy.EdgeColors, extent: VisionScreenGlowStyle.Extent) {
        let graded = Self.grade(edgeColors, extent: extent)
        top = Self.displayColor(graded.top)
        right = Self.displayColor(graded.right)
        bottom = Self.displayColor(graded.bottom)
        left = Self.displayColor(graded.left)
    }

    private struct Linear {
        var top, right, bottom, left: SIMD3<Float>
    }

    private static func grade(
        _ colors: VisionArenaLiveColorPolicy.EdgeColors,
        extent: VisionScreenGlowStyle.Extent
    ) -> Linear {
        let list = [colors.top, colors.right, colors.bottom, colors.left]
        func luminance(_ c: SIMD3<Float>) -> Float {
            c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722
        }
        let peakLuminance = list.map(luminance).max() ?? 0
        let peakComponent = list.flatMap { [$0.x, $0.y, $0.z] }.max() ?? 0
        guard peakLuminance > 0.002, peakComponent > 0 else {
            return Linear(top: .zero, right: .zero, bottom: .zero, left: .zero)
        }
        let gamma: Float
        let exposure: Float
        let maximumGain: Float
        let targetLuminance: Float
        switch extent {
        case .tight:
            gamma = 0.58
            exposure = 1.35
            maximumGain = 4.5
            targetLuminance = 0.62
        case .room:
            gamma = 0.68
            exposure = 1.05
            maximumGain = 3
            targetLuminance = 0.45
        }
        let desired = min(targetLuminance, exposure * pow(peakLuminance, gamma))
        let gain = min(maximumGain, 1 / peakComponent, max(1, desired / peakLuminance))
        let chroma: Float = extent == .tight ? 1.15 : 0.55
        return Linear(
            top: neon(colors.top * gain, chroma: chroma),
            right: neon(colors.right * gain, chroma: chroma),
            bottom: neon(colors.bottom * gain, chroma: chroma),
            left: neon(colors.left * gain, chroma: chroma)
        )
    }

    private static func neon(_ color: SIMD3<Float>, chroma: Float) -> SIMD3<Float> {
        let lum = color.x * 0.2126 + color.y * 0.7152 + color.z * 0.0722
        var pushed = SIMD3(
            lum + (color.x - lum) * (1 + chroma),
            lum + (color.y - lum) * (1 + chroma),
            lum + (color.z - lum) * (1 + chroma)
        )
        pushed = SIMD3(max(0, pushed.x), max(0, pushed.y), max(0, pushed.z))
        let peak = max(pushed.x, max(pushed.y, pushed.z))
        if peak > 1 { pushed = pushed / peak }
        return pushed
    }

    private static func displayColor(_ color: SIMD3<Float>) -> Color {
        Color(
            red: encode(color.x),
            green: encode(color.y),
            blue: encode(color.z),
            opacity: 1
        )
    }

    private static func encode(_ value: Float) -> Double {
        let v = Double(value)
        guard v.isFinite, v > 0 else { return 0 }
        if v <= 0.0031308 { return min(1, 12.92 * v) }
        return min(1, 1.055 * pow(v, 1 / 2.4) - 0.055)
    }
}

struct VisionScreenGlowContainer<Content: View>: View {
    var palette: VisionScreenGlowPalette
    var style: VisionScreenGlowStyle
    var reduceMotion = false
    @ViewBuilder var content: Content

    var body: some View {
        let active = style.isActive && !reduceMotion
        let fade = active ? VisionScreenGlowMetrics.fadeGutter(style: style) : 0
        let gutter = active ? VisionScreenGlowMetrics.padding(style: style) : 0
        ZStack {
            if active { Color.clear } else { Color.black }
            ZStack {
                if active {
                    GeometryReader { picture in
                        glow(size: picture.size, fade: fade, strength: style.strength)
                            .frame(width: picture.size.width, height: picture.size.height)
                            .mask {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .frame(
                                        width: picture.size.width + fade * 0.9,
                                        height: picture.size.height + fade * 0.9
                                    )
                                    .blur(radius: fade * 0.5)
                            }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: VisionScreenGlowMetrics.paletteFade),
                        value: palette
                    )
                }
                content
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: active ? VisionScreenGlowMetrics.pictureCorner : VisionScreenGlowMetrics.outerCorner,
                            style: .continuous
                        )
                    )
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .padding(gutter)
        }
        .overlay {
            if active, style.extent == .room {
                VisionWindowCornerHints()
            }
        }
        .animation(nil, value: gutter)
    }

    @ViewBuilder
    private func glow(size: CGSize, fade: CGFloat, strength: CGFloat) -> some View {
        switch style.extent {
        case .tight:
            TightScreenHalo(size: size, palette: palette, fade: fade, strength: strength)
        case .room:
            RealRoomScreenLight(size: size, palette: palette, fade: fade, strength: strength)
        }
    }
}

private struct TightScreenHalo: View {
    let size: CGSize
    let palette: VisionScreenGlowPalette
    let fade: CGFloat
    let strength: CGFloat

    var body: some View {
        let scale = max(1, fade / 28)
        let opacity = VisionScreenGlowMetrics.tightOpacity * max(0.45, min(1.2, strength))
        ZStack {
            RoundedRectangle(
                cornerRadius: VisionScreenGlowMetrics.pictureCorner,
                style: .continuous
            )
            .fill(ring)
            .frame(width: size.width + 24 * scale, height: size.height + 24 * scale)
            .blur(radius: 18 * scale)
            .opacity(opacity)

            RoundedRectangle(
                cornerRadius: VisionScreenGlowMetrics.pictureCorner + 6,
                style: .continuous
            )
            .strokeBorder(ring, lineWidth: 16 * scale)
            .frame(width: size.width + 12 * scale, height: size.height + 12 * scale)
            .blur(radius: 12 * scale)
            .opacity(opacity)
        }
    }

    private var ring: AngularGradient {
        AngularGradient(
            colors: [
                palette.top,
                palette.right,
                palette.bottom,
                palette.left,
                palette.top
            ],
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
    }
}

private struct VisionWindowCornerHints: View {
    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 6
            let size: CGFloat = 16
            ZStack {
                cornerMark
                    .frame(width: size, height: size)
                    .position(x: inset + size / 2, y: geo.size.height - inset - size / 2)
                cornerMark
                    .scaleEffect(x: -1, y: 1)
                    .frame(width: size, height: size)
                    .position(x: geo.size.width - inset - size / 2, y: geo.size.height - inset - size / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var cornerMark: some View {
        ZStack {
            VisionWindowCornerTick()
                .stroke(Color.black.opacity(0.16), style: tickStyle)
            VisionWindowCornerTick()
                .stroke(Color.white.opacity(0.28), style: tickStyle)
        }
    }

    private var tickStyle: StrokeStyle {
        StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
    }
}

private struct VisionWindowCornerTick: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) * 0.7
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        return path
    }
}

private struct RealRoomScreenLight: View {
    let size: CGSize
    let palette: VisionScreenGlowPalette
    let fade: CGFloat
    let strength: CGFloat

    var body: some View {
        let scale = max(1, fade / 56)
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            palette.left.opacity(0.72),
                            palette.top.opacity(0.34),
                            palette.right.opacity(0.72)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: size.width + 58 * scale, height: size.height + 58 * scale)
                .blur(radius: 30 * scale)
                .opacity(VisionScreenGlowMetrics.roomOpacity * max(0.45, min(1.2, strength)))

            Capsule()
                .fill(palette.bottom.opacity(0.42 * max(0.45, min(1.2, strength))))
                .frame(width: size.width * 0.72, height: 24 * scale)
                .blur(radius: 24 * scale)
                .offset(y: size.height * 0.51)
        }
    }
}
