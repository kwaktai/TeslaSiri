import AppIntents
import SwiftUI

/// Reads the current battery level and reports it as a spoken/written result.
public struct GetBatteryLevelIntent: AppIntent {
    public static let title: LocalizedStringResource = "Check Battery Level"
    public static let description = IntentDescription("Check your Tesla's current battery level.")

    @Parameter(title: "Vehicle")
    public var vehicle: VehicleEntity?

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<VehicleStatusEntity> & ProvidesDialog {
        let service = FleetIntentService.make()
        let resolved = try await service.resolvedVehicle(vehicle?.id)
        let snapshot = try await service.snapshot(vin: resolved.vin)
        let entity = VehicleStatusEntity(snapshot: snapshot, vehicleName: resolved.name)

        let battery = entity.batteryPercent.map { "\($0)%" } ?? "an unknown level"
        let charging = (snapshot.chargingState?.lowercased() == "charging") ? " and charging" : ""
        return .result(
            value: entity,
            dialog: IntentDialog("\(resolved.name) is at \(battery)\(charging).")
        )
    }
}

/// Shows a full vehicle status snippet plus a short supporting dialog.
public struct GetVehicleStatusIntent: AppIntent {
    public static let title: LocalizedStringResource = "Check Vehicle Status"
    public static let description = IntentDescription("See your Tesla's battery, charging, and lock status.")

    @Parameter(title: "Vehicle")
    public var vehicle: VehicleEntity?

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<VehicleStatusEntity> & ShowsSnippetView & ProvidesDialog {
        let service = FleetIntentService.make()
        let resolved = try await service.resolvedVehicle(vehicle?.id)
        let snapshot = try await service.snapshot(vin: resolved.vin)
        let entity = VehicleStatusEntity(snapshot: snapshot, vehicleName: resolved.name)

        return .result(
            value: entity,
            dialog: IntentDialog("Here's the latest on \(resolved.name)."),
            view: VehicleStatusSnippetView(status: entity)
        )
    }
}
