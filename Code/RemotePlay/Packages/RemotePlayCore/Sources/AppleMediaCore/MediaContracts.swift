import ExperienceDomain
import Foundation
import StreamingCore

public struct DecodedVideoFrameDescriptor: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let presentationTimestamp: Duration

    public init(width: Int, height: Int, presentationTimestamp: Duration) {
        self.width = width
        self.height = height
        self.presentationTimestamp = presentationTimestamp
    }
}

public struct PCMBlockDescriptor: Equatable, Sendable {
    public let sampleRate: Double
    public let channelCount: Int
    public let frameCount: Int

    public init(sampleRate: Double, channelCount: Int, frameCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
    }
}

public protocol VideoPresentationSink: Sendable {
    func present(_ frame: DecodedVideoFrameDescriptor) async
    func flush() async
}

public protocol AudioPresentationSink: Sendable {
    func schedule(_ block: PCMBlockDescriptor) async
    func reset() async
}
