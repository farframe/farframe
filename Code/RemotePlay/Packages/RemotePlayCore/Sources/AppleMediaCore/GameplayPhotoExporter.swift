import Foundation
import Photos

/// Shared Apple-platform destination for a finished gameplay movie. The shell
/// owns capture UI and temporary files; this service only requests add access
/// and awaits Photos' import completion. It never reads the photo library.
public protocol GameplayPhotoLibrary: Sendable {
    func requestAddAccess() async -> Bool
    func addMovie(at url: URL) async throws
}

public struct GameplayPhotoExporter: Sendable {
    private let library: any GameplayPhotoLibrary
    public init(library: any GameplayPhotoLibrary = SystemGameplayPhotoLibrary()) {
        self.library = library
    }
    public func requestAccess() async -> Bool { await library.requestAddAccess() }
    public func save(_ url: URL) async throws {
        guard await requestAccess() else { throw ExportError.accessDenied }
        try await library.addMovie(at: url)
    }
    public enum ExportError: LocalizedError {
        case accessDenied, importFailed
        public var errorDescription: String? {
            switch self {
            case .accessDenied: "Allow Farframe to add to Photos in Settings, then retry."
            case .importFailed: "Photos could not save this video. Retry or share the saved file."
            }
        }
    }
}

public struct SystemGameplayPhotoLibrary: GameplayPhotoLibrary {
    public init() {}
    public func requestAddAccess() async -> Bool {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
    }
    public func addMovie(at url: URL) async throws {
        // Fail explicitly if Photos cannot create a request; a no-op changes
        // transaction must never be reported as a successful video import.
        let requestState = PhotoRequestState()
        try await PHPhotoLibrary.shared().performChanges {
            requestState.setCreated(PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) != nil)
        }
        guard requestState.wasCreated else { throw GameplayPhotoExporter.ExportError.importFailed }
    }
}

private final class PhotoRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var created = false
    var wasCreated: Bool { lock.withLock { created } }
    func setCreated(_ value: Bool) { lock.withLock { created = value } }
}
