import AppIntents
import CoreSpotlight
import Foundation
import OSLog

/// A completed drive. Indexed in Spotlight with distance, duration, speed,
/// energy, date, and start/end locations.
public struct DriveEntity: AppEntity, IndexedEntity, SyncableEntity, Identifiable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Drive")
    public static let defaultQuery = DriveEntityQuery()

    public let id: String // sessionID

    @Property(title: "VIN", description: "The car's vehicle identification number, for the app's own use.", visibility: .internal)
    public var vin: String

    @Property(title: "Distance", description: "Distance driven on this trip, in miles.")
    public var distanceMiles: Double?

    @Property(title: "Duration", description: "How long the drive took, in minutes.")
    public var durationMinutes: Int?

    @Property(title: "Average Speed", description: "Average speed over the drive, in miles per hour.")
    public var avgSpeedMPH: Double?

    @Property(title: "Top Speed", description: "Highest speed reached during the drive, in miles per hour.")
    public var maxSpeedMPH: Double?

    @Property(title: "Energy Used", description: "Battery energy the drive used, in kilowatt-hours.")
    public var energyUsedKWH: Double?

    @Property(
        title: "Start Address",
        description: "Where the drive started: a street address or a saved place name such as Home or Work."
    )
    public var startAddress: String?

    @Property(
        title: "Destination",
        description: "Where the drive ended: a street address or a saved place name such as Home or Work.",
        indexingKey: \.namedLocation
    )
    public var endAddress: String?

    @Property(
        title: "Started At",
        description: "When the drive started, in the user's time zone.",
        indexingKey: \.contentCreationDate
    )
    public var startedAt: Date

    @Property(title: "Ended At", description: "When the drive ended, in the user's time zone.")
    public var endedAt: Date?

    @Property(title: "Starting Battery", description: "Battery percent when the drive started, from 0 to 100.")
    public var startingBatteryPercent: Int?

    @Property(title: "Ending Battery", description: "Battery percent when the drive ended, from 0 to 100.")
    public var endingBatteryPercent: Int?

    @Property(title: "Battery Used", description: "Percentage points of battery the drive used, such as 12.")
    public var batteryUsedPercent: Int?

    @Property(
        title: "Efficiency",
        description: "Energy used per mile, in watt-hours per mile (Wh/mi). Lower is more efficient; around 250 is typical."
    )
    public var efficiencyWhPerMile: Double?

    @Property(title: "Rated Range Used", description: "EPA-rated range the drive used, in miles. Compare with Distance to judge efficiency.")
    public var ratedRangeUsedMiles: Double?

    @Property(title: "Autopilot Distance", description: "Miles driven on Autopilot or FSD (Supervised) during this trip.")
    public var autopilotDistanceMiles: Double?

    @Property(title: "Cabin Temperature", description: "Average cabin temperature during the drive, in degrees Fahrenheit.")
    public var insideTempF: Double?

    @Property(title: "Outside Temperature", description: "Average outside temperature during the drive, in degrees Fahrenheit.")
    public var outsideTempF: Double?

    @Property(title: "Drive Tag", description: "The label the user gave this drive in Tessie, such as Work or Personal. Empty when untagged.")
    public var tag: String?

    @Property(title: "Start Latitude", description: "Starting GPS latitude in decimal degrees, for map rendering.", visibility: .internal)
    public var startLatitude: Double?

    @Property(title: "Start Longitude", description: "Starting GPS longitude in decimal degrees, for map rendering.", visibility: .internal)
    public var startLongitude: Double?

    @Property(title: "End Latitude", description: "Ending GPS latitude in decimal degrees, for map rendering.", visibility: .internal)
    public var endLatitude: Double?

    @Property(title: "End Longitude", description: "Ending GPS longitude in decimal degrees, for map rendering.", visibility: .internal)
    public var endLongitude: Double?

    public init(info: FleetDriveInfo) {
        self.id = info.sessionID
        self.vin = info.vin
        self.distanceMiles = info.distanceMiles
        self.durationMinutes = info.durationMinutes
        self.avgSpeedMPH = info.avgSpeedMPH
        self.maxSpeedMPH = info.maxSpeedMPH
        self.energyUsedKWH = info.energyUsedKWH
        self.startAddress = info.startAddress
        self.endAddress = info.endAddress
        self.startedAt = info.startedAtDate
        self.endedAt = info.endedAtDate
        self.startingBatteryPercent = info.startingBatteryPercent
        self.endingBatteryPercent = info.endingBatteryPercent
        self.batteryUsedPercent = info.batteryUsedPercent
        self.efficiencyWhPerMile = info.efficiencyWhPerMile
        self.ratedRangeUsedMiles = info.ratedRangeUsedMiles
        self.autopilotDistanceMiles = info.autopilotDistanceMiles
        self.insideTempF = info.insideTempF
        self.outsideTempF = info.outsideTempF
        self.tag = info.tag
        self.startLatitude = info.startLatitude
        self.startLongitude = info.startLongitude
        self.endLatitude = info.endLatitude
        self.endLongitude = info.endLongitude
    }

    public var distanceText: String {
        distanceMiles.map { miles in
            FleetCopy.text(String(format: "%.1f mi", miles), String(format: "%.1f마일", miles))
        } ?? FleetCopy.text("Drive", "주행")
    }

    public var durationText: String? {
        durationMinutes.map { FleetCopy.text("\($0) min", "\($0)분") }
    }

    public var batterySummaryText: String? {
        guard let start = startingBatteryPercent, let end = endingBatteryPercent else { return nil }
        return "\(start)% → \(end)%"
    }

    public var efficiencyText: String? {
        efficiencyWhPerMile.map { String(format: "%.0f Wh/mi", $0) }
    }

    public var routeText: String {
        if let startAddress, let endAddress {
            return FleetCopy.text("\(startAddress) to \(endAddress)", "\(startAddress)에서 \(endAddress)")
        }
        if let startAddress { return FleetCopy.text("Started at \(startAddress)", "\(startAddress)에서 출발") }
        if let endAddress { return FleetCopy.text("Ended at \(endAddress)", "\(endAddress)에 도착") }
        return startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    public var appleMapsRouteURL: URL? {
        var components = URLComponents(string: "http://maps.apple.com/")
        var items: [URLQueryItem] = []
        if let sLat = startLatitude, let sLon = startLongitude {
            items.append(URLQueryItem(name: "saddr", value: String(format: "%.6f,%.6f", sLat, sLon)))
        } else if let startAddress, !startAddress.isEmpty {
            items.append(URLQueryItem(name: "saddr", value: startAddress))
        }
        if let eLat = endLatitude, let eLon = endLongitude {
            items.append(URLQueryItem(name: "daddr", value: String(format: "%.6f,%.6f", eLat, eLon)))
        } else if let endAddress, !endAddress.isEmpty {
            items.append(URLQueryItem(name: "daddr", value: endAddress))
        }
        guard !items.isEmpty else { return nil }
        items.append(URLQueryItem(name: "dirflg", value: "d"))
        components?.queryItems = items
        return components?.url
    }

    public var detailText: String {
        var parts: [String] = [routeText]
        if let durationText { parts.append(durationText) }
        if let avgSpeedMPH {
            let speed = Int(avgSpeedMPH.rounded())
            parts.append(FleetCopy.text("avg \(speed) mph", "평균 \(speed) mph"))
        }
        if let maxSpeedMPH {
            let speed = Int(maxSpeedMPH.rounded())
            parts.append(FleetCopy.text("max \(speed) mph", "최고 \(speed) mph"))
        }
        if let energyUsedKWH { parts.append(String(format: "%.1f kWh", energyUsedKWH)) }
        if let efficiencyText { parts.append(efficiencyText) }
        if let batterySummaryText { parts.append(batterySummaryText) }
        return parts.joined(separator: " • ")
    }

    /// Detailed natural-language summary suitable for Siri voice readout.
    public func spokenSummary(vehicleName: String? = nil) -> String {
        let whenText = startedAt.formatted(date: .abbreviated, time: .shortened)
        let subject = vehicleName ?? FleetCopy.text("Your Tesla", "내 Tesla")
        var sentences: [String] = []

        if FleetCopy.prefersKorean {
            var lead = "\(whenText)에 \(subject)가 \(distanceText) 달렸습니다"
            if let startAddress, let endAddress {
                lead += ". \(startAddress)에서 \(endAddress)"
            } else if let endAddress {
                lead += ". 도착 \(endAddress)"
            } else if let startAddress {
                lead += ". 출발 \(startAddress)"
            }
            if let minutes = durationMinutes {
                lead += ", \(minutes)분"
            }
            sentences.append(lead + ".")
            var energy: [String] = []
            if let start = startingBatteryPercent, let end = endingBatteryPercent {
                energy.append("배터리 \(start)%에서 \(end)%")
            }
            if let used = energyUsedKWH {
                energy.append(String(format: "%.1f kWh 사용", used))
            }
            if let wh = efficiencyWhPerMile {
                energy.append(String(format: "%.0f Wh/mi", wh))
            }
            if !energy.isEmpty { sentences.append(energy.joined(separator: ", ") + ".") }
            var speed: [String] = []
            if let avg = avgSpeedMPH { speed.append("평균 \(Int(avg.rounded())) mph") }
            if let max = maxSpeedMPH { speed.append("최고 \(Int(max.rounded())) mph") }
            if let ap = autopilotDistanceMiles, ap > 0.05 {
                speed.append(String(format: "오토파일럿 %.1f마일", ap))
            }
            if !speed.isEmpty { sentences.append(speed.joined(separator: ", ") + ".") }
            if let tag, !tag.isEmpty { sentences.append("태그 \(tag).") }
            return sentences.joined(separator: " ")
        }

        var lead = "On \(whenText), \(subject) drove \(distanceText)"
        if let startAddress, let endAddress {
            lead += " from \(startAddress) to \(endAddress)"
        } else if let endAddress {
            lead += " to \(endAddress)"
        } else if let startAddress {
            lead += " starting at \(startAddress)"
        }
        if let minutes = durationMinutes {
            lead += " in \(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        sentences.append("\(lead).")

        var energyParts: [String] = []
        if let start = startingBatteryPercent, let end = endingBatteryPercent {
            energyParts.append("battery went from \(start)% to \(end)%")
        }
        if let energy = energyUsedKWH {
            energyParts.append(String(format: "using %.1f kWh", energy))
        }
        if let whPerMi = efficiencyWhPerMile {
            energyParts.append(String(format: "(%.0f Wh/mi)", whPerMi))
        }
        if !energyParts.isEmpty {
            let joined = energyParts.joined(separator: " ")
            sentences.append(joined.prefix(1).uppercased() + joined.dropFirst() + ".")
        }

        var speedParts: [String] = []
        if let avg = avgSpeedMPH {
            speedParts.append("average speed \(Int(avg.rounded())) mph")
        }
        if let max = maxSpeedMPH {
            speedParts.append("top speed \(Int(max.rounded())) mph")
        }
        if let ap = autopilotDistanceMiles, ap > 0.05 {
            speedParts.append(String(format: "%.1f miles on Autopilot", ap))
        }
        if !speedParts.isEmpty {
            let joined = speedParts.joined(separator: ", ")
            sentences.append(joined.prefix(1).uppercased() + joined.dropFirst() + ".")
        }

        if let tag, !tag.isEmpty {
            sentences.append(FleetCopy.text("Tagged as \(tag).", "태그 \(tag)."))
        }

        return sentences.joined(separator: " ")
    }

    public var displayRepresentation: DisplayRepresentation {
        let date = startedAt.formatted(date: .abbreviated, time: .shortened)
        return DisplayRepresentation(title: "\(distanceText) • \(date)", subtitle: "\(detailText)")
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        let title = "Tesla Drive \(startedAt.formatted(date: .abbreviated, time: .shortened))"
        let description = "Tesla drive for vehicle \(FleetKitLog.vin(vin)). \(distanceText). \(detailText)."
        attributes.title = title
        attributes.displayName = title
        attributes.kind = "Tesla Drive"
        attributes.contentCreationDate = startedAt
        attributes.contentModificationDate = endedAt ?? startedAt
        attributes.contentDescription = description
        attributes.textContent = description
        attributes.keywords = [
            "Tesla", "drive", "trip", "route", "miles", "mileage", "distance", "duration",
            "time", "average speed", "avg speed", "max speed", "energy", "kWh", "efficiency",
            FleetKitLog.vin(vin), startAddress, endAddress, tag
        ].compactMap { $0 }
        return attributes
    }
}

public struct DriveEntityQuery: EntityQuery, EntityStringQuery, IndexedEntityQuery {
    public init() {}

    public func entities(for identifiers: [DriveEntity.ID]) async throws -> [DriveEntity] {
        guard !identifiers.isEmpty else { return [] }

        let service = FleetIntentService.make()
        let vehicles = try await service.vehicles()
        var remaining = Set(identifiers)
        let hasLegacyID = identifiers.contains { !$0.contains(":") }
        let requestedVINs = Set(identifiers.map { String($0.prefix { $0 != ":" }) })
        var found: [DriveEntity] = []

        for vehicle in vehicles where !remaining.isEmpty && (hasLegacyID || requestedVINs.contains(vehicle.vin)) {
            let drives: [FleetDriveInfo]
            do {
                drives = try await service.drives(vin: vehicle.vin, limit: 100)
            } catch let error as FleetKitError where error.isUnavailableFeature {
                continue
            }
            for drive in drives where remaining.contains(drive.sessionID) {
                found.append(DriveEntity(info: drive))
                remaining.remove(drive.sessionID)
            }
        }

        FleetKitLog.entities.info("DriveEntityQuery matched \(found.count, privacy: .public) of \(identifiers.count, privacy: .public) requested drive(s)")
        return found
    }

    public func entities(matching string: String) async throws -> [DriveEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = FleetIntentService.make()
        let vehicles = try await service.vehicles()
        var all: [DriveEntity] = []
        for vehicle in vehicles {
            do {
                let drives = try await service.drives(vin: vehicle.vin, limit: 50).map(DriveEntity.init(info:))
                all.append(contentsOf: drives)
            } catch let error as FleetKitError where error.isUnavailableFeature {
                continue
            } catch FleetKitError.sessionExpired {
                throw FleetKitError.sessionExpired
            } catch {
                continue
            }
        }
        guard !query.isEmpty else {
            return Array(all.prefix(15))
        }
        return all.filter { drive in
            drive.startAddress?.localizedCaseInsensitiveContains(query) == true
                || drive.endAddress?.localizedCaseInsensitiveContains(query) == true
                || drive.tag?.localizedCaseInsensitiveContains(query) == true
                || drive.distanceText.localizedCaseInsensitiveContains(query)
                || drive.startedAt.formatted(date: .abbreviated, time: .shortened).localizedCaseInsensitiveContains(query)
        }
    }

    public func suggestedEntities() async throws -> [DriveEntity] {
        let service = FleetIntentService.make()
        let vehicle = try await service.resolvedVehicle(nil)
        let drives: [DriveEntity]
        do {
            drives = try await service.drives(vin: vehicle.vin, limit: 10).map(DriveEntity.init(info:))
        } catch let error as FleetKitError where error.isUnavailableFeature {
            return []
        }
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
            do {
                all.append(contentsOf: try await service.drives(vin: vehicle.vin, limit: 50).map(DriveEntity.init(info:)))
            } catch let error as FleetKitError where error.isUnavailableFeature {
                continue
            }
        }
        try await FleetSpotlightIndexer.donate(all)
    }
}
