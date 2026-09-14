#if os(visionOS) || FARFRAME_ROOM_LAB
    import Foundation
    import Observation
    import RealityKit

    /// Owns only the exterior subtree. Selection cannot touch the screen, decoder,
    /// session, access gate or room mount. At most one completed exterior is held.
    @MainActor @Observable
    final class VisionArenaExteriorController {
        typealias Loader = @MainActor (VisionArenaExteriorStyle) async throws -> Entity
        static let preferenceKey = "farframe.arena.exterior"
        private(set) var selection: VisionArenaExteriorStyle
        private(set) var displayedStyle: VisionArenaExteriorStyle?
        private(set) var isLoading = false
        private(set) var message: String?
        @ObservationIgnored private let defaults: UserDefaults
        @ObservationIgnored private let loader: Loader
        @ObservationIgnored private var parent: Entity?
        @ObservationIgnored private var exterior: Entity?
        @ObservationIgnored private var request = UUID()
        @ObservationIgnored private var task: Task<Void, Never>?

        init(defaults: UserDefaults = .standard, loader: @escaping Loader) {
            self.defaults = defaults
            self.loader = loader
            selection =
                defaults.string(forKey: Self.preferenceKey)
                .flatMap(VisionArenaExteriorStyle.init(rawValue:)) ?? .quietHorizon
        }

        func mount(on parent: Entity) {
            unmount()
            self.parent = parent
            select(selection)
        }

        func select(_ style: VisionArenaExteriorStyle) {
            guard let parent else {
                // Preserve a choice made while the room itself is still loading.
                // It queues no work until the access-gated room mounts this slot.
                selection = style
                message = nil
                return
            }
            guard selection != style || (!isLoading && displayedStyle != style) else { return }
            task?.cancel()
            selection = style
            message = nil
            isLoading = true
            let request = UUID()
            self.request = request
            task = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled, self.request == request else { return }
                do {
                    let root = try await loader(style)
                    guard !Task.isCancelled, self.request == request, self.parent === parent else { return }
                    // Replace synchronously on the scene actor; no empty render frame.
                    exterior?.removeFromParent()
                    root.name = "ArenaExterior"
                    parent.addChild(root)
                    exterior = root
                    displayedStyle = style
                    defaults.set(style.rawValue, forKey: Self.preferenceKey)
                    isLoading = false
                    task = nil
                } catch {
                    guard !Task.isCancelled, self.request == request, self.parent === parent else { return }
                    isLoading = false
                    task = nil
                    if let displayedStyle { selection = displayedStyle }
                    message = "The view couldn’t load. Your room is still available."
                }
            }
        }

        func finishLoading() async {
            await task?.value
        }

        func unmount() {
            request = UUID()
            task?.cancel()
            task = nil
            exterior?.removeFromParent()
            exterior = nil
            parent = nil
            displayedStyle = nil
            isLoading = false
            message = nil
        }
    }
#endif
