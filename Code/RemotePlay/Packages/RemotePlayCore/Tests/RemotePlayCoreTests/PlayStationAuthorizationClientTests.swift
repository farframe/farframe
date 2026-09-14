import Foundation
import Testing
@testable import PlayStationRemotePlay

private actor AuthorizationHTTPFake: PlayStationAuthorizationHTTPTransport {
    enum Reply: Sendable { case body(String, Int), redirect, networkFailure, oversized }
    var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw PlayStationAuthorizationClientError.invalidResponse }
        switch replies.removeFirst() {
        case .body(let body, let status):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case .redirect:
            return (Data(), HTTPURLResponse(url: URL(string: "https://example.invalid/secret")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        case .networkFailure:
            throw NSError(domain: "contains-sensitive-fixture", code: -1, userInfo: [NSLocalizedDescriptionKey: "token=secret-fixture"])
        case .oversized:
            return (Data(repeating: 65, count: 1_048_577), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}
private func authClient(_ http: AuthorizationHTTPFake) -> PlayStationAuthorizationClient {
    .init(configuration: .init(clientID: "fixture", clientSecret: "fixture",
                               tokenEndpoint: URL(string: "https://accounts.example.invalid/token")!,
                               accountEndpoint: URL(string: "https://accounts.example.invalid/identity")!,
                               redirectURI: URL(string: "https://callback.example.invalid/redirect")!, scopes: "fixture"), transport: http,
          now: { Date(timeIntervalSince1970: 2_000_000_000) })
}

@Test func authorizationHomeLookupDoesNotRequireOrKeepRenewableCredentials() async throws {
    let http = AuthorizationHTTPFake([.body("{\"access_token\":\"fixture\"}", 200), .body("{\"user_id\":\"42\"}", 200)])
    let result = try await authClient(http).signIn(code: "fixture+code&", enableAwayPlay: false)
    #expect(result.remoteAuthorization == nil)
    #expect(result.identity.accountID.bytes == Data([42,0,0,0,0,0,0,0]))
    let requests = await http.requests
    #expect(requests.count == 2)
    #expect(String(data: requests[0].httpBody!, encoding: .utf8)!.contains("code=fixture%2Bcode%26"))
}

@Test func authorizationOneCodeExchangeYieldsIdentityAndAwayBundle() async throws {
    let http = AuthorizationHTTPFake([.body("{\"access_token\":\"a/b?c#d%\",\"refresh_token\":\"renew\",\"expires_in\":3600,\"token_type\":\"bearer\"}", 200), .body("{\"user_id\":\"42\",\"online_id\":\"Fixture\"}", 200)])
    let result = try await authClient(http).signIn(code: "one-code", enableAwayPlay: true)
    #expect(result.remoteAuthorization?.accountID == result.identity.accountID.bytes.base64EncodedString())
    #expect(result.remoteAuthorization?.refreshToken == "renew")
    let requests = await http.requests
    #expect(requests.count == 2)
    #expect(requests[1].url!.absoluteString.hasSuffix("a%2Fb%3Fc%23d%25"))
    #expect(!String(reflecting: result).contains("renew"))
}

@Test func authorizationRemoteRequiresUsableExpiryAndRefresh() async throws {
    let http = AuthorizationHTTPFake([.body("{\"access_token\":\"fixture\",\"expires_in\":0}", 200), .body("{\"user_id\":\"42\"}", 200)])
    await #expect(throws: PlayStationAuthorizationClientError.invalidResponse) {
        try await authClient(http).signIn(code: "one-code", enableAwayPlay: true)
    }
}

@Test func authorizationRefreshRejectsDifferentAccount() async throws {
    let http = AuthorizationHTTPFake([.body("{\"access_token\":\"rotated\",\"refresh_token\":\"new-renew\",\"expires_in\":3600}", 200), .body("{\"user_id\":\"43\"}", 200)])
    let record = try PlayStationRemoteAuthorization(accountID: Data([42,0,0,0,0,0,0,0]).base64EncodedString(), accessToken: "old", refreshToken: "old-renew", issuedAt: Date(timeIntervalSince1970: 1_999_999_900), expiresAt: Date(timeIntervalSince1970: 2_000_000_001))
    await #expect(throws: PlayStationAwayPlayError.accountMismatch) { try await authClient(http).refresh(record) }
}

@Test(arguments: [AuthorizationHTTPFake.Reply.redirect, .oversized])
private func authorizationRejectsEndpointChangesAndOversizedBodies(reply: AuthorizationHTTPFake.Reply) async {
    let http = AuthorizationHTTPFake([reply])
    await #expect(throws: PlayStationAuthorizationClientError.invalidResponse) {
        try await authClient(http).signIn(code: "code", enableAwayPlay: true)
    }
}

@Test func authorizationNetworkErrorsAndProviderBodiesStayRedacted() async {
    let http = AuthorizationHTTPFake([.networkFailure])
    await #expect(throws: PlayStationAuthorizationClientError.network) {
        try await authClient(http).signIn(code: "code", enableAwayPlay: true)
    }
    let denied = AuthorizationHTTPFake([.body("sensitive-provider-response", 401)])
    await #expect(throws: PlayStationAuthorizationClientError.denied(401)) {
        try await authClient(denied).signIn(code: "code", enableAwayPlay: true)
    }
}
