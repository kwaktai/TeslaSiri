import AppIntents
import CoreSpotlight
import OSLog

/// A Tesla on the account, used as the optional vehicle parameter on
/// VIN-scoped intents so Siri/Shortcuts can disambiguate.
public struct VehicleEntity: AppEntity, IndexedEntity, SyncableEntity, Identifiable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Vehicle",
        synonyms: ["Car", "Tesla", "EV", "Electric Car"]
    )
    public static let defaultQuery = VehicleEntityQuery()

    /// Full vehicle identification number (VIN).
    public let id: String

    @Property(
        title: "Vehicle Name",
        description: "The name the owner gave this car in the Tesla app, such as \"Midnight\". Use it to tell the user's cars apart.",
        indexingKey: \.title
    )
    public var name: String

    @Property(
        title: "Model",
        description: "The car's model, such as Model 3, Model Y, Model S, Model X, or Cybertruck. Empty if Tessie hasn't reported it.",
        indexingKey: \.kind
    )
    public var model: String?

    @Property(
        title: "Paint Color",
        description: "The car's exterior paint, such as Pearl White or Midnight Silver Metallic. Empty if unknown."
    )
    public var color: String?

    public var displayRepresentation: DisplayRepresentation {
        let subtitle = [model, color].compactMap { $0 }.joined(separator: " · ")
        var entitySynonyms: [LocalizedStringResource] = [
            "my car",
            "the car",
            "car",
            "my vehicle",
            "my Tesla",
            "Tesla"
        ]
        if let model, !model.isEmpty {
            entitySynonyms.append(LocalizedStringResource(stringLiteral: model))
            entitySynonyms.append(LocalizedStringResource(stringLiteral: "my \(model)"))
        }
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: subtitle.isEmpty ? "Tesla" : "\(subtitle)",
            synonyms: entitySynonyms
        )
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        let modelText = model ?? "Tesla"
        let description = "My car (\(modelText) named \(name)). Ask Siri for its battery, range, tire pressure, mileage, climate, drives, charging history, or software updates, or to lock, unlock, warm up my car, cool down my car, precondition, defrost, or send it a destination."
        attributes.title = name
        attributes.displayName = name
        attributes.alternateNames = ["My Car", "The Car", "My Vehicle", "My Tesla", "Tesla", model].compactMap { $0 }
        attributes.kind = model ?? "Tesla Vehicle"
        attributes.contentDescription = description
        attributes.textContent = description
        attributes.keywords = [
            "car", "my car", "the car", "vehicle", "my vehicle", "electric car", "EV", "Tesla",
            name, model, color,
            "warm up", "warm up my car", "cool down", "cool down my car", "precondition", "defrost",
            "heat", "AC", "air conditioning", "climate",
            "battery", "range", "mileage", "odometer", "tire pressure",
            "drive", "charging", "software", "release notes", "lock", "lock my car", "unlock", "unlock my car",
            "navigation"
        ].compactMap { $0 }
        return attributes
    }

    public init(id: String, name: String, model: String? = nil, color: String? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.color = color
    }

    public init(info: FleetVehicleInfo) {
        self.id = info.vin
        self.name = info.name
        self.model = info.modelName
        self.color = info.colorName
    }
}

/// The vehicle list is small, so an enumerable + string query powers both
/// Shortcuts suggestions and natural-language Siri AI lookups like "my car".
public struct VehicleEntityQuery: EnumerableEntityQuery, EntityStringQuery, IndexedEntityQuery {
    private static let genericCarTerms: Set<String> = [
        "car", "my car", "the car", "our car",
        "vehicle", "my vehicle", "the vehicle",
        "ev", "my ev", "electric car", "electric vehicle",
        "auto", "automobile", "suv", "sedan", "truck",
        "tesla", "my tesla", "the tesla"
    ]

    public init() {}

    public func allEntities() async throws -> [VehicleEntity] {
        let selectedVIN = FleetSharedTokenStore.shared.selectedVIN()
        let vehicles = try await FleetIntentService.make().vehicles()
        let ordered = vehicles.sorted { lhs, rhs in
            if lhs.vin == selectedVIN { return true }
            if rhs.vin == selectedVIN { return false }
            return false
        }
        let entities = ordered.map(VehicleEntity.init(info:))
        FleetKitLog.entities.info("VehicleEntityQuery.allEntities returned \(entities.count, privacy: .public) vehicle(s)")
        return entities
    }

    public func entities(for identifiers: [VehicleEntity.ID]) async throws -> [VehicleEntity] {
        let matches = try await allEntities().filter { identifiers.contains($0.id) }
        FleetKitLog.entities.info("VehicleEntityQuery matched \(matches.count, privacy: .public) of \(identifiers.count, privacy: .public) requested vehicle(s)")
        return matches
    }

    public func entities(matching string: String) async throws -> [VehicleEntity] {
        let all = try await allEntities()
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !Self.genericCarTerms.contains(trimmed) else {
            return all
        }

        let directMatches = all.filter { entity in
            entity.name.localizedStandardContains(trimmed)
                || (entity.model?.localizedStandardContains(trimmed) == true)
                || (entity.color?.localizedStandardContains(trimmed) == true)
        }
        if !directMatches.isEmpty {
            return directMatches
        }

        if trimmed.contains("car") || trimmed.contains("vehicle") || trimmed.contains("tesla") {
            return all
        }
        return []
    }

    public func reindexEntities(for identifiers: [VehicleEntity.ID], indexDescription: CSSearchableIndexDescription) async throws {
        try await FleetSpotlightIndexer.donate(entities(for: identifiers))
    }

    public func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await FleetSpotlightIndexer.donate(allEntities())
    }
}

