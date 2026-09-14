#if os(visionOS)
import Foundation
import ARKit
import QuartzCore
import AVFoundation
import AppleMediaCore
import ImageIO
import Observation
import RealityKit
import SwiftUI
import UIKit

@MainActor
@Observable
final class VisionArenaPreviewState {
    static let controlsWindowID = "farframe-arena-controls"
    enum ControlsCommand: Equatable { case exitRoom, endSession(rest: Bool) }
    var controlsCommand: ControlsCommand?

    static let spaceID = "farframe-glass-arena-preview"
    static let modelName = "FarframeGlassArena"
    static let lightingName = "FarframeGlassArenaLighting"

    enum Phase: Equatable { case closed, opening, open, closing }

    var phase: Phase = .closed
    private(set) var entryAttemptID = UUID()
    @ObservationIgnored private var automaticPreviewAttempted = false
    let exterior = VisionArenaExteriorController(loader: VisionArenaExteriorFactory.make)
    var glow: VisionArenaGlow = .low
    var movable = false
    var partialImmersion = false
    var immersionStyle: ImmersionStyle = .full
    private var manualPlacement: Transform?
    private var distanceAdjustment: (transform: Transform, viewer: SIMD3<Float>)?
    private var alignedEntry = false
    private var roomYaw: Float = 0
    private(set) var selectedPreset: VisionArenaScreenPlacement.Preset? = .seated
    var keepFacingViewer = true
    let savedScreens: VisionArenaSavedScreens
    private(set) var selectedSavedScreenID: UUID?
    var screenSaveMessage: String?

    init(defaults: UserDefaults = .standard) {
        savedScreens = VisionArenaSavedScreens(defaults: defaults)
    }
    @ObservationIgnored private let trackingSession = ARKitSession()
    @ObservationIgnored private var worldTracking: WorldTrackingProvider?
    @ObservationIgnored private var lastViewerPosition = SIMD3<Float>(0, 1.15, 0)
    @ObservationIgnored private var preparedMount: Mount?
    var placement = VisionArenaScreenPlacement()
    @ObservationIgnored private var videoMaterialIsInstalled = false
    @ObservationIgnored private var roomPrepared = false
    var isActive = true
    var reduceMotion = false
    var accessGranted = false
    var entryMessage: String?
    private(set) var statusMessage: String?
    private(set) var liveTicket: VisionArenaPresentationRoute.Ticket?
    private(set) var livePresentationReady = false
    var isLiveMode: Bool { liveTicket != nil }
    var scenePhase: ScenePhase = .active

    @ObservationIgnored private var liveRenderer: AVSampleBufferVideoRenderer?
    @ObservationIgnored private var liveBinding: SampleBufferVideoSurfaceBinding?
    @ObservationIgnored private weak var liveCoordinator: VisionRemotePlayCoordinator?
    @ObservationIgnored private var colorAnalyzer: VisionArenaLiveColorAnalyzer?
    @ObservationIgnored private var colorGeneration: UUID?
    @ObservationIgnored private var liveColors: VisionArenaLiveColorPolicy.EdgeColors?

    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var sceneRoot: Entity?
    @ObservationIgnored private var glowRoot: Entity?
    @ObservationIgnored private var appliedOpacity: Float?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    struct Mount {
        let root: Entity
        let generation: UUID
    }

    func beginOpening() -> UUID {
        entryAttemptID = UUID()
        phase = .opening
        alignedEntry = false
        roomYaw = 0
        distanceAdjustment = nil
        movable = false
        entryMessage = nil
        return entryAttemptID
    }

    func claimAutomaticPreview() -> Bool {
        guard !automaticPreviewAttempted, phase == .closed, liveTicket == nil else { return false }
        automaticPreviewAttempted = true
        return true
    }

    func beginLivePresentation(coordinator: VisionRemotePlayCoordinator) -> Bool {
        guard phase == .opening, accessGranted, let binding = coordinator.videoSurface,
              let ticket = coordinator.beginArenaPresentation() else { return false }
        liveTicket = ticket
        liveBinding = binding
        liveRenderer = AVSampleBufferVideoRenderer()
        liveCoordinator = coordinator
        livePresentationReady = false
        return true
    }

    func prepareScene() -> Mount {
        if let preparedMount, roomPrepared { return preparedMount }
        exterior.unmount()
        loadTask?.cancel()
        loadTask = nil
        generation = UUID()
        sceneRoot?.removeFromParent()
        appliedOpacity = nil
        videoMaterialIsInstalled = false
        roomPrepared = false
        statusMessage = "Loading the room…"

        let root = Entity()
        root.name = "FarframeArenaPreviewRoot"
        let fallback = makeFallbackFloor()
        root.addChild(fallback)
        let rig = VisionArenaScreenRig.make()
        root.addChild(rig.root)
        sceneRoot = root
        glowRoot = rig.glow
        applyPlacement()
        applyGlow()

        return Mount(root: root, generation: generation)
    }

    /// Prepare expensive assets while the flat player is still visible and owns
    /// its lifecycle. No live renderer/route transfer happens during prewarming.
    func prewarmRoom(forLiveSession: Bool) async {
        let mount = prepareScene()
        await loadRoom(into: mount.root, generation: mount.generation, includeFixture: !forLiveSession)
        guard isCurrent(mount.root, generation: mount.generation) else { return }
        roomPrepared = true
        preparedMount = mount
        applyPlacement()
    }

    func startLoading(_ mount: Mount) {
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            guard self.accessGranted, self.isCurrent(mount.root, generation: mount.generation) else { return }
            // Keep the flat renderer until assets/materials are prepared. The
            // previous order transferred video before constructing the room.
            if !roomPrepared {
                await loadRoom(into: mount.root, generation: mount.generation, includeFixture: !isLiveMode)
            }
            guard isCurrent(mount.root, generation: mount.generation) else { return }
            roomPrepared = true
            applyPlacement()
            updateVideoMaterial()
            if let ticket = liveTicket, let binding = liveBinding,
               let renderer = liveRenderer, let coordinator = liveCoordinator {
                let attachment = binding.attach(renderer, preservingOutgoingImage: true)
                await attachment.value
                guard isCurrent(mount.root, generation: mount.generation),
                      liveTicket == ticket,
                      coordinator.arenaRendererDidAttach(ticket) else {
                    binding.detach(renderer)
                    return
                }
                livePresentationReady = true
                updateLiveScenePhase(coordinator: coordinator)
            }
        }
    }

    private func loadRoom(into root: Entity, generation requestedGeneration: UUID, includeFixture: Bool) async {
        let texturesAvailable = await VisionArenaScreenRig.loadTextures(into: root, includeFixture: includeFixture)
        guard isCurrent(root, generation: requestedGeneration) else { return }
        applyGlow()
        guard Bundle.main.url(forResource: Self.modelName, withExtension: "usdz") != nil else {
            statusMessage = "The room asset is unavailable. Showing the screen and floor lighting preview."
            return
        }

        do {
            let room = try await Entity(named: Self.modelName + ".usdz", in: .main)
            guard isCurrent(root, generation: requestedGeneration) else { return }
            room.name = "FarframeAuthoredArena"
            room.stopAllAnimations(recursive: true)
            // Clear panes preserve the exterior without baked probe silhouettes.
            let opticalGlass: ShaderGraphMaterial? = nil
            guard isCurrent(root, generation: requestedGeneration) else { return }
            let surfaceVariation = await VisionArenaMaterials.loadSurfaceVariation()
            guard isCurrent(root, generation: requestedGeneration) else { return }
            VisionArenaMaterials.apply(to: room, opticalGlass: opticalGlass, surfaceVariation: surfaceVariation)
            // The exporter may retain a screen for Blender renders. Runtime owns
            // the only visible screen, keeping its image and halo in one rig.
            room.findEntity(named: "ArenaScreenPlaceholder")?.isEnabled = false
            root.addChild(room)
            VisionArenaScreenRig.mountHousing(from: room, on: root)
            exterior.select(.quietHorizon)
            exterior.mount(on: root)
            root.findEntity(named: "ArenaFallbackFloor")?.removeFromParent()
            statusMessage = texturesAvailable ? nil : "The room is ready. Its screen lighting could not load."

            await loadOptionalLighting(into: root, generation: requestedGeneration)
            await exterior.finishLoading()
        } catch {
            guard isCurrent(root, generation: requestedGeneration) else { return }
            statusMessage = "The room could not load. Showing the screen and floor lighting preview."
        }
    }

    /// Align once to the flat player's right axis, not the gaze at its ornament.
    /// Keep gravity upright: only horizontal yaw moves the room.
    func alignEntry(to transform: AffineTransform3D?) {
        guard !alignedEntry, phase == .opening || phase == .open,
              let transform, let root = sceneRoot else { return }
        let right = transform.matrix.columns.0
        guard right.x.isFinite, right.z.isFinite, hypot(right.x, right.z) > 0.00001 else { return }
        roomYaw = Float(atan2(-right.z, right.x))
        root.orientation = simd_quatf(angle: roomYaw, axis: [0, 1, 0])
        alignedEntry = true
    }

    func worldDidRecenter() {
        // The system has moved the shared world origin to the new heading.
        // Drop the old entry correction so room and recall button follow it.
        sceneRoot?.orientation = .init(angle: 0, axis: [0, 1, 0])
        roomYaw = 0
        lastViewerPosition = [0, 1.15, 0]
        distanceAdjustment = nil
    }

    func applyPlacement() {
        guard let sceneRoot else { return }
        if let manualPlacement {
            VisionArenaScreenRig.applyDisplayTransform(manualPlacement, in: sceneRoot)
        } else {
            VisionArenaScreenRig.applyPlacement(placement, in: sceneRoot)
        }
        VisionArenaScreenRig.setMovable(movable, in: sceneRoot)
    }

    func selectPreset(_ preset: VisionArenaScreenPlacement.Preset) {
        manualPlacement = nil
        distanceAdjustment = nil
        selectedPreset = preset
        selectedSavedScreenID = nil
        placement = preset.placement
        if preset == .cinema {
            let p = preset.placement
            let viewer = viewerPosition()
            manualPlacement = VisionArenaScreenRig.boundedTransform(Transform(
                scale: .init(repeating: p.scale),
                rotation: simd_quatf(angle: p.tilt * .pi / 180, axis: [1, 0, 0]),
                translation: viewer + [0, p.height - 1.15, -p.distance]))
        }
        movable = false
        applyPlacement()
    }

    var currentScreenTransform: Transform {
        if let manualPlacement { return manualPlacement }
        let p = placement.bounded
        return Transform(scale: .init(repeating: p.scale),
            rotation: simd_quatf(angle: p.yaw * .pi / 180, axis: [0, 1, 0])
                * simd_quatf(angle: p.tilt * .pi / 180, axis: [1, 0, 0]),
            translation: [p.horizontal, p.height, -p.distance])
    }

    var screenSize: Float { currentScreenTransform.scale.x }
    var screenDistance: Float { simd_length(currentScreenTransform.translation - lastViewerPosition) }
    var screenTilt: Float {
        let forward = currentScreenTransform.rotation.act(SIMD3<Float>(0, 0, 1))
        return asin(min(1, max(-1, -forward.y))) * 180 / .pi
    }

    func startViewerTracking() async {
        guard WorldTrackingProvider.isSupported else { return }
        let provider = WorldTrackingProvider()
        worldTracking = provider
        do {
            try await trackingSession.run([provider])
            if Task.isCancelled { trackingSession.stop(); worldTracking = nil }
        } catch { worldTracking = nil }
        // Presets/manual controls remain available if tracking is unavailable.
    }

    private func viewerPosition() -> SIMD3<Float> {
        if let worldTracking, worldTracking.state == .running,
           let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), anchor.isTracked {
            let column = anchor.originFromAnchorTransform.columns.3
            let position = SIMD3<Float>(column.x, column.y, column.z)
            lastViewerPosition = sceneRoot?.convert(position: position, from: nil) ?? position
        }
        return lastViewerPosition
    }

    private func commitScreenTransform(_ transform: Transform, preserveDistanceRay: Bool = false) {
        if !preserveDistanceRay { distanceAdjustment = nil }
        // Numeric edits take ownership from direct manipulation. Otherwise a
        // trailing system gesture update can overwrite the slider's transform.
        movable = false
        selectedSavedScreenID = nil
        manualPlacement = VisionArenaScreenRig.boundedTransform(transform)
        selectedPreset = nil
        applyPlacement()
    }

    func setScreenSize(_ scale: Float) {
        var transform = currentScreenTransform
        transform.scale = .init(repeating: scale)
        commitScreenTransform(transform)
    }

    func setScreenDistance(_ distance: Float) {
        if distanceAdjustment == nil {
            distanceAdjustment = (currentScreenTransform, viewerPosition())
        }
        guard let adjustment = distanceAdjustment else { return }
        commitScreenTransform(VisionArenaScreenRig.withDistance(distance,
            transform: adjustment.transform, viewer: adjustment.viewer), preserveDistanceRay: true)
    }

    func setScreenTilt(_ tilt: Float) {
        commitScreenTransform(VisionArenaScreenRig.withTilt(tilt,
            transform: currentScreenTransform, viewer: viewerPosition()))
    }

    func reorientScreen() {
        // Recalling a preset restores its exact saved orientation. Facing is a
        // manipulation policy, not permission to rewrite the saved transform.
        guard keepFacingViewer, selectedSavedScreenID == nil else { return }
        commitScreenTransform(VisionArenaScreenRig.facingViewer(currentScreenTransform, viewer: viewerPosition()))
    }

    func screenWasMoved(_ screen: Entity, finished: Bool) {
        guard screen.name == "ArenaStaticScreen", movable, let sceneRoot else { return }
        var transform = VisionArenaScreenRig.boundedTransform(screen.transform)
        if finished && keepFacingViewer {
            transform = VisionArenaScreenRig.facingViewer(transform, viewer: viewerPosition())
        }
        if finished {
            distanceAdjustment = nil
            manualPlacement = transform
            selectedPreset = nil
            selectedSavedScreenID = nil
        }
        VisionArenaScreenRig.applyDisplayTransform(transform, in: sceneRoot)
    }

    @discardableResult func saveScreen(named name: String) -> Bool {
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        guard !cleanName.isEmpty else { screenSaveMessage = "Name this position first."; return false }
        let transform = VisionArenaScreenRig.boundedTransform(currentScreenTransform)
        let item = VisionArenaSavedScreen(id: UUID(), name: cleanName,
            position: transform.translation, rotation: transform.rotation.vector,
            scale: transform.scale.x, keepFacingViewer: keepFacingViewer)
        guard savedScreens.add(item) else {
            screenSaveMessage = "Remove a saved position to make room."
            return false
        }
        recallScreen(item.id)
        screenSaveMessage = nil
        return true
    }

    func recallScreen(_ id: UUID) {
        guard let item = savedScreens.items.first(where: { $0.id == id }) else { return }
        commitScreenTransform(Transform(scale: .init(repeating: item.scale),
            rotation: simd_quatf(vector: item.rotation), translation: item.position))
        keepFacingViewer = item.keepFacingViewer
        selectedSavedScreenID = id
    }

    func removeScreen(_ id: UUID) {
        savedScreens.remove(id)
        if selectedSavedScreenID == id { selectedSavedScreenID = nil }
    }

    func updateManipulation() {
        if let sceneRoot { VisionArenaScreenRig.setMovable(movable, in: sceneRoot) }
    }

    func updateVideoMaterial() {
        guard isLiveMode, let sceneRoot else { return }
        let shouldInstall = roomPrepared && accessGranted && scenePhase != .background
        guard shouldInstall != videoMaterialIsInstalled else { return }
        VisionArenaScreenRig.installVideo(shouldInstall ? liveRenderer : nil, in: sceneRoot)
        videoMaterialIsInstalled = shouldInstall
    }

    func applyGlow() {
        updateVideoMaterial()
        updateLiveColorActivity()
        if let sceneRoot { VisionArenaLighting.update(in: sceneRoot, isActive: isActive && accessGranted) }
        applyScreenGlow(forceBloomUpdate: true)
    }

    private func applyScreenGlow(forceBloomUpdate: Bool = false) {
        guard let glowRoot else { return }
        if let liveColors { VisionArenaScreenRig.applyLiveColors(liveColors, in: glowRoot) }
        // No fixture color is used in live mode. Until a current frame's palette
        // arrives the live masks remain invisible, including after resumption.
        let glowIsActive = canUseReactiveLighting && (!isLiveMode || liveColors != nil)
        let opacity = glowIsActive ? glow.opacity : 0
        if forceBloomUpdate || appliedOpacity != opacity {
            VisionArenaBloom.update(in: glowRoot, level: glow, isActive: glowIsActive)
        }
        guard appliedOpacity != opacity else { return }
        glowRoot.isEnabled = opacity > 0
        glowRoot.components.set(OpacityComponent(opacity: opacity))
        appliedOpacity = opacity
    }

    func tearDown() {
        trackingSession.stop()
        worldTracking = nil
        controlsCommand = nil
        exterior.unmount()
        entryAttemptID = UUID()
        stopLiveColors()
        colorAnalyzer = nil
        if let liveBinding, let liveRenderer { liveBinding.detach(liveRenderer) }
        liveBinding = nil
        liveRenderer = nil
        videoMaterialIsInstalled = false
        roomPrepared = false
        preparedMount = nil
        liveCoordinator = nil
        liveTicket = nil
        livePresentationReady = false
        loadTask?.cancel()
        loadTask = nil
        generation = UUID()
        sceneRoot?.stopAllAnimations(recursive: true)
        sceneRoot?.removeFromParent()
        sceneRoot = nil
        glowRoot = nil
        appliedOpacity = nil
        statusMessage = nil
        phase = .closed
        accessGranted = false
    }

    func updateAccess(_ granted: Bool) {
        accessGranted = granted
        if !granted { exterior.unmount() }
        applyGlow()
    }

    private var canUseReactiveLighting: Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        return VisionArenaLightingActivity.allowsReactiveLighting(
            accessGranted: accessGranted, active: isActive, reduceMotion: reduceMotion,
            glowEnabled: glow != .off, thermalLimited: thermal == .serious || thermal == .critical
        )
    }

    private func updateLiveColorActivity() {
        guard livePresentationReady, canUseReactiveLighting,
              let ticket = liveTicket, liveCoordinator?.arenaPresentation.ticket == ticket,
              let binding = liveBinding, let renderer = liveRenderer else {
            stopLiveColors()
            return
        }
        guard colorGeneration == nil else { return }
        let generation = UUID()
        colorGeneration = generation
        if colorAnalyzer == nil {
            colorAnalyzer = VisionArenaLiveColorAnalyzer { [weak self] snapshot in
                guard let self, self.colorGeneration == snapshot.generation,
                      self.isActive, self.accessGranted, !self.reduceMotion, self.liveTicket == ticket else { return }
                self.liveColors = snapshot.colors
                self.applyScreenGlow()
            }
        }
        guard let analyzer = colorAnalyzer else { return }
        analyzer.begin(generation: generation)
        binding.observePresentedFrames(on: renderer) { [weak analyzer] frame in
            analyzer?.submit(frame.pixelBuffer, generation: generation)
        }
    }

    private func stopLiveColors() {
        if let colorGeneration { colorAnalyzer?.stop(generation: colorGeneration) }
        if colorGeneration != nil, let liveBinding, let liveRenderer {
            liveBinding.stopObservingPresentedFrames(on: liveRenderer)
        }
        colorGeneration = nil
        liveColors = nil
    }

    func updateLiveScenePhase(coordinator: VisionRemotePlayCoordinator) {
        guard let ticket = liveTicket, livePresentationReady,
              coordinator.arenaPresentation.phase == .immersive(ticket) else { return }
        switch scenePhase {
        case .active:
            Task { @MainActor in
                guard self.scenePhase == .active, self.liveTicket == ticket,
                      self.phase == .open, self.livePresentationReady,
                      coordinator.arenaPresentation.phase == .immersive(ticket) else { return }
                _ = await coordinator.playerSceneBecameActive()
            }
        case .background:
            coordinator.playerSceneBecameNonActive()
        case .inactive:
            coordinator.playerSceneBecameInactive()
        @unknown default:
            coordinator.playerSceneBecameInactive()
        }
    }

    /// Safe for both the Exit button and unexpected system disappearance. The
    /// flat window may have been closed while immersive; reopening is explicit.
    /// A duplicate callback for the same transfer does not recreate its layer.
    @discardableResult
    func restoreFlat(
        ticket: VisionArenaPresentationRoute.Ticket,
        coordinator: VisionRemotePlayCoordinator,
        openPlayer: @MainActor () -> Void
    ) async -> Bool {
        guard coordinator.beginArenaReturn(ticket) else {
            return coordinator.activeSessionID == ticket.sessionID && coordinator.arenaPresentation.flatOwnsLifecycle
        }
        openPlayer()
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while ContinuousClock.now < deadline {
            guard coordinator.activeSessionID == ticket.sessionID,
                  coordinator.arenaPresentation.ticket == ticket else {
                return coordinator.activeSessionID == ticket.sessionID && coordinator.arenaPresentation.flatOwnsLifecycle
            }
            // Do not inherit an exiting SwiftUI task's cancellation: completing
            // this safety handoff is required even when its scene disappears.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
            }
        }
        guard coordinator.activeSessionID == ticket.sessionID,
              coordinator.arenaPresentation.ticket == ticket else {
            return coordinator.activeSessionID == ticket.sessionID && coordinator.arenaPresentation.flatOwnsLifecycle
        }
        if livePresentationReady, let binding = liveBinding, let renderer = liveRenderer, sceneRoot != nil,
           coordinator.cancelArenaReturn(ticket) {
            // Explicit Exit still has its scene and last picture. Restore that
            // renderer instead of turning a presentation delay into lost play.
            await binding.attach(renderer, preservingOutgoingImage: true).value
            guard coordinator.activeSessionID == ticket.sessionID,
                  coordinator.arenaPresentation.phase == .immersive(ticket) else { return false }
            if scenePhase != .background { binding.setPresentationSuspended(false) }
            stopLiveColors() // Backend replacement clears its frame observer.
            phase = .open
            applyGlow()
            statusMessage = "The window could not show video. Try Exit Room again."
            return false
        }
        entryMessage = "The player could not reopen. The session was disconnected."
        await coordinator.disconnect()
        return false
    }

    private func isCurrent(_ root: Entity, generation requestedGeneration: UUID) -> Bool {
        accessGranted && !Task.isCancelled && generation == requestedGeneration && sceneRoot === root
    }

    private func loadOptionalLighting(into root: Entity, generation requestedGeneration: UUID) async {
        let probeURL = ["exr", "hdr"].compactMap {
            Bundle.main.url(forResource: Self.lightingName, withExtension: $0)
        }
        guard let url = probeURL.first else { return }
        do {
            let worker = Task.detached(priority: .utility) {
                try VisionArenaProbeImage.load(at: url)
            }
            let image = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            let environment = try await EnvironmentResource(equirectangular: image)
            guard isCurrent(root, generation: requestedGeneration) else { return }
            _ = VisionArenaLighting.install(on: root, environment: environment)
            VisionArenaLighting.update(in: root, isActive: isActive)
        } catch {
            guard isCurrent(root, generation: requestedGeneration) else { return }
            statusMessage = "The room is ready. Its optional reflection lighting is unavailable."
        }
    }

    private func makeFallbackFloor() -> Entity {
        let material = SimpleMaterial(
            color: UIColor(red: 0.025, green: 0.035, blue: 0.05, alpha: 1),
            roughness: 0.55,
            isMetallic: false
        )
        let floor = ModelEntity(mesh: .generatePlane(width: 11.6, depth: 15.6), materials: [material])
        floor.name = "ArenaFallbackFloor"
        floor.position = [0, -0.005, -4]
        return floor
    }
}

private enum VisionArenaProbeImage {
    enum LoadError: Error { case invalidImage }

    static func load(at url: URL) throws -> CGImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = metadata[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = metadata[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0,
              width.intValue <= 2_048, height.intValue <= 1_024,
              abs(width.doubleValue / height.doubleValue - 2) < 0.01,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw LoadError.invalidImage
        }
        return image
    }
}
#endif
