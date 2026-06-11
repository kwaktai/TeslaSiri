import AppIntents

/// A Tesla on the account, used as the optional vehicle parameter on
/// VIN-scoped intents so Siri/Shortcuts can disambiguate.
public struct VehicleEntity: AppEntity, IndexedEntity, Identifiable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Vehicle")
    public static let defaultQuery = VehicleEntityQuery()

    /// VIN.
    public let id: String
    public let name: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public init(info: FleetVehicleInfo) {
        self.id = info.vin
        self.name = info.name
    }
}

/// The vehicle list is small, so an enumerable query is the simplest fit and
/// also powers suggestions in the Shortcuts editor.
public struct VehicleEntityQuery: EnumerableEntityQuery {
    public init() {}

    public func allEntities() async throws -> [VehicleEntity] {
        try await FleetIntentService.make().vehicles().map(VehicleEntity.init(info:))
    }

    public func entities(for identifiers: [VehicleEntity.ID]) async throws -> [VehicleEntity] {
        try await allEntities().filter { identifiers.contains($0.id) }
    }
}
