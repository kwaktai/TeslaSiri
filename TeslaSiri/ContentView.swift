import AuthenticationServices
import SwiftUI

@main
struct TeslaSiriApp: App {
    @State private var notificationWebhooks = FleetNotificationWebhookStore()
    @State private var notifications = FleetNotificationCenter()
    @State private var oauthClient = FleetBackend.makeOAuthClient()
    @State private var store = FleetBackend.makeDataStore()
    @State private var tokenStore = FleetBackend.makeOAuthTokenStore()

    var body: some Scene {
        WindowGroup {
            AppRootView(
                store: store,
                notificationWebhooks: notificationWebhooks,
                notifications: notifications,
                oauthClient: oauthClient,
                tokenStore: tokenStore
            )
        }
    }
}
