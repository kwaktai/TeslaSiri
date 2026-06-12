import AppIntents
import CoreSpotlight
import Foundation

/// A submitted entity group for Diagnostics. This is our durable view of what
/// the app asked Spotlight to journal; Spotlight does not expose a public
/// "fully visible everywhere" completion signal.
public struct FleetSpotlightSubmittedGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let count: Int
    public let sampleTitles: [String]

    public init(name: String, count: Int, sampleTitles: [String]) {
        self.id = name
        self.name = name
        self.count = count
        self.sampleTitles = sampleTitles
    }
}

public struct FleetSpotlightIndexingReport: Sendable {
    public let indexName: String
    public let submittedAt: Date
    public let groups: [FleetSpotlightSubmittedGroup]
    public let errors: [String]

    public var submittedCount: Int { groups.reduce(0) { $0 + $1.count } }
    public var succeeded: Bool { errors.isEmpty }

    public init(indexName: String, submittedAt: Date, groups: [FleetSpotlightSubmittedGroup], errors: [String]) {
        self.indexName = indexName
        self.submittedAt = submittedAt
        self.groups = groups
        self.errors = errors
    }
}

public struct FleetSpotlightSearchResult: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let contentDescription: String?
    public let keywords: [String]
    public let domainIdentifier: String?

    public init(
        id: String,
        title: String,
        subtitle: String?,
        contentDescription: String?,
        keywords: [String],
        domainIdentifier: String?
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.contentDescription = contentDescription
        self.keywords = keywords
        self.domainIdentifier = domainIdentifier
    }
}

/// Donates the app's entities to a named Spotlight index so vehicles, live
/// status, drives, software, and release notes are findable in Spotlight search.
public enum FleetSpotlightIndexer {
    public static let indexName = "FleetEntities"

    public static func reindexAll() async -> FleetSpotlightIndexingReport {
        let submittedAt = Date()
        let service = FleetIntentService.make()
        var groups: [FleetSpotlightSubmittedGroup] = []
        var errors: [String] = []

        do {
            let vehicles = try await service.vehicles()
            guard !vehicles.isEmpty else {
                return FleetSpotlightIndexingReport(indexName: indexName, submittedAt: submittedAt, groups: [], errors: ["No vehicles returned from the Fleet backend."])
            }

            let vehicleEntities = vehicles.map(VehicleEntity.init(info:))
            await index(vehicleEntities, groupName: "Vehicles", groups: &groups, errors: &errors)

            var statuses: [VehicleStatusEntity] = []
            var drives: [DriveEntity] = []
            var software: [SoftwareUpdateEntity] = []
            var notes: [ReleaseNoteEntity] = []

            for vehicle in vehicles {
                do {
                    let snapshot = try await service.snapshot(vin: vehicle.vin)
                    statuses.append(VehicleStatusEntity(snapshot: snapshot, vehicleName: vehicle.name))
                } catch {
                    errors.append("Status for \(vehicle.name): \(error.localizedDescription)")
                }

                do {
                    let recent = try await service.drives(vin: vehicle.vin, limit: 20)
                    drives.append(contentsOf: recent.map(DriveEntity.init(info:)))
                } catch {
                    errors.append("Drives for \(vehicle.name): \(error.localizedDescription)")
                }

                do {
                    let info = try await service.software(vin: vehicle.vin)
                    software.append(SoftwareUpdateEntity(info: info, vin: vehicle.vin, vehicleName: vehicle.name))
                    notes.append(contentsOf: info.releaseNotes.map { ReleaseNoteEntity(info: $0, vin: vehicle.vin, version: info.availableVersion ?? info.currentVersion) })
                } catch {
                    errors.append("Software for \(vehicle.name): \(error.localizedDescription)")
                }
            }

            await index(statuses, groupName: "Live Status", groups: &groups, errors: &errors)
            await index(drives, groupName: "Recent Drives", groups: &groups, errors: &errors)
            await index(software, groupName: "Software", groups: &groups, errors: &errors)
            await index(notes, groupName: "Release Notes", groups: &groups, errors: &errors)
        } catch {
            errors.append(error.localizedDescription)
        }

        return FleetSpotlightIndexingReport(indexName: indexName, submittedAt: submittedAt, groups: groups, errors: errors)
    }

    public static func search(_ term: String, limit: Int = 20) async throws -> [FleetSpotlightSearchResult] {
        let predicate = queryString(for: term)
        let context = CSSearchQueryContext()
        context.fetchAttributes = ["title", "displayName", "contentDescription", "textContent", "keywords"]
        let query = CSSearchQuery(queryString: predicate, queryContext: context)

        var results: [FleetSpotlightSearchResult] = []
        for try await result in query.results {
            let item = result.item
            let attributes = item.attributeSet
            let title = attributes.title ?? attributes.displayName ?? item.uniqueIdentifier
            results.append(
                FleetSpotlightSearchResult(
                    id: item.uniqueIdentifier,
                    title: title,
                    subtitle: attributes.displayName == title ? nil : attributes.displayName,
                    contentDescription: attributes.contentDescription,
                    keywords: attributes.keywords ?? [],
                    domainIdentifier: item.domainIdentifier
                )
            )
            if results.count >= limit { break }
        }
        return results
    }

    public static func donate<Entity: IndexedEntity>(_ entities: [Entity]) async throws {
        guard !entities.isEmpty else { return }
        try await CSSearchableIndex(name: indexName).indexAppEntities(entities)
    }

    private static func index<Entity: IndexedEntity>(
        _ entities: [Entity],
        groupName: String,
        groups: inout [FleetSpotlightSubmittedGroup],
        errors: inout [String]
    ) async {
        guard !entities.isEmpty else {
            groups.append(FleetSpotlightSubmittedGroup(name: groupName, count: 0, sampleTitles: []))
            return
        }

        do {
            try await donate(entities)
            groups.append(
                FleetSpotlightSubmittedGroup(
                    name: groupName,
                    count: entities.count,
                    sampleTitles: entities.prefix(3).map { String(localized: $0.displayRepresentation.title) }
                )
            )
        } catch {
            errors.append("\(groupName): \(error.localizedDescription)")
        }
    }

    private static func queryString(for rawTerm: String) -> String {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return "title == '*'cd" }
        let escaped = term.replacingOccurrences(of: "'", with: "\\'")
        return "title == '*\(escaped)*'cd || displayName == '*\(escaped)*'cd || contentDescription == '*\(escaped)*'cd || textContent == '*\(escaped)*'cd || keywords == '*\(escaped)*'cd"
    }
}
