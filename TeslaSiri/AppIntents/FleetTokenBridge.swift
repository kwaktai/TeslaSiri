import AppIntents
import FleetKit
import Foundation
import OSLog

/// Mirrors the app's current Tessie access token (and selected VIN) into shared
/// storage so the App Intents extension can authenticate from its own process.
@MainActor
enum FleetTokenBridge {
    private static let logger = Logger(subsystem: FleetKitLog.subsystem, category: "TokenBridge")

    static func sync(store: FleetDataStore) async {
        let tokenStore = FleetBackend.makeAccessTokenStore()

        do {
            let token = try await tokenStore.accessToken()
            FleetSharedTokenStore.shared.save(accessToken: token)
            logger.notice("Mirrored access token to shared keychain")
        } catch {
            FleetSharedTokenStore.shared.clearAccessToken()
            logger.warning("No valid session — cleared shared access token (\(error.localizedDescription, privacy: .public))")
        }

        syncSelectedVehicle(store: store, forceShortcutRefresh: true)
        await FleetIntentDonations.syncCarSuggestions(for: store.selectedVehicle)
    }

    static func syncSelectedVehicle(store: FleetDataStore, forceShortcutRefresh: Bool = false) {
        let vin = store.selectedVehicle?.vin
        guard forceShortcutRefresh || FleetSharedTokenStore.shared.selectedVIN() != vin else { return }

        if let vin {
            FleetSharedTokenStore.shared.save(selectedVIN: vin)
            logger.info("Shared selected VIN set to \(FleetKitLog.vin(vin), privacy: .public)")
        } else {
            FleetSharedTokenStore.shared.clearSelectedVIN()
            logger.info("Cleared shared selected VIN (no vehicle selected)")
        }

        TeslaSiriShortcuts.updateAppShortcutParameters()
    }

    static func clear() {
        FleetSharedTokenStore.shared.clearCredentials()
        logger.notice("Cleared shared credentials (sign-out)")
    }
}
