import Foundation

nonisolated extension FleetDataNormalizer {
    private static let maxCachedRoutePoints = 500
    private static let maxCachedTelemetryPoints = 250
    private static let earthRadiusMeters = 6_371_000.0
    private static let metersPerMile = 1_609.344
    private static let millisecondsPerHour = 3_600_000.0

    // MARK: - Route Points

    static func routePoints(_ points: [FleetRoutePoint], limit: Int? = nil) -> [FleetRoutePoint] {
        let cappedLimit = min(limit ?? maxCachedRoutePoints, maxCachedRoutePoints)
        var seenIDs = Set<String>()

        let normalizedPoints: [FleetRoutePoint] = points.compactMap { rawPoint in
            var point = rawPoint
            guard let latitude = coordinate(point.latitude, min: -90, max: 90),
                  let longitude = coordinate(point.longitude, min: -180, max: 180) else {
                return nil
            }

            point.latitude = latitude
            point.longitude = longitude
            point.odometer = nonNegative(point.odometer)
            point.speed = nonNegative(point.speed)
            point.timestamp = normalizedEpochMilliseconds(point.timestamp)

            let id = point.id
            guard !id.isEmpty, seenIDs.insert(id).inserted else {
                return nil
            }
            return point
        }
        .sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }

        guard normalizedPoints.count > cappedLimit else {
            return normalizedPoints
        }
        return Array(normalizedPoints.suffix(cappedLimit))
    }

    static func routePointsByVIN(_ values: [String: [FleetRoutePoint]]) -> [String: [FleetRoutePoint]] {
        normalizeDictionary(values) { routePoints($0) }
    }

    static func routePointsBySessionID(_ values: [String: [FleetRoutePoint]]) -> [String: [FleetRoutePoint]] {
        normalizeDictionary(values) { routePoints($0) }
    }

    // MARK: - Route Kinematics & Geometry

    static func derivedDistanceMiles(from route: [FleetRoutePoint]) -> Double? {
        guard route.count > 1 else {
            return nil
        }

        let odometerValues = route.compactMap(\.odometer)
        if let firstOdometer = odometerValues.first,
           let lastOdometer = odometerValues.last,
           let odometerDistance = nonNegative(lastOdometer - firstOdometer),
           odometerDistance > 0 {
            return odometerDistance
        }

        let distanceMeters = zip(route, route.dropFirst()).reduce(0.0) { total, pair in
            total + distanceMeters(from: pair.0, to: pair.1)
        }
        let distanceMiles = distanceMeters / metersPerMile
        return distanceMiles > 0 ? distanceMiles : nil
    }

    static func derivedAverageSpeedMPH(
        distanceMiles: Double?,
        durationMS: Int64?,
        route: [FleetRoutePoint]
    ) -> Double? {
        if let distanceMiles,
           let durationMS,
           durationMS > 0 {
            let hours = Double(durationMS) / millisecondsPerHour
            if hours > 0 {
                return nonNegative(distanceMiles / hours)
            }
        }

        let speeds = route.compactMap(\.speed).filter { $0.isFinite && $0 >= 0 }
        guard !speeds.isEmpty else {
            return nil
        }
        return speeds.reduce(0, +) / Double(speeds.count)
    }

    static func derivedMaxSpeedMPH(from route: [FleetRoutePoint]) -> Double? {
        route.compactMap(\.speed).filter { $0.isFinite && $0 >= 0 }.max()
    }

    private static func distanceMeters(from start: FleetRoutePoint, to end: FleetRoutePoint) -> Double {
        guard let startLatitude = start.latitude,
              let startLongitude = start.longitude,
              let endLatitude = end.latitude,
              let endLongitude = end.longitude else {
            return 0
        }

        let startLatitudeRadians = startLatitude * .pi / 180
        let endLatitudeRadians = endLatitude * .pi / 180
        let deltaLatitude = (endLatitude - startLatitude) * .pi / 180
        let deltaLongitude = (endLongitude - startLongitude) * .pi / 180

        let haversine = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
            + cos(startLatitudeRadians) * cos(endLatitudeRadians) * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
        let clampedHaversine = min(max(haversine, 0), 1)
        return earthRadiusMeters * 2 * atan2(sqrt(clampedHaversine), sqrt(1 - clampedHaversine))
    }

    // MARK: - Telemetry Series

    static func telemetrySeries(
        _ points: [FleetTelemetrySeriesPoint],
        limit: Int? = nil
    ) -> [FleetTelemetrySeriesPoint] {
        let cappedLimit = min(limit ?? maxCachedTelemetryPoints, maxCachedTelemetryPoints)
        return points
            .compactMap { rawPoint in
                var point = rawPoint
                point.fields = normalizedTelemetryFields(point.fields)
                return point.isEmpty ? nil : point
            }
            .sorted { telemetryTimestamp($0) > telemetryTimestamp($1) }
            .prefix(cappedLimit)
            .map { $0 }
    }

    static func telemetrySeriesByVIN(
        _ values: [String: [FleetTelemetrySeriesPoint]]
    ) -> [String: [FleetTelemetrySeriesPoint]] {
        normalizeDictionary(values) { telemetrySeries($0) }
    }

    private static func normalizedTelemetryFields(_ fields: [String: JSONValue]) -> [String: JSONValue] {
        var normalizedFields: [String: JSONValue] = [:]
        for (key, value) in fields {
            guard let normalizedKey = normalizedString(key) else {
                continue
            }

            switch normalizedKey.lowercased() {
            case "timestamp", "updated_at", "updatedat", "source_timestamp":
                if let milliseconds = jsonInt64(value).flatMap(normalizedEpochMilliseconds) {
                    normalizedFields[normalizedKey] = .integer(Int(milliseconds))
                }
            case "battery_level", "charge_limit_soc", "download_percent", "install_percent", "state_of_charge":
                if let percentValue = jsonDouble(value).flatMap(percent) {
                    normalizedFields[normalizedKey] = .double(percentValue)
                }
            case "latitude", "lat":
                if let latitude = jsonDouble(value).flatMap({ coordinate($0, min: -90, max: 90) }) {
                    normalizedFields[normalizedKey] = .double(latitude)
                }
            case "longitude", "lon", "lng":
                if let longitude = jsonDouble(value).flatMap({ coordinate($0, min: -180, max: 180) }) {
                    normalizedFields[normalizedKey] = .double(longitude)
                }
            case "speed", "odometer", "charge_rate_mph", "charger_power_kw",
                 "energy_added_kwh", "energy_used_kwh", "inside_temp", "outside_temp", "time_to_full_charge":
                if let numericValue = jsonDouble(value).flatMap(nonNegative) {
                    normalizedFields[normalizedKey] = .double(numericValue)
                }
            default:
                normalizedFields[normalizedKey] = normalizedJSONValue(value)
            }
        }
        return normalizedFields
    }

    private static func telemetryTimestamp(_ point: FleetTelemetrySeriesPoint) -> Int64 {
        jsonInt64(point["timestamp"])
            ?? jsonInt64(point["updated_at"])
            ?? jsonInt64(point["updatedAt"])
            ?? 0
    }
}
