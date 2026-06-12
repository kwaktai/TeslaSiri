import AppIntents
import Foundation

// Convenience controls from the Fleet controls registry: `flash_lights`,
// `honk_horn`, and `navigation_request`. All run immediately.
//
// `window_control` close is intentionally not exposed: the backend requires
// the caller's lat/lon to prove proximity, and the intents extension has no
// location access.

public struct FlashLightsIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Flash Tesla Lights"
    public static let description = IntentDescription("Flash the headlights. Uses your selected car when no vehicle is specified.")
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
            Summary("Flash \(\.$vehicle) lights")
        } otherwise: {
            Summary("Flash my car lights")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Flash", vehicle: vehicle, suffix: "lights"))
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)
            try await service.runControl(action: "flash_lights", vin: resolved.vin, humanName: "flashing the lights")
            log.success("flashed lights on \(resolved.name)")
            return .result(dialog: IntentDialog("Flashing \(resolved.name)'s lights."))
        } catch {
            throw log.failure(error)
        }
    }
}

public struct HonkHornIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Honk Tesla Horn"
    public static let description = IntentDescription("Honk the horn. Uses your selected car when no vehicle is specified.")
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
            Summary("Honk \(\.$vehicle) horn")
        } otherwise: {
            Summary("Honk my car horn")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Honk", vehicle: vehicle, suffix: "horn"))
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)
            try await service.runControl(action: "honk_horn", vin: resolved.vin, humanName: "honking the horn")
            log.success("honked horn on \(resolved.name)")
            return .result(dialog: IntentDialog("Honking \(resolved.name)'s horn."))
        } catch {
            throw log.failure(error)
        }
    }
}

public struct SendNavigationIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Send Destination to Tesla"
    public static let description = IntentDescription("Send an address or place to the car's navigation. Uses your selected car when no vehicle is specified.")
    public static let isDiscoverable = true

    @Parameter(
        title: "Vehicle",
        description: "Your Tesla from your fleet account. Leave blank to use your selected car.",
        requestValueDialog: IntentDialog("Which car?"),
        requestDisambiguationDialog: IntentDialog("Which one?"),
        optionsProvider: SelectedVehicleOptionsProvider()
    )
    public var vehicle: VehicleEntity?

    @Parameter(
        title: "Destination",
        description: "An address or place name to send to the car's navigation.",
        requestValueDialog: IntentDialog("Where to?"),
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    public var destination: String

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        When(\.$vehicle, .hasAnyValue) {
            Summary("Send \(\.$destination) to \(\.$vehicle)")
        } otherwise: {
            Summary("Send \(\.$destination) to my car")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Send navigation to", vehicle: vehicle))
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)
            let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw FleetKitError.api("Tell me where to send \(resolved.name).")
            }
            // The backend wraps a plain string into the Tesla share payload and
            // fills type/locale/timestamp_ms server-side.
            try await service.runControl(
                action: "navigation_request",
                vin: resolved.vin,
                params: ["value": .string(trimmed)],
                humanName: "sending the destination"
            )
            log.success("sent destination to \(resolved.name)")
            return .result(dialog: IntentDialog("Sent \(trimmed) to \(resolved.name)."))
        } catch {
            throw log.failure(error)
        }
    }
}
