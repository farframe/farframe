import AccountsAndSecurity
import Foundation
import Testing
@testable import PlayStationRemotePlay

private let awayNow = Date(timeIntervalSince1970: 2_000_000_000)
private let awayAccount = Data(repeating: 7, count: 8).base64EncodedString()
private func awayRecord(_ token: String = "initial", expiresIn: TimeInterval = 30) throws -> PlayStationRemoteAuthorization {
    try .init(accountID: awayAccount, accessToken: token, refreshToken: "refresh-" + token,
              issuedAt: awayNow.addingTimeInterval(-30), expiresAt: awayNow.addingTimeInterval(expiresIn))
}
private final class AwayConsentFake: PlayStationAwayPlayConsentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    var isEnabled: Bool { lock.withLock { enabled } }
    func setEnabled(_ enabled: Bool) { lock.withLock { self.enabled = enabled } }
}
private actor AwayRefreshFake: PlayStationRemoteAuthorizationRefreshing {
    private(set) var calls = 0
    private var pending: CheckedContinuation<PlayStationRemoteAuthorization, any Error>?
    func refresh(_ authorization: PlayStationRemoteAuthorization) async throws -> PlayStationRemoteAuthorization {
        calls += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finish(_ record: PlayStationRemoteAuthorization) { pending?.resume(returning: record); pending = nil }
    func waitForCall() async {
        for _ in 0..<1_000 { if calls > 0 { return }; await Task.yield() }
        Issue.record("Refresh did not start")
    }
}
private actor AwayStorageFake: CredentialStore {
    private(set) var values: [CredentialKey: Data] = [:]
    private(set) var writes = 0
    var failDelete = false
    var pauseWrite = false
    private var writer: CheckedContinuation<Void, Never>?
    func value(for key: CredentialKey) -> Data? { values[key] }
    func set(_ value: Data, for key: CredentialKey) async {
        writes += 1
        if pauseWrite { await withCheckedContinuation { writer = $0 } }
        values[key] = value
    }
    func removeValue(for key: CredentialKey) throws {
        if failDelete { throw PlayStationAwayPlayError.secureStorageUnavailable }
        values[key] = nil
    }
    func setFailDelete(_ fail: Bool) { failDelete = fail }
    func setPauseWrite(_ pause: Bool) { pauseWrite = pause }
    func resumeWrite() { pauseWrite = false; writer?.resume(); writer = nil }
    func waitForWrite(_ count: Int) async {
        for _ in 0..<1_000 { if writes >= count { return }; await Task.yield() }
        Issue.record("Write did not start")
    }
}

@Test func awayConsentOffRestoresOffAndPreservesHomePairing() async throws {
    let storage = AwayStorageFake(), consent = AwayConsentFake(), refresh = AwayRefreshFake()
    let home = CredentialKey(providerID: "playstation-remote-play", accountID: "console", purpose: "registration")
    await storage.set(Data([1, 2, 3]), for: home)
    let vault = PlayStationRemoteCredentialStore(credentials: storage, consent: consent, refresher: refresh, now: { awayNow })
    try await vault.restore()
    #expect(await vault.status == .off)
    try await vault.enable(with: awayRecord(expiresIn: 3_600), expectedAccountID: awayAccount)
    #expect(consent.isEnabled)
    #expect(try await vault.validAuthorization(for: awayAccount).accessToken == "initial")
    try await vault.disable()
    #expect(!consent.isEnabled)
    #expect(await storage.value(for: home) == Data([1, 2, 3]))
    #expect(await storage.values.count == 1)
    await #expect(throws: PlayStationAwayPlayError.disabled) { try await vault.validAuthorization(for: awayAccount) }
}

@Test func awayRefreshCoalescesAndPersistsRotation() async throws {
    let storage = AwayStorageFake(), consent = AwayConsentFake(), refresh = AwayRefreshFake()
    let vault = PlayStationRemoteCredentialStore(credentials: storage, consent: consent, refresher: refresh, now: { awayNow })
    try await vault.enable(with: awayRecord(), expectedAccountID: awayAccount)
    let first = Task { try await vault.validAuthorization(for: awayAccount) }
    await refresh.waitForCall()
    let second = Task { try await vault.validAuthorization(for: awayAccount) }
    await refresh.finish(try awayRecord("rotated", expiresIn: 3_600))
    #expect(try await first.value.accessToken == "rotated")
    #expect(try await second.value.accessToken == "rotated")
    #expect(await refresh.calls == 1)
    let relaunched = PlayStationRemoteCredentialStore(credentials: storage, consent: consent, refresher: refresh, now: { awayNow })
    #expect(try await relaunched.validAuthorization(for: awayAccount).refreshToken == "refresh-rotated")
}

@Test func awayDisableRejectsLateUncooperativeRefresh() async throws {
    let storage = AwayStorageFake(), consent = AwayConsentFake(), refresh = AwayRefreshFake()
    let vault = PlayStationRemoteCredentialStore(credentials: storage, consent: consent, refresher: refresh, now: { awayNow })
    try await vault.enable(with: awayRecord(), expectedAccountID: awayAccount)
    let request = Task { try await vault.validAuthorization(for: awayAccount) }
    await refresh.waitForCall()
    try await vault.disable()
    await refresh.finish(try awayRecord("too-late", expiresIn: 3_600))
    await #expect(throws: PlayStationAwayPlayError.cancelled) { try await request.value }
    #expect(await storage.values.isEmpty)
    #expect(!consent.isEnabled)
    #expect(await vault.status == .off)
}

@Test func awayDisableWaitsForInFlightSaveThenDeletesIt() async throws {
    let storage = AwayStorageFake(), consent = AwayConsentFake(), refresh = AwayRefreshFake()
    let vault = PlayStationRemoteCredentialStore(credentials: storage, consent: consent, refresher: refresh, now: { awayNow })
    await storage.setPauseWrite(true)
    let enabling = Task { try await vault.enable(with: awayRecord(), expectedAccountID: awayAccount) }
    await storage.waitForWrite(1)
    let disabling = Task { try await vault.disable() }
    for _ in 0..<1_000 { if await vault.status == .cleanupRequired { break }; await Task.yield() }
    #expect(await vault.status == .cleanupRequired)
    await storage.resumeWrite()
    await #expect(throws: PlayStationAwayPlayError.cancelled) { try await enabling.value }
    try await disabling.value
    #expect(await storage.values.isEmpty)
    #expect(!consent.isEnabled)
}

@Test func awayFailedForgetStaysOffAcrossRelaunchAndCanRetry() async throws {
    let storage = AwayStorageFake(), consent = AwayConsentFake(), refresh = AwayRefreshFake()
    let vault = PlayStationRemoteCredentialStore(credentials: storage, consent: consent, refresher: refresh, now: { awayNow })
    try await vault.enable(with: awayRecord(), expectedAccountID: awayAccount)
    await storage.setFailDelete(true)
    await #expect(throws: PlayStationAwayPlayError.cleanupRequired) { try await vault.disable() }
    #expect(!consent.isEnabled)
    #expect(await vault.status == .cleanupRequired)
    let relaunched = PlayStationRemoteCredentialStore(credentials: storage, consent: consent, refresher: refresh, now: { awayNow })
    await #expect(throws: PlayStationAwayPlayError.cleanupRequired) { try await relaunched.restore() }
    await storage.setFailDelete(false)
    try await relaunched.disable()
    #expect(await storage.values.isEmpty)
    #expect(await relaunched.status == .off)
}

@Test func awayAccountMismatchAndMalformedTokensNeverPersist() async throws {
    let storage = AwayStorageFake(), consent = AwayConsentFake(), refresh = AwayRefreshFake()
    let vault = PlayStationRemoteCredentialStore(credentials: storage, consent: consent, refresher: refresh, now: { awayNow })
    await #expect(throws: PlayStationAwayPlayError.accountMismatch) {
        try await vault.enable(with: awayRecord(), expectedAccountID: "another-account")
    }
    #expect(throws: PlayStationAwayPlayError.invalidAuthorization) {
        try PlayStationRemoteAuthorization(accountID: awayAccount, accessToken: "bad\r\nHeader:payload", refreshToken: "refresh",
                                            issuedAt: awayNow, expiresAt: awayNow.addingTimeInterval(60))
    }
    let record = try awayRecord("sensitive-fixture")
    #expect(!String(reflecting: record).contains("sensitive-fixture"))
    #expect(Mirror(reflecting: record).children.isEmpty)
    #expect(await storage.values.isEmpty)
    #expect(!consent.isEnabled)
}
