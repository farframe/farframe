import AppleMediaCore
import PlayStationRemotePlay
import Testing

@Test
func playStationSessionPublishesProviderNeutralVideoSurfaceCapability() {
    requireVideoSurfaceCapability(PlayStationRemotePlayStreamingSession.self)
}

private func requireVideoSurfaceCapability<Session: SampleBufferVideoSurfaceSession>(
    _ sessionType: Session.Type
) {
    _ = sessionType
}
