import Foundation

/// Shared configuration for Tessie and cross-process storage.
///
/// `FleetKit` is intentionally self-contained so the App Intents extension can
/// authenticate and talk to Tessie without dragging in the app's full data
/// layer. The app mirrors the current access token into the shared keychain so
/// this module can read it from either process.
public enum FleetKitConfig {
    public static let baseURL: URL = {
        guard let url = URL(string: "https://api.tessie.com") else {
            preconditionFailure("Invalid Tessie API base URL.")
        }
        return url
    }()

    /// App Group shared between the app and the App Intents extension.
    public static let appGroupIdentifier = "group.com.maxweinbach.TeslaSiri"

    /// Legacy UserDefaults key for access tokens (migrated to shared keychain).
    public static let accessTokenDefaultsKey = "fleet.accessToken"

    public static let sharedAccessTokenKeychainService = "com.maxweinbach.TeslaSiri.fleet.shared"
    public static let sharedAccessTokenKeychainAccount = "extensionAccessToken"

    /// Key under which the app stores the currently selected VIN.
    public static let selectedVINDefaultsKey = "fleet.selectedVIN"

    /// Shared sandbox / demo mode keys read by both the app and App Intents extension.
    public static let sandboxModeDefaultsKey = "fleet.sandbox.mode"
    public static let sandboxPresetDefaultsKey = "fleet.sandbox.preset"
    public static let sandboxDemoStateDefaultsKey = "fleet.sandbox.demoState"
    public static let sandboxCommandLogDefaultsKey = "fleet.sandbox.commandLog"

    public static let requestTimeout: TimeInterval = 30
}
