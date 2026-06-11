import AuthenticationServices
import CryptoKit
import Foundation
import OSLog

nonisolated struct FleetOAuthConfiguration: Sendable {
    var authorizationURL: URL
    var callbackURLScheme: String
    var clientID: String
    var redirectURI: URL
    var scopes: [String]
    var tokenURL: URL

    static var production: FleetOAuthConfiguration {
        FleetOAuthConfiguration(
            authorizationURL: oauthURL("https://auth.maxweinbach.com/api/auth/oauth2/authorize"),
            callbackURLScheme: "teslasiri",
            clientID: "teslasiri-ios",
            redirectURI: oauthURL("teslasiri://oauth/callback"),
            scopes: [
                "openid",
                "profile",
                "email",
                "offline_access",
                "vehicles:read",
                "telemetry:read",
                "charging:read",
                "drives:read",
                "stream:read",
                "vehicles:control",
                "notifications:write",
                "webhooks:write"
            ],
            tokenURL: oauthURL("https://auth.maxweinbach.com/api/auth/oauth2/token")
        )
    }

    private static func oauthURL(_ value: String) -> URL {
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid OAuth URL: \(value)")
        }
        return url
    }
}

nonisolated struct FleetOAuthFlow: Sendable {
    var authorizationURL: URL
    var codeVerifier: String
    var state: String
}

nonisolated struct FleetOAuthTokenSet: Codable, Equatable, Sendable {
    var accessToken: String
    var expiresAt: Date?
    var idToken: String?
    var refreshToken: String?
    var scope: String?
    var tokenType: String

    var inspection: FleetOAuthTokenInspection {
        FleetOAuthTokenInspection(accessToken: accessToken, tokenType: tokenType, responseScope: scope)
    }

    init(response: FleetOAuthTokenResponse, receivedAt: Date = Date()) {
        accessToken = response.accessToken
        expiresAt = response.expiresIn.map { receivedAt.addingTimeInterval(TimeInterval($0)) }
        idToken = response.idToken
        refreshToken = response.refreshToken
        scope = response.scope
        tokenType = response.tokenType
    }
}

nonisolated struct FleetOAuthTokenInspection: Equatable, Sendable {
    var audience: [String]
    var format: String
    var issuer: String?
    var scopes: [String]

    init(accessToken: String, tokenType: String, responseScope: String?) {
        audience = []
        format = "\(tokenType.capitalized) opaque access token"
        issuer = nil
        scopes = Self.scopes(from: responseScope)

        let segments = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard
            segments.count >= 2,
            let payloadData = Data(base64URLEncoded: String(segments[1])),
            let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            return
        }

        audience = Self.stringArray(from: payload["aud"])
        format = "\(tokenType.capitalized) JWT"
        issuer = payload["iss"] as? String

        let tokenScopes = Self.stringArray(from: payload["scp"]) + Self.scopes(from: payload["scope"] as? String)
        if !tokenScopes.isEmpty {
            scopes = Array(Set(tokenScopes)).sorted()
        }
    }

    private static func scopes(from value: String?) -> [String] {
        value?.split(separator: " ").map(String.init).sorted() ?? []
    }

    private static func stringArray(from value: Any?) -> [String] {
        if let string = value as? String {
            return [string]
        }
        return (value as? [String]) ?? []
    }
}

nonisolated struct FleetOAuthTokenResponse: Decodable, Equatable, Sendable {
    var accessToken: String
    var expiresIn: Int?
    var idToken: String?
    var refreshToken: String?
    var scope: String?
    var tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case scope
        case tokenType = "token_type"
    }
}

nonisolated struct FleetOAuthErrorResponse: Decodable, Equatable, Sendable {
    var error: String
    var errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

enum FleetOAuthError: Error, LocalizedError {
    case callbackMissingCode
    case invalidCallbackState
    case invalidCallbackURL
    case invalidAuthorizationURL
    case invalidTokenResponse(statusCode: Int, message: String?)
    case randomBytesFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .callbackMissingCode:
            return "The authorization callback did not include a code."
        case .invalidCallbackState:
            return "The authorization callback state did not match this sign-in request."
        case .invalidCallbackURL:
            return "The authorization callback URL did not match this sign-in request."
        case .invalidAuthorizationURL:
            return "The authorization URL could not be built."
        case .invalidTokenResponse(let statusCode, let message):
            if let message {
                return "Token exchange failed with HTTP \(statusCode): \(message)"
            }
            return "Token exchange failed with HTTP \(statusCode)."
        case .randomBytesFailed(let status):
            return "Could not generate secure OAuth state. Status: \(status)."
        }
    }
}

nonisolated struct FleetOAuthClient: Sendable {
    private static let logger = Logger(subsystem: "com.maxweinbach.TeslaSiri", category: "FleetOAuth")

    private let configuration: FleetOAuthConfiguration
    private let session: URLSession

    init(configuration: FleetOAuthConfiguration = .production, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    var callbackURLScheme: String {
        configuration.callbackURLScheme
    }

    func makeAuthorizationFlow() throws -> FleetOAuthFlow {
        let state = try Self.randomBase64URLString(byteCount: 32)
        let codeVerifier = try Self.randomBase64URLString(byteCount: 64)
        let codeChallenge = Self.codeChallenge(for: codeVerifier)

        var components = URLComponents(url: configuration.authorizationURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let url = components?.url else {
            Self.logger.error("OAuth authorization URL could not be built for client \(configuration.clientID, privacy: .public)")
            throw FleetOAuthError.invalidAuthorizationURL
        }

        Self.logger.info("OAuth authorization flow created for client \(configuration.clientID, privacy: .public)")
        return FleetOAuthFlow(authorizationURL: url, codeVerifier: codeVerifier, state: state)
    }

    func exchangeCode(from callbackURL: URL, flow: FleetOAuthFlow) async throws -> FleetOAuthTokenSet {
        guard isExpectedCallbackURL(callbackURL) else {
            throw FleetOAuthError.invalidCallbackURL
        }

        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let state = queryItems.first { $0.name == "state" }?.value
        guard state == flow.state else {
            throw FleetOAuthError.invalidCallbackState
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw FleetOAuthError.callbackMissingCode
        }

        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formURLEncodedData([
            "grant_type": "authorization_code",
            "client_id": configuration.clientID,
            "code": code,
            "redirect_uri": configuration.redirectURI.absoluteString,
            "code_verifier": flow.codeVerifier
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.error("OAuth token exchange transport failed for client \(configuration.clientID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw FleetAPIError.transport(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            Self.logger.error("OAuth token exchange returned a non-HTTP response for client \(configuration.clientID, privacy: .public)")
            throw FleetAPIError.transport(URLError(.badServerResponse))
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorResponse = try? JSONDecoder().decode(FleetOAuthErrorResponse.self, from: data)
            let responseText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackMessage = responseText.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
            let message = errorResponse?.errorDescription ?? errorResponse?.error ?? fallbackMessage
            let loggedMessage = message ?? "none"
            Self.logger.warning("OAuth token exchange failed for client \(configuration.clientID, privacy: .public) status \(httpResponse.statusCode, privacy: .public) error \(loggedMessage, privacy: .public)")
            throw FleetOAuthError.invalidTokenResponse(statusCode: httpResponse.statusCode, message: message)
        }

        let tokenResponse = try JSONDecoder().decode(FleetOAuthTokenResponse.self, from: data)
        Self.logger.info("OAuth token exchange completed for client \(configuration.clientID, privacy: .public)")
        return FleetOAuthTokenSet(response: tokenResponse)
    }

    func refreshToken(_ refreshToken: String) async throws -> FleetOAuthTokenSet {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formURLEncodedData([
            "grant_type": "refresh_token",
            "client_id": configuration.clientID,
            "refresh_token": refreshToken
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.error("OAuth token refresh transport failed for client \(configuration.clientID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw FleetAPIError.transport(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            Self.logger.error("OAuth token refresh returned a non-HTTP response for client \(configuration.clientID, privacy: .public)")
            throw FleetAPIError.transport(URLError(.badServerResponse))
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorResponse = try? JSONDecoder().decode(FleetOAuthErrorResponse.self, from: data)
            let responseText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackMessage = responseText.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
            let message = errorResponse?.errorDescription ?? errorResponse?.error ?? fallbackMessage
            let loggedMessage = message ?? "none"
            Self.logger.warning("OAuth token refresh failed for client \(configuration.clientID, privacy: .public) status \(httpResponse.statusCode, privacy: .public) error \(loggedMessage, privacy: .public)")
            throw FleetOAuthError.invalidTokenResponse(statusCode: httpResponse.statusCode, message: message)
        }

        let tokenResponse = try JSONDecoder().decode(FleetOAuthTokenResponse.self, from: data)
        var tokenSet = FleetOAuthTokenSet(response: tokenResponse)
        if tokenSet.refreshToken == nil {
            tokenSet.refreshToken = refreshToken
        }
        Self.logger.info("OAuth token refresh completed for client \(configuration.clientID, privacy: .public)")
        return tokenSet
    }

    private func isExpectedCallbackURL(_ callbackURL: URL) -> Bool {
        callbackURL.scheme == configuration.redirectURI.scheme
            && callbackURL.host == configuration.redirectURI.host
            && callbackURL.path == configuration.redirectURI.path
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func randomBase64URLString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw FleetOAuthError.randomBytesFailed(status)
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func formURLEncodedData(_ values: [String: String]) -> Data {
        let body = values
            .map { key, value in
                "\(key.formURLEncoded)=\(value.formURLEncoded)"
            }
            .sorted()
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

actor FleetOAuthAccessTokenProvider: FleetAccessTokenRefreshing {
    private let oauthClient: FleetOAuthClient
    private let refreshLeeway: TimeInterval
    private let tokenStore: FleetOAuthTokenKeychain
    private var refreshTask: Task<String, Error>?

    init(
        oauthClient: FleetOAuthClient = FleetOAuthClient(),
        refreshLeeway: TimeInterval = 120,
        tokenStore: FleetOAuthTokenKeychain = FleetOAuthTokenKeychain()
    ) {
        self.oauthClient = oauthClient
        self.refreshLeeway = refreshLeeway
        self.tokenStore = tokenStore
    }

    func accessToken() async throws -> String {
        guard let tokenSet = try tokenStore.loadTokenSet() else {
            throw FleetAPIError.missingAccessToken
        }

        guard shouldRefresh(tokenSet) else {
            return tokenSet.accessToken
        }

        guard let refreshToken = tokenSet.refreshToken else {
            throw FleetAPIError.expiredAccessToken
        }

        return try await refreshAccessToken(using: refreshToken)
    }

    func refreshAccessToken() async throws -> String {
        guard let tokenSet = try tokenStore.loadTokenSet() else {
            throw FleetAPIError.missingAccessToken
        }
        guard let refreshToken = tokenSet.refreshToken else {
            throw FleetAPIError.expiredAccessToken
        }
        return try await refreshAccessToken(using: refreshToken)
    }

    private func refreshAccessToken(using refreshToken: String) async throws -> String {
        if let refreshTask {
            return try await refreshTask.value
        }

        let oauthClient = oauthClient
        let tokenStore = tokenStore
        let task = Task { () throws -> String in
            let refreshedTokenSet = try await oauthClient.refreshToken(refreshToken)
            try tokenStore.saveTokenSet(refreshedTokenSet)
            return refreshedTokenSet.accessToken
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func shouldRefresh(_ tokenSet: FleetOAuthTokenSet) -> Bool {
        guard let expiresAt = tokenSet.expiresAt else {
            return false
        }
        return expiresAt <= Date().addingTimeInterval(refreshLeeway)
    }
}

nonisolated struct FleetOAuthTokenKeychain: Sendable {
    var service: String

    init(service: String = "com.maxweinbach.TeslaSiri.fleet") {
        self.service = service
    }

    func loadTokenSet() throws -> FleetOAuthTokenSet? {
        guard let data = try loadData(account: "oauthTokenSet") else {
            return nil
        }
        return try JSONDecoder().decode(FleetOAuthTokenSet.self, from: data)
    }

    func saveTokenSet(_ tokenSet: FleetOAuthTokenSet) throws {
        let data = try JSONEncoder().encode(tokenSet)
        try saveData(data, account: "oauthTokenSet")
        try FleetAccessTokenKeychain(service: service).saveAccessToken(tokenSet.accessToken)
    }

    func deleteTokenSet() throws {
        try deleteData(account: "oauthTokenSet")
        try FleetAccessTokenKeychain(service: service).deleteAccessToken()
    }

    private func loadData(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            return nil
        }

        guard status == errSecSuccess else {
            throw FleetAPIError.keychain(status: status)
        }

        return item as? Data
    }

    private func saveData(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            attributes.forEach { key, value in
                addQuery[key] = value
            }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw FleetAPIError.keychain(status: retryStatus)
                }
                return
            }
            guard addStatus == errSecSuccess else {
                throw FleetAPIError.keychain(status: addStatus)
            }
        default:
            throw FleetAPIError.keychain(status: updateStatus)
        }
    }

    private func deleteData(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FleetAPIError.keychain(status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

private extension Data {
    nonisolated init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let paddingLength = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: paddingLength))
        self.init(base64Encoded: base64)
    }

    nonisolated func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    nonisolated var formURLEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .formURLEncodedAllowed) ?? self
    }
}

private extension CharacterSet {
    nonisolated static let formURLEncodedAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return allowed
    }()
}
