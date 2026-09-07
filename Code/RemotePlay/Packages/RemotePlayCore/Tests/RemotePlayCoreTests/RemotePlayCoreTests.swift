import AccountsAndSecurity
import ChiakiNative
import ExperienceDomain
import Foundation
import InputCore
import PlayStationRemotePlay
import StreamingCore
import Testing

@Test
func controllerSlotsCoverThePlannedAppleEcosystem() {
    #expect(ControllerPairingSlot.allCases.map(\.rawValue) == [1, 2, 3, 4])
    #expect(ControllerPairingSlot.vision.recommendedOwner == "Vision Pro")
    #expect(ControllerPairingSlot.mobile.recommendedOwner == "iPhone and iPad")
    #expect(ControllerPairingSlot.mac.recommendedOwner == "Mac")
}

@Test
func providerRegistryRejectsDuplicateProviderIDs() async throws {
    let registry = StreamingProviderRegistry()
    let provider = PlayStationRemotePlayProvider()
    try await registry.register(provider)

    await #expect(throws: StreamingCoreError.duplicateProvider("playstation.remote-play")) {
        try await registry.register(provider)
    }
}

@Test
func nativeRuntimeUsesTheOpaqueVerifiedLayout() {
    let info = ChiakiNativeRuntime.info

    #expect(info.abiVersion == 7)
    #expect(info.hasValidSessionLayout)
    #expect(info.supportsPlayStation5Wake)
    #expect(info.supportsPlayStation5Connect)
    #expect(info.supportsMediaCallbacks)
    #expect(info.supportsPlayStation5Registration)
    #expect(info.capabilityMask & UInt32(RP_CHIAKI_CAPABILITY_CONTROLLER_INPUT) != 0)
    #expect(info.capabilityMask & UInt32(RP_CHIAKI_CAPABILITY_REST_PS5) != 0)
    #expect(info.capabilityMask & UInt32(RP_CHIAKI_CAPABILITY_GO_HOME) != 0)
    #expect(info.capabilityMask & UInt32(RP_CHIAKI_CAPABILITY_CONTROLLER_FEEDBACK) != 0)
    #expect(ChiakiNativeRuntime.allocationMatchesRuntime())
}

@Test
func inMemoryCredentialStoreRoundTripsWithoutPersistence() async throws {
    let store = InMemoryCredentialStore()
    let key = CredentialKey(providerID: "test", accountID: "local", purpose: "registration")
    let secret = Data([0x01, 0x02, 0x03])

    await store.set(secret, for: key)
    #expect(await store.value(for: key) == secret)
    await store.removeValue(for: key)
    #expect(await store.value(for: key) == nil)
}
