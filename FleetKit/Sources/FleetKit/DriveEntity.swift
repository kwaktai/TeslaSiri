import AppIntents
import Foundation

/// A completed drive. Indexed in Spotlight via its display representation
/// (distance, date, and start/end addresses are all searchable text).
public struct DriveEntity: AppEntity, IndexedEntity, Identifiable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Drive")
    public static let defaultQuery = DriveEntityQuery()

    public let id: String // sessionID
    public let vin: String
    public let distanceMiles: Double?
    public let durationMinutes: Int?
    public let avgSpeedMPH: Double?
    public let startAddress: String?
    public let endAddress: String?
    public let startedAt: Date
    public let endedAt: Date?

    public init(info: FleetDriveInfo) {
        self.id = info.sessionID
        self.vin = info.vin
        self.distanceMiles = info.distanceMiles
        self.durationMinutes = info.durationMS.map { Int($0 / 60_000) }
        self.avgSpeedMPH = info.avgSpeedMPH
        self.startAddress = info.startAddress
        self.endAddress = info.endAddress
        self.startedAt = info.startedAtDate
        self.endedAt = info.endedAtDate
    }

    public var distanceText: String {
        distanceMiles.map { String(format: "%.1f mi", $0) } ?? "Drive"
    }

    public var routeText: String {
        if let startAddress, let endAddress {
            return "\(startAddress) → \(endAddress)"
        }
        return startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    public var displayRepresentation: DisplayRepresentation {
        let date = startedAt.formatted(date: .abbreviated, time: .shortened)
        return DisplayRepresentation(title: "\(distanceText) • \(date)", subtitle: "\(routeText)")
    }
}

public struct DriveEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [DriveEntity.ID]) async throws -> [DriveEntity] {
        let service = FleetIntentService.make()
        let vehicle = try await service.resolvedVehicle(nil)
        let drives = try await service.drives(vin: vehicle.vin, limit: 50)
        return drives.filter { identifiers.contains($0.sessionID) }.map(DriveEntity.init(info:))
    }

    public func suggestedEntities() async throws -> [DriveEntity] {
        let service = FleetIntentService.make()
        let vehicle = try await service.resolvedVehicle(nil)
        return try await service.drives(vin: vehicle.vin, limit: 10).map(DriveEntity.init(info:))
    }
}
