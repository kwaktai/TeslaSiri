import MapKit
import SwiftUI

struct DriveRouteMap: View {
    let route: [FleetRoutePoint]
    let selectedPointIndex: Int

    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        let coordinates = route.compactMap(\.coordinate)

        ZStack {
            if coordinates.isEmpty {
                ContentUnavailableView("No route", systemImage: "map", description: Text("Select a drive with normalized route geometry."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
            } else {
                Map(position: $cameraPosition) {
                    MapPolyline(coordinates: coordinates)
                        .stroke(.blue, lineWidth: 5)

                    if let firstCoordinate = coordinates.first {
                        Marker("Start", systemImage: "flag.fill", coordinate: firstCoordinate)
                            .tint(.green)
                    }

                    if let lastCoordinate = coordinates.last {
                        Marker("End", systemImage: "flag.checkered", coordinate: lastCoordinate)
                            .tint(.black)
                    }

                    if let selectedCoordinate = route[safe: selectedPointIndex]?.coordinate {
                        Marker("Selected position", systemImage: "mappin.circle.fill", coordinate: selectedCoordinate)
                            .tint(.red)
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }
                .task(id: cameraKey) {
                    if let rect = mapRect(for: coordinates) {
                        cameraPosition = .rect(rect)
                    }
                }
            }
        }
    }

    private var cameraKey: String {
        [route.first?.id, route.last?.id, String(route.count)].compactMap { $0 }.joined(separator: ":")
    }

    private func mapRect(for coordinates: [CLLocationCoordinate2D]) -> MKMapRect? {
        guard let firstCoordinate = coordinates.first else {
            return nil
        }

        var rect = MKMapRect(origin: MKMapPoint(firstCoordinate), size: MKMapSize(width: 1, height: 1))
        for coordinate in coordinates.dropFirst() {
            rect = rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 1, height: 1)))
        }

        let widthPadding = max(rect.size.width * 0.18, 1_200)
        let heightPadding = max(rect.size.height * 0.18, 1_200)
        return rect.insetBy(dx: -widthPadding, dy: -heightPadding)
    }
}

#Preview("With route") {
    DriveRouteMap(route: PreviewData.previewRoute, selectedPointIndex: 0)
        .frame(height: 260)
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Empty route") {
    DriveRouteMap(route: [], selectedPointIndex: 0)
        .frame(height: 260)
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}

