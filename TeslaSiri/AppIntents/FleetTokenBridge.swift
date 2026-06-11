import FleetKit
import Foundation

/// Mirrors the app's current OAuth access token (and selected VIN) into the
/// shared App Group so the App Intents extension can authenticate to the Fleet
/// backend from its own process.
///
/// The app is the source of truth for tokens: this refreshes via the same
/// provider the API client uses, then stores the resulting token. Called on
/// launch; the extension reads whatever the app most recently wrote.
@MainActor
enum FleetTokenBridge {
    static func sync(store: FleetDataStore) async {
        let provider = FleetOAuthAccessTokenProvider(
            oauthClient: FleetBackend.makeOAuthClient(),
            tokenStore: FleetBackend.makeOAuthTokenStore()
        )

        if let token = try? await provider.accessToken() {
            FleetSharedTokenStore.shared.save(accessToken: token)
        }

        if let vin = store.selectedVehicle?.vin {
            FleetSharedTokenStore.shared.save(selectedVIN: vin)
        }
    }
}
