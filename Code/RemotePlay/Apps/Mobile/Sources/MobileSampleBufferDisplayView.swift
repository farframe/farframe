import AVFoundation
import AppleMediaCore
import Foundation
import SwiftUI
import UIKit

extension MobileVideoContentMode {
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fit: .resizeAspect
        case .fill: .resizeAspectFill
        case .stretch: .resize
        }
    }
}

/// UIKit-only host for the shared sample-buffer presentation boundary.
@MainActor
final class MobileSampleBufferDisplayUIView: UIView {
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

/// The public wrapper owns representable identity. Geometry changes can rebuild
/// surrounding chrome without replacing the display layer; only a replacement
/// native session receives a new UIKit host.
struct MobileSampleBufferDisplayView: View {
    let sessionID: UUID
    let videoSurface: SampleBufferVideoSurfaceBinding
    let onSurfaceQueued: @MainActor () -> Void
    var contentMode: MobileVideoContentMode = .fit

    var body: some View {
        MobileSampleBufferDisplayRepresentable(
            videoSurface: videoSurface,
            onSurfaceQueued: onSurfaceQueued,
            contentMode: contentMode
        )
        .id(sessionID)
    }
}

private struct MobileSampleBufferDisplayRepresentable: UIViewRepresentable {
    let videoSurface: SampleBufferVideoSurfaceBinding
    let onSurfaceQueued: @MainActor () -> Void
    let contentMode: MobileVideoContentMode

    func makeCoordinator() -> Coordinator {
        Coordinator(
            videoSurface: videoSurface,
            onSurfaceQueued: onSurfaceQueued
        )
    }

    func makeUIView(context: Context) -> MobileSampleBufferDisplayUIView {
        let view = MobileSampleBufferDisplayUIView()
        view.backgroundColor = .black
        view.isOpaque = true
        view.displayLayer.backgroundColor = UIColor.black.cgColor
        view.displayLayer.videoGravity = contentMode.videoGravity
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
        _ uiView: MobileSampleBufferDisplayUIView,
        context: Context
    ) {
        uiView.displayLayer.videoGravity = contentMode.videoGravity
    }

    static func dismantleUIView(
        _ uiView: MobileSampleBufferDisplayUIView,
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
            // Session Start waits through the binding FIFO. Notify only after
            // this exact layer attachment has synchronously entered that FIFO.
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
