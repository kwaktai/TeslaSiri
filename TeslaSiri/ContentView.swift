import AppIntents
import FleetKit
import SwiftUI

@main
struct TeslaSiriApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var store = FleetBackend.makeDataStore()
    @State private var tokenStore = FleetBackend.makeAccessTokenStore()

    init() {
        BatteryReminderManager.shared.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(
                store: store,
                tokenStore: tokenStore
            )
            .task {
                await FleetTokenBridge.sync(store: store)
                await BatteryReminderManager.shared.prepare()
                _ = await FleetSpotlightIndexer.reindexAll()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await FleetTokenBridge.sync(store: store)
                }
            }
        }
    }
}

extension TeslaSiriApp: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [FleetKitPackage.self]
    }
}
