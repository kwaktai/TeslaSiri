import AppIntents

/// Schedules the available software update. Conforms to `LongRunningIntent`
/// since kicking off and confirming the install can take a while.
public struct InstallSoftwareUpdateIntent: LongRunningIntent {
    public static let title: LocalizedStringResource = "Install Tesla Software Update"
    public static let description = IntentDescription("Install the available software update on your Tesla.")

    @Parameter(title: "Vehicle") public var vehicle: VehicleEntity?
    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = FleetIntentService.make()
        let resolved = try await service.resolvedVehicle(vehicle?.id)

        let info = try await service.software(vin: resolved.vin)
        guard info.updateAvailable || info.installable else {
            return .result(dialog: IntentDialog("\(resolved.name) is already up to date."))
        }

        let version = info.availableVersion.map { " to \($0)" } ?? ""
        try await requestConfirmation(dialog: IntentDialog("Install the software update\(version) on \(resolved.name)?"))

        try await performBackgroundTask {
            try await service.installSoftwareUpdate(vin: resolved.vin, offsetSec: 0)
        }
        return .result(dialog: IntentDialog("Starting the software update on \(resolved.name)."))
    }
}

/// Cancels a scheduled software update.
public struct CancelSoftwareUpdateIntent: AppIntent {
    public static let title: LocalizedStringResource = "Cancel Tesla Software Update"
    public static let description = IntentDescription("Cancel a scheduled software update on your Tesla.")

    @Parameter(title: "Vehicle") public var vehicle: VehicleEntity?
    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = FleetIntentService.make()
        let resolved = try await service.resolvedVehicle(vehicle?.id)
        try await requestConfirmation(dialog: IntentDialog("Cancel the software update on \(resolved.name)?"))
        try await service.cancelSoftwareUpdate(vin: resolved.vin)
        return .result(dialog: IntentDialog("Canceled the software update on \(resolved.name)."))
    }
}
