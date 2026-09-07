import AppleMediaCore
import SwiftUI

struct VisionFlatPlayerView: View {
    let videoSurface: SampleBufferVideoSurfaceBinding
    let onSurfaceQueued: @MainActor () -> Void

    init(
        videoSurface: SampleBufferVideoSurfaceBinding,
        onSurfaceQueued: @escaping @MainActor () -> Void = {}
    ) {
        self.videoSurface = videoSurface
        self.onSurfaceQueued = onSurfaceQueued
    }

    var body: some View {
        ZStack {
            Color.black
            VisionSampleBufferDisplayView(
                videoSurface: videoSurface,
                onSurfaceQueued: onSurfaceQueued
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
