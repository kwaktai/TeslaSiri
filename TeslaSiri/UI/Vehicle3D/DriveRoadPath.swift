import CoreLocation
import Foundation
import MapKit
import OSLog
import simd

/// A recorded drive laid onto the real road network.
///
/// Tessie records a location about every 30 seconds, which is far too sparse to show the
/// shape of the road. `DriveRoadPath` asks MapKit for driving directions between successive
/// samples, keeps each leg only if it agrees with what the car actually did (length close to
/// the odometer distance, and passing near every sample in between), and stitches the legs
/// into a dense polyline. Legs MapKit can't match fall back to straight lines between samples.
///
/// Positions are kept in local meters (east, north) around the first sample. Each recorded
/// sample is placed at its distance along the polyline, so playback can move continuously
/// along the real road and read speed and Autopilot state at any moment.
final class DriveRoadPath: Sendable {
    /// Polyline vertices in meters east and north of `origin`.
    let points: [SIMD2<Double>]
    /// Distance along the polyline at each vertex.
    let cumulative: [Double]
    /// Distance along the polyline of each recorded sample, never decreasing.
    let sampleDistances: [Double]
    /// Seconds since the first sample for each recorded sample, never decreasing.
    let sampleTimes: [Double]
    let sampleSpeeds: [Double]
    let sampleSelfDriving: [Bool]
    let originLatitude: Double
    let originLongitude: Double
    /// Fraction of the drive's legs that MapKit snapped to roads.
    let matchedFraction: Double

    var length: Double { cumulative.last ?? 0 }
    var duration: Double { sampleTimes.last ?? 0 }

    private init(
        points: [SIMD2<Double>],
        cumulative: [Double],
        sampleDistances: [Double],
        sampleTimes: [Double],
        sampleSpeeds: [Double],
        sampleSelfDriving: [Bool],
        origin: CLLocationCoordinate2D,
        matchedFraction: Double
    ) {
        self.points = points
        self.cumulative = cumulative
        self.sampleDistances = sampleDistances
        self.sampleTimes = sampleTimes
        self.sampleSpeeds = sampleSpeeds
        self.sampleSelfDriving = sampleSelfDriving
        originLatitude = origin.latitude
        originLongitude = origin.longitude
        self.matchedFraction = matchedFraction
    }

    // MARK: - Playback queries

    /// The last recorded sample at or before `time`.
    func sampleIndex(atTime time: Double) -> Int {
        guard !sampleTimes.isEmpty else { return 0 }
        var low = 0, high = sampleTimes.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if sampleTimes[mid] <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func distance(atTime time: Double) -> Double {
        interpolate(sampleDistances, atTime: time)
    }

    func speed(atTime time: Double) -> Double {
        interpolate(sampleSpeeds, atTime: time)
    }

    func isSelfDriving(atTime time: Double) -> Bool {
        sampleSelfDriving.isEmpty ? false : sampleSelfDriving[sampleIndex(atTime: time)]
    }

    func time(ofSample index: Int) -> Double {
        sampleTimes.isEmpty ? 0 : sampleTimes[min(max(index, 0), sampleTimes.count - 1)]
    }

    func coordinate(atDistance distance: Double) -> CLLocationCoordinate2D {
        let local = position(atDistance: distance, segment: segmentIndex(atDistance: distance))
        let metersPerDegreeLatitude = 110_540.0
        let metersPerDegreeLongitude = 111_320.0 * cos(originLatitude * .pi / 180)
        return CLLocationCoordinate2D(
            latitude: originLatitude + local.y / metersPerDegreeLatitude,
            longitude: originLongitude + local.x / max(metersPerDegreeLongitude, 1)
        )
    }

    /// The road around `distance` in the car's frame, for `VehicleRoadScene`.
    func shape(atDistance distance: Double) -> RoadShape {
        guard points.count >= 2 else { return .straight }
        // The heading spans 12 m on either side. With 3 m between samples, its two
        // positions are already four slots away on the same regularly spaced line.
        let step = 3
        let behind = 30
        let ahead = 150
        let headingRadius = 4
        let first = -behind / step
        let last = ahead / step
        var segment = segmentIndex(atDistance: distance + Double((first - headingRadius) * step))
        var positions: [SIMD2<Double>] = []
        positions.reserveCapacity(last - first + 1 + 2 * headingRadius)
        for index in (first - headingRadius)...(last + headingRadius) {
            let along = distance + Double(index * step)
            while segment + 1 < points.count - 1, cumulative[segment + 1] <= along {
                segment += 1
            }
            positions.append(position(atDistance: along, segment: segment))
        }

        let centerIndex = headingRadius - first
        let center = positions[centerIndex]
        let heading = Self.heading(from: positions[centerIndex - headingRadius], to: positions[centerIndex + headingRadius])
        let forward = SIMD2(sin(heading), cos(heading))
        let right = SIMD2(cos(heading), -sin(heading))
        var samples: [SIMD3<Float>] = []
        samples.reserveCapacity(last - first + 1)
        for index in headingRadius..<(positions.count - headingRadius) {
            let offset = positions[index] - center
            var turn = Self.heading(from: positions[index - headingRadius], to: positions[index + headingRadius]) - heading
            while turn > .pi { turn -= 2 * .pi }
            while turn < -.pi { turn += 2 * .pi }
            samples.append(SIMD3(Float(simd_dot(offset, forward)), Float(simd_dot(offset, right)), Float(turn)))
        }
        return RoadShape(curvature: 0, start: Float(-behind), step: Float(step), samples: samples)
    }

    // MARK: - Geometry

    private func interpolate(_ values: [Double], atTime time: Double) -> Double {
        guard !values.isEmpty, values.count == sampleTimes.count else { return values.first ?? 0 }
        let index = sampleIndex(atTime: time)
        guard index + 1 < values.count else { return values[index] }
        let span = sampleTimes[index + 1] - sampleTimes[index]
        let fraction = span > 0 ? min(max((time - sampleTimes[index]) / span, 0), 1) : 0
        return values[index] + (values[index + 1] - values[index]) * fraction
    }

    /// Position at `distance`, continuing straight past either end.
    private func position(atDistance distance: Double, segment: Int) -> SIMD2<Double> {
        guard points.count >= 2 else { return points.first ?? .zero }
        if distance <= 0 {
            let direction = simd_normalize(points[1] - points[0])
            return points[0] + direction * distance
        }
        if distance >= length {
            let count = points.count
            let direction = simd_normalize(points[count - 1] - points[count - 2])
            return points[count - 1] + direction * (distance - length)
        }
        let span = cumulative[segment + 1] - cumulative[segment]
        let fraction = span > 0 ? (distance - cumulative[segment]) / span : 0
        return points[segment] + (points[segment + 1] - points[segment]) * fraction
    }

    /// Compass heading (radians, clockwise from north), smoothed over about 24 m so that
    /// polyline vertices don't make the road twitch.
    private static func heading(from before: SIMD2<Double>, to after: SIMD2<Double>) -> Double {
        let delta = after - before
        guard simd_length(delta) > 0.01 else { return 0 }
        return atan2(delta.x, delta.y)
    }

    private func segmentIndex(atDistance distance: Double) -> Int {
        var low = 0, high = cumulative.count - 2
        while low < high {
            let mid = (low + high + 1) / 2
            if cumulative[mid] <= distance { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

// MARK: - Map matching

extension DriveRoadPath {
    private static let log = Logger(subsystem: "com.maxweinbach.TeslaSiri", category: "DriveRoadPath")
    @MainActor private static var cache: [(driveSessionID: String?, samples: [FleetRoutePoint], path: DriveRoadPath)] = []
    private static let cacheLimit = 8

    /// Builds the road path for a recorded drive, reusing recently matched routes.
    @MainActor
    static func build(for route: [FleetRoutePoint], driveSessionID: String?) async -> DriveRoadPath? {
        guard !Task.isCancelled else { return nil }
        if let index = cache.lastIndex(where: { $0.driveSessionID == driveSessionID && $0.samples == route }) {
            let entry = cache.remove(at: index)
            cache.append(entry)
            return entry.path
        }
        let samples = route.compactMap { point -> (CLLocationCoordinate2D, FleetRoutePoint)? in
            guard let latitude = point.latitude, let longitude = point.longitude else { return nil }
            return (CLLocationCoordinate2D(latitude: latitude, longitude: longitude), point)
        }
        guard samples.count >= 2 else { return nil }

        let origin = samples[0].0
        let metersPerDegreeLatitude = 110_540.0
        let metersPerDegreeLongitude = 111_320.0 * cos(origin.latitude * .pi / 180)
        func local(_ coordinate: CLLocationCoordinate2D) -> SIMD2<Double> {
            SIMD2(
                (coordinate.longitude - origin.longitude) * metersPerDegreeLongitude,
                (coordinate.latitude - origin.latitude) * metersPerDegreeLatitude
            )
        }
        let sampleLocal = samples.map { local($0.0) }

        // Legs of roughly 600 m keep MapKit on the roads the car used while staying well
        // inside its request budget (about 15 requests for a 10-mile drive).
        var legs: [(start: Int, end: Int)] = []
        var legStart = 0
        var legLength = 0.0
        for index in 1..<samples.count {
            legLength += simd_distance(sampleLocal[index - 1], sampleLocal[index])
            if legLength >= 600 || index == samples.count - 1 {
                legs.append((legStart, index))
                legStart = index
                legLength = 0
            }
        }

        var polyline: [SIMD2<Double>] = [sampleLocal[0]]
        var matchedLegs = 0
        var throttled = false
        for leg in legs {
            if Task.isCancelled { return nil }
            var legPoints: [SIMD2<Double>]? = nil
            if !throttled {
                do {
                    legPoints = try await matchedLeg(leg, samples: samples, sampleLocal: sampleLocal, local: local)
                } catch let error as MKError where error.code == .loadingThrottled {
                    throttled = true
                    log.info("MapKit throttled road matching; using recorded points for the rest of the drive")
                } catch {
                    log.debug("Road match failed for a leg: \(error.localizedDescription, privacy: .public)")
                }
            }
            if let legPoints {
                matchedLegs += 1
                polyline.append(contentsOf: legPoints.dropFirst())
            } else {
                polyline.append(contentsOf: sampleLocal[(leg.start + 1)...leg.end])
            }
        }

        guard !Task.isCancelled else { return nil }
        // Remove duplicate vertices, then place every sample at its distance along the road.
        var cleaned: [SIMD2<Double>] = []
        for point in polyline where cleaned.last.map({ simd_distance($0, point) > 0.5 }) ?? true {
            cleaned.append(point)
        }
        guard cleaned.count >= 2 else { return nil }
        let projection = projectedDistances(of: sampleLocal, onto: cleaned)

        let startTime = samples[0].1.timestamp ?? 0
        var times: [Double] = []
        for (index, sample) in samples.enumerated() {
            let raw = sample.1.timestamp.map { Double($0 - startTime) / 1000 } ?? Double(index) * 30
            times.append(max(raw, times.last ?? 0))
        }

        let path = DriveRoadPath(
            points: cleaned,
            cumulative: projection.cumulative,
            sampleDistances: projection.distances,
            sampleTimes: times,
            sampleSpeeds: samples.map { max($0.1.speed ?? 0, 0) },
            sampleSelfDriving: samples.map { $0.1.isSelfDriving },
            origin: origin,
            matchedFraction: legs.isEmpty ? 0 : Double(matchedLegs) / Double(legs.count)
        )
        log.info("Matched \(matchedLegs, privacy: .public)/\(legs.count, privacy: .public) legs, \(cleaned.count, privacy: .public) road points for \(samples.count, privacy: .public) samples")
        guard !Task.isCancelled else { return nil }
        cache.removeAll { entry in
            entry.driveSessionID == driveSessionID && (driveSessionID != nil || entry.samples == route)
        }
        cache.append((driveSessionID, route, path))
        if cache.count > cacheLimit { cache.removeFirst() }
        return path
    }

    /// Driving directions for one leg, accepted only if they plausibly match the drive.
    @MainActor
    private static func matchedLeg(
        _ leg: (start: Int, end: Int),
        samples: [(CLLocationCoordinate2D, FleetRoutePoint)],
        sampleLocal: [SIMD2<Double>],
        local: (CLLocationCoordinate2D) -> SIMD2<Double>
    ) async throws -> [SIMD2<Double>]? {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: samples[leg.start].0.latitude, longitude: samples[leg.start].0.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: samples[leg.end].0.latitude, longitude: samples[leg.end].0.longitude), address: nil)
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        let response = try await MKDirections(request: request).calculate()

        var straight = 0.0
        for index in (leg.start + 1)...leg.end {
            straight += simd_distance(sampleLocal[index - 1], sampleLocal[index])
        }
        var expected = straight
        if let startOdometer = samples[leg.start].1.odometer, let endOdometer = samples[leg.end].1.odometer, endOdometer > startOdometer {
            expected = max(expected, (endOdometer - startOdometer) * 1_609.344)
        }

        for route in response.routes {
            guard route.distance <= expected * 1.3 + 150, route.distance >= expected * 0.7 - 50 else { continue }
            let count = route.polyline.pointCount
            guard count >= 2 else { continue }
            var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: count)
            route.polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: count))
            var points = coordinates.map(local)
            // Every sample inside the leg must sit close to the road MapKit chose.
            let interior = sampleLocal[leg.start...leg.end]
            guard interior.allSatisfy({ isWithinRoadTolerance($0, polyline: points) }) else { continue }
            points[0] = sampleLocal[leg.start]
            points[points.count - 1] = sampleLocal[leg.end]
            return points
        }
        return nil
    }

    private static func isWithinRoadTolerance(_ point: SIMD2<Double>, polyline: [SIMD2<Double>]) -> Bool {
        for index in polyline.indices.dropFirst() {
            let nearest = closestPoint(point, polyline[index - 1], polyline[index]).point
            if simd_distance_squared(point, nearest) < 60 * 60 { return true }
        }
        return false
    }

    private static func closestPoint(_ point: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> (point: SIMD2<Double>, fraction: Double) {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 0 else { return (a, 0) }
        let t = min(max(simd_dot(point - a, ab) / lengthSquared, 0), 1)
        return (a + ab * t, t)
    }

    /// Distance along `polyline` for each sample, searching forward from the previous sample
    /// so the car never moves backward along the road.
    private static func projectedDistances(
        of samples: [SIMD2<Double>],
        onto polyline: [SIMD2<Double>]
    ) -> (cumulative: [Double], distances: [Double]) {
        var cumulative: [Double] = [0]
        for index in polyline.indices.dropFirst() {
            cumulative.append(cumulative[index - 1] + simd_distance(polyline[index - 1], polyline[index]))
        }
        var result: [Double] = []
        var segment = 0
        for sample in samples {
            var bestDistance = Double.infinity
            var bestAlong = cumulative[segment]
            var bestSegment = segment
            var index = segment
            // Look ahead along the road; stop once well past the closest approach.
            while index < polyline.count - 1 {
                let closest = closestPoint(sample, polyline[index], polyline[index + 1])
                let gap = simd_distance(sample, closest.point)
                if gap < bestDistance {
                    bestDistance = gap
                    bestSegment = index
                    bestAlong = cumulative[index] + (cumulative[index + 1] - cumulative[index]) * closest.fraction
                }
                if cumulative[index] - bestAlong > 1_500 { break }
                index += 1
            }
            segment = bestSegment
            result.append(max(bestAlong, result.last ?? 0))
        }
        return (cumulative, result)
    }
}
