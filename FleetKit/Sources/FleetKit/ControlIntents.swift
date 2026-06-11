import AppIntents

// Control intents map to backend-advertised action names via `runControl`.
// `FleetIntentService.runControl` validates the action against the live
// `controlActions()` list and throws a friendly error if unsupported.
//
// Confirmation policy: unlock, trunk, frunk, and charge-limit changes prompt
// for confirmation; lock, climate, and vent run immediately.

public struct LockVehicleIntent: AppIntent {
    public static let title: LocalizedStringResource = "Lock Tesla"
    public static let description = IntentDescription("Lock your Tesla.")
    public static let isDiscoverable = true

    @Parameter(title: "Vehicle") public var vehicle: VehicleEntity?
    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = FleetIntentService.make()
        let resolved = try await service.resolvedVehicle(vehicle?.id)
        try await service.runControl(action: "door_lock", vin: resolved.vin, humanName: "locking")
        return .result(dialog: IntentDialog("Locked \(resolved.name)."))
    }
}

public struct UnlockVehicleIntent: AppIntent {
    public static let title: LocalizedStringResource = "Unlock Tesla"
    public static let description = IntentDescription("Unlock your Tesla.")

    @Parameter(title: "Vehicle") public var vehicle: VehicleEntity?
    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = FleetIntentService.make()
        let resolved = try await service.resolvedVehicle(vehicle?.id)
        try await requestConfirmation(dialog: IntentDialog("Unlock \(resolved.name)?"))
        try await service.runControl(action: "door_unlock", vin: resolved.vin, humanName: "unlocking")
        return .result(dialog: IntentDialog("Unlocked \(resolved.name)."))
    }
}

public struct StartClimateIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Tesla Climate"
    public static let description = IntentDescription("Turn on climate control in your Tesla.")

    @Parameter(title: "Vehicle") public var vehicle: VehicleEntity?
    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = FleetIntentService.make()
        let resolved = try await service.resolvedVehicle(vehicle?.id)
        try await service.runControl(action: "auto_conditioning_start", vin: resolved.vin, humanName: "starting climate")
        return .result(dialog: IntentDialog("Climate is starting in \(resolved.name)."))
    }
}

public struct VentWindowsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Vent Tesla Windows"
    public static let description = IntentDescription("Vent your Tesla's windows.")

    @Parameter(title: "Vehicle") public var vehicle: VehicleEntity?
    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = FleetIntentService.make()
        let resolved = try await service.resolvedVehicle(vehicle?.id)
        try await service.runControl(
            action: "window_control",
            vin: resolved.vin,
            params: ["command": .string("vent")],
            humanName: "venting the windows"
        )
        return .result(dialog: IntentDialog("Venting \(resolved.name)'s windows."))
    }
}

public struct OpenTrunkIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Tesla Trunk"
    public static let description = IntentDescription("Open (or close) your Tesla's rear trunk.")

    @Parameter(title: "Vehicle") public var vehicle: VehicleEntity?
    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = FleetIntentService.make()
        let resolved = try await service.resolvedVehicle(vehicle?.id)
        try await requestConfirmation(dialog: IntentDialog("Open the trunk on \(resolved.name)?"))
        try await service.runControl(
            action: "actuate_trunk",
            vin: resolved.vin,
            params: ["which_trunk": .string("rear")],
            humanName: "opening the trunk"
        )
        return .result(dialog: IntentDialog("Opening the trunk on \(resolved.name)."))
    }
}

public struct OpenFrunkIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Tesla Frunk"
    public static let description = IntentDescription("Open your Tesla's front trunk.")

    @Parameter(title: "Vehicle") public var vehicle: VehicleEntity?
    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = FleetIntentService.make()
        let resolved = try await service.resolvedVehicle(vehicle?.id)
        try await requestConfirmation(dialog: IntentDialog("Open the frunk on \(resolved.name)?"))
        try await service.runControl(
            action: "actuate_trunk",
            vin: resolved.vin,
            params: ["which_trunk": .string("front")],
            humanName: "opening the frunk"
        )
        return .result(dialog: IntentDialog("Opening the frunk on \(resolved.name)."))
    }
}

public struct SetChargeLimitIntent: AppIntent {
    public static let title: LocalizedStringResource = "Set Tesla Charge Limit"
    public static let description = IntentDescription("Set your Tesla's charge limit percentage.")

    @Parameter(title: "Vehicle") public var vehicle: VehicleEntity?

    @Parameter(title: "Charge Limit %", default: 80, inclusiveRange: (50, 100))
    public var percent: Int

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = FleetIntentService.make()
        let resolved = try await service.resolvedVehicle(vehicle?.id)
        try await requestConfirmation(dialog: IntentDialog("Set \(resolved.name)'s charge limit to \(percent)%?"))
        try await service.runControl(
            action: "set_charge_limit",
            vin: resolved.vin,
            params: ["percent": .int(percent)],
            humanName: "setting the charge limit"
        )
        return .result(dialog: IntentDialog("Set \(resolved.name)'s charge limit to \(percent)%."))
    }
}
