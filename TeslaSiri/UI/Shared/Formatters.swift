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
        return WattieCopy.text("\(hours) hr \(minutes) min", "\(hours)시간 \(minutes)분")
    }
    if minutes > 0 {
        return WattieCopy.text("\(minutes) min", "\(minutes)분")
    }
    return WattieCopy.text("\(seconds) sec", "\(seconds)초")
}

/// Turns raw backend states such as "In_Progress" or "charging" into "In progress" / "Charging".
func humanizedStatus(_ raw: String) -> String {
    let spaced = raw
        .replacingOccurrences(of: "_", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard let first = spaced.first else { return raw }
    let titled = first.uppercased() + spaced.dropFirst()
    let korean: [String: String] = [
        "charging": "충전 중",
        "complete": "완료",
        "completed": "완료",
        "stopped": "중지됨",
        "starting": "시작 중",
        "nopower": "전원 없음",
        "no power": "전원 없음",
        "disconnected": "분리됨",
        "in progress": "진행 중",
        "available": "설치 가능",
        "downloading": "다운로드 중",
        "installing": "설치 중",
        "scheduled": "예약됨",
        "asleep": "절전",
        "offline": "오프라인",
        "online": "온라인",
        "parked": "주차",
        "locked": "잠김",
        "unlocked": "잠금 해제",
        "connected": "연결됨"
    ]
    return WattieCopy.text(titled, korean[spaced] ?? titled)
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
        return WattieCopy.text("\(start) to \(end)", "\(start)에서 \(end)")
    case let (start?, nil):
        return WattieCopy.text("From \(start)", "\(start)에서 출발")
    case let (nil, end?):
        return WattieCopy.text("To \(end)", "\(end)에 도착")
    case (nil, nil):
        return WattieCopy.text("Resolving addresses", "주소 찾는 중")
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
