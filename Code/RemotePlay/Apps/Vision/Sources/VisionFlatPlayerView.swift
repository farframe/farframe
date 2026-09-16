import AppleMediaCore
import SwiftUI

struct VisionFlatPlayerView: View {
    let videoSurface: SampleBufferVideoSurfaceBinding
    var mixedLighting: VisionMixedLightingState?
    let onSurfaceQueued: @MainActor () -> Void
    let onSurfaceAttached: @MainActor () -> Void
    let onSurfaceReady: @MainActor () -> Void

    init(
        videoSurface: SampleBufferVideoSurfaceBinding,
        mixedLighting: VisionMixedLightingState? = nil,
        onSurfaceQueued: @escaping @MainActor () -> Void = {},
        onSurfaceAttached: @escaping @MainActor () -> Void = {},
        onSurfaceReady: @escaping @MainActor () -> Void = {}
    ) {
        self.videoSurface = videoSurface
        self.mixedLighting = mixedLighting
        self.onSurfaceQueued = onSurfaceQueued
        self.onSurfaceAttached = onSurfaceAttached
        self.onSurfaceReady = onSurfaceReady
    }

    var body: some View {
        Group {
            if let mixedLighting {
                VisionMixedScreenGlowHost(state: mixedLighting) {
                    videoLayer
                }
            } else {
                ZStack {
                    Color.black
                    videoLayer
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .frame(
            minWidth: 700,
            maxWidth: 3_200,
            minHeight: 394,
            maxHeight: 1_800
        )
        .accessibilityLabel("Remote Play video")
    }

    private var videoLayer: some View {
        VisionSampleBufferDisplayView(
            videoSurface: videoSurface,
            mixedLighting: mixedLighting,
            onSurfaceQueued: onSurfaceQueued,
            onSurfaceAttached: onSurfaceAttached,
            onSurfaceReady: onSurfaceReady
        )
        // A replacement provider session owns a different FIFO binding.
        // Force a new UIView/coordinator instead of reusing the old layer.
        .id(ObjectIdentifier(videoSurface))
    }
}

private struct VisionMixedScreenGlowHost<Content: View>: View {
    @Bindable var state: VisionMixedLightingState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var content: Content

    var body: some View {
        VisionScreenGlowContainer(
            palette: state.screenGlowPalette,
            style: state.screenGlowStyle,
            reduceMotion: reduceMotion
        ) {
            content
        }
        .onAppear {
            state.reduceMotion = reduceMotion
            state.refresh()
        }
        .onChange(of: reduceMotion) { _, value in
            state.reduceMotion = value
            state.refresh()
        }
        .task {
            while !Task.isCancelled {
                state.reduceMotion = reduceMotion
                state.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}
