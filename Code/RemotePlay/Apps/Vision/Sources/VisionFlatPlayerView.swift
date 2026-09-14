import AppleMediaCore
import SwiftUI

struct VisionFlatPlayerView: View {
    let videoSurface: SampleBufferVideoSurfaceBinding
    let onSurfaceQueued: @MainActor () -> Void
    let onSurfaceAttached: @MainActor () -> Void
    let onSurfaceReady: @MainActor () -> Void

    init(
        videoSurface: SampleBufferVideoSurfaceBinding,
        onSurfaceQueued: @escaping @MainActor () -> Void = {},
        onSurfaceAttached: @escaping @MainActor () -> Void = {},
        onSurfaceReady: @escaping @MainActor () -> Void = {}
    ) {
        self.videoSurface = videoSurface
        self.onSurfaceQueued = onSurfaceQueued
        self.onSurfaceAttached = onSurfaceAttached
        self.onSurfaceReady = onSurfaceReady
    }

    var body: some View {
        ZStack {
            Color.black
            VisionSampleBufferDisplayView(
                videoSurface: videoSurface,
                onSurfaceQueued: onSurfaceQueued,
                onSurfaceAttached: onSurfaceAttached,
                onSurfaceReady: onSurfaceReady
            )
                // A replacement provider session owns a different FIFO binding.
                // Force a new UIView/coordinator instead of reusing the old layer.
                .id(ObjectIdentifier(videoSurface))
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .frame(
            minWidth: 700,
            maxWidth: 3_200,
            minHeight: 394,
            maxHeight: 1_800
        )
        .accessibilityLabel("Remote Play video")
    }
}
