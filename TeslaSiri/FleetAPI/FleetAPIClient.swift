import FleetKit
import Foundation
import OSLog
import TeslaFleetTransport

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
    case invalidHistoryRange
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
            return WattieCopy.text(
                "No Tesla server API key is saved.",
                "저장된 Tesla 서버 API 키가 없습니다."
            )
        case .invalidURL(let path):
            return WattieCopy.text(
                "The Tesla server URL could not be built for \(path).",
                "\(path)에 대한 Tesla 서버 주소를 만들지 못했습니다."
            )
        case .invalidHistoryRange:
            return WattieCopy.text(
                "That history request needs a valid start and end time.",
                "기록 요청에는 올바른 시작과 끝 시각이 필요합니다."
            )
        case .transport(let error):
            return WattieCopy.text(
                "Network request failed: \(error.localizedDescription)",
                "네트워크 요청에 실패했습니다: \(error.localizedDescription)"
            )
        case .decoding(let error, let requestID):
            return withRequestID(WattieCopy.text(
                "The Tesla server response could not be decoded: \(decodingMessage(error))",
                "Tesla 서버 응답을 해석하지 못했습니다: \(decodingMessage(error))"
            ), requestID: requestID)
        case .apiFailure(let error, _, let requestID):
            return withRequestID(WattieCopy.text(
                "Tesla server error: \(error)",
                "Tesla 서버 오류: \(error)"
            ), requestID: requestID)
        case .missingData(let requestID):
            return withRequestID(WattieCopy.text(
                "The Tesla server returned a success response without data.",
                "Tesla 서버가 데이터 없는 성공 응답을 반환했습니다."
            ), requestID: requestID)
        case .unacceptableStatus(let statusCode, let error, _, let requestID):
            let base = error.map {
                WattieCopy.text(
                    "Tesla server request failed with HTTP \(statusCode): \($0)",
                    "Tesla 서버 요청이 HTTP \(statusCode)(으)로 실패했습니다: \($0)"
                )
            } ?? WattieCopy.text(
                "Tesla server request failed with HTTP \(statusCode).",
                "Tesla 서버 요청이 HTTP \(statusCode)(으)로 실패했습니다."
            )
            return withRequestID(base, requestID: requestID)
        case .unsupportedFeature(let feature):
            return WattieCopy.text(
                "\(feature) isn't available on this Tesla server. Drive history, charging history, battery health, and release notes need data this server does not provide.",
                "\(feature)은(는) 이 Tesla 서버에서 제공하지 않습니다. 주행 기록, 충전 기록, 배터리 건강, 릴리즈 노트는 이 서버에 없는 데이터입니다."
            )
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
        /// When true, requests use `baseURL`. When false, each request reads the saved server URL.
        var pinsBaseURL: Bool = false
        var timeout: TimeInterval

        static var production: Configuration {
            Configuration(baseURL: TeslaFleetAPI.defaultBaseURL, pinsBaseURL: false, timeout: 30)
        }

        func resolvedBaseURL() -> URL {
            pinsBaseURL ? baseURL : FleetSharedTokenStore.shared.serverBaseURL()
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
        var accept: String
        var cachePolicy: URLRequest.CachePolicy

        init(
            method: HTTPMethod = .get,
            path: String,
            queryItems: [URLQueryItem] = [],
            body: Data? = nil,
            requiresAuthorization: Bool = true,
            accept: String = "application/json",
            cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
        ) {
            self.method = method
            self.path = path
            self.queryItems = queryItems
            self.body = body
            self.requiresAuthorization = requiresAuthorization
            self.accept = accept
            self.cachePolicy = cachePolicy
        }
    }

    private struct Response<Value: Sendable>: Sendable {
        var data: Value
        var requestID: String?
    }

    @MainActor
    private final class VehicleStateScope {
        var vin: String?
        var cached: (token: String, baseURL: URL, response: Response<TessieJSONObject>)?

        init(vin: String) {
            self.vin = vin
        }
    }

    @TaskLocal private static var vehicleStateScope: VehicleStateScope?

    @MainActor
    static func withSharedVehicleState(for vin: String, operation: @MainActor () async -> Void) async {
        let scope = VehicleStateScope(vin: vin)
        defer {
            scope.vin = nil
            scope.cached = nil
        }
        await $vehicleStateScope.withValue(scope) {
            await operation()
        }
    }

    private static let pathComponentAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private var configuration: Configuration
    private var session: URLSession
    private var accessTokenProvider: any FleetAccessTokenProviding

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
        let vehicles = fleetVehicles(from: response.data)
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
        let vehicles = fleetVehicles(from: response.data)
        return page(
            FleetSyncChanges(latest: vehicles.compactMap(\.latest), vehicles: vehicles),
            cursor: max(Self.currentTimeMilliseconds(), cursor + 1),
            requestID: response.requestID
        )
    }

    // MARK: - Vehicles and history

    func vehicles(includeLive: Bool = true) async throws -> FleetAPIPage<[FleetVehicle]> {
        let response = try await vehicleRecords()
        return page(fleetVehicles(from: response.data), requestID: response.requestID)
    }

    func vehicleSummary(vin: String) async throws -> FleetAPIPage<FleetVehicle> {
        let response = try await snapshotState(vin: vin)
        let vehicle = FleetVehicle(
            displayName: response.state.displayName,
            latest: TessieModelAdapter.snapshot(vin: vin, state: response.state, tireState: response.tireState),
            permissions: ["read", "control"],
            vin: vin
        )
        return page(vehicle, requestID: response.requestID)
    }

    func latestSnapshot(vin: String) async throws -> FleetAPIPage<FleetLatestSnapshot> {
        let response = try await snapshotState(vin: vin)
        return page(
            TessieModelAdapter.snapshot(vin: vin, state: response.state, tireState: response.tireState),
            requestID: response.requestID
        )
    }

    func locations(
        vin: String,
        startTime: Int64? = nil,
        endTime: Int64? = nil,
        limit: Int? = nil
    ) async throws -> FleetAPIPage<[FleetRoutePoint]> {
        _ = (vin, startTime, endTime, limit)
        return page([])
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
        _ = (vin, topic, startTime, endTime, limit, maxPoints, fields)
        return page([])
    }

    // MARK: - Drives and charging

    func drives(vin: String, limit: Int? = nil, includeRoute: Bool = true) async throws -> FleetAPIPage<[FleetDriveSession]> {
        _ = (vin, limit, includeRoute)
        return page([])
    }

    func activeDrive(
        vin: String,
        includeRoute: Bool = false,
        routeMaxPoints: Int? = nil
    ) async throws -> FleetAPIPage<FleetActiveDriveSession> {
        let stateResponse = try await vehicleState(vin: vin)
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
        _ = (sessionID, includeRoute, maxPoints, vin)
        throw FleetAPIError.unsupportedFeature("Drive history")
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
        _ = (sessionID, startTime, endTime, limit, maxPoints, vin)
        return page([])
    }

    func chargingSessions(vin: String, limit: Int? = nil) async throws -> FleetAPIPage<[FleetChargeSession]> {
        let state = try await vehicleState(vin: vin)
        var sessions = TessieModelAdapter.activeCharge(vin: vin, state: state.data).map { [$0] } ?? []
        if let limit {
            sessions = Array(sessions.prefix(max(limit, 0)))
        }
        return page(sessions, requestID: state.requestID)
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
        _ = (includeReleaseNotes, refresh)
        let response = try await vehicleState(vin: vin)
        var update = TessieModelAdapter.software(from: response.data)
        // This server has no release-note endpoint. A zero count tells the store not to retry.
        update.releaseNotes = []
        update.releaseNotesCount = 0
        return page(update, requestID: response.requestID)
    }

    func installSoftwareUpdate(vin: String, offsetSec: Int = 0) async throws -> FleetAPIPage<[String: JSONValue]> {
        let command = try buildCommand(action: "schedule_software_update", params: ["offset_sec": .integer(max(offsetSec, 0))])
        return try await postTeslaCommand(vin: vin, command: command)
    }

    func cancelSoftwareUpdate(vin: String) async throws -> FleetAPIPage<[String: JSONValue]> {
        let command = try buildCommand(action: "cancel_software_update", params: [:])
        return try await postTeslaCommand(vin: vin, command: command)
    }

    func runControl(
        action: String,
        vin: String,
        params: [String: JSONValue] = [:]
    ) async throws -> FleetAPIPage<[String: JSONValue]> {
        var translated = params.compactMapValues(\.teslaJSON)
        if action == "window_control", translated["lat"] == nil || translated["lon"] == nil {
            if let state = try? await vehicleState(vin: vin).data {
                let drive = state.object("drive_state")
                if translated["lat"] == nil, let latitude = drive.double("latitude") {
                    translated["lat"] = .double(latitude)
                }
                if translated["lon"] == nil, let longitude = drive.double("longitude") {
                    translated["lon"] = .double(longitude)
                }
            }
        }
        let command = try buildCommand(action: action, params: translated)
        return try await postTeslaCommand(vin: vin, command: command)
    }

    private func buildCommand(action: String, params: [String: TeslaFleetJSON]) throws -> TeslaFleetCommand {
        do {
            return try TeslaFleetCommands.build(
                action: action,
                params: params,
                locale: Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
            )
        } catch let error as TeslaFleetCommandError {
            switch error {
            case .unsupported:
                throw FleetAPIError.unsupportedFeature(action)
            case .missingParameter(let name):
                throw FleetAPIError.apiFailure(error: name, requiredScope: nil, requestID: nil)
            }
        }
    }

    // MARK: - Raw export

    func rawVehicleDataExport(vin: String) async throws -> FleetRawDataExport {
        let accessToken = try await accessTokenProvider.accessToken()
        let list = try await fetchRawResponse(for: Endpoint(path: "/api/vehicles"), accessToken: accessToken)
        var responses = [list]
        if let body = list.body,
           let data = try? JSONEncoder().encode(body),
           let listed = try? TeslaFleetDecoding.vehicles(from: data),
           let match = listed.first(where: { $0.vin.caseInsensitiveCompare(vin) == .orderedSame }),
           TeslaFleetReadPolicy.allowsVehicleDataFetch(state: match.state) {
            let detail = try await fetchRawResponse(
                for: Endpoint(path: "/api/vehicles/\(encoded(match.routeID))/vehicle_data"),
                accessToken: accessToken
            )
            responses.append(detail)
        }
        return FleetRawDataExport(
            apiBaseURL: configuration.resolvedBaseURL().absoluteString,
            appSchemaVersion: 4,
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

    private func routePoints(
        vin: String,
        range: (from: Int64, to: Int64),
        simplify: Bool
    ) async throws -> Response<[FleetRoutePoint]> {
        let response: Response<TessieResults<TessiePathSample>> = try await send(Endpoint(
            path: "/\(encoded(vin))/path",
            queryItems: historyQuery(from: range.from, to: range.to) + [
                URLQueryItem(name: "details", value: "true"),
                URLQueryItem(name: "simplify", value: simplify ? "true" : "false")
            ]
        ))
        let points = response.data.results
            .compactMap(\.routePoint)
            .sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
        return Response(data: points, requestID: response.requestID)
    }

    private func historyQuery(from: Int64, to: Int64) -> [URLQueryItem] {
        [
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "to", value: String(to))
        ]
    }

    private func releaseNotesEndpoint(
        vin: String,
        version: String?,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) -> Endpoint {
        let safeVersion = Self.sanitizedReleaseVersion(version) ?? ""
        return Endpoint(
            path: "/\(encoded(vin))/release_notes/\(encoded(safeVersion))",
            cachePolicy: cachePolicy
        )
    }

    private static func sanitizedReleaseVersion(_ version: String?) -> String? {
        guard let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != ".",
              trimmed != ".." else {
            return nil
        }
        return trimmed
    }

    @MainActor
    private func vehicleState(
        vin: String,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) async throws -> Response<TessieJSONObject> {
        _ = cachePolicy
        let baseURL = configuration.resolvedBaseURL()
        let token = try await accessTokenProvider.accessToken()
        if let scope = Self.vehicleStateScope, scope.vin == vin,
           let cached = scope.cached, cached.token == token, cached.baseURL == baseURL {
            return cached.response
        }

        let response = try await vehicleRecords()
        guard let record = response.data.first(where: { $0.vin.caseInsensitiveCompare(vin) == .orderedSame }),
              let state = record.lastState else {
            throw FleetAPIError.missingData(requestID: response.requestID)
        }
        let page = Response(data: state, requestID: response.requestID)
        if let scope = Self.vehicleStateScope, scope.vin == vin {
            scope.cached = (token, baseURL, page)
        }
        return page
    }

    private func snapshotState(
        vin: String
    ) async throws -> (state: TessieJSONObject, tireState: TessieJSONObject?, requestID: String?) {
        let stateResponse = try await vehicleState(vin: vin)
        return (stateResponse.data, nil, stateResponse.requestID)
    }

    private func vehicleRecords() async throws -> Response<[TessieVehicleRecord]> {
        let token = try await accessTokenProvider.accessToken()
        let baseURL = configuration.resolvedBaseURL()
        let (data, http) = try await performTesla(TeslaFleetRequests.vehicles(baseURL: baseURL), apiKey: token)
        guard (200..<300).contains(http.statusCode) else {
            throw statusFailure(http, data: data)
        }
        let listed: [TeslaFleetVehicle]
        do {
            listed = try TeslaFleetDecoding.vehicles(from: data)
        } catch {
            throw FleetAPIError.decoding(error, requestID: requestID(from: http))
        }

        var records: [TessieVehicleRecord] = []
        for item in listed {
            let fields = try await liveFields(for: item, apiKey: token, baseURL: baseURL)
            let asleep = !TeslaFleetReadPolicy.allowsVehicleDataFetch(state: item.state)
            records.append(TessieVehicleRecord(
                vin: item.vin,
                lastState: fields,
                powerState: asleep ? item.state?.lowercased() : nil
            ))
        }
        return Response(data: records, requestID: requestID(from: http))
    }

    private func liveFields(
        for item: TeslaFleetVehicle,
        apiKey: String,
        baseURL: URL
    ) async throws -> TessieJSONObject {
        let name = item.displayName ?? item.vin
        guard TeslaFleetReadPolicy.allowsVehicleDataFetch(state: item.state) else {
            return ["display_name": .string(name)]
        }
        let (data, http) = try await performTesla(
            TeslaFleetRequests.vehicleData(baseURL: baseURL, vehicleID: item.routeID),
            apiKey: apiKey
        )
        if TeslaFleetDecoding.isAsleep(statusCode: http.statusCode, body: data) {
            return ["display_name": .string(name)]
        }
        guard (200..<300).contains(http.statusCode) else {
            throw statusFailure(http, data: data)
        }
        do {
            return try Self.stateFields(from: data)
        } catch {
            throw FleetAPIError.decoding(error, requestID: requestID(from: http))
        }
    }

    private func fleetVehicles(from records: [TessieVehicleRecord]) -> [FleetVehicle] {
        records.map { record in
            var vehicle = TessieModelAdapter.vehicle(from: record)
            if let power = record.powerState?.lowercased(),
               power == "asleep" || power == "offline" || power == "suspended" {
                vehicle.latest?.gear = power
                vehicle.latest?.chargingState = nil
            }
            return vehicle
        }
    }

    private func postTeslaCommand(vin: String, command: TeslaFleetCommand) async throws -> FleetAPIPage<[String: JSONValue]> {
        let token = try await accessTokenProvider.accessToken()
        let spec = TeslaFleetRequests.command(
            baseURL: configuration.resolvedBaseURL(),
            vehicleID: vin,
            name: command.name,
            body: command.body
        )
        let (data, http) = try await performTesla(spec, apiKey: token)
        if http.statusCode == 401 {
            throw statusFailure(http, data: data)
        }
        switch TeslaFleetDecoding.commandOutcome(statusCode: http.statusCode, body: data) {
        case .accepted:
            return page(["result": .bool(true)], requestID: requestID(from: http))
        case .rejected(let message):
            throw FleetAPIError.apiFailure(error: message, requiredScope: nil, requestID: requestID(from: http))
        }
    }

    private func performTesla(_ spec: TeslaFleetRequest, apiKey: String) async throws -> (Data, HTTPURLResponse) {
        let request = spec.urlRequest(apiKey: apiKey, timeout: configuration.timeout)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FleetAPIError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw FleetAPIError.transport(URLError(.badServerResponse))
        }
        if http.statusCode == 401 {
            throw statusFailure(http, data: data)
        }
        return (data, http)
    }

    private func statusFailure(_ http: HTTPURLResponse, data: Data) -> FleetAPIError {
        let message = http.statusCode == 401
            ? WattieCopy.text(
                "The Tesla server API key is invalid or revoked.",
                "Tesla 서버 API 키가 올바르지 않거나 취소되었습니다."
            )
            : TeslaFleetDecoding.errorMessage(from: data)
        return .unacceptableStatus(
            statusCode: http.statusCode,
            error: message,
            requiredScope: nil,
            requestID: requestID(from: http)
        )
    }

    private static func stateFields(from data: Data) throws -> TessieJSONObject {
        struct Box: Decodable {
            var response: TessieJSONObject?
        }
        if let box = try? JSONDecoder().decode(Box.self, from: data), let response = box.response {
            return response
        }
        return try JSONDecoder().decode(TessieJSONObject.self, from: data)
    }

    @concurrent
    private static func decode<Value: Decodable & Sendable>(_ type: Value.Type, from data: Data) async throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }

    private func send<Value: Decodable & Sendable>(
        _ endpoint: Endpoint,
        accessToken: String? = nil
    ) async throws -> Response<Value> {
        let request = try await makeRequest(for: endpoint, accessToken: accessToken)
        let (data, response) = try await perform(request, endpoint: endpoint)
        do {
            return Response(
                data: try await Self.decode(Value.self, from: data),
                requestID: requestID(from: response)
            )
        } catch {
            let requestID = requestID(from: response)
            Self.logger.error("Tessie decoding failed: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .private) error \(error.localizedDescription, privacy: .private)")
            throw FleetAPIError.decoding(error, requestID: requestID)
        }
    }

    private func perform(_ request: URLRequest, endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
        Self.logger.debug("Tessie request preparing: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .private)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.error("Tessie transport failed: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .private) error \(error.localizedDescription, privacy: .private)")
            throw FleetAPIError.transport(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FleetAPIError.transport(URLError(.badServerResponse))
        }
        let requestID = requestID(from: httpResponse)
        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorObject = try? await Self.decode(TessieJSONObject.self, from: data)
            let responseMessage = errorObject?.string("error") ?? errorObject?.string("message")
            let message = httpResponse.statusCode == 401
                ? WattieCopy.text(
                    "The Tesla server API key is invalid or revoked.",
                    "Tesla 서버 API 키가 올바르지 않거나 취소되었습니다."
                )
                : responseMessage
            Self.logger.warning("Tessie request failed: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .private) status \(httpResponse.statusCode, privacy: .public)")
            throw FleetAPIError.unacceptableStatus(
                statusCode: httpResponse.statusCode,
                error: message,
                requiredScope: nil,
                requestID: requestID
            )
        }

        Self.logger.info("Tessie request completed: \(endpoint.method.rawValue, privacy: .public) \(endpoint.path, privacy: .private) status \(httpResponse.statusCode, privacy: .public)")
        return (data, httpResponse)
    }

    private func makeRequest(for endpoint: Endpoint, accessToken: String? = nil) async throws -> URLRequest {
        let url = try makeURL(path: endpoint.path, queryItems: endpoint.queryItems)
        var request = URLRequest(url: url, cachePolicy: endpoint.cachePolicy, timeoutInterval: configuration.timeout)
        request.httpMethod = endpoint.method.rawValue
        request.setValue(endpoint.accept, forHTTPHeaderField: "Accept")
        if let body = endpoint.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if endpoint.requiresAuthorization {
            let token = if let accessToken { accessToken } else { try await accessTokenProvider.accessToken() }
            request.setValue(token, forHTTPHeaderField: TeslaFleetAPI.apiKeyHeader)
        }
        return request
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: configuration.resolvedBaseURL(), resolvingAgainstBaseURL: false) else {
            throw FleetAPIError.invalidURL(path)
        }
        components.percentEncodedPath = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw FleetAPIError.invalidURL(path)
        }
        return url
    }

    private func fetchRawResponse(for endpoint: Endpoint, accessToken: String) async throws -> FleetRawAPIResponse {
        try Task.checkCancellation()
        let request = try await makeRequest(for: endpoint, accessToken: accessToken)
        let startedAt = Self.currentTimeMilliseconds()
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            let payload = await Self.rawPayload(data, contentType: httpResponse.mimeType)
            try Task.checkCancellation()
            return rawResponse(
                endpoint: endpoint,
                request: request,
                startedAt: startedAt,
                statusCode: httpResponse.statusCode,
                cacheControl: httpResponse.value(forHTTPHeaderField: "Cache-Control"),
                requestID: requestID(from: httpResponse),
                body: payload.body,
                bodyText: payload.text,
                errorMessage: nil
            )
        } catch {
            try Task.checkCancellation()
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

    @concurrent
    private static func rawPayload(_ data: Data, contentType: String?) async -> (body: JSONValue?, text: String?) {
        if let contentType, contentType.hasPrefix("image/") {
            return (.object([
                "content_type": .string(contentType),
                "base64": .string(data.base64EncodedString())
            ]), nil)
        }
        if let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return (json, nil)
        }
        return (nil, String(data: data, encoding: .utf8))
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

    private func historyRange(startTime: Int64?, endTime: Int64?) throws -> (from: Int64, to: Int64) {
        let now = Int64(Date().timeIntervalSince1970)
        let to = apiSeconds(endTime) ?? now
        let from = apiSeconds(startTime) ?? (to - 86_400)
        guard from > 0, to >= from else {
            throw FleetAPIError.invalidHistoryRange
        }
        return (from, to)
    }

    private func apiSeconds(_ timestamp: Int64?) -> Int64? {
        guard let timestamp else { return nil }
        return timestamp.magnitude >= 10_000_000_000 ? timestamp / 1_000 : timestamp
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

extension JSONValue {
    var teslaJSON: TeslaFleetJSON? {
        switch self {
        case .string(let value): .string(value)
        case .integer(let value): .int(value)
        case .double(let value): .double(value)
        case .bool(let value): .bool(value)
        case .object, .array, .null: nil
        }
    }
}

enum FleetBackend {
    static func makeAPIClient() -> FleetAPIClient {
        FleetAPIClient(accessTokenProvider: makeAccessTokenStore())
    }

    static func makeDataStore() -> FleetDataStore {
        FleetDataStore(
            apiClient: FleetSandboxDataClient(liveClient: makeAPIClient()),
            cache: FleetDiskCache()
        )
    }

    static func makeDeviceIdentity() -> FleetDeviceIdentity {
        FleetDeviceIdentity()
    }

    static func makeAccessTokenStore() -> TessieAccessTokenStore {
        TessieAccessTokenStore()
    }
}
