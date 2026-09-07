import AppKit
import AVFoundation
import AppleMediaCore
import SwiftUI

/// Native AppKit host for the shared sample-buffer presentation boundary.
@MainActor
final class MacSampleBufferDisplayNSView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func makeBackingLayer() -> CALayer {
        displayLayer
    }

    /// Reports the backing size in device pixels so the presenter can tell how
    /// far the 1080p stream is being magnified. On a Mac this is entirely
    /// user-controlled: full screen on a 5K display is a large magnification,
    /// a small window is none at all.
    var onBackingPixelSizeChange: ((Int, Int) -> Void)?
    private var lastReportedPixelSize = (width: 0, height: 0)

    override func layout() {
        super.layout()
        reportBackingPixelSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportBackingPixelSize()
    }

    private func reportBackingPixelSize() {
        let scale = window?.backingScaleFactor ?? 2
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0,
              (width, height) != lastReportedPixelSize else { return }
        lastReportedPixelSize = (width, height)
        onBackingPixelSizeChange?(width, height)
    }
}

struct MacSampleBufferDisplayView: NSViewRepresentable {
    let videoSurface: SampleBufferVideoSurfaceBinding
    let onSurfaceQueued: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(videoSurface: videoSurface)
    }

    func makeNSView(context: Context) -> MacSampleBufferDisplayNSView {
        let view = MacSampleBufferDisplayNSView(frame: .zero)
        let coordinator = context.coordinator
        view.onBackingPixelSizeChange = { width, height in
            MainActor.assumeIsolated {
                coordinator.reportBackingPixelSize(width: width, height: height)
            }
        }
        coordinator.attach(view.displayLayer)
        onSurfaceQueued()
        return view
    }

    func updateNSView(
        _ nsView: MacSampleBufferDisplayNSView,
        context: Context
    ) {}

    static func dismantleNSView(
        _ nsView: MacSampleBufferDisplayNSView,
        coordinator: Coordinator
    ) {
        coordinator.detach(nsView.displayLayer)
    }

    @MainActor
    final class Coordinator {
        private let videoSurface: SampleBufferVideoSurfaceBinding

        init(videoSurface: SampleBufferVideoSurfaceBinding) {
            self.videoSurface = videoSurface
        }

        func attach(_ layer: AVSampleBufferDisplayLayer) {
            videoSurface.attach(layer)
        }

        func detach(_ layer: AVSampleBufferDisplayLayer) {
            videoSurface.detach(layer)
        }

        func reportBackingPixelSize(width: Int, height: Int) {
            videoSurface.setDisplayPixelSize(width: width, height: height)
        }
    }
}
