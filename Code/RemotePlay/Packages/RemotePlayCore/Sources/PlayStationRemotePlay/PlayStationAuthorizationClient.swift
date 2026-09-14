import Foundation
import CoreFoundation

/// Extractable provider client configuration is supplied by the existing
/// sign-in integration. It is not a Farframe-owned confidential client secret.
public struct PlayStationAuthorizationClientConfiguration: Sendable, CustomStringConvertible, CustomReflectable {
    let clientID: String
    let clientSecret: String
    let tokenEndpoint: URL
    let accountEndpoint: URL
    let redirectURI: URL
    let scopes: String
    /// Build-time provider configuration; never constructed from user input or
    /// a server redirect. The composition root owns the approved endpoint set.
    public init(clientID: String, clientSecret: String, tokenEndpoint: URL, accountEndpoint: URL, redirectURI: URL, scopes: String) {
        self.clientID = clientID; self.clientSecret = clientSecret
        self.tokenEndpoint = tokenEndpoint; self.accountEndpoint = accountEndpoint
        self.redirectURI = redirectURI; self.scopes = scopes
    }
    public var description: String { "PlayStationAuthorizationClientConfiguration(redacted)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct PlayStationAuthorizationResult: Sendable, CustomStringConvertible, CustomReflectable {
    public let identity: PlayStationRemotePlayAccountIdentity
    public let remoteAuthorization: PlayStationRemoteAuthorization?
    public var description: String { "PlayStationAuthorizationResult(redacted)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum PlayStationAuthorizationClientError: Error, LocalizedError, Equatable, Sendable {
    case network, invalidResponse, denied(Int), cancelled
    public var errorDescription: String? {
        switch self {
        case .network: "PlayStation sign-in could not finish. Check your connection and try again."
        case .invalidResponse: "PlayStation returned an unusable sign-in response."
        case .denied(let status): "PlayStation sign-in could not finish (HTTP \(status)). Try again."
        case .cancelled: "PlayStation sign-in was cancelled."
        }
    }
}

package protocol PlayStationAuthorizationHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Foundation retains normal system trust validation. Never accept a server
/// trust challenge manually, persist cookies/cache, or follow a token redirect.
private final class PlayStationAuthorizationTransport: NSObject, PlayStationAuthorizationHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // Bound the body while receiving, before parsing or allocating an
        // attacker-controlled response in full. No token URL escapes this seam.
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlayStationAuthorizationClientError.invalidResponse }
        guard response.expectedContentLength <= 1_048_576 else { throw PlayStationAuthorizationClientError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw PlayStationAuthorizationClientError.invalidResponse }
            data.append(byte)
        }
        return (data, http)
    }
}

/// Shared code exchange and renewal. Home-only sign-in never requires or
/// retains a refresh token. Away opt-in consumes the same code exchange once.
public struct PlayStationAuthorizationClient: PlayStationRemoteAuthorizationRefreshing, Sendable {
    private let configuration: PlayStationAuthorizationClientConfiguration
    private let transport: any PlayStationAuthorizationHTTPTransport
    private let now: @Sendable () -> Date

    public init(configuration: PlayStationAuthorizationClientConfiguration) {
        self.configuration = configuration
        self.transport = PlayStationAuthorizationTransport()
        self.now = { Date() }
    }
    package init(configuration: PlayStationAuthorizationClientConfiguration,
                 transport: any PlayStationAuthorizationHTTPTransport, now: @escaping @Sendable () -> Date) {
        self.configuration = configuration; self.transport = transport; self.now = now
    }

    public func signIn(code: String, enableAwayPlay: Bool) async throws -> PlayStationAuthorizationResult {
        guard !code.isEmpty, code.utf8.count <= 16_384 else { throw PlayStationAuthorizationClientError.invalidResponse }
        let issuedAt = now()
        let token = try await exchange(["grant_type": "authorization_code", "code": code, "redirect_uri": configuration.redirectURI.absoluteString])
        let identity = try await lookup(token.accessToken)
        let authorization = try enableAwayPlay ? record(token, identity: identity, issuedAt: issuedAt) : nil
        return .init(identity: identity, remoteAuthorization: authorization)
    }

    public func refresh(_ authorization: PlayStationRemoteAuthorization) async throws -> PlayStationRemoteAuthorization {
        try authorization.validate()
        let issuedAt = now()
        let token = try await exchange(["grant_type": "refresh_token", "refresh_token": authorization.refreshToken])
        // Verify identity again; refresh cannot change the paired account.
        let identity = try await lookup(token.accessToken)
        let refreshed = try record(token, identity: identity, issuedAt: issuedAt)
        guard refreshed.accountID == authorization.accountID else { throw PlayStationAwayPlayError.accountMismatch }
        return refreshed
    }

    private struct Token: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?
        let tokenType: String?
        enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", tokenType = "token_type" }
    }

    private func exchange(_ fields: [String: String]) async throws -> Token {
        var fields = fields
        fields["client_id"] = configuration.clientID
        fields["client_secret"] = configuration.clientSecret
        fields["scope"] = configuration.scopes
        var request = URLRequest(url: configuration.tokenEndpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields)
        let data = try await send(request)
        guard let token = try? JSONDecoder().decode(Token.self, from: data),
              token.tokenType == nil || token.tokenType?.lowercased() == "bearer",
              !token.accessToken.isEmpty, token.accessToken.utf8.count <= 16_384,
              token.accessToken.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw PlayStationAuthorizationClientError.invalidResponse
        }
        return token
    }

    private func lookup(_ accessToken: String) async throws -> PlayStationRemotePlayAccountIdentity {
        // This provider endpoint requires the token as a single path segment.
        // Escaping '/', '?', '#' and '%' prevents it from changing the route.
        let segment = Self.escape(accessToken)
        guard let url = URL(string: configuration.accountEndpoint.absoluteString + "/" + segment) else { throw PlayStationAuthorizationClientError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Basic " + Data("\(configuration.clientID):\(configuration.clientSecret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await send(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PlayStationAuthorizationClientError.invalidResponse }
        let numericID = object["user_id"] as? NSNumber
        if let numericID, CFGetTypeID(numericID) == CFBooleanGetTypeID() { throw PlayStationAuthorizationClientError.invalidResponse }
        let rawID = (object["user_id"] as? String) ?? numericID?.stringValue
        guard let rawID, let userID = UInt64(rawID) else { throw PlayStationAuthorizationClientError.invalidResponse }
        var littleEndian = userID.littleEndian
        let bytes = withUnsafeBytes(of: &littleEndian) { Data($0) }
        return try .init(accountID: PlayStationAccountID(bytes: bytes), displayName: object["online_id"] as? String)
    }

    private func record(_ token: Token, identity: PlayStationRemotePlayAccountIdentity, issuedAt: Date) throws -> PlayStationRemoteAuthorization {
        guard let refresh = token.refreshToken, let expiry = token.expiresIn, expiry.isFinite, expiry > 0,
              now().timeIntervalSince(issuedAt) < expiry else { throw PlayStationAuthorizationClientError.invalidResponse }
        return try .init(accountID: identity.accountID.bytes.base64EncodedString(), accessToken: token.accessToken,
                         refreshToken: refresh, issuedAt: issuedAt, expiresAt: issuedAt.addingTimeInterval(expiry))
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
                  url.fragment == nil, url.query == nil else { throw PlayStationAuthorizationClientError.invalidResponse }
            let (data, response) = try await transport.send(request)
            try Task.checkCancellation()
            guard response.url == request.url else { throw PlayStationAuthorizationClientError.invalidResponse }
            guard (200...299).contains(response.statusCode) else { throw PlayStationAuthorizationClientError.denied(response.statusCode) }
            guard data.count <= 1_048_576 else { throw PlayStationAuthorizationClientError.invalidResponse }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let safe as PlayStationAuthorizationClientError { throw safe }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw PlayStationAuthorizationClientError.network
        }
    }

    package static func formBody(_ fields: [String: String]) -> Data {
        Data(fields.sorted { $0.key < $1.key }.map { escape($0.key) + "=" + escape($0.value) }.joined(separator: "&").utf8)
    }
    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
    }
}
