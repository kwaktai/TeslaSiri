import Foundation
import TeslaFleetTransport

/// Shared configuration for the self-hosted Tesla server and cross-process storage.
///
/// `FleetKit` is intentionally self-contained so the App Intents extension can
/// authenticate and talk to the owner's server without dragging in the app's full
/// data layer. The app mirrors the API key into the shared keychain and the
/// server URL into the App Group so this module can read both from either process.
public enum FleetKitConfig {
    /// Used when the owner has not saved a server URL yet.
    public static let defaultBaseURL = TeslaFleetAPI.defaultBaseURL

    public static let serverBaseURLDefaultsKey = "fleet.serverBaseURL"

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
