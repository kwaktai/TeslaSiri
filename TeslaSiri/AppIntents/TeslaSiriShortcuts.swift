import AppIntents
import FleetKit

/// Zero-configuration App Shortcuts so the most common intents are available in
/// Siri, Spotlight, and on the Action button the moment the app is installed.
/// The intents live in the shared `FleetKit` package so the App Intents
/// extension can perform them in the background.
///
/// Apple limits each app to 10 App Shortcuts; less common intents remain
/// available via the Shortcuts app and Spotlight entity/indexing discovery.
struct TeslaSiriShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetVehicleStatusIntent(),
            phrases: [
                "Check \(\.$vehicle) in \(.applicationName)",
                "Check my car in \(.applicationName)",
                "Show \(.applicationName) status for \(\.$vehicle)"
            ],
            shortTitle: "Vehicle Status",
            systemImageName: "car.fill"
        )
        AppShortcut(
            intent: LockVehicleIntent(),
            phrases: [
                "Lock \(\.$vehicle) with \(.applicationName)",
                "Lock my car with \(.applicationName)"
            ],
            shortTitle: "Lock",
            systemImageName: "lock.fill"
        )
        AppShortcut(
            intent: UnlockVehicleIntent(),
            phrases: [
                "Unlock \(\.$vehicle) with \(.applicationName)",
                "Unlock my car with \(.applicationName)"
            ],
            shortTitle: "Unlock",
            systemImageName: "lock.open.fill"
        )
        AppShortcut(
            intent: StartClimateIntent(),
            phrases: [
                "Start climate in \(\.$vehicle) with \(.applicationName)",
                "Precondition my car with \(.applicationName)"
            ],
            shortTitle: "Start Climate",
            systemImageName: "fan.fill"
        )
        AppShortcut(
            intent: VentWindowsIntent(),
            phrases: [
                "Vent \(\.$vehicle) windows with \(.applicationName)",
                "Vent my car windows with \(.applicationName)"
            ],
            shortTitle: "Vent Windows",
            systemImageName: "wind"
        )
        AppShortcut(
            intent: OpenTrunkIntent(),
            phrases: [
                "Open \(\.$vehicle) trunk with \(.applicationName)",
                "Open my car trunk with \(.applicationName)"
            ],
            shortTitle: "Open Trunk",
            systemImageName: "car.rear"
        )
        AppShortcut(
            intent: GetLastDriveIntent(),
            phrases: [
                "Show \(\.$vehicle) last drive in \(.applicationName)",
                "Where did I drive in \(.applicationName)"
            ],
            shortTitle: "Last Drive",
            systemImageName: "map.fill"
        )
        AppShortcut(
            intent: GetSoftwareStatusIntent(),
            phrases: [
                "Does \(\.$vehicle) have an update in \(.applicationName)",
                "Check my car software in \(.applicationName)"
            ],
            shortTitle: "Software Status",
            systemImageName: "arrow.down.circle.fill"
        )
        AppShortcut(
            intent: InstallSoftwareUpdateIntent(),
            phrases: [
                "Update \(\.$vehicle) with \(.applicationName)",
                "Update my car with \(.applicationName)"
            ],
            shortTitle: "Install Update",
            systemImageName: "square.and.arrow.down.fill"
        )
        AppShortcut(
            intent: CancelSoftwareUpdateIntent(),
            phrases: [
                "Cancel the update on \(\.$vehicle) with \(.applicationName)",
                "Cancel my car software update in \(.applicationName)"
            ],
            shortTitle: "Cancel Update",
            systemImageName: "xmark.circle.fill"
        )
    }
}
