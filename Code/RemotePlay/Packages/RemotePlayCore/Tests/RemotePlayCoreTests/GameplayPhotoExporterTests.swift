import Foundation
import Testing
@testable import AppleMediaCore

struct GameplayPhotoExporterTests {
    actor Library: GameplayPhotoLibrary {
        enum Failure: Error { case importFailed }
        var allowed: Bool
        let fails: Bool
        var imports: [URL] = []
        var permissionRequests = 0
        init(allowed: Bool, fails: Bool = false) { self.allowed = allowed; self.fails = fails }
        func requestAddAccess() -> Bool { permissionRequests += 1; return allowed }
        func addMovie(at url: URL) throws {
            imports.append(url)
            if fails { throw Failure.importFailed }
        }
        func deny() { allowed = false }
    }

    @Test func deniedAccessNeverStartsImport() async {
        let library = Library(allowed: false)
        let exporter = GameplayPhotoExporter(library: library)
        await #expect(throws: GameplayPhotoExporter.ExportError.self) {
            try await exporter.save(URL(fileURLWithPath: "/unused/video.mp4"))
        }
        #expect(await library.imports.isEmpty)
    }

    @Test func permissionIsRecheckedBeforeSave() async {
        let library = Library(allowed: true)
        let exporter = GameplayPhotoExporter(library: library)
        #expect(await exporter.requestAccess())
        await library.deny()
        await #expect(throws: GameplayPhotoExporter.ExportError.self) {
            try await exporter.save(URL(fileURLWithPath: "/unused/video.mp4"))
        }
        #expect(await library.permissionRequests == 2)
        #expect(await library.imports.isEmpty)
    }

    @Test func importFailurePreservesTheSourceFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoExport-\(UUID()).mp4")
        try Data([1,2,3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let library = Library(allowed: true, fails: true)
        await #expect(throws: Library.Failure.self) {
            try await GameplayPhotoExporter(library: library).save(url)
        }
        #expect(try Data(contentsOf: url) == Data([1,2,3]))
        #expect(await library.imports == [url])
    }

    actor DeferredLibrary: GameplayPhotoLibrary {
        var importedURL: URL?
        var completion: CheckedContinuation<Void, Never>?
        var saveReturned = false
        func requestAddAccess() -> Bool { true }
        func addMovie(at url: URL) async {
            importedURL = url
            await withCheckedContinuation { completion = $0 }
        }
        func finish() { completion?.resume(); completion = nil }
        func markReturned() { saveReturned = true }
        var awaitingImport: Bool { completion != nil }
    }
    @Test func successWaitsForPhotosCompletion() async throws {
        let library = DeferredLibrary()
        let url = URL(fileURLWithPath: "/unused/video.mp4")
        let task = Task {
            try await GameplayPhotoExporter(library: library).save(url)
            await library.markReturned()
        }
        for _ in 0..<100 where !(await library.awaitingImport) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await library.awaitingImport
        #expect(waiting)
        #expect(await library.saveReturned == false)
        await library.finish()
        try await task.value
        #expect(await library.saveReturned)
        #expect(await library.importedURL == url)
    }
}
