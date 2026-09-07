import Foundation
import Observation
import PlayStationRemotePlay
import Security
import SwiftUI
import WebKit

// MARK: - Errors

public enum PlayStationWebSignInError: LocalizedError, Equatable, Sendable {
    case invalidAuthorizationURL
    case invalidRedirect
    case mismatchedRequest
    case authorizationFailed(String)
    case tokenExchangeFailed(Int)
    case accountLookupFailed(Int)
    case invalidAccountResponse
    case randomGenerationFailed
    case alreadyInProgress
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidAuthorizationURL:
            "Farframe could not open PlayStation sign-in."
        case .invalidRedirect:
            "PlayStation sign-in did not return an authorization code."
        case .mismatchedRequest:
            "The PlayStation sign-in response did not match this request. Start sign-in again."
        case let .authorizationFailed(message):
            message
        case let .tokenExchangeFailed(status):
            "PlayStation could not finish sign-in (HTTP \(status)). Try again in a few minutes, or enter your Account ID under Advanced."
        case let .accountLookupFailed(status):
            "PlayStation could not provide the Remote Play account value (HTTP \(status)). Try again later, or enter your Account ID under Advanced."
        case .invalidAccountResponse:
            "PlayStation returned account data in an unexpected format."
        case .randomGenerationFailed:
            "Farframe could not create a secure sign-in request."
        case .alreadyInProgress:
            "PlayStation sign-in is already open."
        case .cancelled:
            "PlayStation sign-in was cancelled."
        }
    }
}

// MARK: - Request / redirect model

public struct PlayStationWebSignInRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    let state: String
}

enum PlayStationWebSignInRedirectResult: Sendable {
    case code(String)
    case failure(String)
}

// MARK: - Service

/// Web sign-in against the PlayStation account service using the client
/// identity of Sony's own Remote Play application. Farframe is not the issuer
/// of that client identity; decision `D-038` records the accepted risk. The
/// flow yields only the eight-byte Remote Play Account ID. The authorization
/// code and access token live in memory for the duration of one exchange and
/// are never persisted, logged, or included in diagnostics.
enum PlayStationWebSignInService {
    private static let accountBase = "https://ca.account.sony.com"
    private static let authorizeEndpoint = "\(accountBase)/api/authz/v3/oauth/authorize"
    private static let tokenEndpoint = "\(accountBase)/api/authz/v3/oauth/token"
    private static let accountInfoEndpoint =
        "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token"
    private static let clientID = "ba495a24-818c-472b-b12d-ff231c1b5745"
    private static let clientSecret = "mvaiZkRsAsI1IBkY"
    static let redirectHost = "remoteplay.dl.playstation.net"
    static let redirectPath = "/remoteplay/redirect"
    private static let redirectURI = "https://\(redirectHost)\(redirectPath)"
    private static let scopes = [
        "psn:clientapp",
        "referenceDataService:countryConfig.read",
        "pushNotification:webSocket.desktop.connect",
        "sessionManager:remotePlaySession.system.update",
    ].joined(separator: " ")

    private struct TokenResponse: Decodable {
        let accessToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }

    static func authorizationRequest() throws -> PlayStationWebSignInRequest {
        guard var components = URLComponents(string: authorizeEndpoint) else {
            throw PlayStationWebSignInError.invalidAuthorizationURL
        }
        let state = try randomHex(byteCount: 32)
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "service_entity", value: "urn:service-entity:psn"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "duid", value: "0000000700410080" + (try randomHex(byteCount: 16))),
            URLQueryItem(name: "smcid", value: "remoteplay"),
            URLQueryItem(name: "layout_type", value: "popup"),
            URLQueryItem(name: "PlatformPrivacyWs1", value: "minimal"),
            URLQueryItem(name: "no_captcha", value: "true"),
            URLQueryItem(name: "cid", value: UUID().uuidString),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else {
            throw PlayStationWebSignInError.invalidAuthorizationURL
        }
        return PlayStationWebSignInRequest(id: UUID(), url: url, state: state)
    }

    static func redirectResult(
        from url: URL,
        expectedState: String
    ) throws -> PlayStationWebSignInRedirectResult? {
        guard url.scheme == "https",
              url.host == redirectHost,
              url.path == redirectPath,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let items = components.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == expectedState else {
            throw PlayStationWebSignInError.mismatchedRequest
        }
        if let code = items.first(where: { $0.name == "code" })?.value,
           code.isEmpty == false {
            return .code(code)
        }
        if let error = items.first(where: { $0.name == "error" })?.value {
            let detail = items.first(where: { $0.name == "error_description" })?.value
            return .failure((detail?.isEmpty == false) ? detail! : error)
        }
        throw PlayStationWebSignInError.invalidRedirect
    }

    static func accountIdentity(
        fromAuthorizationCode code: String
    ) async throws -> PlayStationRemotePlayAccountIdentity {
        let token = try await exchangeCodeForToken(code)
        return try await fetchAccountIdentity(accessToken: token)
    }

    private static func exchangeCodeForToken(_ code: String) async throws -> String {
        guard let url = URL(string: tokenEndpoint) else {
            throw PlayStationWebSignInError.invalidAuthorizationURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = formBody([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "scope": scopes,
        ])
        let (data, response) = try await transientSession().data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PlayStationWebSignInError.tokenExchangeFailed(
                (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data).accessToken
        guard token.isEmpty == false else {
            throw PlayStationWebSignInError.invalidAccountResponse
        }
        return token
    }

    private static func fetchAccountIdentity(
        accessToken: String
    ) async throws -> PlayStationRemotePlayAccountIdentity {
        guard let encodedToken = accessToken.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ), let url = URL(string: "\(accountInfoEndpoint)/\(encodedToken)") else {
            throw PlayStationWebSignInError.invalidAuthorizationURL
        }
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transientSession().data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PlayStationWebSignInError.accountLookupFailed(
                (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlayStationWebSignInError.invalidAccountResponse
        }
        let rawUserID: String?
        if let value = object["user_id"] as? String {
            rawUserID = value
        } else if let value = object["user_id"] as? NSNumber {
            rawUserID = value.stringValue
        } else {
            rawUserID = nil
        }
        guard let rawUserID, let userID = UInt64(rawUserID) else {
            throw PlayStationWebSignInError.invalidAccountResponse
        }
        return try Self.identity(userID: userID, onlineID: object["online_id"] as? String)
    }

    /// The Remote Play Account ID is the little-endian encoding of the PSN user ID.
    static func identity(
        userID: UInt64,
        onlineID: String?
    ) throws -> PlayStationRemotePlayAccountIdentity {
        var littleEndian = userID.littleEndian
        let bytes = withUnsafeBytes(of: &littleEndian) { Data($0) }
        let accountID = try PlayStationAccountID(bytes: bytes)
        return PlayStationRemotePlayAccountIdentity(accountID: accountID, displayName: onlineID)
    }

    private static func transientSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }

    private static func formBody(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    private static func randomHex(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PlayStationWebSignInError.randomGenerationFailed
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Acquirer

/// Shared `PlayStationAccountIdentityAcquiring` implementation for every shell.
///
/// `acquireAccountIdentity()` publishes an `activeRequest`; the shell root view
/// attaches `.playStationWebSignInSheet(_:)` which presents the web flow and
/// completes the pending continuation. Exactly one request is active at a time.
@MainActor
@Observable
public final class PlayStationWebAccountIdentityAcquirer: PlayStationAccountIdentityAcquiring {
    public let capability: PlayStationAccountIdentityAcquisitionCapability = .available

    public private(set) var activeRequest: PlayStationWebSignInRequest?
    private var continuation: CheckedContinuation<PlayStationRemotePlayAccountIdentity, any Error>?

    public init() {}

    public func acquireAccountIdentity() async throws -> PlayStationRemotePlayAccountIdentity {
        guard activeRequest == nil, continuation == nil else {
            throw PlayStationWebSignInError.alreadyInProgress
        }
        let request = try PlayStationWebSignInService.authorizationRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.activeRequest = request
            }
        } onCancel: {
            Task { @MainActor in
                self.finish(request.id, with: .failure(CancellationError()))
            }
        }
    }

    /// Called by the presentation when the flow ends for any reason.
    public func finish(
        _ requestID: UUID,
        with result: Result<PlayStationRemotePlayAccountIdentity, any Error>
    ) {
        guard activeRequest?.id == requestID, let continuation else { return }
        self.continuation = nil
        activeRequest = nil
        continuation.resume(with: result)
    }

    /// Dismissal without an explicit completion is a plain cancellation, which
    /// every shell already treats as "nothing to report".
    public func presentationDidDismiss(_ requestID: UUID) {
        finish(requestID, with: .failure(CancellationError()))
    }
}

// MARK: - Presentation

public extension View {
    /// Presents the shared PlayStation web sign-in whenever the acquirer has an
    /// active request. Attach once near the shell root.
    func playStationWebSignInSheet(_ acquirer: PlayStationWebAccountIdentityAcquirer) -> some View {
        modifier(PlayStationWebSignInSheetModifier(acquirer: acquirer))
    }
}

private struct PlayStationWebSignInSheetModifier: ViewModifier {
    let acquirer: PlayStationWebAccountIdentityAcquirer

    func body(content: Content) -> some View {
        content.sheet(
            item: Binding(
                get: { acquirer.activeRequest },
                set: { newValue in
                    if newValue == nil, let request = acquirer.activeRequest {
                        acquirer.presentationDidDismiss(request.id)
                    }
                }
            )
        ) { request in
            PlayStationWebSignInView(request: request) { result in
                acquirer.finish(request.id, with: result)
            }
            #if os(macOS) || os(visionOS)
            .frame(minWidth: 720, minHeight: 680)
            #endif
        }
    }
}

public struct PlayStationWebSignInView: View {
    @Environment(\.dismiss) private var dismiss

    private let request: PlayStationWebSignInRequest
    private let onComplete: (Result<PlayStationRemotePlayAccountIdentity, any Error>) -> Void

    @State private var isFinishing = false
    @State private var errorMessage: String?
    @State private var exchangeTask: Task<Void, Never>?
    @State private var completed = false

    public init(
        request: PlayStationWebSignInRequest,
        onComplete: @escaping (Result<PlayStationRemotePlayAccountIdentity, any Error>) -> Void
    ) {
        self.request = request
        self.onComplete = onComplete
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                PlayStationWebSignInWebView(request: request, onRedirect: handleRedirect)

                if isFinishing {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Finishing PlayStation sign-in…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("Continue with PlayStation")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancel()
                    }
                }
            }
        }
        .interactiveDismissDisabled(isFinishing)
        .onDisappear {
            exchangeTask?.cancel()
            exchangeTask = nil
        }
        .alert(
            "PlayStation Sign-In Failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if $0 == false { errorMessage = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                cancel()
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func cancel() {
        exchangeTask?.cancel()
        exchangeTask = nil
        complete(.failure(CancellationError()))
    }

    private func complete(_ result: Result<PlayStationRemotePlayAccountIdentity, any Error>) {
        guard completed == false else { return }
        completed = true
        onComplete(result)
        dismiss()
    }

    private func handleRedirect(_ result: Result<String, any Error>) {
        switch result {
        case let .success(code):
            finish(code: code)
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    private func finish(code: String) {
        guard isFinishing == false else { return }
        isFinishing = true
        exchangeTask = Task {
            do {
                let identity = try await PlayStationWebSignInService.accountIdentity(
                    fromAuthorizationCode: code
                )
                try Task.checkCancellation()
                isFinishing = false
                exchangeTask = nil
                complete(.success(identity))
            } catch is CancellationError {
                isFinishing = false
                exchangeTask = nil
            } catch {
                isFinishing = false
                exchangeTask = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Web view

#if canImport(UIKit)
private typealias PlayStationWebSignInRepresentable = UIViewRepresentable
#else
private typealias PlayStationWebSignInRepresentable = NSViewRepresentable
#endif

private struct PlayStationWebSignInWebView: PlayStationWebSignInRepresentable {
    let request: PlayStationWebSignInRequest
    let onRedirect: (Result<String, any Error>) -> Void

    private func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Non-persistent: no cookies, cache, or credentials survive the sheet.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData))
        return webView
    }

    #if canImport(UIKit)
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ webView: WKWebView, context: Context) {}
    #else
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ webView: WKWebView, context: Context) {}
    #endif

    func makeCoordinator() -> Coordinator {
        Coordinator(request: request, onRedirect: onRedirect)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let request: PlayStationWebSignInRequest
        private let onRedirect: (Result<String, any Error>) -> Void
        private var completed = false

        init(
            request: PlayStationWebSignInRequest,
            onRedirect: @escaping (Result<String, any Error>) -> Void
        ) {
            self.request = request
            self.onRedirect = onRedirect
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard completed == false, let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            do {
                guard let result = try PlayStationWebSignInService.redirectResult(
                    from: url,
                    expectedState: request.state
                ) else {
                    decisionHandler(.allow)
                    return
                }
                completed = true
                decisionHandler(.cancel)
                switch result {
                case let .code(code):
                    onRedirect(.success(code))
                case let .failure(message):
                    onRedirect(.failure(PlayStationWebSignInError.authorizationFailed(message)))
                }
            } catch {
                completed = true
                decisionHandler(.cancel)
                onRedirect(.failure(error))
            }
        }
    }
}
