import AppIntents

// Control intents map to backend-advertised action names via `runControl`.
// `FleetIntentService.runControl` validates the action against the live
// `controlActions()` list and throws a friendly error if unsupported.
//
// Confirmation policy: unlock, trunk, frunk, and charge-limit changes prompt
// for confirmation; lock, climate, and vent run immediately.

public struct LockVehicleIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Lock Tesla"
    public static let description = IntentDescription("Lock your Tesla. Uses your selected car when no vehicle is specified.")
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
            Summary("Lock \(\.$vehicle)")
        } otherwise: {
            Summary("Lock my car")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Lock", vehicle: vehicle))
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)
            try await service.runControl(action: "door_lock", vin: resolved.vin, humanName: "locking")
            log.success("locked \(resolved.name)")
            return .result(dialog: IntentDialog("Locked \(resolved.name)."))
        } catch {
            throw log.failure(error)
        }
    }
}

public struct UnlockVehicleIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Unlock Tesla"
    public static let description = IntentDescription("Unlock your Tesla. Uses your selected car when no vehicle is specified.")
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
            Summary("Unlock \(\.$vehicle)")
        } otherwise: {
            Summary("Unlock my car")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Unlock", vehicle: vehicle))
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)
            try await requestConfirmation(dialog: IntentDialog("Unlock \(resolved.name)?"))
            try await service.runControl(action: "door_unlock", vin: resolved.vin, humanName: "unlocking")
            log.success("unlocked \(resolved.name)")
            return .result(dialog: IntentDialog("Unlocked \(resolved.name)."))
        } catch {
            throw log.failure(error)
        }
    }
}

public struct StartClimateIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Start Tesla Climate"
    public static let description = IntentDescription("Turn on climate control. Uses your selected car when no vehicle is specified.")
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
            Summary("Start climate in \(\.$vehicle)")
        } otherwise: {
            Summary("Start climate in my car")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Start climate in", vehicle: vehicle))
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)
            try await service.runControl(action: "auto_conditioning_start", vin: resolved.vin, humanName: "starting climate")
            log.success("started climate in \(resolved.name)")
            return .result(dialog: IntentDialog("Climate is starting in \(resolved.name)."))
        } catch {
            throw log.failure(error)
        }
    }
}

public struct VentWindowsIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Vent Tesla Windows"
    public static let description = IntentDescription("Vent your Tesla's windows. Uses your selected car when no vehicle is specified.")
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
            Summary("Vent \(\.$vehicle) windows")
        } otherwise: {
            Summary("Vent my car windows")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Vent", vehicle: vehicle, suffix: "windows"))
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)
            try await service.runControl(
                action: "window_control",
                vin: resolved.vin,
                params: ["command": .string("vent")],
                humanName: "venting the windows"
            )
            log.success("venting windows on \(resolved.name)")
            return .result(dialog: IntentDialog("Venting \(resolved.name)'s windows."))
        } catch {
            throw log.failure(error)
        }
    }
}

public struct OpenTrunkIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Open Tesla Trunk"
    public static let description = IntentDescription("Open your Tesla's rear trunk. Uses your selected car when no vehicle is specified.")
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
            Summary("Open \(\.$vehicle) trunk")
        } otherwise: {
            Summary("Open my car trunk")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Open", vehicle: vehicle, suffix: "trunk"))
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)
            try await requestConfirmation(dialog: IntentDialog("Open the trunk on \(resolved.name)?"))
            try await service.runControl(
                action: "actuate_trunk",
                vin: resolved.vin,
                params: ["which_trunk": .string("rear")],
                humanName: "opening the trunk"
            )
            log.success("opened trunk on \(resolved.name)")
            return .result(dialog: IntentDialog("Opening the trunk on \(resolved.name)."))
        } catch {
            throw log.failure(error)
        }
    }
}

public struct OpenFrunkIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Open Tesla Frunk"
    public static let description = IntentDescription("Open your Tesla's front trunk. Uses your selected car when no vehicle is specified.")
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
            Summary("Open \(\.$vehicle) frunk")
        } otherwise: {
            Summary("Open my car frunk")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Open", vehicle: vehicle, suffix: "frunk"))
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)
            try await requestConfirmation(dialog: IntentDialog("Open the frunk on \(resolved.name)?"))
            try await service.runControl(
                action: "actuate_trunk",
                vin: resolved.vin,
                params: ["which_trunk": .string("front")],
                humanName: "opening the frunk"
            )
            log.success("opened frunk on \(resolved.name)")
            return .result(dialog: IntentDialog("Opening the frunk on \(resolved.name)."))
        } catch {
            throw log.failure(error)
        }
    }
}

public struct SetChargeLimitIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Set Tesla Charge Limit"
    public static let description = IntentDescription("Set your Tesla's charge limit. Uses your selected car when no vehicle is specified.")
    public static let isDiscoverable = true

    @Parameter(
        title: "Vehicle",
        description: "Your Tesla from your fleet account. Leave blank to use your selected car.",
        requestValueDialog: IntentDialog("Which car?"),
        requestDisambiguationDialog: IntentDialog("Which one?"),
        optionsProvider: SelectedVehicleOptionsProvider()
    )
    public var vehicle: VehicleEntity?

    @Parameter(title: "Charge Limit %", default: 80, inclusiveRange: (50, 100))
    public var percent: Int

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        When(\.$vehicle, .hasAnyValue) {
            Summary("Set \(\.$vehicle) charge limit to \(\.$percent)%")
        } otherwise: {
            Summary("Set my car charge limit to \(\.$percent)%")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle, \.$percent)) { vehicle, percent in
            let target = vehicle?.name ?? FleetIntentMetadata.myCar
            return DisplayRepresentation(title: LocalizedStringResource(stringLiteral: "Set \(target) charge limit to \(percent)%"))
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)
            try await requestConfirmation(dialog: IntentDialog("Set \(resolved.name)'s charge limit to \(percent)%?"))
            try await service.runControl(
                action: "set_charge_limit",
                vin: resolved.vin,
                params: ["percent": .int(percent)],
                humanName: "setting the charge limit"
            )
            log.success("charge limit \(percent)% on \(resolved.name)")
            return .result(dialog: IntentDialog("Set \(resolved.name)'s charge limit to \(percent)%."))
        } catch {
            throw log.failure(error)
        }
    }
}
