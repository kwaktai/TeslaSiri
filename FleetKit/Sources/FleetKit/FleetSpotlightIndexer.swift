import AppIntents
import CoreSpotlight
import Foundation
import OSLog

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
    public let kind: String?
    public let domainIdentifier: String?

    public init(
        id: String,
        title: String,
        subtitle: String?,
        contentDescription: String?,
        keywords: [String],
        kind: String?,
        domainIdentifier: String?
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.contentDescription = contentDescription
        self.keywords = keywords
        self.kind = kind
        self.domainIdentifier = domainIdentifier
    }
}

/// Donates the app's entities to a named Spotlight index so vehicles, live
/// status, drives, charging sessions, software, and release notes are findable in
/// Spotlight search and by Siri without launching the app.
public enum FleetSpotlightIndexer {
    public static let indexName = "FleetEntities"
    /// Most recent drives indexed per vehicle. Older drives stay reachable through
    /// the Find Tesla Drives tool, which queries Tessie directly.
    public static let drivesPerVehicle = 50
    /// Most recent charging sessions indexed per vehicle. Older sessions stay
    /// reachable through the Get Tesla Charging History tool.
    public static let chargesPerVehicle = 50

    private static let reindexCoordinator = ReindexCoordinator()

    /// Coalesces concurrent callers: if a reindex is already running, callers
    /// join it and receive its report instead of starting a competing run.
    public static func reindexAll() async -> FleetSpotlightIndexingReport {
        await reindexCoordinator.run { await performReindexAll() }
    }

    private static func performReindexAll() async -> FleetSpotlightIndexingReport {
        let submittedAt = Date()
        let start = ContinuousClock.now
        let service = FleetIntentService.make()
        var groups: [FleetSpotlightSubmittedGroup] = []
        var errors: [String] = []

        FleetKitLog.spotlight.notice("Reindex started (index: \(indexName, privacy: .public))")

        do {
            let vehicles = try await service.vehicles()
            guard !vehicles.isEmpty else {
                FleetKitLog.spotlight.error("Reindex aborted: no vehicles returned from the Fleet backend")
                return FleetSpotlightIndexingReport(indexName: indexName, submittedAt: submittedAt, groups: [], errors: ["No vehicles returned from the Fleet backend."])
            }

            do {
                try await deleteAllIndexedEntities()
            } catch {
                errors.append("Clearing stale Spotlight entities: \(error.localizedDescription)")
            }

            let vehicleEntities = vehicles.map(VehicleEntity.init(info:))
            await index(vehicleEntities, groupName: "Vehicles", priority: 10, groups: &groups, errors: &errors)

            var statuses: [VehicleStatusEntity] = []
            var drives: [DriveEntity] = []
            var charges: [ChargeSessionEntity] = []
            var software: [SoftwareUpdateEntity] = []
            var notes: [ReleaseNoteEntity] = []

            // An expired/missing session fails every remaining backend call the
            // same way, so stop fetching at the first auth failure instead of
            // burning minutes on requests that can only 401.
            var stoppedOnAuthFailure = false

            vehicleLoop: for vehicle in vehicles {
                var softwareFromState: FleetSoftwareInfo?
                do {
                    let state = try await service.snapshotAndSoftware(vin: vehicle.vin)
                    softwareFromState = state.software
                    statuses.append(VehicleStatusEntity(snapshot: state.snapshot, vehicleName: vehicle.name))
                } catch {
                    errors.append("Status for \(vehicle.name): \(error.localizedDescription)")
                    if isAuthFailure(error) { stoppedOnAuthFailure = true; break vehicleLoop }
                }

                do {
                    let recent = try await service.drives(vin: vehicle.vin, limit: drivesPerVehicle)
                    drives.append(contentsOf: recent.map(DriveEntity.init(info:)))
                } catch {
                    errors.append("Drives for \(vehicle.name): \(error.localizedDescription)")
                    if isAuthFailure(error) { stoppedOnAuthFailure = true; break vehicleLoop }
                }

                do {
                    let recent = try await service.charges(vin: vehicle.vin, limit: chargesPerVehicle)
                    charges.append(contentsOf: recent.map(ChargeSessionEntity.init(info:)))
                } catch {
                    errors.append("Charging sessions for \(vehicle.name): \(error.localizedDescription)")
                    if isAuthFailure(error) { stoppedOnAuthFailure = true; break vehicleLoop }
                }

                let info: FleetSoftwareInfo
                do {
                    if let softwareFromState {
                        info = softwareFromState
                    } else {
                        info = try await service.software(vin: vehicle.vin)
                    }
                    software.append(SoftwareUpdateEntity(info: info, vin: vehicle.vin, vehicleName: vehicle.name))
                } catch {
                    errors.append("Software for \(vehicle.name): \(error.localizedDescription)")
                    if isAuthFailure(error) { stoppedOnAuthFailure = true; break vehicleLoop }
                    continue
                }

                if let version = info.availableVersion ?? info.currentVersion {
                    do {
                        let releaseNotes = try await service.releaseNotes(vin: vehicle.vin, version: version)
                        notes.append(contentsOf: releaseNotes.map { ReleaseNoteEntity(info: $0, vin: vehicle.vin, version: version) })
                    } catch {
                        errors.append("Release notes for \(vehicle.name): \(error.localizedDescription)")
                        if isAuthFailure(error) { stoppedOnAuthFailure = true; break vehicleLoop }
                    }
                }
            }

            if stoppedOnAuthFailure {
                FleetKitLog.spotlight.error("Reindex stopped early: session not usable; donating what was fetched so far")
            }

            await index(statuses, groupName: "Live Status", priority: 10, groups: &groups, errors: &errors)
            await index(drives, groupName: "Recent Drives", priority: 4, groups: &groups, errors: &errors)
            await index(charges, groupName: "Charging Sessions", priority: 4, groups: &groups, errors: &errors)
            await index(software, groupName: "Software", priority: 8, groups: &groups, errors: &errors)
            await index(notes, groupName: "Release Notes", priority: 2, groups: &groups, errors: &errors)
        } catch {
            FleetKitLog.spotlight.error("Reindex failed: \(error.localizedDescription, privacy: .public)")
            errors.append(error.localizedDescription)
        }

        let report = FleetSpotlightIndexingReport(indexName: indexName, submittedAt: submittedAt, groups: groups, errors: errors)
        let elapsed = FleetKitLog.milliseconds(since: start)
        let groupSummary = groups.map { "\($0.name): \($0.count)" }.joined(separator: ", ")
        if report.succeeded {
            FleetKitLog.spotlight.notice("Reindex finished in \(elapsed, privacy: .public) ms — \(report.submittedCount, privacy: .public) entities [\(groupSummary, privacy: .public)]")
        } else {
            FleetKitLog.spotlight.error("Reindex finished in \(elapsed, privacy: .public) ms with \(errors.count, privacy: .public) error(s) — \(report.submittedCount, privacy: .public) entities [\(groupSummary, privacy: .public)]; errors: \(errors.joined(separator: " | "), privacy: .public)")
        }
        return report
    }

    public static func search(_ term: String, limit: Int = 20) async throws -> [FleetSpotlightSearchResult] {
        guard limit > 0 else { return [] }
        let start = ContinuousClock.now
        let predicate = queryString(for: term)
        let context = CSSearchQueryContext()
        context.fetchAttributes = ["title", "displayName", "contentDescription", "keywords", "kind"]
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
                    kind: attributes.kind,
                    domainIdentifier: item.domainIdentifier
                )
            )
            if results.count >= limit { break }
        }
        let elapsed = FleetKitLog.milliseconds(since: start)
        FleetKitLog.spotlight.info("Search '\(term, privacy: .public)' returned \(results.count, privacy: .public) result(s) in \(elapsed, privacy: .public) ms")
        return results
    }

    public static func donate<Entity: IndexedEntity>(_ entities: [Entity], priority: Int = 0) async throws {
        guard !entities.isEmpty else { return }
        do {
            try await CSSearchableIndex(name: indexName).indexAppEntities(entities, priority: priority)
            FleetKitLog.spotlight.info("Donated \(entities.count, privacy: .public) \(String(describing: Entity.self), privacy: .public) item(s) at priority \(priority, privacy: .public)")
        } catch {
            FleetKitLog.spotlight.error("Donating \(entities.count, privacy: .public) \(String(describing: Entity.self), privacy: .public) item(s) failed — \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public static func deleteAllIndexedEntities() async throws {
        let index = CSSearchableIndex(name: indexName)
        do {
            try await index.deleteAllSearchableItems()
            FleetKitLog.spotlight.notice("Deleted all FleetKit indexed entities")
        } catch {
            FleetKitLog.spotlight.error("Deleting FleetKit indexed entities failed — \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private static func index<Entity: IndexedEntity>(
        _ entities: [Entity],
        groupName: String,
        priority: Int = 0,
        groups: inout [FleetSpotlightSubmittedGroup],
        errors: inout [String]
    ) async {
        guard !entities.isEmpty else {
            groups.append(FleetSpotlightSubmittedGroup(name: groupName, count: 0, sampleTitles: []))
            return
        }

        do {
            try await donate(entities, priority: priority)
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

    private static func isAuthFailure(_ error: any Error) -> Bool {
        switch error {
        case FleetKitError.sessionExpired, FleetKitError.notSignedIn:
            return true
        default:
            return false
        }
    }

    private static func queryString(for rawTerm: String) -> String {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return "title == '*'cd" }
        let escaped = term.replacingOccurrences(of: "'", with: "\\'")
        return "title == '*\(escaped)*'cd || displayName == '*\(escaped)*'cd || contentDescription == '*\(escaped)*'cd || textContent == '*\(escaped)*'cd || keywords == '*\(escaped)*'cd"
    }
}

/// Ensures only one reindex runs at a time. The app triggers reindexing from
/// several launch paths (app task, sign-in, manual refresh) that can fire
/// near-simultaneously; overlapping runs interleave donations and double the
/// backend load for no benefit.
private actor ReindexCoordinator {
    private var inFlight: Task<FleetSpotlightIndexingReport, Never>?

    func run(_ operation: @escaping @Sendable () async -> FleetSpotlightIndexingReport) async -> FleetSpotlightIndexingReport {
        if let inFlight {
            FleetKitLog.spotlight.notice("Reindex already in flight — joining the existing run")
            return await inFlight.value
        }
        let task = Task { await operation() }
        inFlight = task
        let report = await task.value
        inFlight = nil
        return report
    }
}
