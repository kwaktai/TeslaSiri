import AppIntents
import CoreSpotlight
import Foundation
import OSLog

/// A completed drive. Indexed in Spotlight with distance, duration, speed,
/// energy, date, and start/end locations.
public struct DriveEntity: AppEntity, IndexedEntity, Identifiable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Drive")
    public static let defaultQuery = DriveEntityQuery()

    public let id: String // sessionID
    public let vin: String
    public let distanceMiles: Double?
    public let durationMinutes: Int?
    public let avgSpeedMPH: Double?
    public let maxSpeedMPH: Double?
    public let energyUsedKWH: Double?
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
        self.maxSpeedMPH = info.maxSpeedMPH
        self.energyUsedKWH = info.energyUsedKWH
        self.startAddress = info.startAddress
        self.endAddress = info.endAddress
        self.startedAt = info.startedAtDate
        self.endedAt = info.endedAtDate
    }

    public var distanceText: String {
        distanceMiles.map { String(format: "%.1f mi", $0) } ?? "Drive"
    }

    public var durationText: String? {
        durationMinutes.map { "\($0) min" }
    }

    public var routeText: String {
        if let startAddress, let endAddress {
            return "\(startAddress) to \(endAddress)"
        }
        if let startAddress { return "Started at \(startAddress)" }
        if let endAddress { return "Ended at \(endAddress)" }
        return startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    public var detailText: String {
        var parts: [String] = [routeText]
        if let durationText { parts.append(durationText) }
        if let avgSpeedMPH { parts.append("avg \(Int(avgSpeedMPH.rounded())) mph") }
        if let maxSpeedMPH { parts.append("max \(Int(maxSpeedMPH.rounded())) mph") }
        if let energyUsedKWH { parts.append(String(format: "%.1f kWh", energyUsedKWH)) }
        return parts.joined(separator: " • ")
    }

    public var displayRepresentation: DisplayRepresentation {
        let date = startedAt.formatted(date: .abbreviated, time: .shortened)
        return DisplayRepresentation(title: "\(distanceText) • \(date)", subtitle: "\(detailText)")
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentCreationDate = startedAt
        attributes.contentModificationDate = endedAt ?? startedAt
        attributes.contentDescription = "Tesla drive for VIN \(vin). \(distanceText). \(detailText)."
        attributes.keywords = [
            "Tesla", "drive", "trip", "route", "miles", "mileage", "distance", "duration",
            "time", "average speed", "avg speed", "max speed", "energy", "kWh", vin,
            startAddress, endAddress
        ].compactMap { $0 }
        return attributes
    }
}

public struct DriveEntityQuery: EntityQuery, IndexedEntityQuery {
    public init() {}

    public func entities(for identifiers: [DriveEntity.ID]) async throws -> [DriveEntity] {
        guard !identifiers.isEmpty else { return [] }

        let service = FleetIntentService.make()
        let vehicles = try await service.vehicles()
        var remaining = Set(identifiers)
        var found: [DriveEntity] = []

        for vehicle in vehicles where !remaining.isEmpty {
            let drives = try await service.drives(vin: vehicle.vin, limit: 50)
            for drive in drives where remaining.contains(drive.sessionID) {
                found.append(DriveEntity(info: drive))
                remaining.remove(drive.sessionID)
            }
        }

        FleetKitLog.entities.info("DriveEntityQuery matched \(found.count, privacy: .public) of \(identifiers.count, privacy: .public) requested drive(s)")
        return found
    }

    public func suggestedEntities() async throws -> [DriveEntity] {
        let service = FleetIntentService.make()
        let vehicle = try await service.resolvedVehicle(nil)
        let drives = try await service.drives(vin: vehicle.vin, limit: 10).map(DriveEntity.init(info:))
        FleetKitLog.entities.info("DriveEntityQuery suggesting \(drives.count, privacy: .public) drive(s) for \(vehicle.name, privacy: .public)")
        return drives
    }

    public func reindexEntities(for identifiers: [DriveEntity.ID], indexDescription: CSSearchableIndexDescription) async throws {
        try await FleetSpotlightIndexer.donate(entities(for: identifiers))
    }

    public func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        let service = FleetIntentService.make()
        var all: [DriveEntity] = []
        for vehicle in try await service.vehicles() {
            all.append(contentsOf: try await service.drives(vin: vehicle.vin, limit: 50).map(DriveEntity.init(info:)))
        }
        try await FleetSpotlightIndexer.donate(all)
    }
}
