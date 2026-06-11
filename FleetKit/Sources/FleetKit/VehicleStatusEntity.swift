import AppIntents

/// A point-in-time, human-readable status snapshot for a vehicle. Conforms to
/// `IndexedEntity` so it can be surfaced in Spotlight.
public struct VehicleStatusEntity: AppEntity, IndexedEntity, Identifiable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Vehicle Status")
    public static let defaultQuery = VehicleStatusEntityQuery()

    /// VIN — one current-status entity per vehicle.
    public let id: String
    public let vehicleName: String
    public let batteryPercent: Int?
    public let chargeLimitPercent: Int?
    public let chargingState: String?
    public let isLocked: Bool?

    public init(snapshot: FleetSnapshotInfo, vehicleName: String) {
        self.id = snapshot.vin
        self.vehicleName = vehicleName
        self.batteryPercent = snapshot.batteryLevel.map { Int($0.rounded()) }
        self.chargeLimitPercent = snapshot.chargeLimitSOC.map { Int($0.rounded()) }
        self.chargingState = snapshot.chargingState
        self.isLocked = snapshot.locked
    }

    public var batteryDisplay: String {
        batteryPercent.map { "\($0)%" } ?? "—"
    }

    public var statusSummary: String {
        var parts: [String] = []
        if let chargingState, !chargingState.isEmpty {
            parts.append(chargingState.capitalized)
        }
        if let isLocked {
            parts.append(isLocked ? "Locked" : "Unlocked")
        }
        return parts.isEmpty ? "Battery \(batteryDisplay)" : "\(batteryDisplay) • \(parts.joined(separator: " • "))"
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(vehicleName)", subtitle: "\(statusSummary)")
    }
}

public struct VehicleStatusEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [VehicleStatusEntity.ID]) async throws -> [VehicleStatusEntity] {
        let service = FleetIntentService.make()
        let vehicles = try await service.vehicles()
        var results: [VehicleStatusEntity] = []
        for vin in identifiers {
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
}
