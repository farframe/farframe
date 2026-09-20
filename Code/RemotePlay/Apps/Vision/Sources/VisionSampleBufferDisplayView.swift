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
    var mixedLighting: VisionMixedLightingState?
    let videoSurface: SampleBufferVideoSurfaceBinding
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

    func makeCoordinator() -> Coordinator {
        Coordinator(videoSurface: videoSurface, onSurfaceQueued: onSurfaceQueued, onSurfaceAttached: onSurfaceAttached, onSurfaceReady: onSurfaceReady, mixedLighting: mixedLighting)
    }

    func makeUIView(context: Context) -> VisionSampleBufferDisplayUIView {
        let view = VisionSampleBufferDisplayUIView()
        applyCanvas(view)
        view.displayLayer.videoGravity = .resizeAspect
        view.clipsToBounds = true
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
    ) {
        applyCanvas(uiView)
        context.coordinator.mixedLighting = mixedLighting
    }

    private func applyCanvas(_ view: VisionSampleBufferDisplayUIView) {
        let glow = mixedLighting?.screenGlowStyle.isActive == true
        let windowVisible = mixedLighting?.windowVisible != false
        let clear = glow && windowVisible
        view.backgroundColor = clear ? .clear : .black
        view.isOpaque = !clear
        view.displayLayer.backgroundColor = (clear ? UIColor.clear : UIColor.black).cgColor
        view.clipsToBounds = true
    }

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
        private let onSurfaceAttached: @MainActor () -> Void
        private let onSurfaceReady: @MainActor () -> Void
        private var attachmentID: UUID?
        weak var mixedLighting: VisionMixedLightingState?

        init(
            videoSurface: SampleBufferVideoSurfaceBinding,
            onSurfaceQueued: @escaping @MainActor () -> Void,
            onSurfaceAttached: @escaping @MainActor () -> Void,
            onSurfaceReady: @escaping @MainActor () -> Void,
            mixedLighting: VisionMixedLightingState?
        ) {
            self.videoSurface = videoSurface
            self.onSurfaceQueued = onSurfaceQueued
            self.onSurfaceAttached = onSurfaceAttached
            self.onSurfaceReady = onSurfaceReady
            self.mixedLighting = mixedLighting
        }

        func attach(_ layer: AVSampleBufferDisplayLayer) {
            let id = UUID()
            attachmentID = id
            let attachment = videoSurface.attach(layer, preservingOutgoingImage: true)
            // The attach operation is now synchronously present in the
            // binding's FIFO. Session Start will wait through that exact work.
            onSurfaceQueued()
            Task { @MainActor [weak self] in
                await attachment.value
                guard let self, self.attachmentID == id else { return }
                self.mixedLighting?.bind(layer: layer, surface: self.videoSurface)
                self.onSurfaceAttached()
                // Attachment only establishes ownership. Apple's display-ready
                // flag means the first image is actually available to show.
                // It is NOT KVO-observable; poll only for this bounded transfer.
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while self.attachmentID == id, !layer.isReadyForDisplay,
                      ContinuousClock.now < deadline, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                guard self.attachmentID == id, layer.isReadyForDisplay,
                      !Task.isCancelled else { return }
                self.onSurfaceReady()
            }
        }

        func detach(_ layer: AVSampleBufferDisplayLayer) {
            attachmentID = nil
            mixedLighting?.unbind(layer: layer)
            videoSurface.detach(layer)
        }

        func reportBackingPixelSize(width: Int, height: Int) {
            videoSurface.setDisplayPixelSize(width: width, height: height)
        }
    }
}
