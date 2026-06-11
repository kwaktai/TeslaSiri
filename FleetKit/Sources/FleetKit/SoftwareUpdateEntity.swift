import AppIntents

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
        DisplayRepresentation(title: "\(vehicleName) — \(headline)", subtitle: "\(detailText)")
    }
}

public struct SoftwareUpdateEntityQuery: EntityQuery {
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
}

/// A single software release note, indexed so notes are searchable in Spotlight.
public struct ReleaseNoteEntity: AppEntity, IndexedEntity, Identifiable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Release Note")
    public static let defaultQuery = ReleaseNoteEntityQuery()

    public let id: String
    public let title: String
    public let details: String?

    public init(info: FleetReleaseNoteInfo) {
        self.id = info.id
        self.title = info.title
        self.details = info.details ?? info.subtitle
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(details ?? "")")
    }
}

public struct ReleaseNoteEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [ReleaseNoteEntity.ID]) async throws -> [ReleaseNoteEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    public func suggestedEntities() async throws -> [ReleaseNoteEntity] {
        let service = FleetIntentService.make()
        let vehicle = try await service.resolvedVehicle(nil)
        return try await service.software(vin: vehicle.vin).releaseNotes.map(ReleaseNoteEntity.init(info:))
    }
}
