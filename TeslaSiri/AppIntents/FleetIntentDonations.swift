import AppIntents
import FleetKit
import OSLog

/// App-side donations for actions completed from TeslaSiri's own UI.
///
/// Siri and Shortcuts donate intents they run themselves. These helpers cover
/// matching interactions performed in the app so the system can learn the same
/// vehicle-scoped habits from dashboard usage.
enum FleetIntentDonations {
    private static let logger = Logger(subsystem: FleetKitLog.subsystem, category: "AppIntents")

    static func donateManualStatusRefresh(for vehicle: FleetVehicle?) async {
        guard let vehicleEntity = VehicleEntity(vehicle: vehicle) else { return }

        let intent = GetVehicleStatusIntent()
        intent.vehicle = vehicleEntity
        await donate(intent, label: "manual vehicle status refresh")
    }

    static func donateSoftwareStatusRefresh(for vehicle: FleetVehicle?) async {
        guard let vehicleEntity = VehicleEntity(vehicle: vehicle) else { return }

        let intent = GetSoftwareStatusIntent()
        intent.vehicle = vehicleEntity
        await donate(intent, label: "software status refresh")
    }

    static func donateSoftwareInstall(for vehicle: FleetVehicle?) async {
        guard let vehicleEntity = VehicleEntity(vehicle: vehicle) else { return }

        let intent = InstallSoftwareUpdateIntent()
        intent.vehicle = vehicleEntity
        await donate(intent, label: "software install")
    }

    static func donateSoftwareCancel(for vehicle: FleetVehicle?) async {
        guard let vehicleEntity = VehicleEntity(vehicle: vehicle) else { return }

        let intent = CancelSoftwareUpdateIntent()
        intent.vehicle = vehicleEntity
        await donate(intent, label: "software cancel")
    }

    private static func donate(_ intent: some AppIntent, label: String) async {
        do {
            _ = try await intent.donate()
            logger.info("Donated intent for \(label, privacy: .public)")
        } catch {
            logger.warning("Intent donation failed for \(label, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

private extension VehicleEntity {
    init?(vehicle: FleetVehicle?) {
        guard let vehicle, !vehicle.vin.isEmpty else { return nil }
        self.init(id: vehicle.vin, name: vehicle.name)
    }
}
