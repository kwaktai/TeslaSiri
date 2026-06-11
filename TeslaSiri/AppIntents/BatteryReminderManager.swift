import BackgroundTasks
import FleetKit
import UserNotifications

/// On-device fallback for the "you should charge your car" reminder.
///
/// Registers a `BGAppRefreshTask` that periodically reads the selected
/// vehicle's battery via the shared `FleetIntentService` and posts a local
/// notification when it's low and not charging. The primary path (server
/// webhook → push) is handled elsewhere; this covers the case where the app
/// hasn't received a push recently.
@MainActor
final class BatteryReminderManager {
    static let shared = BatteryReminderManager()

    static let taskIdentifier = "com.maxweinbach.TeslaSiri.batterycheck"
    private let lowBatteryThreshold = 20

    private init() {}

    /// Must be called during app launch (before launch finishes).
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated {
                self.handle(refreshTask)
            }
        }
    }

    /// Requests notification permission (foreground) and schedules the first check.
    func prepare() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        schedule()
    }

    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handle(_ task: BGAppRefreshTask) {
        schedule() // queue the next check regardless of this one's outcome

        let work = Task {
            await checkBatteryAndNotify()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    func checkBatteryAndNotify() async {
        let service = FleetIntentService.make()
        guard
            let vehicle = try? await service.resolvedVehicle(nil),
            let snapshot = try? await service.snapshot(vin: vehicle.vin),
            let battery = snapshot.batteryLevel
        else { return }

        let isCharging = snapshot.chargingState?.lowercased() == "charging"
        let level = Int(battery.rounded())
        guard !isCharging, level <= lowBatteryThreshold else { return }

        await postLowBatteryNotification(vehicleName: vehicle.name, battery: level)
    }

    private func postLowBatteryNotification(vehicleName: String, battery: Int) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = "Low Battery"
        content.body = "\(vehicleName) is at \(battery)%. You should charge your car."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "battery-reminder",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}
