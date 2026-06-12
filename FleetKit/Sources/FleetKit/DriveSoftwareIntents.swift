import AppIntents
import SwiftUI

/// Returns a list of recent drives.
public struct GetRecentDrivesIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Recent Drives"
    public static let description = IntentDescription("List recent drives. Uses your selected car when no vehicle is specified.")
    public static let isDiscoverable = true

    @Parameter(
        title: "Vehicle",
        description: "Your Tesla from your fleet account. Leave blank to use your selected car.",
        requestValueDialog: IntentDialog("Which car?"),
        requestDisambiguationDialog: IntentDialog("Which one?")
    )
    public var vehicle: VehicleEntity?

    @Parameter(title: "Count", default: 5, inclusiveRange: (1, 25))
    public var count: Int

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        When(\.$vehicle, .hasAnyValue) {
            Summary("Show \(\.$count) recent drives for \(\.$vehicle)")
        } otherwise: {
            Summary("Show \(\.$count) recent drives for my car")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle, \.$count)) { vehicle, count in
            let target = vehicle?.name ?? FleetIntentMetadata.myCar
            return DisplayRepresentation(title: LocalizedStringResource(stringLiteral: "Show \(count) recent drives for \(target)"))
        }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<[DriveEntity]> {
        let service = FleetIntentService.make()
        let resolved = try await service.resolvedVehicle(vehicle?.id)
        let drives = try await service.drives(vin: resolved.vin, limit: count)
        return .result(value: drives.map(DriveEntity.init(info:)))
    }
}

/// Shows the most recent drive with a snippet.
public struct GetLastDriveIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Last Drive"
    public static let description = IntentDescription("See your most recent drive. Uses your selected car when no vehicle is specified.")
    public static let isDiscoverable = true

    @Parameter(
        title: "Vehicle",
        description: "Your Tesla from your fleet account. Leave blank to use your selected car.",
        requestValueDialog: IntentDialog("Which car?"),
        requestDisambiguationDialog: IntentDialog("Which one?")
    )
    public var vehicle: VehicleEntity?

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        When(\.$vehicle, .hasAnyValue) {
            Summary("Show \(\.$vehicle) last drive")
        } otherwise: {
            Summary("Show my car last drive")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Show", vehicle: vehicle, suffix: "last drive"))
        }
    }

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
            dialog: IntentDialog("\(resolved.name)'s last drive was \(entity.distanceText)."),
            view: DriveSnippetView(drive: entity)
        )
    }
}

/// Shows the software update status with a snippet. Doubles as the
/// "check install status" intent (reports download/install progress).
public struct GetSoftwareStatusIntent: AppIntent, PredictableIntent, SnippetIntent {
    public static let title: LocalizedStringResource = "Software Update Status"
    public static let description = IntentDescription("Check software version and update status. Uses your selected car when no vehicle is specified.")
    public static let isDiscoverable = true

    @Parameter(
        title: "Vehicle",
        description: "Your Tesla from your fleet account. Leave blank to use your selected car.",
        requestValueDialog: IntentDialog("Which car?"),
        requestDisambiguationDialog: IntentDialog("Which one?")
    )
    public var vehicle: VehicleEntity?

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        When(\.$vehicle, .hasAnyValue) {
            Summary("Check software on \(\.$vehicle)")
        } otherwise: {
            Summary("Check software on my car")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Check software on", vehicle: vehicle))
        }
    }

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
