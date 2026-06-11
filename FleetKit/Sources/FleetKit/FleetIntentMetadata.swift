import AppIntents

/// Shared copy and helpers for vehicle-scoped App Intent metadata.
enum FleetIntentMetadata {
    static let vehicleParameterTitle: LocalizedStringResource = "Vehicle"
    static let vehicleParameterDescription: LocalizedStringResource =
        "Your Tesla from your fleet account. Leave blank to use your selected car."
    static let vehicleRequestDialog = IntentDialog("Which car?")
    static let vehicleDisambiguationDialog = IntentDialog("Which one?")
    static let myCar = "my car"
}

/// Loads vehicles from the Fleet API for App Shortcut parameter pickers and
/// defaults to the app’s currently selected VIN.
public struct SelectedVehicleOptionsProvider: DynamicOptionsProvider {
    public init() {}

    public func results() async throws -> [VehicleEntity] {
        try await FleetIntentService.make().vehicles().map(VehicleEntity.init(info:))
    }

    public func defaultResult() async -> VehicleEntity? {
        let service = FleetIntentService.make()
        guard let vehicles = try? await service.vehicles(), !vehicles.isEmpty else {
            return nil
        }
        if let vin = FleetSharedTokenStore.shared.selectedVIN(),
           let match = vehicles.first(where: { $0.vin == vin }) {
            return VehicleEntity(info: match)
        }
        return VehicleEntity(info: vehicles[0])
    }
}

extension VehicleEntity {
    /// Siri/Shortcuts label for proactive suggestions when a vehicle is optional.
    static func predictionTitle(verb: String, vehicle: VehicleEntity?) -> LocalizedStringResource {
        if let vehicle {
            return LocalizedStringResource(stringLiteral: "\(verb) \(vehicle.name)")
        }
        return LocalizedStringResource(stringLiteral: "\(verb) \(FleetIntentMetadata.myCar)")
    }

    static func predictionTitle(verb: String, vehicle: VehicleEntity?, suffix: String) -> LocalizedStringResource {
        if let vehicle {
            return LocalizedStringResource(stringLiteral: "\(verb) \(vehicle.name) \(suffix)")
        }
        return LocalizedStringResource(stringLiteral: "\(verb) my car \(suffix)")
    }
}
