import AppIntents
import CoreSpotlight
import Foundation

/// The software-update status for a vehicle, indexed in Spotlight.
public struct SoftwareUpdateEntity: AppEntity, IndexedEntity, Identifiable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Software Update")
    public static let defaultQuery = SoftwareUpdateEntityQuery()

    public let id: String // VIN
    public let vehicleName: String
    public let currentVersion: String?
    public let availableVersion: String?
    public let updateAvailable: Bool
    public let installable: Bool
    public let status: String?
    public let downloadPercent: Int?
    public let installPercent: Int?

    public init(info: FleetSoftwareInfo, vin: String, vehicleName: String) {
        self.id = vin
        self.vehicleName = vehicleName
        self.currentVersion = info.currentVersion
        self.availableVersion = info.availableVersion
        self.updateAvailable = info.updateAvailable
        self.installable = info.installable
        self.status = info.status
        self.downloadPercent = info.downloadPercent.map { Int($0.rounded()) }
        self.installPercent = info.installPercent.map { Int($0.rounded()) }
    }

    public var headline: String {
        if updateAvailable, let availableVersion {
            return "Update available: \(availableVersion)"
        }
        if let currentVersion {
            return "Up to date: \(currentVersion)"
        }
        return "Software"
    }

    public var detailText: String {
        if let installPercent { return "Installing • \(installPercent)%" }
        if let downloadPercent { return "Downloading • \(downloadPercent)%" }
        if let status, !status.isEmpty { return status.capitalized }
        return currentVersion.map { "Current \($0)" } ?? ""
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(vehicleName) - \(headline)", subtitle: "\(detailText)")
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        var parts = [headline]
        if let currentVersion { parts.append("Current version \(currentVersion)") }
        if let availableVersion { parts.append("Available version \(availableVersion)") }
        if let status { parts.append("Status \(status)") }
        if installable { parts.append("Installable now") }
        attributes.contentDescription = "Tesla software update for \(vehicleName). \(parts.joined(separator: ". "))."
        attributes.keywords = [
            vehicleName, id, "Tesla", "software", "software update", "release", "release version",
            "version", "install", "download", "update available", currentVersion, availableVersion, status
        ].compactMap { $0 }
        return attributes
    }
}

public struct SoftwareUpdateEntityQuery: EntityQuery, IndexedEntityQuery {
    public init() {}

    public func entities(for identifiers: [SoftwareUpdateEntity.ID]) async throws -> [SoftwareUpdateEntity] {
        let service = FleetIntentService.make()
        let vehicles = try await service.vehicles()
        var results: [SoftwareUpdateEntity] = []
        for vin in identifiers {
            guard let vehicle = vehicles.first(where: { $0.vin == vin }) else { continue }
            let info = try await service.software(vin: vin)
            results.append(SoftwareUpdateEntity(info: info, vin: vin, vehicleName: vehicle.name))
        }
        return results
    }

    public func suggestedEntities() async throws -> [SoftwareUpdateEntity] {
        let service = FleetIntentService.make()
        let vehicle = try await service.resolvedVehicle(nil)
        let info = try await service.software(vin: vehicle.vin)
        return [SoftwareUpdateEntity(info: info, vin: vehicle.vin, vehicleName: vehicle.name)]
    }

    public func reindexEntities(for identifiers: [SoftwareUpdateEntity.ID], indexDescription: CSSearchableIndexDescription) async throws {
        try await FleetSpotlightIndexer.donate(entities(for: identifiers))
    }

    public func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        let service = FleetIntentService.make()
        var all: [SoftwareUpdateEntity] = []
        for vehicle in try await service.vehicles() {
            let info = try await service.software(vin: vehicle.vin)
            all.append(SoftwareUpdateEntity(info: info, vin: vehicle.vin, vehicleName: vehicle.name))
        }
        try await FleetSpotlightIndexer.donate(all)
    }
}

/// A single software release note, indexed so notes are searchable in Spotlight.
public struct ReleaseNoteEntity: AppEntity, IndexedEntity, Identifiable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Release Note")
    public static let defaultQuery = ReleaseNoteEntityQuery()

    public let id: String
    public let vin: String
    public let version: String?
    public let title: String
    public let details: String?

    public init(info: FleetReleaseNoteInfo, vin: String, version: String?) {
        self.id = [vin, version, info.id].compactMap { $0 }.joined(separator: ":")
        self.vin = vin
        self.version = version
        self.title = info.title
        self.details = info.details ?? info.subtitle
    }

    public var displayRepresentation: DisplayRepresentation {
        let subtitle = [version.map { "Version \($0)" }, details].compactMap { $0 }.joined(separator: " • ")
        return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = ["Tesla release note", version.map { "Version \($0)" }, title, details].compactMap { $0 }.joined(separator: ". ")
        attributes.keywords = ["Tesla", "release note", "release version", "software", "update", "version", vin, version, title, details].compactMap { $0 }
        return attributes
    }
}

public struct ReleaseNoteEntityQuery: EntityQuery, IndexedEntityQuery {
    public init() {}

    public func entities(for identifiers: [ReleaseNoteEntity.ID]) async throws -> [ReleaseNoteEntity] {
        try await allReleaseNotes().filter { identifiers.contains($0.id) }
    }

    public func suggestedEntities() async throws -> [ReleaseNoteEntity] {
        let service = FleetIntentService.make()
        let vehicle = try await service.resolvedVehicle(nil)
        let info = try await service.software(vin: vehicle.vin)
        return info.releaseNotes.map { ReleaseNoteEntity(info: $0, vin: vehicle.vin, version: info.availableVersion ?? info.currentVersion) }
    }

    public func reindexEntities(for identifiers: [ReleaseNoteEntity.ID], indexDescription: CSSearchableIndexDescription) async throws {
        try await FleetSpotlightIndexer.donate(entities(for: identifiers))
    }

    public func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await FleetSpotlightIndexer.donate(allReleaseNotes())
    }

    private func allReleaseNotes() async throws -> [ReleaseNoteEntity] {
        let service = FleetIntentService.make()
        var all: [ReleaseNoteEntity] = []
        for vehicle in try await service.vehicles() {
            let info = try await service.software(vin: vehicle.vin)
            all.append(contentsOf: info.releaseNotes.map { ReleaseNoteEntity(info: $0, vin: vehicle.vin, version: info.availableVersion ?? info.currentVersion) })
        }
        return all
    }
}
