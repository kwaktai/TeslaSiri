import CoreLocation
import Foundation
import MapKit

func formattedNumber(_ value: Double?, fractionLength: Int = 0, suffix: String = "") -> String {
    guard let value else {
        return "--"
    }

    return value.formatted(.number.precision(.fractionLength(fractionLength))) + suffix
}

func formattedDuration(milliseconds: Int64?) -> String {
    guard let milliseconds, milliseconds > 0 else {
        return "--"
    }

    let totalSeconds = Int(milliseconds / 1_000)
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
        return "\(hours) hr \(minutes) min"
    }
    if minutes > 0 {
        return "\(minutes) min"
    }
    return "\(seconds) sec"
}

/// Turns raw backend states such as "In_Progress" or "charging" into "In progress" / "Charging".
func humanizedStatus(_ raw: String) -> String {
    let spaced = raw
        .replacingOccurrences(of: "_", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard let first = spaced.first else { return raw }
    return first.uppercased() + spaced.dropFirst()
}

func formattedCoordinate(latitude: Double?, longitude: Double?) -> String {
    guard let latitude, let longitude else {
        return "--"
    }

    let lat = latitude.formatted(.number.precision(.fractionLength(4)))
    let lon = longitude.formatted(.number.precision(.fractionLength(4)))
    return "\(lat), \(lon)"
}

func driveEndpointSummary(_ drive: FleetDriveSession, endpointAddresses: DriveEndpointAddresses?) -> String {
    let startAddress = endpointAddresses?.start ?? drive.startAddress
    let endAddress = endpointAddresses?.end ?? drive.endAddress

    switch (startAddress, endAddress) {
    case let (start?, end?):
        return "\(start) to \(end)"
    case let (start?, nil):
        return "From \(start)"
    case let (nil, end?):
        return "To \(end)"
    case (nil, nil):
        return "Resolving addresses"
    }
}

func formattedJSONValue(_ value: JSONValue) -> String {
    switch value {
    case .string(let value):
        return value
    case .integer(let value):
        return String(value)
    case .double(let value):
        return value.formatted(.number.precision(.fractionLength(0...3)))
    case .bool(let value):
        return value ? "true" : "false"
    case .array(let values):
        return "[\(values.count) values]"
    case .object(let object):
        return "{\(object.count) fields}"
    case .null:
        return "null"
    }
}

extension FleetRoutePoint {
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    nonisolated var coordinateKey: String {
        guard let latitude, let longitude else {
            return "missing"
        }
        let lat = latitude.formatted(.number.precision(.fractionLength(5)))
        let lon = longitude.formatted(.number.precision(.fractionLength(5)))
        return "\(lat),\(lon)"
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else {
            return nil
        }
        return self[index]
    }
}
