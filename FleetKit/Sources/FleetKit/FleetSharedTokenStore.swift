import Foundation
import Security
import TeslaFleetTransport

/// Reads and writes the small amount of state shared between the app and the
/// App Intents extension.
///
/// Access tokens live in the shared keychain (both targets declare the same
/// `keychain-access-groups` entitlement). The selected VIN is stored in the App
/// Group's `UserDefaults` because it is not secret.
///
/// The app is the source of truth and mirrors the Tesla server API key here so
/// the extension can authenticate. The server URL is not secret and lives in the
/// App Group defaults.
public struct FleetSharedTokenStore: Sendable {
    public static let shared = FleetSharedTokenStore()

    private let appGroup: String

    public init(appGroup: String = FleetKitConfig.appGroupIdentifier) {
        self.appGroup = appGroup
    }

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    public func accessToken() -> String? {
        if let token = try? SharedAccessTokenKeychain.load(), !token.isEmpty {
            return token
        }

        // Migrate a legacy UserDefaults mirror from earlier builds.
        if let legacy = defaults?.string(forKey: FleetKitConfig.accessTokenDefaultsKey),
           !legacy.isEmpty {
            do {
                try SharedAccessTokenKeychain.save(legacy)
                defaults?.removeObject(forKey: FleetKitConfig.accessTokenDefaultsKey)
            } catch {
                // Keep the legacy value until keychain migration succeeds. This
                // also keeps extension-safe clients usable in test processes.
            }
            return legacy
        }

        return nil
    }

    public func save(accessToken: String) {
        try? SharedAccessTokenKeychain.save(accessToken)
        defaults?.removeObject(forKey: FleetKitConfig.accessTokenDefaultsKey)
    }

    public func clearAccessToken() {
        try? SharedAccessTokenKeychain.delete()
        defaults?.removeObject(forKey: FleetKitConfig.accessTokenDefaultsKey)
    }

    public func serverBaseURL() -> URL {
        if let raw = defaults?.string(forKey: FleetKitConfig.serverBaseURLDefaultsKey),
           let url = TeslaFleetAPI.normalizedBaseURL(from: raw) {
            return url
        }
        return FleetKitConfig.defaultBaseURL
    }

    public func save(serverBaseURL url: URL) {
        defaults?.set(url.absoluteString, forKey: FleetKitConfig.serverBaseURLDefaultsKey)
    }

    public func selectedVIN() -> String? {
        let vin = defaults?.string(forKey: FleetKitConfig.selectedVINDefaultsKey)
        return (vin?.isEmpty == false) ? vin : nil
    }

    public func save(selectedVIN: String) {
        defaults?.set(selectedVIN, forKey: FleetKitConfig.selectedVINDefaultsKey)
    }

    public func clearSelectedVIN() {
        defaults?.removeObject(forKey: FleetKitConfig.selectedVINDefaultsKey)
    }

    /// Clears the mirrored access token and selected vehicle default.
    public func clearCredentials() {
        clearAccessToken()
        clearSelectedVIN()
    }
}

private enum SharedAccessTokenKeychain {
    static let service = FleetKitConfig.sharedAccessTokenKeychainService
    static let account = FleetKitConfig.sharedAccessTokenKeychainAccount

    static func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
        guard
            let data = item as? Data,
            let token = String(data: data, encoding: .utf8),
            !token.isEmpty
        else {
            return nil
        }
        return token
    }

    static func save(_ token: String) throws {
        let data = Data(token.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            attributes.forEach { key, value in
                addQuery[key] = value
            }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                let retryStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw KeychainError(status: retryStatus)
                }
                return
            }
            guard addStatus == errSecSuccess else {
                throw KeychainError(status: addStatus)
            }
        default:
            throw KeychainError(status: updateStatus)
        }
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

private struct KeychainError: Error {
    let status: OSStatus
}
