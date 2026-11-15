import CoreLocation
import Foundation
import Observation

/// Plays a recorded drive back along its map-matched road.
///
/// The playhead is time since the drive started. Each rendered frame it advances (while
/// playing), finds the matching distance along the road, and hands the stage the real road
/// shape around that point, how far the car moved this frame (so lane lines stream at the
/// replay's true pace), and the recorded speed and Autopilot state. SwiftUI-facing values are
/// published at most a few times a second so the card around the 3D view stays calm.
@MainActor
@Observable
final class DriveReplayController {
    enum Speed: Double, CaseIterable, Identifiable {
        case real = 1
        case fast = 5
        case faster = 20

        var id: Double { rawValue }
        var title: String {
            switch self {
            case .real: "1×"
            case .fast: "5×"
            case .faster: "20×"
            }
        }
    }

    private(set) var path: DriveRoadPath?
    private(set) var isMatchingRoads = false
    /// The recorded sample under the playhead, for the scrubber and map.
    private(set) var sampleIndex = 0
    /// Recorded speed at the playhead, rounded to whole miles per hour.
    private(set) var speedMPH: Double = 0
    private(set) var isSelfDriving = false
    /// The car's position, refreshed every couple of seconds while playing, for street view.
    private(set) var streetCoordinate: CLLocationCoordinate2D?
    var speed: Speed = .fast
    var isPlaying = false {
        didSet {
            guard oldValue != isPlaying else { return }
            if isPlaying, let path, time >= path.duration - 0.5 { time = 0 }
            sincePublish = 0
            sinceStreet = 0
            publish()
            publishStreetCoordinate()
        }
    }

    struct Route: Equatable {
        let driveSessionID: String?
        let points: [FleetRoutePoint]
    }

    @ObservationIgnored private var time: Double = 0
    @ObservationIgnored private var shownDistance: Double?
    @ObservationIgnored private var shownShape: RoadShape?
    @ObservationIgnored private var loadedRoute: Route?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var sincePublish: Double = 0
    @ObservationIgnored private var sinceStreet: Double = 0

    func load(_ route: Route) async {
        guard !Task.isCancelled, route != loadedRoute else { return }
        loadGeneration += 1
        let generation = loadGeneration
        loadedRoute = nil
        path = nil
        isPlaying = false
        shownDistance = nil
        shownShape = nil
        streetCoordinate = nil
        isMatchingRoads = true
        let built = await DriveRoadPath.build(for: route.points, driveSessionID: route.driveSessionID)
        guard generation == loadGeneration else { return }
        isMatchingRoads = false
        guard !Task.isCancelled else { return }
        loadedRoute = route
        path = built
        time = built?.time(ofSample: sampleIndex) ?? 0
        publish()
        publishStreetCoordinate()
    }

    func hasLoadedDrive(_ driveSessionID: String?) -> Bool {
        path != nil && loadedRoute?.driveSessionID == driveSessionID
    }

    /// Jumps the playhead to a recorded sample, such as when the user scrubs.
    func seek(toSample index: Int) {
        guard index != sampleIndex || path == nil else { return }
        sampleIndex = index
        guard let path else { return }
        time = path.time(ofSample: index)
        publish()
        publishStreetCoordinate()
    }

    /// Advances playback by one frame and drives the stage, if the 3D view is showing.
    func frame(_ deltaTime: Double, stage: VehicleStage?) {
        guard let path else {
            stage?.setDriveOverride(nil)
            return
        }
        if isPlaying {
            time = min(time + deltaTime * speed.rawValue, path.duration)
            if time >= path.duration { isPlaying = false }
        }

        if let stage {
            updateStage(stage, path: path, deltaTime: deltaTime)
        } else {
            // A newly enabled 3D stage starts at the current playhead.
            shownDistance = nil
            shownShape = nil
        }

        guard isPlaying else { return }
        sincePublish += deltaTime
        if sincePublish >= 0.25 {
            sincePublish = 0
            publish()
        }
        sinceStreet += deltaTime
        if sinceStreet >= 2 {
            sinceStreet = 0
            publishStreetCoordinate()
        }
    }

    private func updateStage(_ stage: VehicleStage, path: DriveRoadPath, deltaTime: Double) {
        let target = path.distance(atTime: time)
        let previous = shownDistance ?? target
        let gap = target - previous
        let shown: Double
        if abs(gap) < 0.001 || (isPlaying && abs(gap) < 400) || abs(gap) > 4_000 {
            shown = target
        } else {
            // Glide toward a newly scrubbed position.
            shown = previous + gap * min(1, deltaTime * 4)
        }

        let shape: RoadShape
        if shown == shownDistance, let shownShape {
            shape = shownShape
        } else {
            shape = path.shape(atDistance: shown)
            shownDistance = shown
            shownShape = shape
        }

        let recordedSpeed = path.speed(atTime: time)
        let travel = shown - previous
        // The paused stage still animates its wheels and lane lines at the recorded speed.
        let travelSpeed = deltaTime > 0 && abs(travel) > 0.001 ? travel / deltaTime : recordedSpeed * 0.44704
        stage.setDriveOverride(.init(
            speedMPH: recordedSpeed,
            travelSpeed: Float(travelSpeed),
            shape: shape,
            isSelfDriving: path.isSelfDriving(atTime: time)
        ))
    }

    private func publish() {
        guard let path else { return }
        let index = path.sampleIndex(atTime: time)
        if index != sampleIndex { sampleIndex = index }
        let roundedSpeed = path.speed(atTime: time).rounded()
        if roundedSpeed != speedMPH { speedMPH = roundedSpeed }
        let selfDriving = path.isSelfDriving(atTime: time)
        if selfDriving != isSelfDriving { isSelfDriving = selfDriving }
    }

    private func publishStreetCoordinate() {
        guard let path else { return }
        streetCoordinate = path.coordinate(atDistance: path.distance(atTime: time))
    }
}
