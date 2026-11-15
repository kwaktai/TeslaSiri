import CoreLocation
import Foundation
import Observation
import OSLog

/// An on-device index of where a car goes: its drive history grouped into places by where
/// each drive started and ended, with each place named by `DrivePlaceResolver`. The index
/// is saved to disk per vehicle, so names resolve once and repeat visits group instantly.
/// It powers the Drives tab's place filter and search.
@MainActor
@Observable
final class DrivePlacesIndex {
    private(set) var places: [DrivePlace] = []
    /// Indexed drive history, newest first.
    private(set) var drives: [FleetDriveSession] = []
    private(set) var isIndexing = false

    @ObservationIgnored private let vin: String
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var didLoadCache = false
    private var placeOffsets: [String: Int] = [:]
    private var frequentPlaceOffsets: [Int] = []
    @ObservationIgnored private var placeIDsByArrival: [String: String] = [:]
    @ObservationIgnored private var placeIDsByDeparture: [String: String] = [:]

    private static var instances: [String: DrivePlacesIndex] = [:]
    private static let log = Logger(subsystem: "com.maxweinbach.TeslaSiri", category: "DrivePlaces")
    /// Endpoints closer than this belong to the same place.
    private nonisolated static let clusterRadius: CLLocationDistance = 120
    /// Places named per batch; MapKit throttles at about 50 requests a minute, and each place
    /// takes two.
    private static let lookupBudget = 20

    static func shared(vin: String) -> DrivePlacesIndex {
        if let index = instances[vin] { return index }
        let index = DrivePlacesIndex(vin: vin)
        instances[vin] = index
        return index
    }

    private init(vin: String) {
        self.vin = vin
    }

    // MARK: - Queries

    /// Places by number of visits, then by most recent visit.
    var frequentPlaces: [DrivePlace] {
        frequentPlaceOffsets.map { places[$0] }
    }

    func destination(of drive: FleetDriveSession) -> DrivePlace? {
        placeIDsByArrival[drive.sessionID].flatMap(place(id:))
    }

    func origin(of drive: FleetDriveSession) -> DrivePlace? {
        placeIDsByDeparture[drive.sessionID].flatMap(place(id:))
    }

    func place(id: String) -> DrivePlace? {
        placeOffsets[id].map { places[$0] }
    }

    /// Drives that ended at, or started from, `place`, newest first.
    func drives(at place: DrivePlace) -> [FleetDriveSession] {
        drives.filter {
            placeIDsByArrival[$0.sessionID] == place.id || placeIDsByDeparture[$0.sessionID] == place.id
        }
    }

    func search(_ query: String, at selectedPlace: DrivePlace?) -> (places: [DrivePlace], drives: [FleetDriveSession]) {
        let matches = places.map { $0.matches(query) }
        let matchingPlaces = frequentPlaceOffsets.compactMap { matches[$0] ? places[$0] : nil }
        if let selectedPlace { return (matchingPlaces, drives(at: selectedPlace)) }

        // Departure-only places can match a drive even though they have no chip in the strip.
        let matchingIDs = Set(places.indices.compactMap { matches[$0] ? places[$0].id : nil })
        let matchingDrives = drives.filter { drive in
            if let id = placeIDsByArrival[drive.sessionID], matchingIDs.contains(id) { return true }
            if let id = placeIDsByDeparture[drive.sessionID], matchingIDs.contains(id) { return true }
            return drive.startAddress?.localizedStandardContains(query) == true
                || drive.endAddress?.localizedStandardContains(query) == true
        }
        return (matchingPlaces, matchingDrives)
    }

    // MARK: - Indexing

    /// Fetches recent history, groups endpoints into places and names new places.
    func refresh(using store: FleetDataStore) async {
        let previous = refreshTask
        previous?.cancel()
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await updateHistory(using: store)
        }
        refreshTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if refreshTask == task { refreshTask = nil }
    }

    private func updateHistory(using store: FleetDataStore) async {
        func isCurrent() -> Bool { !Task.isCancelled && store.selectedVehicle?.vin == vin }
        guard isCurrent() else { return }
        isIndexing = true
        defer { isIndexing = false }

        if !didLoadCache {
            let snapshot = await Snapshot.load(for: vin)
            guard isCurrent() else { return }
            if let snapshot {
                drives = snapshot.drives
                placeIDsByArrival = snapshot.arrivals
                placeIDsByDeparture = snapshot.departures
                replacePlaces(with: snapshot.places)
            }
            didLoadCache = true
        }

        let fetched = await store.selectedVehicleDriveHistory(limit: 200)
        guard isCurrent() else { return }
        if var history = fetched ?? (drives.isEmpty ? store.selectedVehicleRecentDrives : nil) {
            history.sort { $0.startedAt > $1.startedAt }
            if history != drives {
                let membership = await Self.cluster(history, around: places.map(\.coordinate))
                guard isCurrent(), let membership else { return }
                drives = history
                applyClusters(membership)
                labelHome()
                await saveToDisk()
            }
        }

        // Resolvers run in batches within MapKit's request budget while the tab stays open.
        let drivesByID = Dictionary(drives.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        while isCurrent() {
            let pending = places
                .filter { !$0.isResolved }
                .sorted { ($0.visitCount + $0.departureIDs.count) > ($1.visitCount + $1.departureIDs.count) }
                .prefix(Self.lookupBudget)
            guard !pending.isEmpty else { break }
            var changed = false
            var throttled = false
            for place in pending {
                guard isCurrent() else { break }
                let label = place.arrivalIDs.first.flatMap { drivesByID[$0]?.endAddress }
                    ?? place.departureIDs.first.flatMap { drivesByID[$0]?.startAddress }
                do {
                    let resolution = try await DrivePlaceResolver.resolve(place.coordinate, tessieLabel: label)
                    guard isCurrent(), let index = placeOffsets[place.id] else { break }
                    var resolved = place
                    resolved.name = resolution.name
                    resolved.category = resolution.category
                    resolved.address = resolution.address ?? place.address
                    resolved.isResolved = true
                    places[index] = resolved
                    changed = true
                } catch {
                    throttled = true
                    break
                }
            }
            if changed {
                labelHome()
                await saveToDisk()
            }
            guard isCurrent() else { return }
            let remaining = places.lazy.filter { !$0.isResolved }.count
            guard remaining > 0 else { break }
            isIndexing = false
            Self.log.info("\(remaining, privacy: .public) places left to name\(throttled ? " (throttled)" : "", privacy: .public); continuing in a minute")
            do {
                try await Task.sleep(for: .seconds(65))
            } catch {
                return
            }
        }
    }

    private func replacePlaces(with updated: [DrivePlace]) {
        placeOffsets = Dictionary(updated.indices.map { (updated[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
        frequentPlaceOffsets = updated.indices.filter { updated[$0].visitCount > 0 }.sorted {
            (updated[$0].visitCount, updated[$0].lastVisit) > (updated[$1].visitCount, updated[$1].lastVisit)
        }
        places = updated
    }

    /// Finds the nearest cluster for each endpoint, including clusters formed earlier in this pass.
    @concurrent private nonisolated static func cluster(
        _ drives: [FleetDriveSession], around coordinates: [CLLocationCoordinate2D]
    ) async -> [(arrival: Int?, departure: Int?)]? {
        // A 0.002° latitude band is over 220 m wide even at the equator. Any endpoint
        // within 120 m lies in this band or an adjacent one, including across the dateline.
        func band(for latitude: Double) -> Int { Int(floor(latitude / 0.002)) }
        var bands: [Int: [(index: Int, location: CLLocation)]] = [:]
        for (index, coordinate) in coordinates.enumerated() where CLLocationCoordinate2DIsValid(coordinate) {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            bands[band(for: coordinate.latitude), default: []].append((index, location))
        }
        var nextIndex = coordinates.count

        func nearest(to latitude: Double?, _ longitude: Double?) -> Int? {
            guard let coordinate = Self.coordinate(latitude, longitude) else { return nil }
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let centralBand = band(for: coordinate.latitude)
            var nearestIndex = nextIndex
            var shortest = CLLocationDistance.infinity
            for neighbor in (centralBand - 1)...(centralBand + 1) {
                guard let candidates = bands[neighbor] else { continue }
                for candidate in candidates {
                    let distance = candidate.location.distance(from: location)
                    if distance <= clusterRadius,
                       distance < shortest || (distance == shortest && candidate.index < nearestIndex) {
                        nearestIndex = candidate.index
                        shortest = distance
                    }
                }
            }
            if nearestIndex == nextIndex {
                bands[centralBand, default: []].append((nextIndex, location))
                nextIndex += 1
            }
            return nearestIndex
        }

        var membership: [(arrival: Int?, departure: Int?)] = []
        membership.reserveCapacity(drives.count)
        for drive in drives {
            guard !Task.isCancelled else { return nil }
            let arrival = nearest(to: drive.endLatitude, drive.endLongitude)
            let departure = nearest(to: drive.startLatitude, drive.startLongitude)
            membership.append((arrival, departure))
        }
        return membership
    }

    private func applyClusters(_ membership: [(arrival: Int?, departure: Int?)]) {
        var updated = places.map { place in
            var copy = place
            copy.arrivalIDs = []
            copy.departureIDs = []
            copy.lastVisit = 0
            return copy
        }
        placeIDsByArrival = [:]
        placeIDsByDeparture = [:]

        func addPlaceIfNeeded(_ index: Int, latitude: Double, longitude: Double, label: String?) {
            guard index == updated.count else { return }
            updated.append(DrivePlace(
                id: String(format: "%.4f,%.4f", latitude, longitude),
                name: DrivePlaceResolver.savedName(from: label) ?? DrivePlaceResolver.shortAddress(label) ?? "Unnamed place",
                category: nil,
                address: label,
                latitude: latitude,
                longitude: longitude,
                arrivalIDs: [],
                departureIDs: [],
                lastVisit: 0,
                isResolved: false
            ))
        }

        for (drive, indices) in zip(drives, membership) {
            if let index = indices.arrival, let lat = drive.endLatitude, let lon = drive.endLongitude {
                addPlaceIfNeeded(index, latitude: lat, longitude: lon, label: drive.endAddress)
                updated[index].arrivalIDs.append(drive.sessionID)
                updated[index].lastVisit = max(updated[index].lastVisit, drive.endedAt ?? drive.startedAt)
                placeIDsByArrival[drive.sessionID] = updated[index].id
            }
            if let index = indices.departure, let lat = drive.startLatitude, let lon = drive.startLongitude {
                addPlaceIfNeeded(index, latitude: lat, longitude: lon, label: drive.startAddress)
                updated[index].departureIDs.append(drive.sessionID)
                placeIDsByDeparture[drive.sessionID] = updated[index].id
            }
        }
        replacePlaces(with: updated.filter { !$0.arrivalIDs.isEmpty || !$0.departureIDs.isEmpty })
    }

    /// Names the place the car most often spends the night "Home": the place where an evening
    /// arrival is followed by the next departure at least 6 hours later. Businesses and names
    /// the user saved in Tessie are left alone.
    private func labelHome() {
        let chronological = drives.sorted { $0.startedAt < $1.startedAt }
        var overnights: [String: Int] = [:]
        for (drive, next) in zip(chronological, chronological.dropFirst()) {
            guard let arrival = placeIDsByArrival[drive.sessionID],
                  placeIDsByDeparture[next.sessionID] == arrival,
                  let endedAt = drive.endedAt
            else { continue }
            let parked = Double(next.startedAt - endedAt) / 1000
            guard parked >= 6 * 3600 else { continue }
            let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: Double(endedAt) / 1000))
            if hour >= 16 || hour < 4 {
                overnights[arrival, default: 0] += 1
            }
        }
        guard let (homeID, nights) = overnights.max(by: { $0.value < $1.value }), nights >= 3,
              let index = places.firstIndex(where: { $0.id == homeID }),
              places[index].category == nil,
              DrivePlaceResolver.savedName(from: places[index].name) == nil || places[index].name == "Home"
        else { return }
        if places[index].name != "Home" {
            places[index].address = places[index].address ?? places[index].name
            places[index].name = "Home"
        }
    }

    private nonisolated static func coordinate(_ latitude: Double?, _ longitude: Double?) -> CLLocationCoordinate2D? {
        guard let latitude, let longitude, abs(latitude) <= 90, abs(longitude) <= 180, latitude != 0 || longitude != 0 else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    // MARK: - Persistence

    private func saveToDisk() async {
        let snapshot = Snapshot(places: places, drives: drives, arrivals: placeIDsByArrival, departures: placeIDsByDeparture)
        await snapshot.save(for: vin)
    }

    private nonisolated struct Snapshot: Codable, Sendable {
        var places: [DrivePlace]
        var drives: [FleetDriveSession]
        var arrivals: [String: String]
        var departures: [String: String]

        private static func fileURL(for vin: String) -> URL? {
            guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
            let directory = support.appendingPathComponent("DrivePlaces", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let safe = vin.filter { $0.isLetter || $0.isNumber }
            return directory.appendingPathComponent("\(safe).json")
        }

        @concurrent static func load(for vin: String) async -> Self? {
            guard let url = fileURL(for: vin), let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Self.self, from: data)
        }

        @concurrent func save(for vin: String) async {
            guard let url = Self.fileURL(for: vin) else { return }
            var compact = self
            for index in compact.drives.indices where !compact.drives[index].route.isEmpty {
                compact.drives[index].route = []
            }
            guard let data = try? JSONEncoder().encode(compact) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }
}
