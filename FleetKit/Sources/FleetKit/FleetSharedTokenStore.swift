import Foundation

/// Reads and writes the small amount of state shared between the app and the
/// App Intents extension via the App Group's `UserDefaults`.
///
/// The app is the source of truth: it refreshes the OAuth access token and
/// mirrors the current value here so the extension can authenticate.
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
        guard let token = defaults?.string(forKey: FleetKitConfig.accessTokenDefaultsKey),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    public func save(accessToken: String) {
        defaults?.set(accessToken, forKey: FleetKitConfig.accessTokenDefaultsKey)
    }

    public func clearAccessToken() {
        defaults?.removeObject(forKey: FleetKitConfig.accessTokenDefaultsKey)
    }

    public func selectedVIN() -> String? {
        let vin = defaults?.string(forKey: FleetKitConfig.selectedVINDefaultsKey)
        return (vin?.isEmpty == false) ? vin : nil
    }

    public func save(selectedVIN: String) {
        defaults?.set(selectedVIN, forKey: FleetKitConfig.selectedVINDefaultsKey)
    }
}
