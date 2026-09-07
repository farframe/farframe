import AVFoundation
import AppleMediaCore
import SwiftUI
import UIKit

@MainActor
final class VisionSampleBufferDisplayUIView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    /// Reports the backing size in device pixels so the presenter can tell how
    /// far the 1080p stream is being magnified.
    var onBackingPixelSizeChange: ((Int, Int) -> Void)?
    private var lastReportedPixelSize = (width: 0, height: 0)

    override func layoutSubviews() {
        super.layoutSubviews()
        reportBackingPixelSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportBackingPixelSize()
    }

    private func reportBackingPixelSize() {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0,
              (width, height) != lastReportedPixelSize else { return }
        lastReportedPixelSize = (width, height)
        onBackingPixelSizeChange?(width, height)
    }
}

/// A stable, frame-state-free visionOS host whose backing layer is the sample-
/// buffer display layer. Presentation work stays in AppleMediaCore.
struct VisionSampleBufferDisplayView: UIViewRepresentable {
    let videoSurface: SampleBufferVideoSurfaceBinding
    let onSurfaceQueued: @MainActor () -> Void

    init(
        videoSurface: SampleBufferVideoSurfaceBinding,
        onSurfaceQueued: @escaping @MainActor () -> Void = {}
    ) {
        self.videoSurface = videoSurface
        self.onSurfaceQueued = onSurfaceQueued
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(videoSurface: videoSurface, onSurfaceQueued: onSurfaceQueued)
    }

    func makeUIView(context: Context) -> VisionSampleBufferDisplayUIView {
        let view = VisionSampleBufferDisplayUIView()
        view.backgroundColor = .black
        view.isOpaque = true
        view.displayLayer.backgroundColor = UIColor.black.cgColor
        view.displayLayer.videoGravity = .resizeAspect
        let coordinator = context.coordinator
        view.onBackingPixelSizeChange = { width, height in
            MainActor.assumeIsolated {
                coordinator.reportBackingPixelSize(width: width, height: height)
            }
        }
        coordinator.attach(view.displayLayer)
        return view
    }

    func updateUIView(
        _ uiView: VisionSampleBufferDisplayUIView,
        context: Context
    ) {}

    static func dismantleUIView(
        _ uiView: VisionSampleBufferDisplayUIView,
        coordinator: Coordinator
    ) {
        coordinator.detach(uiView.displayLayer)
    }

    @MainActor
    final class Coordinator {
        private let videoSurface: SampleBufferVideoSurfaceBinding
        private let onSurfaceQueued: @MainActor () -> Void

        init(
            videoSurface: SampleBufferVideoSurfaceBinding,
            onSurfaceQueued: @escaping @MainActor () -> Void
        ) {
            self.videoSurface = videoSurface
            self.onSurfaceQueued = onSurfaceQueued
        }

        func attach(_ layer: AVSampleBufferDisplayLayer) {
            videoSurface.attach(layer)
            // The attach operation is now synchronously present in the
            // binding's FIFO. Session Start will wait through that exact work.
            onSurfaceQueued()
        }

        func detach(_ layer: AVSampleBufferDisplayLayer) {
            videoSurface.detach(layer)
        }

        func reportBackingPixelSize(width: Int, height: Int) {
            videoSurface.setDisplayPixelSize(width: width, height: height)
        }
    }
}
