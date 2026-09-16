import AppleMediaCore
import AVFoundation
import FarframeStorefront
import Observation
import RealityKit
import Spatial
import SwiftUI
import UIKit

/// Mixed immersion adds wall lights. Screen glow lives on the player window
/// and uses the same Off/Low/Medium and Nearby/Standard/Wide settings.
@MainActor @Observable
final class VisionMixedLightingState {
    static let spaceID = "farframe-mixed-lighting"
    enum Phase { case closed, opening, open, closing }
    var phase: Phase = .closed
    var entryID = UUID()
    @ObservationIgnored private let defaults: UserDefaults
    var level: VisionArenaGlow = .medium {
        didSet { defaults.set(level.rawValue, forKey: "farframe.vision.mixed.level") }
    }
    private(set) var lightBoost: Float = 1 {
        didSet { defaults.set(lightBoost, forKey: "farframe.vision.mixed.boost") }
    }
    enum Spread: String, CaseIterable, Identifiable {
        case nearby = "Nearby", standard = "Standard", wide = "Wide"
        var id: Self { self }
        var radius: Float {
            switch self { case .nearby: 3; case .standard: 4; case .wide: 5 }
        }
        var outerAngle: Float {
            switch self { case .nearby: 55; case .standard: 65; case .wide: 75 }
        }
    }
    var spread: Spread = .standard {
        didSet { defaults.set(spread.rawValue, forKey: "farframe.vision.mixed.spread") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        level = defaults.string(forKey: "farframe.vision.mixed.level")
            .flatMap(VisionArenaGlow.init(rawValue:)) ?? .medium
        spread = defaults.string(forKey: "farframe.vision.mixed.spread")
            .flatMap(Spread.init(rawValue:)) ?? .standard
        let stored = defaults.object(forKey: "farframe.vision.mixed.boost") as? NSNumber
        let boost = stored?.floatValue ?? 1
        lightBoost = boost.isFinite ? min(2, max(1, boost)) : 1
    }

    func setLightBoost(_ value: Float) {
        lightBoost = value.isFinite ? min(2, max(1, value)) : 1
        refresh()
    }

    func selectLevel(_ value: VisionArenaGlow) {
        level = value
        refresh()
    }
    var windowCenter: Point3D?
    var windowTransform: AffineTransform3D?
    var windowSize: Size3D?
    var windowExtentMeters: SIMD2<Float>?
    var windowActive = true
    var spaceActive = true
    var reduceMotion = false
    var accessGranted = false
    var message: String?
    private(set) var windowAttached = false
    @ObservationIgnored let root = Entity()
    @ObservationIgnored private var lights: [Entity] = []
    @ObservationIgnored private weak var layer: AVSampleBufferDisplayLayer?
    @ObservationIgnored private var surface: SampleBufferVideoSurfaceBinding?
    @ObservationIgnored private var analyzer: VisionArenaLiveColorAnalyzer?
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var colors = VisionArenaLiveColorPolicy.EdgeColors.black
    var screenGlowPalette = VisionScreenGlowPalette.black
    var screenGlowStyle: VisionScreenGlowStyle {
        let extent: VisionScreenGlowStyle.Extent = spread == .wide ? .room : .tight
        let levelWidth: CGFloat = level == .low ? 0.85 : 1
        let spreadWidth: CGFloat
        switch spread {
        case .nearby: spreadWidth = 0.85
        case .standard: spreadWidth = 1.4
        case .wide: spreadWidth = 1.2
        }
        return VisionScreenGlowStyle(
            isActive: level != .off,
            extent: extent,
            widthScale: levelWidth * spreadWidth,
            strength: level == .low ? 0.75 : 1
        )
    }

    static var supported: Bool {
        #if compiler(>=6.4)
        if #available(visionOS 27.0, *) { return true }
        #endif
        return false
    }

    func bind(layer: AVSampleBufferDisplayLayer, surface: SampleBufferVideoSurfaceBinding) {
        if self.layer === layer, self.surface === surface { return }
        stopSampling()
        self.layer = layer
        self.surface = surface
        windowAttached = true
        refresh()
    }

    func unbind(layer: AVSampleBufferDisplayLayer) {
        guard self.layer === layer else { return }
        stopSampling()
        self.layer = nil
        surface = nil
        windowAttached = false
    }

    func mount() -> Entity {
        if lights.count != 4 {
            lights.forEach { $0.removeFromParent() }
            lights.removeAll()
            let placements: [SIMD3<Float>] = [
                [-0.42, 0, 0.1],
                [0.42, 0, 0.1],
                [0, 0.28, 0.1],
                [0, -0.28, 0.1]
            ]
            for position in placements {
                let light = Entity()
                light.name = "MixedAmbientLight"
                light.position = position
                light.components.remove(CollisionComponent.self)
                light.components.remove(InputTargetComponent.self)
                #if compiler(>=6.4)
                if #available(visionOS 27.0, *) {
                    light.components.set(PointLightComponent.SurroundingsLight())
                }
                #endif
                root.addChild(light)
                lights.append(light)
            }
        }
        root.isEnabled = false
        return root
    }

    func place(using content: RealityViewContent) {
        guard let center = windowCenter, let transform = windowTransform else {
            root.isEnabled = false
            return
        }
        let converted = content.convert(transform, from: .immersiveSpace, to: .scene)
        root.position = content.convert(center, from: .immersiveSpace, to: .scene)
        root.orientation = converted.rotation
        // Physical light radius is in meters, independent of SwiftUI point scale.
        root.scale = .one
        refresh()
    }

    func refresh() {
        if canSampleColors, let layer, let surface {
            startSamplingIfNeeded(layer: layer, surface: surface)
        } else if level == .off || layer == nil {
            stopSampling()
        } else {
            pauseSampling()
        }
        root.isEnabled = canPlaceWallLights
        applyWallLights()
        if level == .off {
            screenGlowPalette = .black
        } else {
            screenGlowPalette = VisionScreenGlowPalette(
                edgeColors: colors,
                extent: screenGlowStyle.extent
            )
        }
    }

    private var canSampleColors: Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        return windowAttached && windowActive && level != .off && !reduceMotion
            && thermal != .serious && thermal != .critical
            && layer != nil && surface != nil
    }

    private var canPlaceWallLights: Bool {
        phase == .open && spaceActive && canSampleColors && Self.supported
            && lightBoost > 1.05
            && windowCenter != nil && windowTransform != nil
    }

    private func startSamplingIfNeeded(layer: AVSampleBufferDisplayLayer, surface: SampleBufferVideoSurfaceBinding) {
        guard generation == nil else { return }
        let id = UUID()
        generation = id
        if analyzer == nil {
            analyzer = VisionArenaLiveColorAnalyzer { [weak self] snapshot in
                guard let self, self.generation == snapshot.generation else { return }
                self.colors = snapshot.colors
                self.screenGlowPalette = VisionScreenGlowPalette(
                    edgeColors: snapshot.colors,
                    extent: self.screenGlowStyle.extent
                )
                self.applyWallLights()
            }
        }
        guard let analyzer else { return }
        analyzer.begin(generation: id)
        surface.observePresentedFrames(on: layer) { [weak analyzer] frame in
            analyzer?.submit(frame.pixelBuffer, generation: id)
        }
    }

    private func applyWallLights() {
        let enabled = canPlaceWallLights && generation != nil
        for light in lights { light.isEnabled = enabled }
        guard enabled else { return }
        for (light, color) in zip(lights, [colors.left, colors.right, colors.top, colors.bottom]) {
            let peak = max(color.x, max(color.y, color.z))
            let normalized = peak > 0.001 ? color / peak : .zero
            let tint = UIColor(red: encoded(normalized.x), green: encoded(normalized.y),
                               blue: encoded(normalized.z), alpha: 1)
            let wash = max(0, lightBoost - 1)
            light.components.set(PointLightComponent(color: tint,
                intensity: (level == .medium ? 900 : 450) * wash * peak,
                attenuationRadius: 3.5 + wash * 2))
        }
    }

    private func encoded(_ value: Float) -> CGFloat {
        CGFloat(value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055)
    }

    private func pauseSampling() {
        if let generation {
            analyzer?.stop(generation: generation)
            if let layer { surface?.stopObservingPresentedFrames(on: layer) }
        }
        generation = nil
        root.isEnabled = false
    }

    private func stopSampling() {
        pauseSampling()
        colors = .black
        screenGlowPalette = .black
    }

    func close() {
        entryID = UUID()
        root.removeFromParent()
        phase = .closed
        accessGranted = false
        refresh()
    }
}

struct VisionMixedLightingView: View {
    @Bindable var state: VisionMixedLightingState
    @Bindable var coordinator: VisionRemotePlayCoordinator
    @Bindable var accessStore: FarframeAccessStore
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = (state.windowCenter, state.windowTransform, state.windowSize,
                 state.windowExtentMeters, state.level, state.spread, state.lightBoost, state.phase)
        RealityView { content in
            content.add(state.mount())
            state.place(using: content)
        } update: { content in
            state.place(using: content)
        }
        .onAppear {
            state.spaceActive = scenePhase == .active
            state.reduceMotion = reduceMotion
            state.refresh()
        }
        .onDisappear { state.close() }
        .onChange(of: scenePhase) { _, phase in state.spaceActive = phase == .active; state.refresh() }
        .onChange(of: reduceMotion) { _, value in state.reduceMotion = value; state.refresh() }
        .onChange(of: state.windowActive) { _, _ in state.refresh() }
        .onChange(of: state.phase) { _, _ in state.refresh() }
        .onChange(of: state.level) { _, _ in state.refresh() }
        .task {
            // Also removes illumination promptly on thermal pressure, access
            // loss, session end, or a closed player without touching transport.
            while !Task.isCancelled {
                state.accessGranted = accessStore.allowsImmersive
                guard coordinator.activeSessionID != nil, state.windowAttached,
                      state.accessGranted else {
                    state.phase = .closing
                    await dismissImmersiveSpace()
                    state.close()
                    return
                }
                state.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}

struct VisionEnvironmentControl: View {
    @Bindable var arena: VisionArenaPreviewState
    @Bindable var coordinator: VisionRemotePlayCoordinator
    let accessStore: FarframeAccessStore
    @State private var showChoices = false
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        Button { showChoices.toggle() } label: {
            Image(systemName: "cube.transparent").font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .help("Immersive environment")
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .accessibilityLabel("Immersive environment")
        .popover(isPresented: $showChoices) {
            VStack(alignment: .leading, spacing: 18) {
                screenGlowControls
                Text("Immersive environments").font(.headline)
                if arena.mixedLighting.phase == .open {
                    Text("Mixed").font(.headline)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Light boost")
                            Spacer()
                            Text("\(Int((arena.mixedLighting.lightBoost * 100).rounded()))%")
                                .monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { arena.mixedLighting.lightBoost },
                            set: { arena.mixedLighting.setLightBoost($0) }),
                            in: 1...2, step: 0.05)
                            .accessibilityLabel("Light boost")
                            .accessibilityValue("\(Int((arena.mixedLighting.lightBoost * 100).rounded())) percent")
                        Text("100% is screen glow only. Raise this for light on the walls.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .disabled(arena.mixedLighting.level == .off)
                    Button("Exit Mixed") {
                        Task { @MainActor in
                            arena.mixedLighting.phase = .closing
                            arena.mixedLighting.refresh()
                            await dismissImmersiveSpace()
                            arena.mixedLighting.close()
                        }
                    }
                    Text("Exit Mixed to choose Glass Arena.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button("Mixed", systemImage: "rectangle.on.rectangle") { openMixed() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!VisionMixedLightingState.supported || arena.mixedLighting.phase != .closed)
                    Text("A full mixed environment, with optional light on the walls.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !VisionMixedLightingState.supported {
                        Text("Mixed wall light requires visionOS 27.").font(.footnote)
                    }
                    VisionArenaPreviewLauncher(state: arena, accessStore: accessStore,
                        coordinator: coordinator, showsTitle: true)
                        .disabled(arena.mixedLighting.phase != .closed)
                }
                if let message = arena.mixedLighting.message { Text(message).font(.footnote) }
            }
            .padding(24).frame(width: 340)
        }
    }

    @ViewBuilder
    private var screenGlowControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ambient glow").font(.headline)
            Picker("Ambient glow", selection: Binding(
                get: { arena.mixedLighting.level },
                set: { arena.mixedLighting.selectLevel($0) })) {
                ForEach(VisionArenaGlow.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Spread")
            Picker("Spread", selection: Binding(
                get: { arena.mixedLighting.spread },
                set: { arena.mixedLighting.spread = $0; arena.mixedLighting.refresh() })) {
                ForEach(VisionMixedLightingState.Spread.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(arena.mixedLighting.level == .off)
            Text("Nearby hugs the picture. Standard is a fuller ring. Wide is the broad wash.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Glow around the window in your space. Nearby, Standard, and Wide change how far it reaches.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func openMixed() {
        let state = arena.mixedLighting
        guard state.phase == .closed, arena.phase == .closed else { return }
        guard let sessionID = coordinator.activeSessionID else { return }
        let entryID = UUID()
        state.entryID = entryID
        state.phase = .opening
        state.message = nil
        Task { @MainActor in
            let allowed = await accessStore.revalidateImmersiveAccess()
            guard state.entryID == entryID, state.phase == .opening else { return }
            guard allowed, state.windowAttached,
                  coordinator.activeSessionID == sessionID else {
                state.close()
                state.message = "Start playing and unlock Farframe before entering."
                return
            }
            state.accessGranted = true
            let result = await openImmersiveSpace(id: VisionMixedLightingState.spaceID)
            guard state.entryID == entryID else { return }
            switch result {
            case .opened:
                let stillAllowed = await accessStore.revalidateImmersiveAccess()
                guard state.entryID == entryID else { return }
                guard state.windowAttached, coordinator.activeSessionID == sessionID,
                      stillAllowed else {
                    await dismissImmersiveSpace()
                    state.close()
                    return
                }
                state.phase = .open
                state.refresh()
                showChoices = false
            case .userCancelled:
                state.close()
            default:
                state.close()
                state.message = "Mixed could not open. Your game remains in its window."
            }
        }
    }
}
