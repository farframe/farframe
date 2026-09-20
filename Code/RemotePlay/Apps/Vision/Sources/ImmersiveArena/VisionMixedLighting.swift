import AppleMediaCore
import AVFoundation
import FarframeStorefront
import Observation
import RealityKit
import Spatial
import SwiftUI
import UIKit

/// Screen glow stays on the player window. One existing mixed space supports
/// optional wall lighting and dimming, both explicitly inside Mixed immersion.
@MainActor @Observable
final class VisionMixedLightingState {
    static let spaceID = "farframe-mixed-lighting"
    enum Phase { case closed, opening, open, closing }
    var phase: Phase = .closed
    var entryID = UUID()
    @ObservationIgnored private var dismissalInFlight = false
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
        var localizedTitle: LocalizedStringKey { LocalizedStringKey(rawValue) }
        var radius: Float {
            switch self { case .nearby: 3; case .standard: 4; case .wide: 5 }
        }
        var outerAngle: Float {
            switch self { case .nearby: 55; case .standard: 65; case .wide: 75 }
        }
    }
    var dimSurroundings = false {
        didSet { defaults.set(dimSurroundings, forKey: "farframe.vision.mixed.dimSurroundings") }
    }
    var spread: Spread = .standard {
        didSet { defaults.set(spread.rawValue, forKey: "farframe.vision.mixed.spread") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dimSurroundings = defaults.bool(forKey: "farframe.vision.mixed.dimSurroundings")
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

    enum GlowPreset: String, CaseIterable, Identifiable {
        case off = "Off", low = "Low", medium = "Medium", wide = "Wide"
        var id: Self { self }
    }
    var glowPreset: GlowPreset {
        if level == .off { return .off }
        if spread == .wide { return .wide }
        return level == .low ? .low : .medium
    }
    func selectGlowPreset(_ preset: GlowPreset) {
        switch preset {
        case .off: level = .off
        case .low: level = .low; spread = .nearby
        case .medium: level = .medium; spread = .standard
        case .wide: level = .medium; spread = .wide
        }
        refresh()
    }
    var windowCenter: Point3D?
    var windowTransform: AffineTransform3D?
    var windowSize: Size3D?
    var windowExtentMeters: SIMD2<Float>?
    // Inactive can still be visible while a popover or system capture owns focus.
    var windowVisible = true
    var spaceVisible = true
    var reduceMotion = false
    private(set) var thermalState = ProcessInfo.processInfo.thermalState
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
        // Follow all four screen edges as the window grows. Fixed offsets kept
        // every emitter clustered in the middle of a large game window.
        let extent = windowExtentMeters ?? SIMD2<Float>(0.94, 0.66)
        let halfWidth = extent.x.isFinite ? max(0.1, extent.x / 2 - 0.05) : 0.42
        let halfHeight = extent.y.isFinite ? max(0.1, extent.y / 2 - 0.05) : 0.28
        let positions: [SIMD3<Float>] = [
            [-halfWidth, 0, 0.1], [halfWidth, 0, 0.1],
            [0, halfHeight, 0.1], [0, -halfHeight, 0.1]
        ]
        for (light, position) in zip(lights, positions) { light.position = position }
        refresh()
    }

    func refresh() {
        thermalState = ProcessInfo.processInfo.thermalState
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
        return windowAttached && windowVisible && level != .off && !reduceMotion
            && thermalState != .serious && thermalState != .critical
            && layer != nil && surface != nil
    }

    private var canPlaceWallLights: Bool {
        phase == .open && spaceVisible && canSampleColors && Self.supported
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
            let output = VisionMixedWallLightPolicy.output(color: color, low: level == .low,
                boost: lightBoost, thermalState: thermalState)
            light.isEnabled = output.lumens > 0
            guard output.lumens > 0 else { continue }
            let tint = UIColor(red: encoded(output.tint.x), green: encoded(output.tint.y),
                               blue: encoded(output.tint.z), alpha: 1)
            light.components.set(PointLightComponent(color: tint,
                intensity: output.lumens, attenuationRadius: output.radius))
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

    func dismiss(using dismissSpace: @MainActor () async -> Void) async {
        guard phase != .closed, !dismissalInFlight else { return }
        dismissalInFlight = true
        phase = .closing
        refresh()
        await dismissSpace()
        dismissalInFlight = false
        close()
    }

    func close() {
        entryID = UUID()
        root.isEnabled = false
        root.removeFromParent()
        lights.forEach { $0.removeFromParent() }
        lights.removeAll()
        // onDisappear can arrive before dismissImmersiveSpace returns. Keep
        // Arena/re-entry unavailable until that pending dismissal completes.
        phase = dismissalInFlight ? .closing : .closed
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
        .preferredSurroundingsEffect(state.dimSurroundings ? .systemDark : nil)
        .onAppear {
            state.spaceVisible = scenePhase != .background
            state.reduceMotion = reduceMotion
            state.refresh()
        }
        .onDisappear { state.close() }
        .onChange(of: scenePhase) { _, phase in state.spaceVisible = phase != .background; state.refresh() }
        .onChange(of: reduceMotion) { _, value in state.reduceMotion = value; state.refresh() }
        .onChange(of: state.windowVisible) { _, _ in state.refresh() }
        .onChange(of: state.phase) { _, _ in state.refresh() }
        .onChange(of: state.level) { _, _ in state.refresh() }
        .task {
            // Also removes illumination promptly on thermal pressure, access
            // loss, session end, or a closed player without touching transport.
            while !Task.isCancelled {
                state.accessGranted = accessStore.allowsImmersive
                guard coordinator.activeSessionID != nil, state.windowAttached,
                      state.accessGranted else {
                    if state.phase != .closing && state.phase != .closed {
                        await state.dismiss { await dismissImmersiveSpace() }
                    }
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
            Image(systemName: VisionPlayerControlID.immersive.reference.symbol).font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .help("Immersive environment")
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .accessibilityLabel(Text(LocalizedStringKey(VisionPlayerControlID.immersive.reference.title)))
        .popover(isPresented: $showChoices) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    screenGlowControls
                    Divider()
                    environmentChoices
                    if let message = arena.mixedLighting.message { Text(message).font(.footnote) }
                }
                .padding(24)
            }
            .frame(width: 360, height: 580)
        }
    }

    @ViewBuilder
    private var environmentChoices: some View {
        Text("Immersive environments").font(.headline)
        if arena.mixedLighting.phase == .open {
            Text("Mixed").font(.subheadline)
            Toggle("Dim surroundings", isOn: Binding(
                get: { arena.mixedLighting.dimSurroundings },
                set: { arena.mixedLighting.dimSurroundings = $0 }))
            Text("Dimming applies while Mixed is open.")
                .font(.footnote).foregroundStyle(.secondary)
            wallLightControls
            Button("Exit Mixed") {
                Task { @MainActor in
                    await arena.mixedLighting.dismiss { await dismissImmersiveSpace() }
                }
            }
            Text("Exit Mixed to choose Glass Arena.").font(.footnote).foregroundStyle(.secondary)
        } else {
            Button("Mixed", systemImage: "rectangle.on.rectangle") { openMixed() }
                .buttonStyle(.borderedProminent)
                .disabled(!VisionMixedLightingState.supported || arena.mixedLighting.phase != .closed)
            Text("Enter Mixed for dimming and optional light on the walls.")
                .font(.footnote).foregroundStyle(.secondary)
            if !VisionMixedLightingState.supported {
                Text("Mixed wall light requires visionOS 27.").font(.footnote)
            }
            VisionArenaPreviewLauncher(state: arena, accessStore: accessStore,
                coordinator: coordinator, showsTitle: true)
                .disabled(arena.mixedLighting.phase != .closed)
        }
    }

    private var wallLightControls: some View {
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
            if arena.mixedLighting.thermalState == .serious || arena.mixedLighting.thermalState == .critical {
                Text("Wall lighting is paused while Vision Pro cools down.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .disabled(arena.mixedLighting.level == .off)
    }

    @ViewBuilder
    private var screenGlowControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ambient glow").font(.headline)
            Picker("Ambient glow", selection: Binding(
                get: { arena.mixedLighting.glowPreset },
                set: { arena.mixedLighting.selectGlowPreset($0) })) {
                ForEach(VisionMixedLightingState.GlowPreset.allCases) {
                    Text(LocalizedStringKey($0.rawValue)).tag($0)
                }
            }
            .pickerStyle(.segmented)
            Text("Medium is the standard glow. Wide extends farther around the picture.")
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
                    await state.dismiss { await dismissImmersiveSpace() }
                    return
                }
                state.phase = .open
                state.refresh()
                // Keep the controls available so dimming is immediately visible.
            case .userCancelled:
                state.close()
            default:
                state.close()
                state.message = "Mixed could not open. Your game remains in its window."
            }
        }
    }
}
