import Foundation
import OSLog

protocol FleetAccessTokenProviding {
    func accessToken() async throws -> String
}

protocol FleetAccessTokenRefreshing: FleetAccessTokenProviding {
    func refreshAccessToken() async throws -> String
}

struct StaticFleetAccessTokenProvider: FleetAccessTokenProviding {
    var token: String

    func accessToken() async throws -> String {
        token
    }
}

struct MissingFleetAccessTokenProvider: FleetAccessTokenProviding {
    func accessToken() async throws -> String {
        throw FleetAPIError.missingAccessToken
    }
}

enum FleetAPIError: Error, LocalizedError {
    case missingAccessToken
    case expiredAccessToken
    case invalidURL(String)
    case transport(Error)
    case decoding(Error, requestID: String?)
    case apiFailure(error: String, requiredScope: String?, requestID: String?)
    case missingData(requestID: String?)
    case unacceptableStatus(statusCode: Int, error: String?, requiredScope: String?, requestID: String?)
    case keychain(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingAccessToken:
            return "No Fleet access token is saved."
        case .expiredAccessToken:
            return "The saved Fleet access token is expired. Sign in again to continue."
        case .invalidURL(let path):
            return "The Fleet API URL could not be built for \(path)."
        case .transport(let error):
            return "Network request failed: \(error.localizedDescription)"
        case .decoding(let error, let requestID):
            return withRequestID("The Fleet API response could not be decoded: \(decodingMessage(error))", requestID: requestID)
        case .apiFailure(let error, let requiredScope, let requestID):
            return withRequestID(scopeMessage("Fleet API error: \(error)", requiredScope: requiredScope), requestID: requestID)
        case .missingData(let requestID):
            return withRequestID("The Fleet API returned a success envelope without data.", requestID: requestID)
        case .unacceptableStatus(let statusCode, let error, let requiredScope, let requestID):
            let base = error.map { "Fleet API request failed with HTTP \(statusCode): \($0)" } ?? "Fleet API request failed with HTTP \(statusCode)."
            return withRequestID(scopeMessage(base, requiredScope: requiredScope), requestID: requestID)
        case .keychain(let status):
            return "Keychain operation failed with status \(status)."
        }
    }

    private func scopeMessage(_ message: String, requiredScope: String?) -> String {
        guard let requiredScope else {
            return message
        }
        return "\(message) Required scope: \(requiredScope)."
    }

    private func decodingMessage(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "missing key \(key.stringValue) at \(codingPath(context.codingPath))"
        case DecodingError.typeMismatch(_, let context):
            return "type mismatch at \(codingPath(context.codingPath)): \(context.debugDescription)"
        case DecodingError.valueNotFound(_, let context):
            return "missing value at \(codingPath(context.codingPath)): \(context.debugDescription)"
        case DecodingError.dataCorrupted(let context):
            return "corrupt data at \(codingPath(context.codingPath)): \(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }

    private func codingPath(_ path: [CodingKey]) -> String {
        let value = path.map(\.stringValue).joined(separator: ".")
        return value.isEmpty ? "root" : value
    }

    private func withRequestID(_ message: String, requestID: String?) -> String {
        guard let requestID else {
            return message
        }
        return "\(message) Request ID: \(requestID)."
    }
}

struct FleetAPIClient {
    private static let logger = Logger(subsystem: "com.maxweinbach.TeslaSiri", category: "FleetAPI")

    struct Configuration {
        var baseURL: URL
        var timeout: TimeInterval

        static var production: Configuration {
            guard let url = URL(string: "https://fleet.maxweinbach.com") else {
                preconditionFailure("Invalid Fleet API base URL.")
            }
            return Configuration(baseURL: url, timeout: 30)
        }
    }

    private enum HTTPMethod: String {
        case delete = "DELETE"
        case get = "GET"
        case patch = "PATCH"
        case post = "POST"
    }

    private struct Endpoint {
        var method: HTTPMethod
        var path: String
        var queryItems: [URLQueryItem]
        var body: Data?
        var requiresAuthorization: Bool

        init(method: HTTPMethod = .get, path: String, queryItems: [URLQueryItem] = [], body: Data? = nil, requiresAuthorization: Bool = true) {
            self.method = method
            self.path = path
            self.queryItems = queryItems
            self.body = body
            self.requiresAuthorization = requiresAuthorization
        }
    }

    private struct FleetAPIEnvelope<Value: Decodable>: Decodable {
        var ok: Bool
        var data: Value?
        var error: String?
        var requiredScope: String?
        var invalidEvents: [String]?
        var invalidVins: [String]?
        var cached: Bool?
        var cursor: Int64?
        var stale: Bool?

        enum CodingKeys: String, CodingKey {
            case ok
            case data
            case error
            case requiredScope = "required_scope"
            case invalidEvents = "invalid_events"
            case invalidVins = "invalid_vins"
            case cached
            case cursor
            case stale
        }
    }

    private static let pathComponentAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private var configuration: Configuration
    private var session: URLSession
    private var accessTokenProvider: FleetAccessTokenProviding
    private var decoder: JSONDecoder
    private var encoder: JSONEncoder

    init(
        configuration: Configuration = .production,
        session: URLSession = .shared,
        accessTokenProvider: FleetAccessTokenProviding
    ) {
        self.configuration = configuration
        self.session = session
        self.accessTokenProvider = accessTokenProvider

        self.decoder = JSONDecoder()

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder
    }

    func currentUser() async throws -> FleetAPIPage<FleetUser> {
        try await send(Endpoint(path: "/api/v1/me"))
    }

    func capabilities() async throws -> FleetAPIPage<FleetCapabilities> {
        try await send(Endpoint(path: "/api/v1/capabilities"))
    }

    func bootstrap() async throws -> FleetAPIPage<FleetBootstrap> {
        try await send(Endpoint(path: "/api/v1/sync/bootstrap"))
    }

    func changes(since cursor: Int64) async throws -> FleetAPIPage<FleetSyncChanges> {
        try await send(Endpoint(path: "/api/v1/sync/changes", queryItems: [URLQueryItem(name: "since", value: String(cursor))]))
    }

    func vehicles(includeLive: Bool = true) async throws -> FleetAPIPage<[FleetVehicle]> {
        try await send(Endpoint(path: "/api/v1/vehicles", queryItems: [URLQueryItem(name: "include_live", value: includeLive ? "true" : "false")]))
    }

    func vehicleSummary(vin: String) async throws -> FleetAPIPage<FleetVehicle> {
        try await send(Endpoint(path: "/api/v1/vehicles/\(percentEncodedPathComponent(vin))/summary"))
    }

    func latestSnapshot(vin: String) async throws -> FleetAPIPage<FleetLatestSnapshot> {
        try await send(Endpoint(path: "/api/v1/vehicles/\(percentEncodedPathComponent(vin))/live"))
    }

    func locations(vin: String, startTime: Int64? = nil, endTime: Int64? = nil, limit: Int? = nil) async throws -> FleetAPIPage<[FleetRoutePoint]> {
        try await send(Endpoint(
            path: "/api/v1/vehicles/\(percentEncodedPathComponent(vin))/locations",
            queryItems: telemetryQueryItems(startTime: startTime, endTime: endTime, limit: limit)
        ))
    }

    func telemetrySeries(
        vin: String,
        topic: String? = nil,
        startTime: Int64? = nil,
        endTime: Int64? = nil,
        limit: Int? = nil,
        maxPoints: Int? = nil,
        fields: [String] = []
    ) async throws -> FleetAPIPage<[FleetTelemetrySeriesPoint]> {
        var queryItems = telemetryQueryItems(startTime: startTime, endTime: endTime, limit: limit)
        if let topic, !topic.isEmpty {
            queryItems.append(URLQueryItem(name: "topic", value: topic))
        }
        if let maxPoints {
            queryItems.append(URLQueryItem(name: "maxPoints", value: String(maxPoints)))
        }
        if !fields.isEmpty {
            queryItems.append(URLQueryItem(name: "fields", value: fields.joined(separator: ",")))
        }

        let page: FleetAPIPage<FleetTelemetrySeriesPayload> = try await send(Endpoint(path: "/api/v1/vehicles/\(percentEncodedPathComponent(vin))/telemetry/series", queryItems: queryItems))
        return FleetAPIPage(
            data: page.data.points,
            cursor: page.cursor,
            cached: page.cached,
            stale: page.stale,
            requestID: page.requestID
        )
    }

    func drives(vin: String, limit: Int? = nil, includeRoute: Bool = true) async throws -> FleetAPIPage<[FleetDriveSession]> {
        var queryItems = [URLQueryItem(name: "include_route", value: includeRoute ? "true" : "false")]
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }

        return try await send(Endpoint(path: "/api/v1/vehicles/\(percentEncodedPathComponent(vin))/drives", queryItems: queryItems))
    }

    func activeDrive(vin: String, includeRoute: Bool = false, routeMaxPoints: Int? = nil) async throws -> FleetAPIPage<FleetActiveDriveSession> {
        var queryItems = [URLQueryItem(name: "include_route", value: includeRoute ? "true" : "false")]
        if let routeMaxPoints {
            queryItems.append(URLQueryItem(name: "maxPoints", value: String(routeMaxPoints)))
        }

        let page: FleetAPIPage<FleetActiveDriveSession?> = try await sendAllowingNullData(Endpoint(path: "/api/v1/vehicles/\(percentEncodedPathComponent(vin))/drives/active", queryItems: queryItems))
        return FleetAPIPage(
            data: page.data ?? FleetActiveDriveSession(active: false, vin: vin),
            cursor: page.cursor,
            cached: page.cached,
            stale: page.stale,
            requestID: page.requestID
        )
    }

    func driveSession(sessionID: String, includeRoute: Bool = false, maxPoints: Int? = nil) async throws -> FleetAPIPage<FleetDriveSession> {
        var queryItems = [URLQueryItem(name: "include_route", value: includeRoute ? "true" : "false")]
        if let maxPoints {
            queryItems.append(URLQueryItem(name: "maxPoints", value: String(maxPoints)))
        }

        return try await send(Endpoint(path: "/api/v1/drives/\(percentEncodedPathComponent(sessionID))", queryItems: queryItems))
    }

    func driveRoute(sessionID: String, startTime: Int64? = nil, endTime: Int64? = nil, limit: Int? = nil, maxPoints: Int? = nil) async throws -> FleetAPIPage<[FleetRoutePoint]> {
        var queryItems = telemetryQueryItems(startTime: startTime, endTime: endTime, limit: limit)
        if let maxPoints {
            queryItems.append(URLQueryItem(name: "maxPoints", value: String(maxPoints)))
        }

        return try await send(Endpoint(path: "/api/v1/drives/\(percentEncodedPathComponent(sessionID))/route", queryItems: queryItems))
    }

    func chargingSessions(vin: String, limit: Int? = nil) async throws -> FleetAPIPage<[FleetChargeSession]> {
        var queryItems: [URLQueryItem] = []
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }

        return try await send(Endpoint(path: "/api/v1/vehicles/\(percentEncodedPathComponent(vin))/charging/sessions", queryItems: queryItems))
    }

    func chargingOptions(vin: String) async throws -> FleetAPIPage<FleetChargingOptions> {
        try await send(Endpoint(path: "/api/v1/vehicles/\(percentEncodedPathComponent(vin))/charging/options"))
    }

    func chargingCurve(sessionID: String, limit: Int? = nil) async throws -> FleetAPIPage<[FleetTelemetrySeriesPoint]> {
        var queryItems: [URLQueryItem] = []
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }

        let page: FleetAPIPage<FleetTelemetrySeriesPayload> = try await send(Endpoint(path: "/api/v1/charging/sessions/\(percentEncodedPathComponent(sessionID))/curve", queryItems: queryItems))
        return FleetAPIPage(
            data: page.data.points,
            cursor: page.cursor,
            cached: page.cached,
            stale: page.stale,
            requestID: page.requestID
        )
    }

    func controlActions() async throws -> FleetAPIPage<FleetControlActions> {
        try await send(Endpoint(path: "/api/v1/controls/actions"))
    }

    func softwareUpdate(vin: String, includeReleaseNotes: Bool = true, refresh: Bool = false) async throws -> FleetAPIPage<FleetSoftwareUpdate> {
        try await send(Endpoint(
            path: "/api/v1/vehicles/\(percentEncodedPathComponent(vin))/software",
            queryItems: [
                URLQueryItem(name: "include_release_notes", value: includeReleaseNotes ? "true" : "false"),
                URLQueryItem(name: "refresh", value: refresh ? "true" : "false")
            ]
        ))
    }

    func installSoftwareUpdate(vin: String, offsetSec: Int = 0) async throws -> FleetAPIPage<[String: JSONValue]> {
        let body = try encoder.encode(FleetSoftwareInstallRequest(offsetSec: offsetSec))
        return try await send(Endpoint(method: .post, path: "/api/v1/vehicles/\(percentEncodedPathComponent(vin))/software/install", body: body))
    }

    func cancelSoftwareUpdate(vin: String) async throws -> FleetAPIPage<[String: JSONValue]> {
        try await send(Endpoint(method: .post, path: "/api/v1/vehicles/\(percentEncodedPathComponent(vin))/software/cancel"))
    }

    func rawVehicleDataExport(vin: String) async throws -> FleetRawDataExport {
        let encodedVIN = percentEncodedPathComponent(vin)
        let endpoints = [
            Endpoint(path: "/api/v1/me"),
            Endpoint(path: "/api/v1/capabilities"),
            Endpoint(path: "/api/v1/sync/bootstrap"),
            Endpoint(path: "/api/v1/vehicles", queryItems: [URLQueryItem(name: "include_live", value: "true")]),
            Endpoint(path: "/api/v1/vehicles/\(encodedVIN)/summary"),
            Endpoint(path: "/api/v1/vehicles/\(encodedVIN)/live"),
            Endpoint(
                path: "/api/v1/vehicles/\(encodedVIN)/software",
                queryItems: [
                    URLQueryItem(name: "include_release_notes", value: "true"),
                    URLQueryItem(name: "refresh", value: "true")
                ]
            ),
            Endpoint(
                path: "/api/v1/vehicles/\(encodedVIN)/drives/active",
                queryItems: [
                    URLQueryItem(name: "include_route", value: "true"),
                    URLQueryItem(name: "maxPoints", value: "500")
                ]
            ),
            Endpoint(
                path: "/api/v1/vehicles/\(encodedVIN)/drives",
                queryItems: [
                    URLQueryItem(name: "include_route", value: "true"),
                    URLQueryItem(name: "limit", value: "10")
                ]
            ),
            Endpoint(path: "/api/v1/vehicles/\(encodedVIN)/locations", queryItems: [URLQueryItem(name: "limit", value: "500")]),
            Endpoint(
                path: "/api/v1/vehicles/\(encodedVIN)/telemetry/series",
                queryItems: [
                    URLQueryItem(name: "limit", value: "500"),
                    URLQueryItem(name: "maxPoints", value: "500")
                ]
            ),
            Endpoint(path: "/api/v1/vehicles/\(encodedVIN)/charging/sessions", queryItems: [URLQueryItem(name: "limit", value: "10")]),
            Endpoint(path: "/api/v1/vehicles/\(encodedVIN)/charging/options")
        ]

        var responses: [FleetRawAPIResponse] = []
        responses.reserveCapacity(endpoints.count)
        for endpoint in endpoints {
            responses.append(try await rawJSONResponse(endpoint))
        }

        return FleetRawDataExport(
            apiBaseURL: configuration.baseURL.absoluteString,
            appSchemaVersion: 1,
            generatedAt: Self.currentTimeMilliseconds(),
            responses: responses,
            vin: vin
        )
    }

    func webhooks(includeDisabled: Bool = false) async throws -> FleetAPIPage<[FleetWebhook]> {
        try await send(Endpoint(path: "/api/v1/webhooks", queryItems: [URLQueryItem(name: "include_disabled", value: includeDisabled ? "true" : "false")]))
    }

    func createWebhook(_ request: FleetWebhookCreateRequest) async throws -> FleetAPIPage<FleetWebhook> {
        let body = try encoder.encode(request)
        return try await send(Endpoint(method: .post, path: "/api/v1/webhooks", body: body))
    }

    func updateWebhook(id: String, request: FleetWebhookUpdateRequest) async throws -> FleetAPIPage<FleetWebhook> {
        let body = try encoder.encode(request)
        return try await send(Endpoint(method: .patch, path: "/api/v1/webhooks/\(percentEncodedPathComponent(id))", body: body))
    }

    func deleteWebhook(id: String) async throws -> FleetAPIPage<[String: JSONValue]> {
        try await send(Endpoint(method: .delete, path: "/api/v1/webhooks/\(percentEncodedPathComponent(id))"))
    }

    func testWebhook(id: String) async throws -> FleetAPIPage<FleetWebhookDeliveryResult> {
        try await send(Endpoint(method: .post, path: "/api/v1/webhooks/\(percentEncodedPathComponent(id))/test"))
    }

    func notificationWebhooks(deviceID: String? = nil, includeDisabled: Bool = false) async throws -> FleetAPIPage<[FleetDeviceNotificationWebhook]> {
        var queryItems = [URLQueryItem(name: "include_disabled", value: includeDisabled ? "true" : "false")]
        if let deviceID {
            queryItems.append(URLQueryItem(name: "device_id", value: deviceID))
        }

        return try await send(Endpoint(path: "/api/v1/notification-webhooks", queryItems: queryItems))
    }

    func createNotificationWebhook(_ request: FleetDeviceNotificationWebhookCreateRequest) async throws -> FleetAPIPage<FleetDeviceNotificationWebhook> {
        let body = try encoder.encode(request)
        return try await send(Endpoint(method: .post, path: "/api/v1/notification-webhooks", body: body))
    }

    func updateNotificationWebhook(id: String, request: FleetDeviceNotificationWebhookUpdateRequest) async throws -> FleetAPIPage<FleetDeviceNotificationWebhook> {
        let body = try encoder.encode(request)
        return try await send(Endpoint(method: .patch, path: "/api/v1/notification-webhooks/\(percentEncodedPathComponent(id))", body: body))
    }

    func deleteNotificationWebhook(id: String) async throws -> FleetAPIPage<[String: JSONValue]> {
        try await send(Endpoint(method: .delete, path: "/api/v1/notification-webhooks/\(percentEncodedPathComponent(id))"))
    }

    func testNotificationWebhook(id: String, request: FleetDeviceNotificationWebhookTestRequest? = nil) async throws -> FleetAPIPage<FleetWebhookDeliveryResult> {
        let body = try request.map { try encoder.encode($0) }
        return try await send(Endpoint(method: .post, path: "/api/v1/notification-webhooks/\(percentEncodedPathComponent(id))/test", body: body))
    }

    func notificationWebhooks(forDeviceID deviceID: String, includeDisabled: Bool = false) async throws -> FleetAPIPage<[FleetDeviceNotificationWebhook]> {
        try await send(Endpoint(
            path: "/api/v1/devices/\(percentEncodedPathComponent(deviceID))/notification-webhooks",
            queryItems: [URLQueryItem(name: "include_disabled", value: includeDisabled ? "true" : "false")]
        ))
    }

    func createNotificationWebhook(forDeviceID deviceID: String, request: FleetDeviceNotificationWebhookCreateForDeviceRequest) async throws -> FleetAPIPage<FleetDeviceNotificationWebhook> {
        let body = try encoder.encode(request)
        return try await send(Endpoint(method: .post, path: "/api/v1/devices/\(percentEncodedPathComponent(deviceID))/notification-webhooks", body: body))
    }

    func updateNotificationWebhook(forDeviceID deviceID: String, id: String, request: FleetDeviceNotificationWebhookUpdateRequest) async throws -> FleetAPIPage<FleetDeviceNotificationWebhook> {
        let body = try encoder.encode(request)
        return try await send(Endpoint(method: .patch, path: "/api/v1/devices/\(percentEncodedPathComponent(deviceID))/notification-webhooks/\(percentEncodedPathComponent(id))", body: body))
    }

    func deleteNotificationWebhook(forDeviceID deviceID: String, id: String) async throws -> FleetAPIPage<[String: JSONValue]> {
        try await send(Endpoint(method: .delete, path: "/api/v1/devices/\(percentEncodedPathComponent(deviceID))/notification-webhooks/\(percentEncodedPathComponent(id))"))
    }

    func testNotificationWebhook(forDeviceID deviceID: String, id: String, request: FleetDeviceNotificationWebhookTestRequest? = nil) async throws -> FleetAPIPage<FleetWebhookDeliveryResult> {
        let body = try request.map { try encoder.encode($0) }
        return try await send(Endpoint(method: .post, path: "/api/v1/devices/\(percentEncodedPathComponent(deviceID))/notification-webhooks/\(percentEncodedPathComponent(id))/test", body: body))
    }

    func runControl(action: String, vin: String, params: [String: JSONValue] = [:]) async throws -> FleetAPIPage<[String: JSONValue]> {
        let request = FleetControlRequest(action: action, params: params)
        let body = try encoder.encode(request)
        return try await send(Endpoint(method: .post, path: "/api/v1/vehicles/\(percentEncodedPathComponent(vin))/controls", body: body))
    }

    func streamURL(vin: String? = nil, includeDrive: Bool = true, includeRoute: Bool = false, routeMaxPoints: Int? = nil) throws -> URL {
        try makeStreamURL(vin: vin, includeDrive: includeDrive, includeRoute: includeRoute, routeMaxPoints: routeMaxPoints)
    }

    func streamRequest(vin: String? = nil, includeDrive: Bool = true, includeRoute: Bool = false, routeMaxPoints: Int? = nil) async throws -> URLRequest {
        let accessToken = try await accessTokenProvider.accessToken()
        var request = URLRequest(
            url: try makeStreamURL(vin: vin, includeDrive: includeDrive, includeRoute: includeRoute, routeMaxPoints: routeMaxPoints),
            timeoutInterval: configuration.timeout
        )
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
        return request
    }

    private func makeStreamURL(vin: String?, includeDrive: Bool, includeRoute: Bool, routeMaxPoints: Int?) throws -> URL {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw FleetAPIError.invalidURL("/api/v1/stream")
        }

        components.scheme = components.scheme == "http" ? "ws" : "wss"
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [basePath, "api/v1/stream"].filter { !$0.isEmpty }.joined(separator: "/")

        var queryItems: [URLQueryItem] = []
        if let vin, !vin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "vin", value: vin))
        }
        queryItems.append(URLQueryItem(name: "include_drive", value: includeDrive ? "true" : "false"))
        if includeRoute {
            queryItems.append(URLQueryItem(name: "include_route", value: "true"))
            if let routeMaxPoints {
                queryItems.append(URLQueryItem(name: "route_max_points", value: String(routeMaxPoints)))
            }
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw FleetAPIError.invalidURL("/api/v1/stream")
        }
        return url
    }

    private func rawJSONResponse(_ endpoint: Endpoint) async throws -> FleetRawAPIResponse {
        Self.logger.debug("Fleet raw export request preparing: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .public)")

        let request = try await makeRequest(for: endpoint)
        let startedAt = Self.currentTimeMilliseconds()
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.error("Fleet raw export transport failed: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .public) error \(error.localizedDescription, privacy: .public)")
            return rawResponse(
                endpoint: endpoint,
                request: request,
                startedAt: startedAt,
                statusCode: nil,
                apiVersion: nil,
                cacheControl: nil,
                requestID: nil,
                body: nil,
                bodyText: nil,
                errorMessage: error.localizedDescription
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return rawResponse(
                endpoint: endpoint,
                request: request,
                startedAt: startedAt,
                statusCode: nil,
                apiVersion: nil,
                cacheControl: nil,
                requestID: nil,
                body: nil,
                bodyText: nil,
                errorMessage: URLError(.badServerResponse).localizedDescription
            )
        }

        let decodedBody = try? decoder.decode(JSONValue.self, from: data)
        let bodyText = decodedBody == nil && !data.isEmpty ? String(data: data, encoding: .utf8) : nil
        let requestID = httpResponse.value(forHTTPHeaderField: "X-Fleet-Request-Id")
        let loggedRequestID = requestID ?? "none"
        Self.logger.info("Fleet raw export request completed: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .public) status \(httpResponse.statusCode, privacy: .public) request \(loggedRequestID, privacy: .public)")

        return rawResponse(
            endpoint: endpoint,
            request: request,
            startedAt: startedAt,
            statusCode: httpResponse.statusCode,
            apiVersion: httpResponse.value(forHTTPHeaderField: "X-Fleet-API-Version"),
            cacheControl: httpResponse.value(forHTTPHeaderField: "Cache-Control"),
            requestID: requestID,
            body: decodedBody,
            bodyText: bodyText,
            errorMessage: nil
        )
    }

    private func rawResponse(
        endpoint: Endpoint,
        request: URLRequest,
        startedAt: Int64,
        statusCode: Int?,
        apiVersion: String?,
        cacheControl: String?,
        requestID: String?,
        body: JSONValue?,
        bodyText: String?,
        errorMessage: String?
    ) -> FleetRawAPIResponse {
        FleetRawAPIResponse(
            apiVersion: apiVersion,
            body: body,
            bodyText: bodyText,
            cacheControl: cacheControl,
            durationMS: max(Self.currentTimeMilliseconds() - startedAt, 0),
            errorMessage: errorMessage,
            method: endpoint.method.rawValue,
            path: endpoint.path,
            query: rawQuery(from: endpoint.queryItems),
            requestID: requestID,
            statusCode: statusCode,
            timestamp: startedAt,
            url: request.url?.absoluteString ?? endpoint.path
        )
    }

    private func rawQuery(from queryItems: [URLQueryItem]) -> [String: String] {
        var values: [String: String] = [:]
        for item in queryItems {
            let value = item.value ?? ""
            if let existingValue = values[item.name], !existingValue.isEmpty {
                values[item.name] = existingValue + "," + value
            } else {
                values[item.name] = value
            }
        }
        return values
    }

    private static func currentTimeMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private func telemetryQueryItems(startTime: Int64?, endTime: Int64?, limit: Int?) -> [URLQueryItem] {
        var queryItems: [URLQueryItem] = []
        if let startTime {
            queryItems.append(URLQueryItem(name: "startTime", value: String(startTime)))
        }
        if let endTime {
            queryItems.append(URLQueryItem(name: "endTime", value: String(endTime)))
        }
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        return queryItems
    }

    private func send<Value: Decodable>(_ endpoint: Endpoint) async throws -> FleetAPIPage<Value> {
        let page: FleetAPIPage<Value?> = try await sendAllowingNullData(endpoint)
        guard let payload = page.data else {
            let loggedRequestID = page.requestID ?? "none"
            Self.logger.warning("Fleet envelope missing data: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .public) request \(loggedRequestID, privacy: .public)")
            throw FleetAPIError.missingData(requestID: page.requestID)
        }

        return FleetAPIPage(
            data: payload,
            cursor: page.cursor,
            cached: page.cached,
            stale: page.stale,
            requestID: page.requestID
        )
    }

    private func sendAllowingNullData<Value: Decodable>(_ endpoint: Endpoint, retryingAfterUnauthorized: Bool = false) async throws -> FleetAPIPage<Value?> {
        Self.logger.debug("Fleet request preparing: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .public)")

        let request: URLRequest
        do {
            request = try await makeRequest(for: endpoint)
        } catch {
            Self.logger.error("Fleet request setup failed: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .public) error \(error.localizedDescription, privacy: .public)")
            throw error
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.error("Fleet transport failed: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .public) error \(error.localizedDescription, privacy: .public)")
            throw FleetAPIError.transport(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            Self.logger.error("Fleet response was not HTTP: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .public)")
            throw FleetAPIError.transport(URLError(.badServerResponse))
        }

        let requestID = httpResponse.value(forHTTPHeaderField: "X-Fleet-Request-Id")
        let loggedRequestID = requestID ?? "none"

        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401,
               endpoint.requiresAuthorization,
               !retryingAfterUnauthorized,
               let refreshingProvider = accessTokenProvider as? any FleetAccessTokenRefreshing {
                Self.logger.info("Fleet request received unauthorized response, refreshing access token once: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .public) request \(loggedRequestID, privacy: .public)")
                _ = try await refreshingProvider.refreshAccessToken()
                return try await sendAllowingNullData(endpoint, retryingAfterUnauthorized: true)
            }

            let errorEnvelope = try? decoder.decode(FleetAPIEnvelope<JSONValue>.self, from: data)
            let loggedError = errorEnvelope?.error ?? "none"
            Self.logger.warning("Fleet request failed: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .public) status \(httpResponse.statusCode, privacy: .public) request \(loggedRequestID, privacy: .public) error \(loggedError, privacy: .public)")
            throw FleetAPIError.unacceptableStatus(
                statusCode: httpResponse.statusCode,
                error: errorEnvelope?.error,
                requiredScope: errorEnvelope?.requiredScope,
                requestID: requestID
            )
        }

        do {
            let envelope = try decoder.decode(FleetAPIEnvelope<Value>.self, from: data)

            guard envelope.ok else {
                let loggedError = envelope.error ?? "unknown_error"
                Self.logger.warning("Fleet envelope failed: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .public) request \(loggedRequestID, privacy: .public) error \(loggedError, privacy: .public)")
                throw FleetAPIError.apiFailure(error: loggedError, requiredScope: envelope.requiredScope, requestID: requestID)
            }

            Self.logger.info("Fleet request completed: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .public) status \(httpResponse.statusCode, privacy: .public) request \(loggedRequestID, privacy: .public)")
            return FleetAPIPage(
                data: envelope.data,
                cursor: envelope.cursor,
                cached: envelope.cached ?? false,
                stale: envelope.stale ?? false,
                requestID: requestID
            )
        } catch let error as FleetAPIError {
            throw error
        } catch {
            Self.logger.error("Fleet decoding failed: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .public) request \(loggedRequestID, privacy: .public) error \(error.localizedDescription, privacy: .public)")
            throw FleetAPIError.decoding(error, requestID: requestID)
        }
    }

    private func makeRequest(for endpoint: Endpoint) async throws -> URLRequest {
        let url = try makeURL(path: endpoint.path, queryItems: endpoint.queryItems)
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")

        if let body = endpoint.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if endpoint.requiresAuthorization {
            let accessToken = try await accessTokenProvider.accessToken()
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw FleetAPIError.invalidURL(path)
        }

        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw FleetAPIError.invalidURL(path)
        }

        return url
    }

    private func percentEncodedPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.pathComponentAllowedCharacters) ?? value
    }
}

enum FleetBackend {
    static func makeAPIClient() -> FleetAPIClient {
        FleetAPIClient(accessTokenProvider: FleetOAuthAccessTokenProvider(
            oauthClient: makeOAuthClient(),
            tokenStore: makeOAuthTokenStore()
        ))
    }

    static func makeDataStore() -> FleetDataStore {
        FleetDataStore(apiClient: makeAPIClient(), cache: FleetDiskCache())
    }

    static func makeDeviceIdentity() -> FleetDeviceIdentity {
        FleetDeviceIdentity()
    }

    static func makeOAuthClient() -> FleetOAuthClient {
        FleetOAuthClient()
    }

    static func makeOAuthTokenStore() -> FleetOAuthTokenKeychain {
        FleetOAuthTokenKeychain()
    }
}
