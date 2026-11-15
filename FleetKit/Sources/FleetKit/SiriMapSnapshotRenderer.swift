import CoreLocation
import Foundation
import MapKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum SiriMapVisualStyle: String, Codable, Sendable {
    case standard
    case hybrid

    public var toggled: SiriMapVisualStyle {
        self == .standard ? .hybrid : .standard
    }

    public var badgeLabel: String {
        switch self {
        case .standard: "Satellite"
        case .hybrid: "Standard"
        }
    }

    public var badgeIcon: String {
        switch self {
        case .standard: "globe.americas.fill"
        case .hybrid: "map.fill"
        }
    }
}

public struct SiriRenderedMapData: Sendable {
    public let pngData: Data?
    public let points: [FleetDriveRoutePoint]
    public let style: SiriMapVisualStyle

    public init(pngData: Data?, points: [FleetDriveRoutePoint], style: SiriMapVisualStyle = .standard) {
        self.pngData = pngData
        self.points = points
        self.style = style
    }

    public var hasAutopilotSegments: Bool {
        points.contains(where: \.isAutopilotActive)
    }

    public var swiftUIImage: Image? {
        guard let pngData else { return nil }
        #if canImport(UIKit)
        guard let uiImage = UIImage(data: pngData) else { return nil }
        return Image(uiImage: uiImage)
        #elseif canImport(AppKit)
        guard let nsImage = NSImage(data: pngData) else { return nil }
        return Image(nsImage: nsImage)
        #else
        return nil
        #endif
    }
}

/// Persists lightweight interactive Siri snippet UI state (selected drive index and map style)
/// across `SnippetIntent.reload()` invocations in the App Group container.
public final class SiriSnippetStateStore: @unchecked Sendable {
    public static let shared = SiriSnippetStateStore()
    public static let stateDidChangeNotification = Notification.Name("FleetKit.SiriSnippetStateDidChange")

    private let defaults: UserDefaults?
    private let lock = NSLock()
    private var memoryFallback: [String: String] = [:]

    private init() {
        self.defaults = UserDefaults(suiteName: FleetKitConfig.appGroupIdentifier)
    }

    public func notifyChanged() {
        NotificationCenter.default.post(name: Self.stateDidChangeNotification, object: nil)
    }

    public func mapStyle(for key: String = "global") -> SiriMapVisualStyle {
        let storageKey = "siri.snippet.mapStyle.\(key)"
        guard let raw = readString(forKey: storageKey),
              let style = SiriMapVisualStyle(rawValue: raw) else {
            return .standard
        }
        return style
    }

    @discardableResult
    public func toggleMapStyle(for key: String = "global") -> SiriMapVisualStyle {
        let next = mapStyle(for: key).toggled
        writeString(next.rawValue, forKey: "siri.snippet.mapStyle.\(key)")
        return next
    }

    public func selectedDriveIndex(for sessionKey: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let storageKey = "siri.snippet.driveIndex.\(sessionKey)"
        let raw = Int(readString(forKey: storageKey) ?? "0") ?? 0
        return min(max(raw, 0), count - 1)
    }

    public func setSelectedDriveIndex(_ index: Int, for sessionKey: String) {
        writeString(String(max(index, 0)), forKey: "siri.snippet.driveIndex.\(sessionKey)")
    }

    private func readString(forKey key: String) -> String? {
        if let defaults, let value = defaults.string(forKey: key) {
            return value
        }
        lock.lock()
        defer { lock.unlock() }
        return memoryFallback[key]
    }

    private func writeString(_ value: String, forKey key: String) {
        defaults?.set(value, forKey: key)
        lock.lock()
        memoryFallback[key] = value
        lock.unlock()
        notifyChanged()
    }
}

private final class SnapshotMemoryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Data] = [:]
    private var order: [String] = []
    private let limit = 32

    func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    func store(_ data: Data, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        if entries[key] == nil {
            order.append(key)
            if order.count > limit, let oldest = order.first {
                order.removeFirst()
                entries.removeValue(forKey: oldest)
            }
        }
        entries[key] = data
    }
}

/// Renders crisp Apple Maps route and point snapshots for Siri Snippets, with automatic
/// timeout protection, in-memory caching, and GPS/MKDirections route resolution.
public enum SiriMapSnapshotRenderer {
    private static let cache = SnapshotMemoryCache()

    /// Resolves GPS route points for a `DriveEntity` and renders an Apple Maps route image.
    public static func renderDriveRoute(
        for drive: DriveEntity,
        service: FleetIntentService = .make(),
        style: SiriMapVisualStyle = .standard,
        size: CGSize = CGSize(width: 380, height: 172),
        allowNetworkSnapshot: Bool = true
    ) async -> SiriRenderedMapData {
        let points = await resolveRoutePoints(for: drive, service: service, allowGeocoding: allowNetworkSnapshot)
        guard points.count >= 2, allowNetworkSnapshot else {
            return SiriRenderedMapData(pngData: nil, points: points, style: style)
        }

        let cacheKey = "route:\(drive.id):\(style.rawValue):\(Int(size.width))x\(Int(size.height)):\(points.count)"
        if let cached = cache.data(forKey: cacheKey) {
            return SiriRenderedMapData(pngData: cached, points: points, style: style)
        }

        let pngData = await snapshotRoutePNG(points: points, style: style, size: size)
        if let pngData {
            cache.store(pngData, forKey: cacheKey)
        }
        return SiriRenderedMapData(pngData: pngData, points: points, style: style)
    }

    /// Renders a single-coordinate Apple Maps snapshot (parked car or charging station).
    public static func renderLocationPin(
        latitude: Double?,
        longitude: Double?,
        fallbackPlaceQuery: String? = nil,
        style: SiriMapVisualStyle = .standard,
        accentHex: UInt32 = 0x0A84FF,
        size: CGSize = CGSize(width: 380, height: 126),
        allowNetworkSnapshot: Bool = true
    ) async -> SiriRenderedMapData {
        var resolvedLat = latitude
        var resolvedLon = longitude

        if (resolvedLat == nil || resolvedLon == nil),
           allowNetworkSnapshot,
           let query = fallbackPlaceQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
           !query.isEmpty,
           let geocoded = await geocodeCoordinate(query: query) {
            resolvedLat = geocoded.latitude
            resolvedLon = geocoded.longitude
        }

        guard let lat = resolvedLat, let lon = resolvedLon else {
            return SiriRenderedMapData(pngData: nil, points: [], style: style)
        }

        let singlePoint = [FleetDriveRoutePoint(latitude: lat, longitude: lon)]
        guard allowNetworkSnapshot else {
            return SiriRenderedMapData(pngData: nil, points: singlePoint, style: style)
        }

        let coordKey = String(format: "%.4f,%.4f", lat, lon)
        let cacheKey = "pin:\(coordKey):\(style.rawValue):\(accentHex):\(Int(size.width))x\(Int(size.height))"
        if let cached = cache.data(forKey: cacheKey) {
            return SiriRenderedMapData(pngData: cached, points: singlePoint, style: style)
        }

        let pngData = await snapshotPinPNG(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            style: style,
            accentHex: accentHex,
            size: size
        )
        if let pngData {
            cache.store(pngData, forKey: cacheKey)
        }
        return SiriRenderedMapData(pngData: pngData, points: singlePoint, style: style)
    }

    // MARK: - Route Point Resolution

    public static func resolveRoutePoints(
        for drive: DriveEntity,
        service: FleetIntentService = .make(),
        allowGeocoding: Bool = true
    ) async -> [FleetDriveRoutePoint] {
        let endDate = drive.endedAt ?? drive.startedAt.addingTimeInterval(TimeInterval((drive.durationMinutes ?? 20) * 60))
        if let fetched = try? await service.drivePath(
            vin: drive.vin,
            driveID: drive.id,
            from: drive.startedAt,
            to: endDate,
            maxPoints: 72
        ), fetched.count >= 2 {
            return fetched
        }

        var startCoord: CLLocationCoordinate2D?
        if let sLat = drive.startLatitude, let sLon = drive.startLongitude {
            startCoord = CLLocationCoordinate2D(latitude: sLat, longitude: sLon)
        } else if allowGeocoding, let startAddress = drive.startAddress, !startAddress.isEmpty {
            startCoord = await geocodeCoordinate(query: startAddress)
        }

        var endCoord: CLLocationCoordinate2D?
        if let eLat = drive.endLatitude, let eLon = drive.endLongitude {
            endCoord = CLLocationCoordinate2D(latitude: eLat, longitude: eLon)
        } else if allowGeocoding, let endAddress = drive.endAddress, !endAddress.isEmpty {
            endCoord = await geocodeCoordinate(query: endAddress)
        }

        if let startCoord, let endCoord {
            if allowGeocoding, let roadRoute = await directionsPolyline(from: startCoord, to: endCoord), roadRoute.count >= 2 {
                return roadRoute
            }
            return interpolatedArc(from: startCoord, to: endCoord, steps: 24)
        }

        if let single = startCoord ?? endCoord {
            return [FleetDriveRoutePoint(latitude: single.latitude, longitude: single.longitude)]
        }

        return []
    }

    private static func interpolatedArc(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        steps: Int
    ) -> [FleetDriveRoutePoint] {
        let dLat = end.latitude - start.latitude
        let dLon = end.longitude - start.longitude
        let perpLat = -dLon * 0.08
        let perpLon = dLat * 0.08
        return (0...steps).map { idx in
            let t = Double(idx) / Double(max(steps, 1))
            let curve = sin(t * .pi)
            return FleetDriveRoutePoint(
                latitude: start.latitude + dLat * t + perpLat * curve,
                longitude: start.longitude + dLon * t + perpLon * curve
            )
        }
    }

    private static func geocodeCoordinate(query: String) async -> CLLocationCoordinate2D? {
        await withTimeout(seconds: 1.1) {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            let response = try? await MKLocalSearch(request: request).start()
            return response?.mapItems.first?.location.coordinate
        } ?? nil
    }

    private static func directionsPolyline(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) async -> [FleetDriveRoutePoint]? {
        await withTimeout(seconds: 1.2) {
            let request = MKDirections.Request()
            request.source = MKMapItem(location: CLLocation(latitude: start.latitude, longitude: start.longitude), address: nil)
            request.destination = MKMapItem(location: CLLocation(latitude: end.latitude, longitude: end.longitude), address: nil)
            request.transportType = .automobile
            guard let route = try? await MKDirections(request: request).calculate().routes.first else {
                return nil
            }
            let count = route.polyline.pointCount
            guard count >= 2 else { return nil }
            var coords = Array(repeating: kCLLocationCoordinate2DInvalid, count: count)
            route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
            let maxSamples = 64
            if count <= maxSamples {
                return coords.map { FleetDriveRoutePoint(latitude: $0.latitude, longitude: $0.longitude) }
            }
            return (0..<maxSamples).map { idx in
                let c = coords[idx * (count - 1) / (maxSamples - 1)]
                return FleetDriveRoutePoint(latitude: c.latitude, longitude: c.longitude)
            }
        } ?? nil
    }

    // MARK: - MKMapSnapshotter Drawing

    private static func snapshotRoutePNG(
        points: [FleetDriveRoutePoint],
        style: SiriMapVisualStyle,
        size: CGSize
    ) async -> Data? {
        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        guard let mapRect = fittedMapRect(for: coordinates) else { return nil }

        return await withTimeout(seconds: 2.2) { @MainActor in
            let options = MKMapSnapshotter.Options()
            options.size = size
            options.mapRect = mapRect
            options.preferredConfiguration = mapConfiguration(for: style)
            #if canImport(UIKit)
            options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
            #endif

            let snapshotter = MKMapSnapshotter(options: options)
            guard let snapshot = try? await snapshotter.start() else { return nil }
            return drawRouteOverlay(on: snapshot, points: points, size: size)
        } ?? nil
    }

    private static func snapshotPinPNG(
        coordinate: CLLocationCoordinate2D,
        style: SiriMapVisualStyle,
        accentHex: UInt32,
        size: CGSize
    ) async -> Data? {
        await withTimeout(seconds: 2.0) { @MainActor in
            let options = MKMapSnapshotter.Options()
            options.size = size
            options.region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 900,
                longitudinalMeters: 1_350
            )
            options.preferredConfiguration = mapConfiguration(for: style)
            #if canImport(UIKit)
            options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
            #endif

            let snapshotter = MKMapSnapshotter(options: options)
            guard let snapshot = try? await snapshotter.start() else { return nil }
            return drawPinOverlay(on: snapshot, coordinate: coordinate, accentHex: accentHex, size: size)
        } ?? nil
    }

    private static func mapConfiguration(for style: SiriMapVisualStyle) -> MKMapConfiguration {
        switch style {
        case .standard:
            let config = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
            config.pointOfInterestFilter = .excludingAll
            return config
        case .hybrid:
            let config = MKHybridMapConfiguration(elevationStyle: .realistic)
            config.pointOfInterestFilter = .excludingAll
            return config
        }
    }

    private static func fittedMapRect(for coordinates: [CLLocationCoordinate2D]) -> MKMapRect? {
        guard let first = coordinates.first else { return nil }
        var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 1, height: 1))
        for coord in coordinates.dropFirst() {
            rect = rect.union(MKMapRect(origin: MKMapPoint(coord), size: MKMapSize(width: 1, height: 1)))
        }
        let padX = max(rect.size.width * 0.28, 1_400)
        let padY = max(rect.size.height * 0.34, 1_400)
        return rect.insetBy(dx: -padX, dy: -padY)
    }

    @MainActor
    private static func drawRouteOverlay(
        on snapshot: MKMapSnapshotter.Snapshot,
        points: [FleetDriveRoutePoint],
        size: CGSize
    ) -> Data? {
        let projected = points.map {
            snapshot.point(for: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
        }
        guard projected.count >= 2 else { return nil }

        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        let composed = renderer.image { ctx in
            snapshot.image.draw(at: .zero)
            let cg = ctx.cgContext
            renderRouteCoreGraphics(cg: cg, projected: projected, points: points)
        }
        return composed.pngData()
        #elseif canImport(AppKit)
        let image = NSImage(size: size, flipped: true) { _ in
            snapshot.image.draw(in: NSRect(origin: .zero, size: size))
            if let cg = NSGraphicsContext.current?.cgContext {
                renderRouteCoreGraphics(cg: cg, projected: projected, points: points)
            }
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #endif
    }

    @MainActor
    private static func drawPinOverlay(
        on snapshot: MKMapSnapshotter.Snapshot,
        coordinate: CLLocationCoordinate2D,
        accentHex: UInt32,
        size: CGSize
    ) -> Data? {
        let pt = snapshot.point(for: coordinate)
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        let composed = renderer.image { ctx in
            snapshot.image.draw(at: .zero)
            renderPinCoreGraphics(cg: ctx.cgContext, point: pt, accentHex: accentHex)
        }
        return composed.pngData()
        #elseif canImport(AppKit)
        let image = NSImage(size: size, flipped: true) { _ in
            snapshot.image.draw(in: NSRect(origin: .zero, size: size))
            if let cg = NSGraphicsContext.current?.cgContext {
                renderPinCoreGraphics(cg: cg, point: pt, accentHex: accentHex)
            }
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #endif
    }

    private static func renderRouteCoreGraphics(
        cg: CGContext,
        projected: [CGPoint],
        points: [FleetDriveRoutePoint]
    ) {
        cg.saveGState()
        cg.setLineCap(.round)
        cg.setLineJoin(.round)

        let fullPath = CGMutablePath()
        fullPath.move(to: projected[0])
        for pt in projected.dropFirst() {
            fullPath.addLine(to: pt)
        }

        // Outer dark casing for contrast over streets and satellite imagery
        cg.addPath(fullPath)
        cg.setStrokeColor(CGColor(red: 0.04, green: 0.08, blue: 0.18, alpha: 0.78))
        cg.setLineWidth(8.0)
        cg.strokePath()

        // Base Apple Maps route blue
        cg.addPath(fullPath)
        cg.setStrokeColor(CGColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 0.96))
        cg.setLineWidth(4.8)
        cg.strokePath()

        // Highlight Autopilot / FSD segments in electric cyan
        for idx in 0..<(projected.count - 1) where points[idx].isAutopilotActive || points[idx + 1].isAutopilotActive {
            cg.beginPath()
            cg.move(to: projected[idx])
            cg.addLine(to: projected[idx + 1])
            cg.setStrokeColor(CGColor(red: 0.22, green: 0.84, blue: 0.98, alpha: 0.98))
            cg.setLineWidth(4.8)
            cg.strokePath()
        }

        // Start marker (Green circle with crisp white border)
        drawEndpointMarker(
            cg: cg,
            center: projected[0],
            fill: CGColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1.0),
            innerDot: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        )

        // End marker (Tesla crimson circle with crisp white border)
        if let last = projected.last {
            drawEndpointMarker(
                cg: cg,
                center: last,
                fill: CGColor(red: 0.96, green: 0.24, blue: 0.22, alpha: 1.0),
                innerDot: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            )
        }
        cg.restoreGState()
    }

    private static func renderPinCoreGraphics(cg: CGContext, point: CGPoint, accentHex: UInt32) {
        let r = CGFloat((accentHex >> 16) & 0xFF) / 255.0
        let g = CGFloat((accentHex >> 8) & 0xFF) / 255.0
        let b = CGFloat(accentHex & 0xFF) / 255.0

        cg.saveGState()
        let haloRect = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
        cg.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 0.24))
        cg.fillEllipse(in: haloRect)

        drawEndpointMarker(
            cg: cg,
            center: point,
            fill: CGColor(red: r, green: g, blue: b, alpha: 1.0),
            innerDot: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            radius: 9.5
        )
        cg.restoreGState()
    }

    private static func drawEndpointMarker(
        cg: CGContext,
        center: CGPoint,
        fill: CGColor,
        innerDot: CGColor,
        radius: CGFloat = 8.0
    ) {
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: 2), blur: 5, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        let outer = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cg.fillEllipse(in: outer)
        cg.restoreGState()

        let innerRadius = radius - 2.2
        let inner = CGRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2)
        cg.setFillColor(fill)
        cg.fillEllipse(in: inner)

        let dotRadius: CGFloat = 2.4
        let dot = CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
        cg.setFillColor(innerDot)
        cg.fillEllipse(in: dot)
    }

    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Pure-SwiftUI topographic route canvas rendered automatically if offline or before map tiles arrive.
public struct SiriVectorRouteFallbackView: View {
    public let points: [FleetDriveRoutePoint]

    public init(points: [FleetDriveRoutePoint]) {
        self.points = points
    }

    public var body: some View {
        Canvas { context, size in
            let bgRect = CGRect(origin: .zero, size: size)
            context.fill(
                Path(bgRect),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.08, green: 0.12, blue: 0.20),
                        Color(red: 0.05, green: 0.08, blue: 0.14)
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: size.height)
                )
            )

            // Subtle topographic street grid lines
            var grid = Path()
            let step: CGFloat = 26
            var x: CGFloat = step
            while x < size.width {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = step
            while y < size.height {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(grid, with: .color(.white.opacity(0.05)), lineWidth: 0.75)

            let projected = normalizedPoints(in: size)
            guard projected.count >= 2 else {
                if let only = projected.first {
                    let halo = CGRect(x: only.x - 18, y: only.y - 18, width: 36, height: 36)
                    context.fill(Path(ellipseIn: halo), with: .color(.blue.opacity(0.28)))
                    let pin = CGRect(x: only.x - 7, y: only.y - 7, width: 14, height: 14)
                    context.fill(Path(ellipseIn: pin), with: .color(.white))
                    context.fill(Path(ellipseIn: pin.insetBy(dx: 2, dy: 2)), with: .color(.blue))
                }
                return
            }

            var routePath = Path()
            routePath.move(to: projected[0])
            for pt in projected.dropFirst() {
                routePath.addLine(to: pt)
            }

            context.stroke(
                routePath,
                with: .color(.cyan.opacity(0.28)),
                style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                routePath,
                with: .linearGradient(
                    Gradient(colors: [.blue, .cyan]),
                    startPoint: projected[0],
                    endPoint: projected[projected.count - 1]
                ),
                style: StrokeStyle(lineWidth: 4.2, lineCap: .round, lineJoin: .round)
            )

            if let first = projected.first {
                let rect = CGRect(x: first.x - 7, y: first.y - 7, width: 14, height: 14)
                context.fill(Path(ellipseIn: rect), with: .color(.white))
                context.fill(Path(ellipseIn: rect.insetBy(dx: 2.2, dy: 2.2)), with: .color(.green))
            }
            if let last = projected.last {
                let rect = CGRect(x: last.x - 7, y: last.y - 7, width: 14, height: 14)
                context.fill(Path(ellipseIn: rect), with: .color(.white))
                context.fill(Path(ellipseIn: rect.insetBy(dx: 2.2, dy: 2.2)), with: .color(.red))
            }
        }
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard !points.isEmpty else { return [] }
        if points.count == 1 {
            return [CGPoint(x: size.width * 0.5, y: size.height * 0.52)]
        }

        let lats = points.map(\.latitude)
        let lons = points.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            return []
        }

        let insetX: CGFloat = 34
        let insetY: CGFloat = 30
        let usableW = max(size.width - insetX * 2, 20)
        let usableH = max(size.height - insetY * 2, 20)
        let spanLat = max(maxLat - minLat, 0.002)
        let spanLon = max(maxLon - minLon, 0.002)

        return points.map { pt in
            let nx = CGFloat((pt.longitude - minLon) / spanLon)
            let ny = CGFloat((maxLat - pt.latitude) / spanLat)
            return CGPoint(x: insetX + nx * usableW, y: insetY + ny * usableH)
        }
    }
}
