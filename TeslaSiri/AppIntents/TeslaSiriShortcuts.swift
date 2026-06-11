import AppIntents
import FleetKit

/// Zero-configuration App Shortcuts so the most common intents are available in
/// Siri, Spotlight, and on the Action button the moment the app is installed.
/// The intents live in the shared `FleetKit` package so the App Intents
/// extension can perform them in the background.
struct TeslaSiriShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetBatteryLevelIntent(),
            phrases: [
                "Check \(.applicationName) battery",
                "What's my battery in \(.applicationName)"
            ],
            shortTitle: "Battery Level",
            systemImageName: "battery.100percent"
        )
        AppShortcut(
            intent: GetVehicleStatusIntent(),
            phrases: [
                "Check my car in \(.applicationName)",
                "Show \(.applicationName) status"
            ],
            shortTitle: "Vehicle Status",
            systemImageName: "car.fill"
        )
        AppShortcut(
            intent: LockVehicleIntent(),
            phrases: [
                "Lock my Tesla with \(.applicationName)",
                "Lock my car in \(.applicationName)"
            ],
            shortTitle: "Lock",
            systemImageName: "lock.fill"
        )
        AppShortcut(
            intent: UnlockVehicleIntent(),
            phrases: [
                "Unlock my Tesla with \(.applicationName)",
                "Unlock my car in \(.applicationName)"
            ],
            shortTitle: "Unlock",
            systemImageName: "lock.open.fill"
        )
        AppShortcut(
            intent: StartClimateIntent(),
            phrases: [
                "Start climate in \(.applicationName)",
                "Precondition my Tesla with \(.applicationName)"
            ],
            shortTitle: "Start Climate",
            systemImageName: "fan.fill"
        )
        AppShortcut(
            intent: OpenFrunkIntent(),
            phrases: [
                "Open the frunk with \(.applicationName)",
                "Open my Tesla frunk in \(.applicationName)"
            ],
            shortTitle: "Open Frunk",
            systemImageName: "car.fill"
        )
        AppShortcut(
            intent: GetLastDriveIntent(),
            phrases: [
                "Show my last drive in \(.applicationName)",
                "Where did I drive in \(.applicationName)"
            ],
            shortTitle: "Last Drive",
            systemImageName: "map.fill"
        )
        AppShortcut(
            intent: GetSoftwareStatusIntent(),
            phrases: [
                "Does my Tesla have an update in \(.applicationName)",
                "Check \(.applicationName) software"
            ],
            shortTitle: "Software Status",
            systemImageName: "arrow.down.circle.fill"
        )
        AppShortcut(
            intent: InstallSoftwareUpdateIntent(),
            phrases: [
                "Install the Tesla update with \(.applicationName)",
                "Update my Tesla in \(.applicationName)"
            ],
            shortTitle: "Install Update",
            systemImageName: "square.and.arrow.down.fill"
        )
        AppShortcut(
            intent: SetChargeLimitIntent(),
            phrases: [
                "Set my Tesla charge limit in \(.applicationName)",
                "Change charge limit with \(.applicationName)"
            ],
            shortTitle: "Set Charge Limit",
            systemImageName: "bolt.fill"
        )
    }
}
