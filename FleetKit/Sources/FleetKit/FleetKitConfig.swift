import Foundation

/// Shared configuration for the Fleet backend and cross-process storage.
///
/// `FleetKit` is intentionally self-contained so the App Intents extension can
/// authenticate and talk to the backend without dragging in the app's full data
/// layer. The app mirrors the current access token into the shared App Group so
/// this module can read it from either process.
public enum FleetKitConfig {
    public static let baseURL = URL(string: "https://fleet.maxweinbach.com")!

    /// App Group shared between the app and the App Intents extension.
    public static let appGroupIdentifier = "group.com.maxweinbach.TeslaSiri"

    /// Legacy UserDefaults key for access tokens (migrated to shared keychain).
    public static let accessTokenDefaultsKey = "fleet.accessToken"

    public static let sharedAccessTokenKeychainService = "com.maxweinbach.TeslaSiri.fleet.shared"
    public static let sharedAccessTokenKeychainAccount = "extensionAccessToken"

    /// Key under which the app stores the currently selected VIN.
    public static let selectedVINDefaultsKey = "fleet.selectedVIN"

    public static let requestTimeout: TimeInterval = 30
}
