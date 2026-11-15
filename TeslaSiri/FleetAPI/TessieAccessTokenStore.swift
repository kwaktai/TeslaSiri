import FleetKit
import Foundation

nonisolated enum TessieAccessTokenError: Error, LocalizedError {
    case emptyToken

    var errorDescription: String? {
        switch self {
        case .emptyToken:
            return "Paste a Tessie access token to connect your account."
        }
    }
}

nonisolated struct TessieAccessTokenStore: FleetAccessTokenProviding, Sendable {
    static let developerSettingsURL: URL = {
        guard let url = URL(string: "https://dash.tessie.com/settings/api") else {
            preconditionFailure("Invalid Tessie Developer Settings URL.")
        }
        return url
    }()

    private let keychain: FleetAccessTokenKeychain

    init(keychain: FleetAccessTokenKeychain = FleetAccessTokenKeychain()) {
        self.keychain = keychain
    }

    @concurrent
    func accessToken() async throws -> String {
        try keychain.loadAccessToken()
    }

    func loadAccessToken() throws -> String? {
        do {
            return try keychain.loadAccessToken()
        } catch FleetAPIError.missingAccessToken {
            return nil
        }
    }

    func saveAccessToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TessieAccessTokenError.emptyToken
        }
        try keychain.saveAccessToken(trimmed)
        FleetSharedTokenStore.shared.save(accessToken: trimmed)
    }

    func deleteAccessToken() throws {
        try keychain.deleteAccessToken()
        FleetSharedTokenStore.shared.clearAccessToken()
    }
}
