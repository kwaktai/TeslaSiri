import AppIntents
import CoreSpotlight
import Foundation

/// A point-in-time, human-readable status snapshot for a vehicle. Conforms to
/// `IndexedEntity` so it can be surfaced in Spotlight.
public struct VehicleStatusEntity: AppEntity, IndexedEntity, Identifiable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Vehicle Status")
    public static let defaultQuery = VehicleStatusEntityQuery()

    /// "status:<VIN>" — one current-status entity per vehicle. Namespaced so it
    /// can't collide with other VIN-keyed entity types in the shared Spotlight
    /// index, where the identifier is the primary key and collisions overwrite.
    public let id: String
    public let vin: String
    public let vehicleName: String
    public let batteryPercent: Int?
    public let chargeLimitPercent: Int?
    public let chargingState: String?
    public let isLocked: Bool?
    public let odometerMiles: Double?
    public let speedMPH: Double?
    public let insideTemp: Double?
    public let outsideTemp: Double?
    public let latitude: Double?
    public let longitude: Double?
    public let tireSummary: String?
    public let updatedAt: Date?

    public init(snapshot: FleetSnapshotInfo, vehicleName: String) {
        self.id = Self.entityID(forVIN: snapshot.vin)
        self.vin = snapshot.vin
        self.vehicleName = vehicleName
        self.batteryPercent = snapshot.batteryLevel.map { Int($0.rounded()) }
        self.chargeLimitPercent = snapshot.chargeLimitSOC.map { Int($0.rounded()) }
        self.chargingState = snapshot.chargingState
        self.isLocked = snapshot.locked
        self.odometerMiles = snapshot.odometer
        self.speedMPH = snapshot.speed
        self.insideTemp = snapshot.insideTemp
        self.outsideTemp = snapshot.outsideTemp
        self.latitude = snapshot.latitude
        self.longitude = snapshot.longitude
        self.tireSummary = snapshot.tires?.displaySummary
        self.updatedAt = snapshot.updatedAtDate
    }

    public static func entityID(forVIN vin: String) -> String {
        "status:\(vin)"
    }

    /// Accepts bare VINs too so identifiers saved before namespacing still resolve.
    public static func vin(fromEntityID id: String) -> String {
        id.hasPrefix("status:") ? String(id.dropFirst("status:".count)) : id
    }

    public var batteryDisplay: String {
        batteryPercent.map { "\($0)%" } ?? "unknown battery"
    }

    public var odometerDisplay: String? {
        odometerMiles.map { "\(Int($0.rounded())) mi" }
    }

    public var statusSummary: String {
        var parts: [String] = []
        parts.append("Battery \(batteryDisplay)")
        if let chargingState, !chargingState.isEmpty {
            parts.append(chargingState.capitalized)
        }
        if let isLocked {
            parts.append(isLocked ? "Locked" : "Unlocked")
        }
        if let odometerDisplay {
            parts.append("Odometer \(odometerDisplay)")
        }
        if let tireSummary {
            parts.append("Tires \(tireSummary)")
        }
        return parts.joined(separator: " • ")
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(vehicleName) Status", subtitle: "\(statusSummary)")
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        var descriptionParts = [statusSummary]
        if let chargeLimitPercent { descriptionParts.append("Charge limit \(chargeLimitPercent)%") }
        if let speedMPH { descriptionParts.append("Speed \(Int(speedMPH.rounded())) mph") }
        if let insideTemp { descriptionParts.append("Cabin \(Int(insideTemp.rounded())) degrees") }
        if let outsideTemp { descriptionParts.append("Outside \(Int(outsideTemp.rounded())) degrees") }
        if let updatedAt { descriptionParts.append("Updated \(updatedAt.formatted(date: .abbreviated, time: .shortened))") }
        attributes.contentDescription = descriptionParts.joined(separator: ". ")
        attributes.keywords = [
            vehicleName, vin, "Tesla", "vehicle status", "battery", "charge", "charging",
            "lock", "unlock", "locked", "unlocked", "mileage", "odometer", "miles",
            "tire", "tires", "tire pressure", "PSI", "climate", "temperature", "location"
        ]
        if let latitude, let longitude {
            attributes.latitude = NSNumber(value: latitude)
            attributes.longitude = NSNumber(value: longitude)
            attributes.supportsNavigation = NSNumber(value: true)
            attributes.namedLocation = "\(vehicleName) location"
        }
        return attributes
    }
}

public struct VehicleStatusEntityQuery: EntityQuery, IndexedEntityQuery {
    public init() {}

    public func entities(for identifiers: [VehicleStatusEntity.ID]) async throws -> [VehicleStatusEntity] {
        let service = FleetIntentService.make()
        let vehicles = try await service.vehicles()
        var results: [VehicleStatusEntity] = []
        for identifier in identifiers {
            let vin = VehicleStatusEntity.vin(fromEntityID: identifier)
            guard let vehicle = vehicles.first(where: { $0.vin == vin }) else { continue }
            let snapshot = try await service.snapshot(vin: vin)
            results.append(VehicleStatusEntity(snapshot: snapshot, vehicleName: vehicle.name))
        }
        return results
    }

    public func suggestedEntities() async throws -> [VehicleStatusEntity] {
        let service = FleetIntentService.make()
        var results: [VehicleStatusEntity] = []
        for vehicle in try await service.vehicles() {
            let snapshot = try await service.snapshot(vin: vehicle.vin)
            results.append(VehicleStatusEntity(snapshot: snapshot, vehicleName: vehicle.name))
        }
        return results
    }

    public func reindexEntities(for identifiers: [VehicleStatusEntity.ID], indexDescription: CSSearchableIndexDescription) async throws {
        try await FleetSpotlightIndexer.donate(entities(for: identifiers))
    }

    public func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await FleetSpotlightIndexer.donate(suggestedEntities())
    }
}
