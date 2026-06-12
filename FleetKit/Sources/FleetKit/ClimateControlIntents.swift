import AppIntents
import Foundation

// Climate controls from the Fleet controls registry: `auto_conditioning_stop`,
// `set_temps`, `remote_defrost`, `set_pet_mode`, and `set_bioweapon_mode`.
//
// Confirmation policy: climate changes run immediately, except turning dog
// mode OFF, which prompts because a pet may be relying on it.

public struct StopClimateIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Stop Tesla Climate"
    public static let description = IntentDescription("Turn off climate control. Uses your selected car when no vehicle is specified.")
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
            Summary("Stop climate in \(\.$vehicle)")
        } otherwise: {
            Summary("Stop climate in my car")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Stop climate in", vehicle: vehicle))
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)
            try await service.runControl(action: "auto_conditioning_stop", vin: resolved.vin, humanName: "stopping climate")
            log.success("stopped climate in \(resolved.name)")
            return .result(dialog: IntentDialog("Climate is turning off in \(resolved.name)."))
        } catch {
            throw log.failure(error)
        }
    }
}

public struct SetCabinTemperatureIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Set Tesla Temperature"
    public static let description = IntentDescription("Set the cabin temperature. Uses your selected car when no vehicle is specified.")
    public static let isDiscoverable = true

    /// Tesla accepts roughly 15–28 °C; values outside are clamped.
    static let minCelsius = 15.0
    static let maxCelsius = 28.0

    static func targetCelsius(for measurement: Measurement<UnitTemperature>) -> Double {
        let requestedCelsius = measurement.converted(to: .celsius).value
        let clampedCelsius = min(max(requestedCelsius, Self.minCelsius), Self.maxCelsius)
        return (clampedCelsius * 2).rounded() / 2
    }

    @Parameter(
        title: "Vehicle",
        description: "Your Tesla from your fleet account. Leave blank to use your selected car.",
        requestValueDialog: IntentDialog("Which car?"),
        requestDisambiguationDialog: IntentDialog("Which one?"),
        optionsProvider: SelectedVehicleOptionsProvider()
    )
    public var vehicle: VehicleEntity?

    @Parameter(
        title: "Temperature",
        description: "Target cabin temperature for both front seats.",
        unit: .celsius,
        unitAdjustForLocale: true,
        supportsNegativeNumbers: false,
        requestValueDialog: IntentDialog("What temperature?")
    )
    public var temperature: Measurement<UnitTemperature>

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        When(\.$vehicle, .hasAnyValue) {
            Summary("Set \(\.$vehicle) cabin to \(\.$temperature)")
        } otherwise: {
            Summary("Set my car cabin to \(\.$temperature)")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Set cabin temperature in", vehicle: vehicle))
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)

            let targetCelsius = Self.targetCelsius(for: temperature)

            try await service.runControl(
                action: "set_temps",
                vin: resolved.vin,
                params: [
                    "driver_temp": .double(targetCelsius),
                    "passenger_temp": .double(targetCelsius)
                ],
                humanName: "setting the cabin temperature"
            )

            let applied = Measurement(value: targetCelsius, unit: UnitTemperature.celsius)
                .converted(to: temperature.unit)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1))))
            log.success("set \(resolved.name) cabin to \(targetCelsius)°C")
            return .result(dialog: IntentDialog("Set \(resolved.name)'s cabin to \(applied)."))
        } catch {
            throw log.failure(error)
        }
    }
}

public struct SetMaxDefrostIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Set Tesla Max Defrost"
    public static let description = IntentDescription("Turn max defrost on or off. Uses your selected car when no vehicle is specified.")
    public static let isDiscoverable = true

    @Parameter(
        title: "Vehicle",
        description: "Your Tesla from your fleet account. Leave blank to use your selected car.",
        requestValueDialog: IntentDialog("Which car?"),
        requestDisambiguationDialog: IntentDialog("Which one?"),
        optionsProvider: SelectedVehicleOptionsProvider()
    )
    public var vehicle: VehicleEntity?

    @Parameter(title: "On", default: true)
    public var on: Bool

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        When(\.$vehicle, .hasAnyValue) {
            Summary("Turn max defrost \(\.$on) in \(\.$vehicle)")
        } otherwise: {
            Summary("Turn max defrost \(\.$on) in my car")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle, \.$on)) { vehicle, on in
            let target = vehicle?.name ?? FleetIntentMetadata.myCar
            return DisplayRepresentation(title: LocalizedStringResource(stringLiteral: "Turn max defrost \(on ? "on" : "off") in \(target)"))
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)
            try await service.runControl(
                action: "remote_defrost",
                vin: resolved.vin,
                params: ["on": .bool(on)],
                humanName: "setting max defrost"
            )
            log.success("max defrost \(on ? "on" : "off") in \(resolved.name)")
            return .result(dialog: IntentDialog(on ? "Max defrost is on in \(resolved.name)." : "Max defrost is off in \(resolved.name)."))
        } catch {
            throw log.failure(error)
        }
    }
}

public struct SetPetModeIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Set Tesla Dog Mode"
    public static let description = IntentDescription("Turn dog mode (pet climate keeper) on or off. Uses your selected car when no vehicle is specified.")
    public static let isDiscoverable = true

    @Parameter(
        title: "Vehicle",
        description: "Your Tesla from your fleet account. Leave blank to use your selected car.",
        requestValueDialog: IntentDialog("Which car?"),
        requestDisambiguationDialog: IntentDialog("Which one?"),
        optionsProvider: SelectedVehicleOptionsProvider()
    )
    public var vehicle: VehicleEntity?

    @Parameter(title: "On", default: true)
    public var on: Bool

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        When(\.$vehicle, .hasAnyValue) {
            Summary("Turn dog mode \(\.$on) in \(\.$vehicle)")
        } otherwise: {
            Summary("Turn dog mode \(\.$on) in my car")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle, \.$on)) { vehicle, on in
            let target = vehicle?.name ?? FleetIntentMetadata.myCar
            return DisplayRepresentation(title: LocalizedStringResource(stringLiteral: "Turn dog mode \(on ? "on" : "off") in \(target)"))
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)
            if !on {
                // Turning dog mode off remotely could leave a pet without climate.
                try await requestConfirmation(dialog: IntentDialog("Turn off dog mode in \(resolved.name)?"))
            }
            try await service.runControl(
                action: "set_pet_mode",
                vin: resolved.vin,
                params: ["on": .bool(on)],
                humanName: "setting dog mode"
            )
            log.success("dog mode \(on ? "on" : "off") in \(resolved.name)")
            return .result(dialog: IntentDialog(on ? "Dog mode is on in \(resolved.name)." : "Dog mode is off in \(resolved.name)."))
        } catch {
            throw log.failure(error)
        }
    }
}

public struct SetBioweaponModeIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Set Tesla Bioweapon Defense"
    public static let description = IntentDescription("Turn Bioweapon Defense Mode on or off. Uses your selected car when no vehicle is specified.")
    public static let isDiscoverable = true

    @Parameter(
        title: "Vehicle",
        description: "Your Tesla from your fleet account. Leave blank to use your selected car.",
        requestValueDialog: IntentDialog("Which car?"),
        requestDisambiguationDialog: IntentDialog("Which one?"),
        optionsProvider: SelectedVehicleOptionsProvider()
    )
    public var vehicle: VehicleEntity?

    @Parameter(title: "On", default: true)
    public var on: Bool

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        When(\.$vehicle, .hasAnyValue) {
            Summary("Turn Bioweapon Defense \(\.$on) in \(\.$vehicle)")
        } otherwise: {
            Summary("Turn Bioweapon Defense \(\.$on) in my car")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle, \.$on)) { vehicle, on in
            let target = vehicle?.name ?? FleetIntentMetadata.myCar
            return DisplayRepresentation(title: LocalizedStringResource(stringLiteral: "Turn Bioweapon Defense \(on ? "on" : "off") in \(target)"))
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)
            try await service.runControl(
                action: "set_bioweapon_mode",
                vin: resolved.vin,
                params: ["on": .bool(on), "manual_override": .bool(false)],
                humanName: "setting Bioweapon Defense Mode"
            )
            log.success("Bioweapon Defense \(on ? "on" : "off") in \(resolved.name)")
            return .result(dialog: IntentDialog(on ? "Bioweapon Defense Mode is on in \(resolved.name)." : "Bioweapon Defense Mode is off in \(resolved.name)."))
        } catch {
            throw log.failure(error)
        }
    }
}
