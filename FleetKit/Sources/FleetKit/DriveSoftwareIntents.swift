import AppIntents
import SwiftUI

/// Returns a list of recent drives.
public struct GetRecentDrivesIntent: AppIntent {
    public static let title: LocalizedStringResource = "Recent Drives"
    public static let description = IntentDescription("List your Tesla's recent drives.")

    @Parameter(title: "Vehicle")
    public var vehicle: VehicleEntity?

    @Parameter(title: "Count", default: 5, inclusiveRange: (1, 25))
    public var count: Int

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<[DriveEntity]> {
        let service = FleetIntentService.make()
        let resolved = try await service.resolvedVehicle(vehicle?.id)
        let drives = try await service.drives(vin: resolved.vin, limit: count)
        return .result(value: drives.map(DriveEntity.init(info:)))
    }
}

/// Shows the most recent drive with a snippet.
public struct GetLastDriveIntent: AppIntent {
    public static let title: LocalizedStringResource = "Last Drive"
    public static let description = IntentDescription("See details about your Tesla's most recent drive.")

    @Parameter(title: "Vehicle")
    public var vehicle: VehicleEntity?

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<DriveEntity> & ShowsSnippetView & ProvidesDialog {
        let service = FleetIntentService.make()
        let resolved = try await service.resolvedVehicle(vehicle?.id)
        guard let last = try await service.drives(vin: resolved.vin, limit: 1).first else {
            throw FleetKitError.api("No recent drives were found.")
        }
        let entity = DriveEntity(info: last)
        return .result(
            value: entity,
            dialog: IntentDialog("Your last drive was \(entity.distanceText)."),
            view: DriveSnippetView(drive: entity)
        )
    }
}

/// Shows the software update status with a snippet. Doubles as the
/// "check install status" intent (reports download/install progress).
public struct GetSoftwareStatusIntent: AppIntent {
    public static let title: LocalizedStringResource = "Software Update Status"
    public static let description = IntentDescription("Check your Tesla's software version and update status.")

    @Parameter(title: "Vehicle")
    public var vehicle: VehicleEntity?

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<SoftwareUpdateEntity> & ShowsSnippetView & ProvidesDialog {
        let service = FleetIntentService.make()
        let resolved = try await service.resolvedVehicle(vehicle?.id)
        let info = try await service.software(vin: resolved.vin)
        let entity = SoftwareUpdateEntity(info: info, vin: resolved.vin, vehicleName: resolved.name)
        return .result(
            value: entity,
            dialog: IntentDialog("\(resolved.name): \(entity.headline)."),
            view: SoftwareSnippetView(software: entity)
        )
    }
}
