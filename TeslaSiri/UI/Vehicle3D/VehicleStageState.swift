import CoreLocation
import Foundation

/// Everything the 3D stage mirrors from the real car. Built from a live snapshot or from a
/// recorded drive sample; the stage animates toward each new value rather than jumping.
struct VehicleStageState: Equatable {
    enum Mode: Equatable {
        case parked
        case charging
        case driving
    }

    var mode: Mode = .parked
    var openings: Set<VehicleOpening> = []
    var isLocked: Bool?
    var isChargePortOpen = false
    var isCharging = false
    var isSentryOn = false
    var isClimateOn = false
    var isReversing = false
    /// Autopilot or FSD was steering, per Tessie's recorded path.
    var isSelfDriving = false
    /// Road speed in miles per hour.
    var speedMPH: Double = 0
    /// Path curvature in 1/meters. Positive bends right.
    var curvature: Double = 0

    static let showroom = VehicleStageState()

    init() {}

    init(snapshot: FleetLatestSnapshot, activeDrive: FleetActiveDriveSession? = nil, rightHandDrive: Bool = false) {
        let gear = snapshot.gear?.uppercased()
        let speed = snapshot.speed ?? activeDrive?.latestRoutePoint?.speed ?? 0
        let isInMotionGear = gear == "D" || gear == "R" || gear == "N"
        let chargingState = snapshot.chargingState?.lowercased() ?? ""
        let isPluggedIn = !chargingState.isEmpty && chargingState != "disconnected"

        if isInMotionGear || speed > 0.5 {
            mode = .driving
        } else if isPluggedIn {
            mode = .charging
        } else {
            mode = .parked
        }

        isLocked = snapshot.locked
        isChargePortOpen = snapshot.chargePortDoorOpen == true || isPluggedIn
        isCharging = snapshot.isActivelyCharging
        isSentryOn = snapshot.sentryMode == true
        isClimateOn = snapshot.climateOn == true
        isReversing = gear == "R"
        speedMPH = max(speed, 0)
        openings = VehicleOpening.openings(in: snapshot.closures, rightHandDrive: rightHandDrive)

        isSelfDriving = (activeDrive?.route.last ?? activeDrive?.latestRoutePoint)?.isSelfDriving ?? false

        if mode == .driving, let route = activeDrive?.route, route.count >= 3 {
            curvature = Self.curvature(of: route.suffix(3).map { $0 })
        }
    }

    /// A recorded drive sample for route playback.
    init(drivePoint index: Int, in route: [FleetRoutePoint]) {
        mode = .driving
        isLocked = true
        speedMPH = max(route[safe: index]?.speed ?? 0, 0)
        isSelfDriving = route[safe: index]?.isSelfDriving ?? false
        let lower = max(0, index - 2)
        let upper = min(route.count - 1, index + 2)
        if upper - lower >= 2 {
            curvature = Self.curvature(of: Array(route[lower...upper]))
        }
    }

    /// Signed curvature (1/m) through route points, from the change in compass bearing
    /// over the distance travelled. Clamped to a 12 m radius.
    static func curvature(of points: [FleetRoutePoint]) -> Double {
        let coordinates = points.compactMap { point -> CLLocation? in
            guard let latitude = point.latitude, let longitude = point.longitude else { return nil }
            return CLLocation(latitude: latitude, longitude: longitude)
        }
        guard coordinates.count >= 3 else { return 0 }
        let first = coordinates[0]
        let middle = coordinates[coordinates.count / 2]
        let last = coordinates[coordinates.count - 1]
        let distance = first.distance(from: middle) + middle.distance(from: last)
        guard distance > 3 else { return 0 }
        var turn = bearing(from: middle, to: last) - bearing(from: first, to: middle)
        while turn > .pi { turn -= 2 * .pi }
        while turn < -.pi { turn += 2 * .pi }
        let curvature = turn / distance
        return min(max(curvature, -1.0 / 12), 1.0 / 12)
    }

    private static func bearing(from start: CLLocation, to end: CLLocation) -> Double {
        let lat1 = start.coordinate.latitude * .pi / 180
        let lat2 = end.coordinate.latitude * .pi / 180
        let deltaLon = (end.coordinate.longitude - start.coordinate.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        return atan2(y, x)
    }
}

/// Doors, windows and trunks that have keyframed animations on every bundled build.
enum VehicleOpening: String, CaseIterable, Hashable, Sendable {
    case frunk
    case trunk
    case chargePort
    case leftFrontDoor
    case rightFrontDoor
    case leftRearDoor
    case rightRearDoor
    case leftFrontWindow
    case rightFrontWindow
    case leftRearWindow
    case rightRearWindow

    /// Clip-name prefixes in `vehicle.json`, most specific first.
    var clipPrefixes: [String] {
        switch self {
        case .frunk: ["HoodAnimation"]
        case .trunk: ["TrunkAnimation"]
        case .chargePort: ["ChargeportAnimation"]
        case .leftFrontDoor: ["LFDoorAnimation"]
        case .rightFrontDoor: ["RFDoorAnimation"]
        case .leftRearDoor: ["LRDoorAnimationComplete", "LRDoorAnimation"]
        case .rightRearDoor: ["RRDoorAnimationComplete", "RRDoorAnimation"]
        case .leftFrontWindow: ["LFWindowAnimation"]
        case .rightFrontWindow: ["RFWindowAnimation"]
        case .leftRearWindow: ["LRWindowAnimation"]
        case .rightRearWindow: ["RRWindowAnimation"]
        }
    }

    /// Tessie reports doors by driver/passenger; the model's clips are left/right.
    static func openings(in closures: FleetVehicleClosureState?, rightHandDrive: Bool) -> Set<VehicleOpening> {
        guard let closures else { return [] }
        var result: Set<VehicleOpening> = []
        let driverFront: VehicleOpening = rightHandDrive ? .rightFrontDoor : .leftFrontDoor
        let passengerFront: VehicleOpening = rightHandDrive ? .leftFrontDoor : .rightFrontDoor
        let driverRear: VehicleOpening = rightHandDrive ? .rightRearDoor : .leftRearDoor
        let passengerRear: VehicleOpening = rightHandDrive ? .leftRearDoor : .rightRearDoor
        let driverFrontWindow: VehicleOpening = rightHandDrive ? .rightFrontWindow : .leftFrontWindow
        let passengerFrontWindow: VehicleOpening = rightHandDrive ? .leftFrontWindow : .rightFrontWindow
        let driverRearWindow: VehicleOpening = rightHandDrive ? .rightRearWindow : .leftRearWindow
        let passengerRearWindow: VehicleOpening = rightHandDrive ? .leftRearWindow : .rightRearWindow

        let pairs: [(Bool?, VehicleOpening)] = [
            (closures.frontTrunkOpen, .frunk),
            (closures.rearTrunkOpen, .trunk),
            (closures.frontDriverDoorOpen, driverFront),
            (closures.frontPassengerDoorOpen, passengerFront),
            (closures.rearDriverDoorOpen, driverRear),
            (closures.rearPassengerDoorOpen, passengerRear),
            (closures.frontDriverWindowOpen, driverFrontWindow),
            (closures.frontPassengerWindowOpen, passengerFrontWindow),
            (closures.rearDriverWindowOpen, driverRearWindow),
            (closures.rearPassengerWindowOpen, passengerRearWindow)
        ]
        for (isOpen, opening) in pairs where isOpen == true {
            result.insert(opening)
        }
        return result
    }
}
