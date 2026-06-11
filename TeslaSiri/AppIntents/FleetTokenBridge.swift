import AppIntents
import FleetKit
import Foundation

/// Mirrors the app's current OAuth access token (and selected VIN) into shared
/// storage so the App Intents extension can authenticate from its own process.
///
/// The app is the source of truth for tokens: this refreshes via the same
/// provider the API client uses, then stores the resulting token.
@MainActor
enum FleetTokenBridge {
    static func sync(store: FleetDataStore) async {
        let provider = FleetOAuthAccessTokenProvider(
            oauthClient: FleetBackend.makeOAuthClient(),
            tokenStore: FleetBackend.makeOAuthTokenStore()
        )

        do {
            let token = try await provider.accessToken()
            FleetSharedTokenStore.shared.save(accessToken: token)
        } catch {
            FleetSharedTokenStore.shared.clearAccessToken()
        }

        if let vin = store.selectedVehicle?.vin {
            FleetSharedTokenStore.shared.save(selectedVIN: vin)
        } else {
            FleetSharedTokenStore.shared.clearSelectedVIN()
        }

        TeslaSiriShortcuts.updateAppShortcutParameters()
    }

    static func clear() {
        FleetSharedTokenStore.shared.clearCredentials()
    }
}
