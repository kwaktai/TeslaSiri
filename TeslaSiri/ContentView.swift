import AppIntents
import AuthenticationServices
import FleetKit
import SwiftUI

@main
struct TeslaSiriApp: App {
    @State private var notificationWebhooks = FleetNotificationWebhookStore()
    @State private var notifications = FleetNotificationCenter()
    @State private var oauthClient = FleetBackend.makeOAuthClient()
    @State private var store = FleetBackend.makeDataStore()
    @State private var tokenStore = FleetBackend.makeOAuthTokenStore()

    init() {
        BatteryReminderManager.shared.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(
                store: store,
                notificationWebhooks: notificationWebhooks,
                notifications: notifications,
                oauthClient: oauthClient,
                tokenStore: tokenStore
            )
            .task {
                await FleetTokenBridge.sync(store: store)
                await BatteryReminderManager.shared.prepare()
                await FleetSpotlightIndexer.reindexAll()
            }
        }
    }
}

extension TeslaSiriApp: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [FleetKitPackage.self]
    }
}
