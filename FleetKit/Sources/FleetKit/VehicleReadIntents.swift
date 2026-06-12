import AppIntents
import SwiftUI

/// Reads the current battery level and reports it as a spoken/written result.
public struct GetBatteryLevelIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Check Battery Level"
    public static let description = IntentDescription("Check your Tesla's battery level. Uses your selected car when no vehicle is specified.")
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
            Summary("Check \(\.$vehicle) battery")
        } otherwise: {
            Summary("Check my car battery")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Check", vehicle: vehicle, suffix: "battery"))
        }
    }

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

/// Reads the vehicle odometer/mileage from the latest live snapshot.
public struct GetVehicleMileageIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Check Vehicle Mileage"
    public static let description = IntentDescription("Check your Tesla's odometer mileage. Uses your selected car when no vehicle is specified.")
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
            Summary("Check \(\.$vehicle) mileage")
        } otherwise: {
            Summary("Check my car mileage")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Check", vehicle: vehicle, suffix: "mileage"))
        }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<VehicleStatusEntity> & ProvidesDialog {
        let service = FleetIntentService.make()
        let resolved = try await service.resolvedVehicle(vehicle?.id)
        let snapshot = try await service.snapshot(vin: resolved.vin)
        let entity = VehicleStatusEntity(snapshot: snapshot, vehicleName: resolved.name)
        let mileage = entity.odometerDisplay ?? "unknown mileage"
        return .result(
            value: entity,
            dialog: IntentDialog("\(resolved.name)'s odometer is \(mileage).")
        )
    }
}

/// Reads current TPMS PSI values from the latest live snapshot.
public struct GetTirePressureIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Check Tire Pressure"
    public static let description = IntentDescription("Check your Tesla's tire PSI readings. Uses your selected car when no vehicle is specified.")
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
            Summary("Check \(\.$vehicle) tire pressure")
        } otherwise: {
            Summary("Check my car tire pressure")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Check", vehicle: vehicle, suffix: "tire pressure"))
        }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<VehicleStatusEntity> & ProvidesDialog {
        let service = FleetIntentService.make()
        let resolved = try await service.resolvedVehicle(vehicle?.id)
        let snapshot = try await service.snapshot(vin: resolved.vin)
        let entity = VehicleStatusEntity(snapshot: snapshot, vehicleName: resolved.name)
        let tires = entity.tireSummary ?? "no recent tire pressure reading"
        return .result(
            value: entity,
            dialog: IntentDialog("\(resolved.name)'s tire pressure: \(tires).")
        )
    }
}

/// Shows a full vehicle status snippet plus a short supporting dialog.
public struct GetVehicleStatusIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Check Vehicle Status"
    public static let description = IntentDescription("See battery, charging, lock status, mileage, tire PSI, temperature, and location. Uses your selected car when no vehicle is specified.")
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
            Summary("Check \(\.$vehicle) status")
        } otherwise: {
            Summary("Check my car status")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Check", vehicle: vehicle, suffix: "status"))
        }
    }

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
