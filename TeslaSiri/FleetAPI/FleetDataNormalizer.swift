import Foundation

/// Sanitizes, deduplicates, and bounds raw Fleet/Tessie domain models before presentation or caching.
nonisolated enum FleetDataNormalizer {
    private static let maxCachedDrivesPerVehicle = 50

    // MARK: - Account & Vehicles

    static func capabilities(_ capabilities: FleetCapabilities?) -> FleetCapabilities? {
        guard var capabilities else {
            return nil
        }
        capabilities.chargeActions = normalizedStrings(capabilities.chargeActions)
        capabilities.controlActions = normalizedStrings(capabilities.controlActions)
        capabilities.events = normalizedStrings(capabilities.events)
        capabilities.notificationEvents = normalizedStrings(capabilities.notificationEvents)
        capabilities.scopes = normalizedStrings(capabilities.scopes)
        capabilities.software = normalizedJSONObject(capabilities.software)
        return capabilities
    }

    static func user(_ user: FleetUser?) -> FleetUser? {
        guard var user else {
            return nil
        }
        user.authType = normalizedString(user.authType)
        user.email = normalizedString(user.email)
        user.id = normalizedString(user.id)
        user.name = normalizedString(user.name)
        user.role = normalizedString(user.role)
        user.scopes = normalizedStrings(user.scopes)
        user.units = normalizedString(user.units)?.lowercased()
        return user
    }

    static func vehicles(_ vehicles: [FleetVehicle]) -> [FleetVehicle] {
        var vehiclesByVIN: [String: FleetVehicle] = [:]

        for rawVehicle in vehicles {
            var vehicle = rawVehicle
            vehicle.vin = normalizedVIN(vehicle.vin)
            guard !vehicle.vin.isEmpty, !vehicle.hidden else {
                continue
            }

            vehicle.displayName = normalizedString(vehicle.displayName)
            vehicle.vehicleTag = normalizedString(vehicle.vehicleTag)
            vehicle.permissions = normalizedStrings(vehicle.permissions)
            if var latest = vehicle.latest {
                if normalizedString(latest.vin) == nil {
                    latest.vin = vehicle.vin
                }
                vehicle.latest = latestSnapshot(latest)
            }

            if let existingVehicle = vehiclesByVIN[vehicle.vin],
               !isNewer(vehicle.latest, than: existingVehicle.latest) {
                continue
            }
            vehiclesByVIN[vehicle.vin] = vehicle
        }

        return vehiclesByVIN.values.sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func latestSnapshots(_ snapshots: [FleetLatestSnapshot]) -> [FleetLatestSnapshot] {
        var snapshotsByVIN: [String: FleetLatestSnapshot] = [:]
        for snapshot in snapshots.compactMap(latestSnapshot) {
            if let existingSnapshot = snapshotsByVIN[snapshot.vin],
               !isNewer(snapshot, than: existingSnapshot) {
                continue
            }
            snapshotsByVIN[snapshot.vin] = snapshot
        }
        return Array(snapshotsByVIN.values)
    }

    static func latestSnapshot(_ snapshot: FleetLatestSnapshot) -> FleetLatestSnapshot? {
        var snapshot = snapshot
        snapshot.vin = normalizedVIN(snapshot.vin)
        guard !snapshot.vin.isEmpty else {
            return nil
        }

        snapshot.batteryLevel = percent(snapshot.batteryLevel)
        snapshot.batteryRange = nonNegative(snapshot.batteryRange)
        snapshot.chargeLimitSOC = percent(snapshot.chargeLimitSOC)
        snapshot.chargeRateMPH = nonNegative(snapshot.chargeRateMPH)
        snapshot.chargerPowerKW = nonNegative(snapshot.chargerPowerKW)
        snapshot.chargingState = normalizedString(snapshot.chargingState)
        snapshot.freshnessMS = nonNegative(snapshot.freshnessMS)
        snapshot.gear = normalizedString(snapshot.gear)
        snapshot.insideTemp = finite(snapshot.insideTemp)
        snapshot.latitude = coordinate(snapshot.latitude, min: -90, max: 90)
        snapshot.longitude = coordinate(snapshot.longitude, min: -180, max: 180)
        snapshot.odometer = nonNegative(snapshot.odometer)
        snapshot.outsideTemp = finite(snapshot.outsideTemp)
        snapshot.software = snapshot.software.flatMap(softwareUpdate)
        snapshot.speed = nonNegative(snapshot.speed)
        snapshot.targetTemperature = finite(snapshot.targetTemperature)
        snapshot.timeToFullCharge = nonNegative(snapshot.timeToFullCharge)
        snapshot.timestamp = normalizedEpochMilliseconds(snapshot.timestamp)
        snapshot.updatedAt = normalizedEpochMilliseconds(snapshot.updatedAt) ?? snapshot.timestamp
        if snapshot.timestamp == nil {
            snapshot.timestamp = snapshot.updatedAt
        }
        return snapshot
    }

    // MARK: - Charging & Drives

    static func chargeSessions(_ sessions: [FleetChargeSession], fallbackVIN: String? = nil) -> [FleetChargeSession] {
        var sessionsByID: [String: FleetChargeSession] = [:]
        for rawSession in sessions {
            var session = rawSession
            let vin = resolvedVIN(session.vin, fallback: fallbackVIN)
            guard let startedAt = normalizedEpochMilliseconds(session.startedAt), !vin.isEmpty else {
                continue
            }

            session.vin = vin
            session.startedAt = startedAt
            session.endedAt = sanitizedEndedAt(session.endedAt, startedAt: startedAt)
            session.durationMS = normalizedDuration(session.durationMS, startedAt: startedAt, endedAt: session.endedAt)
            session.avgPowerKW = nonNegative(session.avgPowerKW)
            session.batteryLevelEnd = percent(session.batteryLevelEnd)
            session.batteryLevelStart = percent(session.batteryLevelStart)
            session.cost = nonNegative(session.cost)
            session.currency = normalizedString(session.currency)
            session.energyAddedKWH = nonNegative(session.energyAddedKWH)
            session.maxPowerKW = nonNegative(session.maxPowerKW)
            session.sessionID = normalizedSessionID(session.sessionID, fallback: "charge:\(vin):\(startedAt)")
            session.status = normalizedString(session.status)

            if let existingSession = sessionsByID[session.sessionID], existingSession.startedAt >= session.startedAt {
                continue
            }
            sessionsByID[session.sessionID] = session
        }
        return sessionsByID.values.sorted { $0.startedAt > $1.startedAt }
    }

    static func driveSessions(_ drives: [FleetDriveSession], fallbackVIN: String? = nil) -> [FleetDriveSession] {
        var drivesByID: [String: FleetDriveSession] = [:]
        for rawDrive in drives {
            var drive = rawDrive
            let vin = resolvedVIN(drive.vin, fallback: fallbackVIN)
            guard let startedAt = normalizedEpochMilliseconds(drive.startedAt), !vin.isEmpty else {
                continue
            }

            drive.vin = vin
            drive.startedAt = startedAt
            drive.endedAt = sanitizedEndedAt(drive.endedAt, startedAt: startedAt)
            drive.route = routePoints(drive.route)
            drive.durationMS = normalizedDuration(drive.durationMS, startedAt: startedAt, endedAt: drive.endedAt)
            drive.distanceMiles = nonNegative(drive.distanceMiles) ?? derivedDistanceMiles(from: drive.route)
            drive.energyUsedKWH = nonNegative(drive.energyUsedKWH)
            drive.maxSpeedMPH = nonNegative(drive.maxSpeedMPH) ?? derivedMaxSpeedMPH(from: drive.route)
            drive.avgSpeedMPH = nonNegative(drive.avgSpeedMPH) ?? derivedAverageSpeedMPH(
                distanceMiles: drive.distanceMiles,
                durationMS: drive.durationMS,
                route: drive.route
            )
            drive.sessionID = normalizedSessionID(drive.sessionID, fallback: "drive:\(vin):\(startedAt)")
            drive.startAddress = normalizedString(drive.startAddress)
            drive.endAddress = normalizedString(drive.endAddress)

            if let existingDrive = drivesByID[drive.sessionID], existingDrive.startedAt >= drive.startedAt {
                continue
            }
            drivesByID[drive.sessionID] = drive
        }

        return drivesByID.values
            .sorted { $0.startedAt > $1.startedAt }
            .cappedPerVehicle(limit: maxCachedDrivesPerVehicle)
    }

    static func activeDrive(_ rawDrive: FleetActiveDriveSession, fallbackVIN: String? = nil) -> FleetActiveDriveSession? {
        var drive = rawDrive
        let vin = resolvedVIN(drive.vin, fallback: fallbackVIN)
        guard !vin.isEmpty else {
            return nil
        }

        drive.vin = vin
        drive.distanceMiles = nonNegative(drive.distanceMiles)
        drive.lastUpdate = normalizedEpochMilliseconds(drive.lastUpdate)
        drive.sessionID = normalizedString(drive.sessionID) ?? "active:\(vin)"
        drive.startBattery = percent(drive.startBattery)
        drive.startLocation = normalizedCoordinate(drive.startLocation)
        drive.startOdometer = nonNegative(drive.startOdometer)
        drive.startedAt = normalizedEpochMilliseconds(drive.startedAt)
        drive.status = normalizedString(drive.status)
        if let startedAt = drive.startedAt {
            drive.durationMS = normalizedDuration(drive.durationMS, startedAt: startedAt, endedAt: nil)
        } else {
            drive.durationMS = nonNegative(drive.durationMS)
        }
        if let routePointCount = drive.routePointCount, routePointCount < 0 {
            drive.routePointCount = nil
        }
        if var latest = drive.latest {
            if normalizedString(latest.vin) == nil {
                latest.vin = vin
            }
            drive.latest = latestSnapshot(latest)
        }

        drive.bufferedPoints = routePoints(drive.bufferedPoints)
        drive.route = routePoints(drive.route + drive.bufferedPoints)
        let latestRoutePoint = drive.latestRoutePoint.flatMap { routePoints([$0], limit: 1).first }
        drive.latestRoutePoint = latestRoutePoint ?? drive.route.last
        if drive.routePointCount == nil, !drive.route.isEmpty {
            drive.routePointCount = drive.route.count
        }

        return drive
    }

    static func activeDrivesByVIN(_ values: [String: FleetActiveDriveSession]) -> [String: FleetActiveDriveSession] {
        var normalizedValues: [String: FleetActiveDriveSession] = [:]
        for (key, value) in values {
            guard let drive = activeDrive(value, fallbackVIN: key), drive.active else {
                continue
            }
            normalizedValues[drive.vin] = drive
        }
        return normalizedValues
    }

    // MARK: - Software Updates

    static func softwareUpdate(_ rawUpdate: FleetSoftwareUpdate) -> FleetSoftwareUpdate? {
        var update = rawUpdate
        update.availableVersion = normalizedString(update.availableVersion)
        update.currentVersion = normalizedString(update.currentVersion)
        update.downloadPercent = percent(update.downloadPercent)
        update.expectedDurationMinutes = nonNegative(update.expectedDurationMinutes)
        update.expectedDurationSec = nonNegative(update.expectedDurationSec)
        update.installPercent = percent(update.installPercent)
        update.releaseNotes = softwareReleaseNotes(update.releaseNotes)
        if let releaseNotesCount = update.releaseNotesCount, releaseNotesCount < 0 {
            update.releaseNotesCount = nil
        }
        update.scheduledStartTimeMS = normalizedEpochMilliseconds(update.scheduledStartTimeMS)
        update.sourceTimestamp = normalizedEpochMilliseconds(update.sourceTimestamp)
        update.status = normalizedString(update.status)
        update.updatedAt = normalizedEpochMilliseconds(update.updatedAt)
        update.warningTimeRemainingMS = nonNegative(update.warningTimeRemainingMS)

        let hasDistinctAvailableVersion = update.availableVersion != nil && update.availableVersion != update.currentVersion
        if !hasDistinctAvailableVersion {
            clearUnavailableUpdateFields(&update)
        }

        let hasSoftwareState = update.currentVersion != nil
            || update.availableVersion != nil
            || update.status != nil
            || update.updateAvailable
            || update.installable
            || !update.releaseNotes.isEmpty
        return hasSoftwareState ? update : nil
    }

    static func softwareUpdatesByVIN(_ values: [String: FleetSoftwareUpdate]) -> [String: FleetSoftwareUpdate] {
        var normalizedValues: [String: FleetSoftwareUpdate] = [:]
        for (key, value) in values {
            let vin = normalizedVIN(key)
            guard !vin.isEmpty, let normalized = softwareUpdate(value) else {
                continue
            }
            normalizedValues[vin] = normalized
        }
        return normalizedValues
    }

    static func softwareUpdatesByVIN(from vehicles: [FleetVehicle]) -> [String: FleetSoftwareUpdate] {
        var updates: [String: FleetSoftwareUpdate] = [:]
        for vehicle in vehicles {
            if let software = vehicle.latest?.software {
                updates[vehicle.vin] = software
            }
        }
        return softwareUpdatesByVIN(updates)
    }

    private static func clearUnavailableUpdateFields(_ update: inout FleetSoftwareUpdate) {
        update.availableVersion = nil
        update.downloadPercent = nil
        update.expectedDurationMinutes = nil
        update.expectedDurationSec = nil
        update.installPercent = nil
        update.installable = false
        update.updateAvailable = false
        if update.status == nil, update.currentVersion != nil {
            update.status = "Current"
        }
    }

    private static func softwareReleaseNotes(_ notes: [FleetSoftwareReleaseNote]) -> [FleetSoftwareReleaseNote] {
        var seenIDs = Set<String>()
        return notes.compactMap { rawNote in
            guard let title = normalizedString(rawNote.title) else {
                return nil
            }

            let note = FleetSoftwareReleaseNote(
                description: normalizedString(rawNote.description),
                imageURL: rawNote.imageURL,
                subtitle: normalizedString(rawNote.subtitle),
                title: title
            )
            guard seenIDs.insert(note.id).inserted else {
                return nil
            }
            return note
        }
    }

    // MARK: - Shared Scalar & JSON Sanitizers

    static func normalizedStrings(_ values: [String]) -> [String] {
        Array(Set(values.compactMap(normalizedString))).sorted()
    }

    static func normalizedString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func normalizedVIN(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func resolvedVIN(_ primary: String, fallback: String?) -> String {
        let normalized = normalizedVIN(primary)
        return normalized.isEmpty ? normalizedVIN(fallback ?? "") : normalized
    }

    static func normalizedSessionID(_ value: String, fallback: String) -> String {
        normalizedString(value) ?? fallback
    }

    static func normalizedEpochMilliseconds(_ value: Int64?) -> Int64? {
        guard let value else {
            return nil
        }
        return normalizedEpochMilliseconds(value)
    }

    static func normalizedEpochMilliseconds(_ value: Int64) -> Int64? {
        guard value > 0 else {
            return nil
        }
        if value >= 1_000_000_000 && value < 10_000_000_000 {
            return value * 1_000
        }
        return value
    }

    private static func sanitizedEndedAt(_ endedAt: Int64?, startedAt: Int64) -> Int64? {
        guard let normalized = normalizedEpochMilliseconds(endedAt), normalized >= startedAt else {
            return nil
        }
        return normalized
    }

    static func normalizedDuration(_ value: Int64?, startedAt: Int64, endedAt: Int64?) -> Int64? {
        if let value = nonNegative(value), value > 0 {
            return value
        }
        guard let endedAt, endedAt > startedAt else {
            return nil
        }
        return endedAt - startedAt
    }

    static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else {
            return nil
        }
        return value
    }

    static func nonNegative(_ value: Double?) -> Double? {
        guard let value = finite(value), value >= 0 else {
            return nil
        }
        return value
    }

    static func nonNegative(_ value: Int64?) -> Int64? {
        guard let value, value >= 0 else {
            return nil
        }
        return value
    }

    static func percent(_ value: Double?) -> Double? {
        guard let value = finite(value) else {
            return nil
        }
        return min(max(value, 0), 100)
    }

    static func coordinate(_ value: Double?, min: Double, max: Double) -> Double? {
        guard let value = finite(value), value >= min, value <= max else {
            return nil
        }
        return value
    }

    static func normalizedCoordinate(_ location: FleetLocationCoordinate?) -> FleetLocationCoordinate? {
        guard var location,
              let latitude = coordinate(location.latitude, min: -90, max: 90),
              let longitude = coordinate(location.longitude, min: -180, max: 180) else {
            return nil
        }
        location.latitude = latitude
        location.longitude = longitude
        return location
    }

    private static func isNewer(_ lhs: FleetLatestSnapshot?, than rhs: FleetLatestSnapshot?) -> Bool {
        (lhs?.updatedAt ?? lhs?.timestamp ?? 0) >= (rhs?.updatedAt ?? rhs?.timestamp ?? 0)
    }

    static func normalizedJSONObject(_ object: [String: JSONValue]) -> [String: JSONValue] {
        guard case .object(let normalizedObject) = normalizedJSONValue(.object(object)) else {
            return [:]
        }
        return normalizedObject
    }

    static func normalizedJSONValue(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let string):
            return normalizedString(string).map(JSONValue.string) ?? .null
        case .array(let values):
            return .array(values.map(normalizedJSONValue))
        case .object(let object):
            var normalizedObject: [String: JSONValue] = [:]
            for (key, value) in object {
                if let normalizedKey = normalizedString(key) {
                    normalizedObject[normalizedKey] = normalizedJSONValue(value)
                }
            }
            return .object(normalizedObject)
        default:
            return value
        }
    }

    static func jsonInt64(_ value: JSONValue?) -> Int64? {
        switch value {
        case .integer(let value):
            return Int64(value)
        case .double(let value):
            return safeInt64(from: value)
        case .string(let value):
            return Int64(value) ?? Double(value).flatMap(safeInt64(from:))
        default:
            return nil
        }
    }

    private static func safeInt64(from value: Double) -> Int64? {
        guard value.isFinite,
              value >= Double(Int64.min),
              value < Double(Int64.max) else {
            return nil
        }
        return Int64(value)
    }

    static func jsonDouble(_ value: JSONValue?) -> Double? {
        switch value {
        case .integer(let value):
            return Double(value)
        case .double(let value) where value.isFinite:
            return value
        case .string(let value):
            return Double(value)
        default:
            return nil
        }
    }

    static func normalizeDictionary<Value>(
        _ values: [String: [Value]],
        normalize: ([Value]) -> [Value]
    ) -> [String: [Value]] {
        var normalizedValues: [String: [Value]] = [:]
        for (key, value) in values {
            guard let normalizedKey = normalizedString(key) else {
                continue
            }
            let normalizedValue = normalize(value)
            if !normalizedValue.isEmpty {
                normalizedValues[normalizedKey] = normalizedValue
            }
        }
        return normalizedValues
    }
}

nonisolated private extension Array where Element == FleetDriveSession {
    func cappedPerVehicle(limit: Int) -> [FleetDriveSession] {
        var countsByVIN: [String: Int] = [:]
        return filter { drive in
            let count = countsByVIN[drive.vin, default: 0]
            guard count < limit else {
                return false
            }
            countsByVIN[drive.vin] = count + 1
            return true
        }
    }
}
