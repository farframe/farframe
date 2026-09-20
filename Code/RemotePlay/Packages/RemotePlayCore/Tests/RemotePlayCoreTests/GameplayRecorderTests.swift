import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import AppleMediaCore
import StreamingCore

@Suite(.serialized)
struct GameplayRecorderTests {
    private func format() throws -> StreamingAudioFormat {
        try StreamingAudioFormat(channelCount: 2, bitsPerSample: 16, sampleRate: 48_000, frameSize: 480)
    }
    private func output() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FarframeRecorderTests-\(UUID())/clip.mp4")
    }
    private func frame(_ time: Double) throws -> DecodedVideoFrame {
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 128, 72, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess)
        let buffer = try #require(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<72 { for x in 0..<128 {
            let i = y * stride + x * 4
            bytes[i] = 25; bytes[i+1] = 90; bytes[i+2] = 220; bytes[i+3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return DecodedVideoFrame(generation: 1, pixelBuffer: buffer,
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 1_000_000),
            duration: CMTime(value: 1, timescale: 60))
    }
    private func audio(_ time: Double) throws -> InterleavedS16PCMBlock {
        var pcm = [Int16](repeating: 0, count: 960)
        for n in 0..<480 {
            let value = Int16(sin(Double(n) / 48_000 * 440 * 2 * .pi) * 3_000)
            pcm[n*2] = value; pcm[n*2+1] = value
        }
        return try InterleavedS16PCMBlock(data: pcm.withUnsafeBytes { Data($0) }, frameCount: 480,
            channelCount: 2, sampleRate: 48_000,
            receivedUptimeNanoseconds: UInt64((time + 0.01) * 1_000_000_000))
    }

    @Test func recordingWritesPlayableVideoAndGameAudio() async throws {
        let recorder = GameplayRecorder(); recorder.configureAudio(try format())
        let url = output(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try recorder.start(to: url)
        recorder.submitVideo(try frame(100))
        // The first hardware encoder setup may be slow on a cold test host.
        // Wait for startup, then feed a real-time stream instead of treating a
        // startup burst as 1.8 seconds of sustained recording.
        for _ in 0..<300 where recorder.snapshot().videoFrames == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(recorder.snapshot().videoFrames == 1)
        for n in 1..<180 {
            let t = 100.0 + Double(n) / 100
            if n.isMultiple(of: 3) { recorder.submitVideo(try frame(t)) }
            recorder.submitAudio(try audio(t))
            try await Task.sleep(for: .milliseconds(10))
        }
        async let first = recorder.stop()
        async let second = recorder.stop()
        let (a,b) = await (first,second)
        #expect(a.phase == .saved, "\(String(describing: a.message))")
        #expect(b.phase == .saved)
        #expect(a.videoFrames > 10); #expect(a.audioFrames > 1_000)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("partial").path))
        let asset = AVURLAsset(url: url)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 1 && duration.seconds < 2.5)
        // Decode each track, rather than trusting that a file/header exists.
        let reader = try AVAssetReader(asset: asset)
        let pictureOutput = AVAssetReaderTrackOutput(track: video,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let soundOutput = AVAssetReaderTrackOutput(track: audio,
            outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(pictureOutput); reader.add(soundOutput)
        #expect(reader.startReading())
        #expect(pictureOutput.copyNextSampleBuffer() != nil)
        #expect(soundOutput.copyNextSampleBuffer() != nil)
        reader.cancelReading()
        #expect(await recorder.stop() == a)
    }

    @Test func recordedAudioResumesAtTheVideoTimeAfterAnInterruption() async throws {
        let recorder = GameplayRecorder(); recorder.configureAudio(try format())
        let url = output(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try recorder.start(to: url)
        recorder.submitVideo(try frame(100))
        for _ in 0..<300 where recorder.snapshot().videoFrames == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(recorder.snapshot().videoFrames == 1)
        for offset in [0.0, 2.7] {
            for n in 0..<20 {
                let t = 100 + offset + Double(n) / 100
                if n.isMultiple(of: 4) { recorder.submitVideo(try frame(t)) }
                recorder.submitAudio(try audio(t))
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let result = await recorder.stop()
        #expect(result.phase == .saved)
        let asset = AVURLAsset(url: url)
        let audioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        reader.add(output); #expect(reader.startReading())
        var lastTime = 0.0
        while let sample = output.copyNextSampleBuffer() {
            lastTime = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        }
        #expect(reader.status == .completed)
        #expect(lastTime > 2.7 && lastTime < 3.1, "Last encoded audio timestamp: \(lastTime)")

    }

    @Test func stopBeforeFirstFrameIsSafeAndCanRestart() async throws {
        let recorder = GameplayRecorder(); recorder.configureAudio(try format())
        let url = output(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try recorder.start(to: url)
        let stopped = await recorder.stop()
        #expect(stopped.phase == .failed)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try recorder.start(to: url)
        #expect(recorder.snapshot().phase == .starting)
        #expect(await recorder.stop().phase == .failed)
    }

    @Test func protectedContentAndExistingFilesAreRejected() async throws {
        let recorder = GameplayRecorder(); recorder.configureAudio(try format())
        let url = output(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        recorder.setContentBlocked(true)
        #expect(throws: (any Error).self) { try recorder.start(to: url) }
        recorder.setContentBlocked(false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data("preserve".utf8); try data.write(to: url)
        #expect(throws: (any Error).self) { try recorder.start(to: url) }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func contentRestrictionStopsAdmissionDuringRecording() async throws {
        let recorder = GameplayRecorder(); recorder.configureAudio(try format())
        let url = output(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try recorder.start(to: url)
        recorder.setContentBlocked(true)
        recorder.submitVideo(try frame(100))
        recorder.submitAudio(try audio(100))
        let result = await recorder.stop()
        #expect(result.videoFrames == 0 && result.audioFrames == 0)
        #expect(result.phase == .failed)
        #expect(throws: (any Error).self) { try recorder.start(to: url) }
        recorder.setContentBlocked(false)
        try recorder.start(to: url)
        #expect(await recorder.stop().phase == .failed)
    }

    @Test func admissionIsBoundedUnderVideoBurst() async throws {
        let recorder = GameplayRecorder(); recorder.configureAudio(try format())
        let url = output(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try recorder.start(to: url)
        let picture = try frame(100)
        for _ in 0..<10_000 { recorder.submitVideo(picture) }
        #expect(recorder.snapshot().droppedVideoFrames > 0)
        // Missing audio must not be described as a complete saved recording.
        let stopped = await recorder.stop()
        #expect(stopped.phase == .failed)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("partial").path))
    }
}
