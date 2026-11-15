import CoreLocation
import Foundation
import MapKit

/// A place the car drives to or from, such as a gym, an office or home: a cluster of drive
/// endpoints within about 120 m, named from the nearest Apple Maps point of interest, a name
/// saved in Tessie, or the street address.
struct DrivePlace: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    /// Raw `MKPointOfInterestCategory` value when the name came from a point of interest.
    var category: String?
    var address: String?
    var latitude: Double
    var longitude: Double
    /// Drives that ended here, newest first.
    var arrivalIDs: [String]
    /// Drives that started here, newest first.
    var departureIDs: [String]
    var lastVisit: Int64
    /// Whether the name has been looked up (not just taken from Tessie's address).
    var isResolved: Bool

    var visitCount: Int { arrivalIDs.count }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    var systemImage: String {
        let lowered = name.lowercased()
        if lowered == "home" { return "house.fill" }
        if lowered == "work" || lowered == "office" { return "briefcase.fill" }
        guard let category else { return "mappin.circle.fill" }
        return Self.symbols[MKPointOfInterestCategory(rawValue: category)] ?? "mappin.circle.fill"
    }

    /// Words to match in search beyond the name: the category in plain English.
    var categoryName: String? {
        guard let category else { return nil }
        return Self.categoryNames[MKPointOfInterestCategory(rawValue: category)]
    }

    func matches(_ query: String) -> Bool {
        name.localizedStandardContains(query)
            || address?.localizedStandardContains(query) == true
            || categoryName?.localizedStandardContains(query) == true
    }

    private static let symbols: [MKPointOfInterestCategory: String] = [
        .fitnessCenter: "figure.strengthtraining.traditional",
        .restaurant: "fork.knife",
        .cafe: "cup.and.saucer.fill",
        .bakery: "birthday.cake.fill",
        .brewery: "mug.fill",
        .winery: "wineglass.fill",
        .nightlife: "wineglass.fill",
        .foodMarket: "cart.fill",
        .store: "bag.fill",
        .gasStation: "fuelpump.fill",
        .evCharger: "bolt.car.fill",
        .parking: "parkingsign",
        .school: "graduationcap.fill",
        .university: "graduationcap.fill",
        .hospital: "cross.case.fill",
        .pharmacy: "pills.fill",
        .airport: "airplane",
        .hotel: "bed.double.fill",
        .park: "tree.fill",
        .nationalPark: "tree.fill",
        .beach: "beach.umbrella.fill",
        .marina: "sailboat.fill",
        .bank: "building.columns.fill",
        .atm: "banknote.fill",
        .movieTheater: "film.fill",
        .theater: "theatermasks.fill",
        .museum: "building.columns",
        .library: "books.vertical.fill",
        .stadium: "sportscourt.fill",
        .postOffice: "envelope.fill",
        .publicTransport: "tram.fill",
        .carRental: "car.fill",
        .police: "shield.fill",
        .fireStation: "flame.fill",
        .laundry: "washer.fill",
        .zoo: "pawprint.fill",
        .amusementPark: "ferriswheel"
    ]

    private static let categoryNames: [MKPointOfInterestCategory: String] = [
        .fitnessCenter: "Gym",
        .restaurant: "Restaurant",
        .cafe: "Cafe coffee",
        .bakery: "Bakery",
        .brewery: "Brewery",
        .winery: "Winery",
        .nightlife: "Bar",
        .foodMarket: "Grocery",
        .store: "Store shopping",
        .gasStation: "Gas station",
        .evCharger: "Charger charging",
        .parking: "Parking",
        .school: "School",
        .university: "University",
        .hospital: "Hospital",
        .pharmacy: "Pharmacy",
        .airport: "Airport",
        .hotel: "Hotel",
        .park: "Park",
        .beach: "Beach",
        .bank: "Bank",
        .movieTheater: "Movies cinema",
        .museum: "Museum",
        .library: "Library",
        .stadium: "Stadium",
        .postOffice: "Post office"
    ]
}

/// Names a coordinate the way a person would: the point of interest the car parked at, a
/// name the user saved in Tessie, or failing those, the street address.
@MainActor
enum DrivePlaceResolver {
    struct Resolution: Sendable {
        var name: String
        var category: String?
        var address: String?
    }

    enum Failure: Error {
        case throttled
    }

    /// Looks up a place for `coordinate`. `tessieLabel` is Tessie's ending/starting location,
    /// which is either a saved name (e.g. "Home") or an address.
    static func resolve(_ coordinate: CLLocationCoordinate2D, tessieLabel: String?) async throws -> Resolution {
        async let addressLookup = reverseGeocode(coordinate)
        if let saved = savedName(from: tessieLabel) {
            let address = try await addressLookup
            return Resolution(name: saved, category: nil, address: address ?? tessieLabel)
        }
        let poi = try await nearestPointOfInterest(to: coordinate)
        let address = try await addressLookup
        if let poi {
            return Resolution(
                name: poi.name ?? address ?? "Unknown place",
                category: poi.pointOfInterestCategory?.rawValue,
                address: address
            )
        }
        return Resolution(
            name: address ?? shortAddress(tessieLabel) ?? "Unknown place",
            category: nil,
            address: address ?? tessieLabel
        )
    }

    /// Tessie reports saved locations by name ("Home", "Work") and everything else as an
    /// address; a short label with no digits or commas is a saved name.
    static func savedName(from label: String?) -> String? {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
              label.count <= 40, !label.contains(","), !label.contains(where: \.isNumber)
        else { return nil }
        return label
    }

    /// The street part of an address ("42 Danbury Avenue").
    static func shortAddress(_ address: String?) -> String? {
        guard let first = address?.split(separator: ",").first else { return nil }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nearestPointOfInterest(to coordinate: CLLocationCoordinate2D) async throws -> MKMapItem? {
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: 150)
        request.pointOfInterestFilter = MKPointOfInterestFilter(excluding: [.parking, .publicTransport, .atm])
        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch let error as MKError where error.code == .loadingThrottled {
            throw Failure.throttled
        } catch {
            return nil
        }
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // The car parks in the lot, not at the pin, so accept anything within about 100 m and
        // take the closest.
        return response.mapItems
            .map { ($0, $0.location.distance(from: target)) }
            .filter { $0.1 <= 100 && $0.0.name?.isEmpty == false }
            .min { $0.1 < $1.1 }?
            .0
    }

    private static func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async throws -> String? {
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) else {
            return nil
        }
        do {
            let item = try await request.mapItems.first
            return item?.address?.shortAddress ?? item?.address?.fullAddress
        } catch let error as MKError where error.code == .loadingThrottled {
            throw Failure.throttled
        } catch {
            return nil
        }
    }
}
