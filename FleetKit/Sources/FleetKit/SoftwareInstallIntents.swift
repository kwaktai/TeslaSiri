import AppIntents

/// Schedules the available software update. Conforms to `LongRunningIntent`
/// since kicking off and confirming the install can take a while.
public struct InstallSoftwareUpdateIntent: LongRunningIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Install Tesla Software Update"
    public static let description = IntentDescription("Install a software update. Uses your selected car when no vehicle is specified.")
    public static let isDiscoverable = true

    @Parameter(
        title: "Vehicle",
        description: "Your Tesla from your fleet account. Leave blank to use your selected car.",
        requestValueDialog: IntentDialog("Which car?"),
        requestDisambiguationDialog: IntentDialog("Which one?"),
        optionsProvider: SelectedVehicleOptionsProvider()
    )
    public var vehicle: VehicleEntity?

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        When(\.$vehicle, .hasAnyValue) {
            Summary("Update \(\.$vehicle)")
        } otherwise: {
            Summary("Update my car")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Update", vehicle: vehicle))
        }
    }

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
public struct CancelSoftwareUpdateIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Cancel Tesla Software Update"
    public static let description = IntentDescription("Cancel a scheduled software update. Uses your selected car when no vehicle is specified.")
    public static let isDiscoverable = true

    @Parameter(
        title: "Vehicle",
        description: "Your Tesla from your fleet account. Leave blank to use your selected car.",
        requestValueDialog: IntentDialog("Which car?"),
        requestDisambiguationDialog: IntentDialog("Which one?"),
        optionsProvider: SelectedVehicleOptionsProvider()
    )
    public var vehicle: VehicleEntity?

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        When(\.$vehicle, .hasAnyValue) {
            Summary("Cancel update on \(\.$vehicle)")
        } otherwise: {
            Summary("Cancel update on my car")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Cancel update on", vehicle: vehicle))
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = FleetIntentService.make()
        let resolved = try await service.resolvedVehicle(vehicle?.id)
        try await requestConfirmation(dialog: IntentDialog("Cancel the software update on \(resolved.name)?"))
        try await service.cancelSoftwareUpdate(vin: resolved.vin)
        return .result(dialog: IntentDialog("Canceled the software update on \(resolved.name)."))
    }
}
