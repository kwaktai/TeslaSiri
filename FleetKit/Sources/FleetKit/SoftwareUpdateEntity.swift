import AppIntents
import CoreSpotlight
import Foundation

/// The software-update status for a vehicle, indexed in Spotlight.
public struct SoftwareUpdateEntity: AppEntity, IndexedEntity, Identifiable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Software Update")
    public static let defaultQuery = SoftwareUpdateEntityQuery()

    /// "software:<VIN>" — namespaced so it can't collide with other VIN-keyed
    /// entity types in the shared Spotlight index, where the identifier is the
    /// primary key and collisions overwrite.
    public let id: String
    public let vin: String
    public let vehicleName: String
    public let currentVersion: String?
    public let availableVersion: String?
    public let updateAvailable: Bool
    public let installable: Bool
    public let status: String?
    public let downloadPercent: Int?
    public let installPercent: Int?

    public init(info: FleetSoftwareInfo, vin: String, vehicleName: String) {
        self.id = Self.entityID(forVIN: vin)
        self.vin = vin
        self.vehicleName = vehicleName
        self.currentVersion = info.currentVersion
        self.availableVersion = info.availableVersion
        self.updateAvailable = info.updateAvailable
        self.installable = info.installable
        self.status = info.status
        self.downloadPercent = info.downloadPercent.map { Int($0.rounded()) }
        self.installPercent = info.installPercent.map { Int($0.rounded()) }
    }

    public static func entityID(forVIN vin: String) -> String {
        "software:\(vin)"
    }

    /// Accepts bare VINs too so identifiers saved before namespacing still resolve.
    public static func vin(fromEntityID id: String) -> String {
        id.hasPrefix("software:") ? String(id.dropFirst("software:".count)) : id
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
        let description = "Tesla software update for \(vehicleName). \(parts.joined(separator: ". "))."
        attributes.title = "\(vehicleName) Software"
        attributes.displayName = "\(vehicleName) software update"
        attributes.kind = "Tesla Software Update"
        attributes.contentDescription = description
        attributes.textContent = description
        attributes.keywords = [
            vehicleName, FleetKitLog.vin(vin), "Tesla", "software", "software update", "release", "release version",
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
        for identifier in identifiers {
            let vin = SoftwareUpdateEntity.vin(fromEntityID: identifier)
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
        self.id = Self.entityID(forVIN: vin, version: version, noteID: info.id)
        self.vin = vin
        self.version = version
        self.title = info.title
        self.details = info.details ?? info.subtitle
    }

    public static func entityID(forVIN vin: String, version: String?, noteID: String) -> String {
        [vin, version, noteID].compactMap { $0 }.joined(separator: ":")
    }

    public var displayRepresentation: DisplayRepresentation {
        let subtitle = [version.map { "Version \($0)" }, details].compactMap { $0 }.joined(separator: " • ")
        return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        let description = ["Tesla release note", version.map { "Version \($0)" }, title, details].compactMap { $0 }.joined(separator: ". ")
        attributes.title = title
        attributes.displayName = version.map { "\(title) \($0)" } ?? title
        attributes.kind = "Tesla Release Note"
        attributes.contentDescription = description
        attributes.textContent = description
        attributes.keywords = ["Tesla", "release note", "release version", "software", "update", "version", FleetKitLog.vin(vin), version, title, details].compactMap { $0 }
        return attributes
    }
}

public struct ReleaseNoteEntityQuery: EntityQuery, IndexedEntityQuery {
    private let service: FleetIntentService

    public init() {
        self.init(service: .make())
    }

    init(service: FleetIntentService) {
        self.service = service
    }

    public func entities(for identifiers: [ReleaseNoteEntity.ID]) async throws -> [ReleaseNoteEntity] {
        guard !identifiers.isEmpty else { return [] }
        let authorizedVINs = Set(try await service.vehicles().map(\.vin))
        var versionsByVIN: [String: Set<String>] = [:]
        for identifier in identifiers {
            let parts = identifier.split(separator: ":", maxSplits: 2)
            guard parts.count == 3, authorizedVINs.contains(String(parts[0])) else { continue }
            versionsByVIN[String(parts[0]), default: []].insert(String(parts[1]))
        }

        var notesByID: [ReleaseNoteEntity.ID: ReleaseNoteEntity] = [:]
        for (vin, versions) in versionsByVIN {
            for version in versions {
                for note in try await service.releaseNotes(vin: vin, version: version) {
                    let entity = ReleaseNoteEntity(info: note, vin: vin, version: version)
                    notesByID[entity.id] = entity
                }
            }
        }
        return identifiers.compactMap { notesByID[$0] }
    }

    public func suggestedEntities() async throws -> [ReleaseNoteEntity] {
        let vehicle = try await service.resolvedVehicle(nil)
        return try await latestReleaseNotes(vin: vehicle.vin)
    }

    public func reindexEntities(for identifiers: [ReleaseNoteEntity.ID], indexDescription: CSSearchableIndexDescription) async throws {
        try await FleetSpotlightIndexer.donate(entities(for: identifiers))
    }

    public func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await FleetSpotlightIndexer.donate(allReleaseNotes())
    }

    private func allReleaseNotes() async throws -> [ReleaseNoteEntity] {
        var all: [ReleaseNoteEntity] = []
        for vehicle in try await service.vehicles() {
            all.append(contentsOf: try await latestReleaseNotes(vin: vehicle.vin))
        }
        return all
    }

    private func latestReleaseNotes(vin: String) async throws -> [ReleaseNoteEntity] {
        let software = try await service.software(vin: vin)
        guard let version = software.availableVersion ?? software.currentVersion else { return [] }
        return try await service.releaseNotes(vin: vin, version: version)
            .map { ReleaseNoteEntity(info: $0, vin: vin, version: version) }
    }
}
