import Foundation
import OSLog

protocol FleetAccessTokenProviding {
    func accessToken() async throws -> String
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
    case invalidURL(String)
    case transport(Error)
    case decoding(Error, requestID: String?)
    case apiFailure(error: String, requiredScope: String?, requestID: String?)
    case missingData(requestID: String?)
    case unacceptableStatus(statusCode: Int, error: String?, requiredScope: String?, requestID: String?)
    case unsupportedFeature(String)
    case keychain(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingAccessToken:
            return "No Tessie access token is saved."
        case .invalidURL(let path):
            return "The Tessie API URL could not be built for \(path)."
        case .transport(let error):
            return "Network request failed: \(error.localizedDescription)"
        case .decoding(let error, let requestID):
            return withRequestID("The Tessie response could not be decoded: \(decodingMessage(error))", requestID: requestID)
        case .apiFailure(let error, _, let requestID):
            return withRequestID("Tessie API error: \(error)", requestID: requestID)
        case .missingData(let requestID):
            return withRequestID("Tessie returned a success response without data.", requestID: requestID)
        case .unacceptableStatus(let statusCode, let error, _, let requestID):
            let base = error.map { "Tessie request failed with HTTP \(statusCode): \($0)" }
                ?? "Tessie request failed with HTTP \(statusCode)."
            return withRequestID(base, requestID: requestID)
        case .unsupportedFeature(let feature):
            return "\(feature) is not available through the Tessie API."
        case .keychain(let status):
            return "Keychain operation failed with status \(status)."
        }
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
        guard let requestID else { return message }
        return "\(message) Request ID: \(requestID)."
    }
}

struct FleetAPIClient {
    private static let logger = Logger(subsystem: "com.maxweinbach.TeslaSiri", category: "TessieAPI")

    struct Configuration {
        var baseURL: URL
        var timeout: TimeInterval

        static var production: Configuration {
            guard let url = URL(string: "https://api.tessie.com") else {
                preconditionFailure("Invalid Tessie API base URL.")
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

        init(
            method: HTTPMethod = .get,
            path: String,
            queryItems: [URLQueryItem] = [],
            body: Data? = nil,
            requiresAuthorization: Bool = true
        ) {
            self.method = method
            self.path = path
            self.queryItems = queryItems
            self.body = body
            self.requiresAuthorization = requiresAuthorization
        }
    }

    private struct Response<Value> {
        var data: Value
        var requestID: String?
    }

    private static let pathComponentAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private var configuration: Configuration
    private var session: URLSession
    private var accessTokenProvider: any FleetAccessTokenProviding
    private var decoder = JSONDecoder()

    init(
        configuration: Configuration = .production,
        session: URLSession = .shared,
        accessTokenProvider: any FleetAccessTokenProviding
    ) {
        self.configuration = configuration
        self.session = session
        self.accessTokenProvider = accessTokenProvider
    }

    // MARK: - Account and synchronization

    func currentUser() async throws -> FleetAPIPage<FleetUser> {
        let response = try await vehicleRecords()
        return page(TessieModelAdapter.user(from: response.data.first?.lastState), requestID: response.requestID)
    }

    func capabilities() async throws -> FleetAPIPage<FleetCapabilities> {
        page(TessieModelAdapter.capabilities)
    }

    func bootstrap() async throws -> FleetAPIPage<FleetBootstrap> {
        let response = try await vehicleRecords()
        let vehicles = response.data.map(TessieModelAdapter.vehicle)
        let activeCharging = response.data.compactMap { record in
            record.lastState.flatMap { TessieModelAdapter.activeCharge(vin: record.vin, state: $0) }
        }
        let bootstrap = FleetBootstrap(
            activeCharging: activeCharging,
            capabilities: TessieModelAdapter.capabilities,
            recentDrives: [],
            user: TessieModelAdapter.user(from: response.data.first?.lastState),
            vehicles: vehicles
        )
        return page(bootstrap, cursor: Self.currentTimeMilliseconds(), requestID: response.requestID)
    }

    func changes(since cursor: Int64) async throws -> FleetAPIPage<FleetSyncChanges> {
        let response = try await vehicleRecords()
        let snapshots = response.data.map { record in
            TessieModelAdapter.snapshot(vin: record.vin, state: record.lastState ?? [:])
        }
        return page(
            FleetSyncChanges(latest: snapshots),
            cursor: max(Self.currentTimeMilliseconds(), cursor + 1),
            requestID: response.requestID
        )
    }

    // MARK: - Vehicles and history

    func vehicles(includeLive: Bool = true) async throws -> FleetAPIPage<[FleetVehicle]> {
        let response = try await vehicleRecords()
        return page(response.data.map(TessieModelAdapter.vehicle), requestID: response.requestID)
    }

    func vehicleSummary(vin: String) async throws -> FleetAPIPage<FleetVehicle> {
        let response: Response<TessieJSONObject> = try await send(Endpoint(path: "/\(encoded(vin))/state"))
        let vehicle = FleetVehicle(
            displayName: response.data.displayName,
            latest: TessieModelAdapter.snapshot(vin: vin, state: response.data),
            permissions: ["read", "control"],
            vin: vin
        )
        return page(vehicle, requestID: response.requestID)
    }

    func latestSnapshot(vin: String) async throws -> FleetAPIPage<FleetLatestSnapshot> {
        let response: Response<TessieJSONObject> = try await send(Endpoint(path: "/\(encoded(vin))/state"))
        return page(TessieModelAdapter.snapshot(vin: vin, state: response.data), requestID: response.requestID)
    }

    func locations(
        vin: String,
        startTime: Int64? = nil,
        endTime: Int64? = nil,
        limit: Int? = nil
    ) async throws -> FleetAPIPage<[FleetRoutePoint]> {
        let range = historyRange(startTime: startTime, endTime: endTime)
        let response: Response<TessieResults<TessieJSONObject>> = try await send(Endpoint(
            path: "/\(encoded(vin))/path",
            queryItems: [
                URLQueryItem(name: "from", value: String(range.from)),
                URLQueryItem(name: "to", value: String(range.to)),
                URLQueryItem(name: "details", value: "true"),
                URLQueryItem(name: "simplify", value: "true")
            ]
        ))
        var points = response.data.results.compactMap(TessieModelAdapter.routePoint)
        if let limit, points.count > limit {
            points = Array(points.suffix(limit))
        }
        return page(points, requestID: response.requestID)
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
        let range = historyRange(startTime: startTime, endTime: endTime)
        let desiredPoints = max(maxPoints ?? limit ?? 100, 1)
        let interval = max((range.to - range.from) / Int64(desiredPoints), 1)
        let response: Response<TessieResults<FleetTelemetrySeriesPoint>> = try await send(Endpoint(
            path: "/\(encoded(vin))/states",
            queryItems: [
                URLQueryItem(name: "from", value: String(range.from)),
                URLQueryItem(name: "to", value: String(range.to)),
                URLQueryItem(name: "interval", value: String(interval)),
                URLQueryItem(name: "condense", value: "false"),
                URLQueryItem(name: "distance_format", value: "mi"),
                URLQueryItem(name: "temperature_format", value: "f")
            ]
        ))
        var points = response.data.results
        if let limit, points.count > limit {
            points = Array(points.suffix(limit))
        }
        return page(points, requestID: response.requestID)
    }

    // MARK: - Drives and charging

    func drives(vin: String, limit: Int? = nil, includeRoute: Bool = true) async throws -> FleetAPIPage<[FleetDriveSession]> {
        var query = [URLQueryItem(name: "distance_format", value: "mi")]
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        let response: Response<TessieResults<TessieJSONObject>> = try await send(Endpoint(
            path: "/\(encoded(vin))/drives",
            queryItems: query
        ))
        return page(
            response.data.results.compactMap { TessieModelAdapter.drive(from: $0, vin: vin) },
            requestID: response.requestID
        )
    }

    func activeDrive(
        vin: String,
        includeRoute: Bool = false,
        routeMaxPoints: Int? = nil
    ) async throws -> FleetAPIPage<FleetActiveDriveSession> {
        let stateResponse: Response<TessieJSONObject> = try await send(Endpoint(path: "/\(encoded(vin))/state"))
        let gear = stateResponse.data.object("drive_state").string("shift_state")?.uppercased()
        let isActive = gear.map { $0 != "P" } ?? false
        var route: [FleetRoutePoint] = []
        var requestID = stateResponse.requestID
        if isActive, includeRoute {
            let routePage = try await locations(
                vin: vin,
                startTime: Self.currentTimeMilliseconds() - 7_200_000,
                endTime: nil,
                limit: routeMaxPoints
            )
            route = routePage.data
            requestID = routePage.requestID ?? requestID
        }
        return page(
            TessieModelAdapter.activeDrive(vin: vin, state: stateResponse.data, route: route),
            requestID: requestID
        )
    }

    func driveSession(
        sessionID: String,
        includeRoute: Bool = false,
        maxPoints: Int? = nil
    ) async throws -> FleetAPIPage<FleetDriveSession> {
        guard let vin = vin(fromSessionID: sessionID) else {
            throw FleetAPIError.missingData(requestID: nil)
        }
        let drivesPage = try await drives(vin: vin, limit: 100, includeRoute: false)
        guard var drive = drivesPage.data.first(where: { $0.sessionID == sessionID }) else {
            throw FleetAPIError.missingData(requestID: drivesPage.requestID)
        }
        if includeRoute {
            drive.route = try await driveRoute(
                sessionID: sessionID,
                startTime: drive.startedAt,
                endTime: drive.endedAt,
                limit: nil,
                maxPoints: maxPoints
            ).data
        }
        return page(drive, requestID: drivesPage.requestID)
    }

    func driveRoute(
        sessionID: String,
        startTime: Int64? = nil,
        endTime: Int64? = nil,
        limit: Int? = nil,
        maxPoints: Int? = nil
    ) async throws -> FleetAPIPage<[FleetRoutePoint]> {
        guard let vin = vin(fromSessionID: sessionID) else {
            throw FleetAPIError.missingData(requestID: nil)
        }
        return try await locations(
            vin: vin,
            startTime: startTime,
            endTime: endTime,
            limit: maxPoints ?? limit
        )
    }

    func chargingSessions(vin: String, limit: Int? = nil) async throws -> FleetAPIPage<[FleetChargeSession]> {
        var query = [URLQueryItem(name: "distance_format", value: "mi")]
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        let chargeQuery = query

        async let stateResponse: Response<TessieJSONObject> = send(
            Endpoint(path: "/\(encoded(vin))/state")
        )
        async let chargesResponse: Response<TessieResults<TessieJSONObject>> = send(
            Endpoint(path: "/\(encoded(vin))/charges", queryItems: chargeQuery)
        )
        let (state, charges) = try await (stateResponse, chargesResponse)

        var sessions = TessieModelAdapter.activeCharge(vin: vin, state: state.data).map { [$0] } ?? []
        sessions.append(contentsOf: charges.data.results.compactMap {
            TessieModelAdapter.completedCharge(from: $0, vin: vin)
        })
        if let limit, sessions.count > limit {
            sessions = Array(sessions.prefix(limit))
        }
        return page(sessions, requestID: charges.requestID ?? state.requestID)
    }

    func chargingOptions(vin: String) async throws -> FleetAPIPage<FleetChargingOptions> {
        let vehiclePage = try await vehicleSummary(vin: vin)
        return page(
            FleetChargingOptions(
                actions: TessieModelAdapter.chargeActions,
                chargeState: vehiclePage.data.latest,
                vehicle: vehiclePage.data
            ),
            requestID: vehiclePage.requestID
        )
    }

    func chargingCurve(sessionID: String, limit: Int? = nil) async throws -> FleetAPIPage<[FleetTelemetrySeriesPoint]> {
        throw FleetAPIError.unsupportedFeature("Per-session charging curves")
    }

    // MARK: - Software and commands

    func controlActions() async throws -> FleetAPIPage<FleetControlActions> {
        page(TessieModelAdapter.controlActionInfo)
    }

    func softwareUpdate(
        vin: String,
        includeReleaseNotes: Bool = true,
        refresh: Bool = false
    ) async throws -> FleetAPIPage<FleetSoftwareUpdate> {
        let response: Response<TessieJSONObject> = try await send(Endpoint(path: "/\(encoded(vin))/state"))
        return page(TessieModelAdapter.software(from: response.data), requestID: response.requestID)
    }

    func installSoftwareUpdate(vin: String, offsetSec: Int = 0) async throws -> FleetAPIPage<[String: JSONValue]> {
        try await command(
            path: "/\(encoded(vin))/command/schedule_software_update",
            queryItems: [URLQueryItem(name: "in_seconds", value: String(max(offsetSec, 0)))]
        )
    }

    func cancelSoftwareUpdate(vin: String) async throws -> FleetAPIPage<[String: JSONValue]> {
        try await command(path: "/\(encoded(vin))/command/cancel_software_update")
    }

    func runControl(
        action: String,
        vin: String,
        params: [String: JSONValue] = [:]
    ) async throws -> FleetAPIPage<[String: JSONValue]> {
        let commandName: String
        var queryItems: [URLQueryItem] = []

        switch action {
        case "door_lock": commandName = "lock"
        case "door_unlock": commandName = "unlock"
        case "auto_conditioning_start": commandName = "start_climate"
        case "auto_conditioning_stop": commandName = "stop_climate"
        case "window_control":
            guard params["command"]?.tessieStringValue == "vent" else {
                throw FleetAPIError.unsupportedFeature("That window command")
            }
            commandName = "vent_windows"
        case "actuate_trunk":
            commandName = params["which_trunk"]?.tessieStringValue == "front"
                ? "activate_front_trunk"
                : "activate_rear_trunk"
        case "set_charge_limit":
            commandName = "set_charge_limit"
            queryItems = [try queryItem("percent", params: params)]
        case "set_temps":
            commandName = "set_temperatures"
            guard let temperature = params["driver_temp"] ?? params["passenger_temp"] else {
                throw FleetAPIError.missingData(requestID: nil)
            }
            queryItems = [URLQueryItem(name: "temperature", value: temperature.tessieStringValue)]
        case "remote_defrost":
            commandName = params["on"]?.tessieBoolValue == false ? "stop_max_defrost" : "start_max_defrost"
        case "set_pet_mode":
            commandName = "set_climate_keeper_mode"
            queryItems = [URLQueryItem(name: "mode", value: params["on"]?.tessieBoolValue == false ? "0" : "2")]
        case "set_bioweapon_mode":
            commandName = "set_bioweapon_mode"
            queryItems = [try queryItem("on", params: params)]
        case "flash_lights": commandName = "flash"
        case "honk_horn": commandName = "honk"
        case "navigation_request":
            commandName = "share"
            queryItems = [try queryItem("value", params: params)]
        default:
            throw FleetAPIError.unsupportedFeature(action)
        }

        return try await command(
            path: "/\(encoded(vin))/command/\(commandName)",
            queryItems: queryItems
        )
    }

    // MARK: - Raw export

    func rawVehicleDataExport(vin: String) async throws -> FleetRawDataExport {
        let encodedVIN = encoded(vin)
        let now = Int64(Date().timeIntervalSince1970)
        let endpoints = [
            Endpoint(path: "/vehicles", queryItems: [URLQueryItem(name: "only_active", value: "true")]),
            Endpoint(path: "/\(encodedVIN)/state"),
            Endpoint(path: "/\(encodedVIN)/drives", queryItems: [
                URLQueryItem(name: "distance_format", value: "mi"),
                URLQueryItem(name: "limit", value: "10")
            ]),
            Endpoint(path: "/\(encodedVIN)/charges", queryItems: [
                URLQueryItem(name: "distance_format", value: "mi"),
                URLQueryItem(name: "limit", value: "10")
            ]),
            Endpoint(path: "/\(encodedVIN)/path", queryItems: [
                URLQueryItem(name: "from", value: String(now - 604_800)),
                URLQueryItem(name: "to", value: String(now)),
                URLQueryItem(name: "details", value: "true"),
                URLQueryItem(name: "simplify", value: "true")
            ]),
            Endpoint(path: "/\(encodedVIN)/states", queryItems: [
                URLQueryItem(name: "from", value: String(now - 86_400)),
                URLQueryItem(name: "to", value: String(now)),
                URLQueryItem(name: "interval", value: "300"),
                URLQueryItem(name: "condense", value: "false")
            ]),
            Endpoint(path: "/\(encodedVIN)/tire_pressure", queryItems: [
                URLQueryItem(name: "pressure_format", value: "psi")
            ])
        ]

        var responses: [FleetRawAPIResponse] = []
        for endpoint in endpoints {
            responses.append(try await rawJSONResponse(endpoint))
        }

        return FleetRawDataExport(
            apiBaseURL: configuration.baseURL.absoluteString,
            appSchemaVersion: 2,
            generatedAt: Self.currentTimeMilliseconds(),
            responses: responses,
            vin: vin
        )
    }

    // MARK: - Features not exposed by Tessie

    func webhooks(includeDisabled: Bool = false) async throws -> FleetAPIPage<[FleetWebhook]> {
        throw FleetAPIError.unsupportedFeature("Webhook management")
    }

    func createWebhook(_ request: FleetWebhookCreateRequest) async throws -> FleetAPIPage<FleetWebhook> {
        throw FleetAPIError.unsupportedFeature("Webhook management")
    }

    func updateWebhook(id: String, request: FleetWebhookUpdateRequest) async throws -> FleetAPIPage<FleetWebhook> {
        throw FleetAPIError.unsupportedFeature("Webhook management")
    }

    func deleteWebhook(id: String) async throws -> FleetAPIPage<[String: JSONValue]> {
        throw FleetAPIError.unsupportedFeature("Webhook management")
    }

    func testWebhook(id: String) async throws -> FleetAPIPage<FleetWebhookDeliveryResult> {
        throw FleetAPIError.unsupportedFeature("Webhook management")
    }

    func notificationWebhooks(deviceID: String? = nil, includeDisabled: Bool = false) async throws -> FleetAPIPage<[FleetDeviceNotificationWebhook]> {
        throw FleetAPIError.unsupportedFeature("Notification webhooks")
    }

    func createNotificationWebhook(_ request: FleetDeviceNotificationWebhookCreateRequest) async throws -> FleetAPIPage<FleetDeviceNotificationWebhook> {
        throw FleetAPIError.unsupportedFeature("Notification webhooks")
    }

    func updateNotificationWebhook(id: String, request: FleetDeviceNotificationWebhookUpdateRequest) async throws -> FleetAPIPage<FleetDeviceNotificationWebhook> {
        throw FleetAPIError.unsupportedFeature("Notification webhooks")
    }

    func deleteNotificationWebhook(id: String) async throws -> FleetAPIPage<[String: JSONValue]> {
        throw FleetAPIError.unsupportedFeature("Notification webhooks")
    }

    func testNotificationWebhook(id: String, request: FleetDeviceNotificationWebhookTestRequest? = nil) async throws -> FleetAPIPage<FleetWebhookDeliveryResult> {
        throw FleetAPIError.unsupportedFeature("Notification webhooks")
    }

    func notificationWebhooks(forDeviceID deviceID: String, includeDisabled: Bool = false) async throws -> FleetAPIPage<[FleetDeviceNotificationWebhook]> {
        throw FleetAPIError.unsupportedFeature("Notification webhooks")
    }

    func createNotificationWebhook(forDeviceID deviceID: String, request: FleetDeviceNotificationWebhookCreateForDeviceRequest) async throws -> FleetAPIPage<FleetDeviceNotificationWebhook> {
        throw FleetAPIError.unsupportedFeature("Notification webhooks")
    }

    func updateNotificationWebhook(forDeviceID deviceID: String, id: String, request: FleetDeviceNotificationWebhookUpdateRequest) async throws -> FleetAPIPage<FleetDeviceNotificationWebhook> {
        throw FleetAPIError.unsupportedFeature("Notification webhooks")
    }

    func deleteNotificationWebhook(forDeviceID deviceID: String, id: String) async throws -> FleetAPIPage<[String: JSONValue]> {
        throw FleetAPIError.unsupportedFeature("Notification webhooks")
    }

    func testNotificationWebhook(forDeviceID deviceID: String, id: String, request: FleetDeviceNotificationWebhookTestRequest? = nil) async throws -> FleetAPIPage<FleetWebhookDeliveryResult> {
        throw FleetAPIError.unsupportedFeature("Notification webhooks")
    }

    func streamURL(vin: String? = nil, includeDrive: Bool = true, includeRoute: Bool = false, routeMaxPoints: Int? = nil) throws -> URL {
        throw FleetAPIError.unsupportedFeature("The legacy websocket stream")
    }

    func streamRequest(vin: String? = nil, includeDrive: Bool = true, includeRoute: Bool = false, routeMaxPoints: Int? = nil) async throws -> URLRequest {
        throw FleetAPIError.unsupportedFeature("The legacy websocket stream")
    }

    // MARK: - Transport

    private func vehicleRecords() async throws -> Response<[TessieVehicleRecord]> {
        let response: Response<TessieResults<TessieVehicleRecord>> = try await send(Endpoint(
            path: "/vehicles",
            queryItems: [URLQueryItem(name: "only_active", value: "true")]
        ))
        return Response(data: response.data.results, requestID: response.requestID)
    }

    private func command(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> FleetAPIPage<[String: JSONValue]> {
        let response: Response<TessieCommandResponse> = try await send(Endpoint(
            method: .post,
            path: path,
            queryItems: queryItems
        ))
        guard response.data.result else {
            throw FleetAPIError.apiFailure(
                error: "Tessie did not accept the vehicle command.",
                requiredScope: nil,
                requestID: response.requestID
            )
        }
        return page(["result": .bool(true)], requestID: response.requestID)
    }

    private func queryItem(_ name: String, params: [String: JSONValue]) throws -> URLQueryItem {
        guard let value = params[name]?.tessieStringValue else {
            throw FleetAPIError.missingData(requestID: nil)
        }
        return URLQueryItem(name: name, value: value)
    }

    private func send<Value: Decodable>(_ endpoint: Endpoint) async throws -> Response<Value> {
        let request = try await makeRequest(for: endpoint)
        let (data, response) = try await perform(request, endpoint: endpoint)
        do {
            return Response(
                data: try decoder.decode(Value.self, from: data),
                requestID: requestID(from: response)
            )
        } catch {
            let requestID = requestID(from: response)
            Self.logger.error("Tessie decoding failed: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .public) error \(error.localizedDescription, privacy: .public)")
            throw FleetAPIError.decoding(error, requestID: requestID)
        }
    }

    private func perform(_ request: URLRequest, endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
        Self.logger.debug("Tessie request preparing: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .public)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.error("Tessie transport failed: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .public) error \(error.localizedDescription, privacy: .public)")
            throw FleetAPIError.transport(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FleetAPIError.transport(URLError(.badServerResponse))
        }
        let requestID = requestID(from: httpResponse)
        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorObject = try? decoder.decode(TessieJSONObject.self, from: data)
            let responseMessage = errorObject?.string("error") ?? errorObject?.string("message")
            let message = httpResponse.statusCode == 401
                ? "The Tessie access token is invalid or revoked."
                : responseMessage
            Self.logger.warning("Tessie request failed: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .public) status \(httpResponse.statusCode, privacy: .public)")
            throw FleetAPIError.unacceptableStatus(
                statusCode: httpResponse.statusCode,
                error: message,
                requiredScope: nil,
                requestID: requestID
            )
        }

        Self.logger.info("Tessie request completed: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .public) status \(httpResponse.statusCode, privacy: .public)")
        return (data, httpResponse)
    }

    private func makeRequest(for endpoint: Endpoint) async throws -> URLRequest {
        let url = try makeURL(path: endpoint.path, queryItems: endpoint.queryItems)
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + endpointPath
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw FleetAPIError.invalidURL(path)
        }
        return url
    }

    private func rawJSONResponse(_ endpoint: Endpoint) async throws -> FleetRawAPIResponse {
        let request = try await makeRequest(for: endpoint)
        let startedAt = Self.currentTimeMilliseconds()
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            let decodedBody = try? decoder.decode(JSONValue.self, from: data)
            return rawResponse(
                endpoint: endpoint,
                request: request,
                startedAt: startedAt,
                statusCode: httpResponse.statusCode,
                cacheControl: httpResponse.value(forHTTPHeaderField: "Cache-Control"),
                requestID: requestID(from: httpResponse),
                body: decodedBody,
                bodyText: decodedBody == nil ? String(data: data, encoding: .utf8) : nil,
                errorMessage: nil
            )
        } catch {
            return rawResponse(
                endpoint: endpoint,
                request: request,
                startedAt: startedAt,
                statusCode: nil,
                cacheControl: nil,
                requestID: nil,
                body: nil,
                bodyText: nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func rawResponse(
        endpoint: Endpoint,
        request: URLRequest,
        startedAt: Int64,
        statusCode: Int?,
        cacheControl: String?,
        requestID: String?,
        body: JSONValue?,
        bodyText: String?,
        errorMessage: String?
    ) -> FleetRawAPIResponse {
        FleetRawAPIResponse(
            apiVersion: "tessie-v1",
            body: body,
            bodyText: bodyText,
            cacheControl: cacheControl,
            durationMS: max(Self.currentTimeMilliseconds() - startedAt, 0),
            errorMessage: errorMessage,
            method: endpoint.method.rawValue,
            path: endpoint.path,
            query: Dictionary(uniqueKeysWithValues: endpoint.queryItems.map { ($0.name, $0.value ?? "") }),
            requestID: requestID,
            statusCode: statusCode,
            timestamp: startedAt,
            url: request.url?.absoluteString ?? endpoint.path
        )
    }

    private func requestID(from response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "X-Request-Id")
            ?? response.value(forHTTPHeaderField: "CF-Ray")
    }

    private func historyRange(startTime: Int64?, endTime: Int64?) -> (from: Int64, to: Int64) {
        let now = Int64(Date().timeIntervalSince1970)
        let to = apiSeconds(endTime) ?? now
        return (apiSeconds(startTime) ?? (to - 86_400), to)
    }

    private func apiSeconds(_ timestamp: Int64?) -> Int64? {
        guard let timestamp else { return nil }
        return abs(timestamp) >= 10_000_000_000 ? timestamp / 1_000 : timestamp
    }

    private func vin(fromSessionID sessionID: String) -> String? {
        guard let separator = sessionID.firstIndex(of: ":") else { return nil }
        let vin = String(sessionID[..<separator])
        return vin.isEmpty ? nil : vin
    }

    private func page<Value: Decodable>(
        _ data: Value,
        cursor: Int64? = nil,
        requestID: String? = nil
    ) -> FleetAPIPage<Value> {
        FleetAPIPage(
            data: data,
            cursor: cursor,
            cached: false,
            stale: false,
            requestID: requestID
        )
    }

    private func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.pathComponentAllowedCharacters) ?? value
    }

    private static func currentTimeMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

enum FleetBackend {
    static func makeAPIClient() -> FleetAPIClient {
        FleetAPIClient(accessTokenProvider: makeAccessTokenStore())
    }

    static func makeDataStore() -> FleetDataStore {
        FleetDataStore(apiClient: makeAPIClient(), cache: FleetDiskCache())
    }

    static func makeDeviceIdentity() -> FleetDeviceIdentity {
        FleetDeviceIdentity()
    }

    static func makeAccessTokenStore() -> TessieAccessTokenStore {
        TessieAccessTokenStore()
    }
}
