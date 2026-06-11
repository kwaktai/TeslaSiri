import CoreLocation
import Foundation
import MapKit

struct DriveEndpointAddresses: Equatable, Sendable {
    var start: String?
    var end: String?
}

let driveEndpointAddressGeocoder = DriveEndpointAddressGeocoder()

actor DriveEndpointAddressGeocoder {
    private var cachedAddresses: [String: String] = [:]

    func addresses(for drive: FleetDriveSession, route: [FleetRoutePoint]) async -> DriveEndpointAddresses {
        let startAddress: String?
        if let start = drive.startAddress {
            startAddress = start
        } else {
            startAddress = await address(for: route.first)
        }

        let endAddress: String?
        if let end = drive.endAddress {
            endAddress = end
        } else if route.first?.coordinateKey == route.last?.coordinateKey {
            endAddress = startAddress
        } else {
            endAddress = await address(for: route.last)
        }
        return DriveEndpointAddresses(start: startAddress, end: endAddress)
    }

    private func address(for point: FleetRoutePoint?) async -> String? {
        guard let point, let latitude = point.latitude, let longitude = point.longitude else {
            return nil
        }

        let cacheKey = point.coordinateKey
        if let cachedAddress = cachedAddresses[cacheKey] {
            return cachedAddress
        }

        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else {
            return nil
        }

        do {
            guard let mapItem = try await request.mapItems.first else {
                return nil
            }
            let address = formattedAddress(from: mapItem)
            cachedAddresses[cacheKey] = address
            return address
        } catch {
            return nil
        }
    }

    private func formattedAddress(from mapItem: MKMapItem) -> String {
        [mapItem.address?.shortAddress, mapItem.address?.fullAddress, mapItem.name]
            .compactMap(normalizedPlacemarkPart)
            .first ?? "Address unavailable"
    }

    private func normalizedPlacemarkPart(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }
}
