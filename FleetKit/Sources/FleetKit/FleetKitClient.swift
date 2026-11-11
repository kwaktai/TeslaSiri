import Foundation
import OSLog

public enum FleetKitError: Swift.Error, LocalizedError {
    case notSignedIn
    case sessionExpired
    case api(String?)
    case badResponse
    case unsupportedAction(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Open TeslaSiri and add your Tessie access token to use this."
        case .sessionExpired:
            return "Your Tessie access token is invalid or revoked. Open TeslaSiri to replace it."
        case .api(let message):
            return message ?? "Tessie returned an error."
        case .badResponse:
            return "Tessie returned an unexpected response."
        case .unsupportedAction(let action):
            return "Your vehicle doesn't support \(action) right now."
        }
    }
}

/// A control parameter value that can be translated to Tessie's command query items.
public enum FleetControlValue: Encodable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    fileprivate var queryValue: String {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        }
    }

    fileprivate var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

/// Extension-safe Tessie client for the reads and commands used by App Intents.
public struct FleetIntentClient: Sendable {
    private let session: URLSession
    private let tokenStore: FleetSharedTokenStore

    public init(session: URLSession = .shared, tokenStore: FleetSharedTokenStore = .shared) {
        self.session = session
        self.tokenStore = tokenStore
    }

    // MARK: - Reads

    public func vehicles() async throws -> [FleetVehicleInfo] {
        let response: TessieResults<TessieVehicle> = try await get(
            "/vehicles",
            query: [URLQueryItem(name: "only_active", value: "true")]
        )
        return response.results.map { vehicle in
            FleetVehicleInfo(
                vin: vehicle.vin,
                displayName: vehicle.lastState?.displayName
            )
        }
    }

    public func snapshot(vin: String) async throws -> FleetSnapshotInfo {
        let state: TessieObject = try await get("/\(encoded(vin))/state")
        let tireState: TessieObject?
        do {
            tireState = try await get(
                "/\(encoded(vin))/tire_pressure",
                query: [URLQueryItem(name: "pressure_format", value: "psi")]
            )
        } catch FleetKitError.sessionExpired {
            throw FleetKitError.sessionExpired
        } catch FleetKitError.notSignedIn {
            throw FleetKitError.notSignedIn
        } catch {
            try Task.checkCancellation()
            tireState = nil
        }
        return state.snapshot(vin: vin, tireState: tireState)
    }

    public func user() async throws -> FleetUserInfo {
        let response: TessieResults<TessieVehicle> = try await get(
            "/vehicles",
            query: [URLQueryItem(name: "only_active", value: "true")]
        )
        return FleetUserInfo(units: response.results.first?.lastState?.units)
    }

    public func drives(vin: String, limit: Int) async throws -> [FleetDriveInfo] {
        let response: TessieResults<TessieObject> = try await get(
            "/\(encoded(vin))/drives",
            query: [
                URLQueryItem(name: "distance_format", value: "mi"),
                URLQueryItem(name: "limit", value: String(limit))
            ]
        )
        return response.results.compactMap { $0.drive(vin: vin) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func software(vin: String) async throws -> FleetSoftwareInfo {
        let state: TessieObject = try await get("/\(encoded(vin))/state")
        return state.software
    }

    public func releaseNotes(vin: String, version: String) async throws -> [FleetReleaseNoteInfo] {
        guard !version.isEmpty, version != ".", version != ".." else {
            throw FleetKitError.badResponse
        }
        let response: TessieReleaseNotes = try await get("/\(encoded(vin))/release_notes/\(encoded(version))")
        return response.releaseNotes ?? []
    }

    public func controlActions() async throws -> FleetControlActionsInfo {
        FleetControlActionsInfo(
            actions: [
                "actuate_trunk",
                "auto_conditioning_start",
                "auto_conditioning_stop",
                "door_lock",
                "door_unlock",
                "flash_lights",
                "honk_horn",
                "navigation_request",
                "remote_defrost",
                "set_bioweapon_mode",
                "set_pet_mode",
                "set_temps",
                "window_control"
            ],
            chargeActions: ["set_charge_limit"],
            schemas: [
                "actuate_trunk": ["which_trunk"],
                "navigation_request": ["value"],
                "remote_defrost": ["on"],
                "set_bioweapon_mode": ["on"],
                "set_charge_limit": ["percent"],
                "set_pet_mode": ["on"],
                "set_temps": ["driver_temp", "passenger_temp"],
                "window_control": ["command"]
            ]
        )
    }

    // MARK: - Writes

    public func runControl(action: String, vin: String, params: [String: FleetControlValue]) async throws {
        let command: String
        var query: [URLQueryItem] = []

        switch action {
        case "door_lock":
            command = "lock"
        case "door_unlock":
            command = "unlock"
        case "auto_conditioning_start":
            command = "start_climate"
        case "auto_conditioning_stop":
            command = "stop_climate"
        case "window_control":
            guard params["command"]?.queryValue == "vent" else {
                throw FleetKitError.unsupportedAction("that window command")
            }
            command = "vent_windows"
        case "actuate_trunk":
            command = params["which_trunk"]?.queryValue == "front"
                ? "activate_front_trunk"
                : "activate_rear_trunk"
        case "set_charge_limit":
            command = "set_charge_limit"
            query = requiredQuery("percent", from: params)
        case "set_temps":
            command = "set_temperatures"
            let temperature = params["driver_temp"] ?? params["passenger_temp"]
            guard let temperature else { throw FleetKitError.badResponse }
            query = [URLQueryItem(name: "temperature", value: temperature.queryValue)]
        case "remote_defrost":
            command = params["on"]?.boolValue == false ? "stop_max_defrost" : "start_max_defrost"
        case "set_pet_mode":
            command = "set_climate_keeper_mode"
            query = [URLQueryItem(name: "mode", value: params["on"]?.boolValue == false ? "0" : "2")]
        case "set_bioweapon_mode":
            command = "set_bioweapon_mode"
            query = requiredQuery("on", from: params)
        case "flash_lights":
            command = "flash"
        case "honk_horn":
            command = "honk"
        case "navigation_request":
            command = "share"
            query = requiredQuery("value", from: params)
        default:
            throw FleetKitError.unsupportedAction(action)
        }

        try await postCommand("/\(encoded(vin))/command/\(command)", query: query)
    }

    public func installSoftwareUpdate(vin: String, offsetSec: Int) async throws {
        try await postCommand(
            "/\(encoded(vin))/command/schedule_software_update",
            query: [URLQueryItem(name: "in_seconds", value: String(max(offsetSec, 0)))]
        )
    }

    public func cancelSoftwareUpdate(vin: String) async throws {
        try await postCommand("/\(encoded(vin))/command/cancel_software_update")
    }

    // MARK: - Transport

    private func get<Value: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Value {
        let request = try authorizedRequest(path: path, query: query, method: "GET")
        let data = try await execute(request)
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            FleetKitLog.client.error("GET \(Self.logPath(path), privacy: .public) decode failed — \(error.localizedDescription, privacy: .private)")
            throw FleetKitError.badResponse
        }
    }

    private func postCommand(_ path: String, query: [URLQueryItem] = []) async throws {
        let request = try authorizedRequest(path: path, query: query, method: "POST")
        let data = try await execute(request)
        guard let response = try? JSONDecoder().decode(TessieCommandResponse.self, from: data), response.result else {
            FleetKitLog.client.error("POST \(Self.logPath(path), privacy: .public) command was not accepted")
            throw FleetKitError.api("Tessie did not accept the vehicle command.")
        }
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let method = request.httpMethod ?? "GET"
        let path = Self.logPath(request.url?.path(percentEncoded: true) ?? "?")
        let start = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw FleetKitError.badResponse
            }

            let elapsed = FleetKitLog.milliseconds(since: start)
            FleetKitLog.client.info("\(method, privacy: .public) \(path, privacy: .public) → \(http.statusCode, privacy: .public) in \(elapsed, privacy: .public) ms")

            if http.statusCode == 401 {
                FleetKitLog.client.warning("Received 401 from Tessie — the saved access token is invalid or revoked")
                throw FleetKitError.sessionExpired
            }
            guard (200..<300).contains(http.statusCode) else {
                throw FleetKitError.api(Self.errorMessage(from: data) ?? "Tessie request failed with HTTP \(http.statusCode).")
            }
            return data
        } catch let error as FleetKitError {
            throw error
        } catch {
            let elapsed = FleetKitLog.milliseconds(since: start)
            FleetKitLog.client.error("\(method, privacy: .public) \(path, privacy: .public) failed after \(elapsed, privacy: .public) ms — \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: FleetKitConfig.baseURL, resolvingAgainstBaseURL: false) else {
            throw FleetKitError.badResponse
        }

        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + endpointPath
        components.queryItems = query.isEmpty ? nil : query

        guard let url = components.url else {
            throw FleetKitError.badResponse
        }
        return url
    }

    private func authorizedRequest(path: String, query: [URLQueryItem], method: String) throws -> URLRequest {
        guard let token = tokenStore.accessToken() else {
            throw FleetKitError.notSignedIn
        }
        let url = try makeURL(path: path, query: query)
        var request = URLRequest(url: url, timeoutInterval: FleetKitConfig.requestTimeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func requiredQuery(_ key: String, from params: [String: FleetControlValue]) -> [URLQueryItem] {
        guard let value = params[key] else { return [] }
        return [URLQueryItem(name: key, value: value.queryValue)]
    }

    private static func logPath(_ path: String) -> String {
        guard let separator = path.dropFirst().firstIndex(of: "/") else { return path }
        return "/{vin}" + path[separator...]
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONDecoder().decode(TessieObject.self, from: data) else { return nil }
        return object.string("error") ?? object.string("message")
    }

    private func encoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private typealias TessieObject = [String: TessieValue]

private struct TessieResults<Value: Decodable>: Decodable {
    let results: [Value]
}

private struct TessieVehicle: Decodable {
    let vin: String
    let lastState: TessieObject?

    enum CodingKeys: String, CodingKey {
        case vin
        case lastState = "last_state"
    }
}

private struct TessieReleaseNotes: Decodable {
    let releaseNotes: [FleetReleaseNoteInfo]?

    enum CodingKeys: String, CodingKey {
        case releaseNotes = "release_notes"
    }
}

private struct TessieCommandResponse: Decodable {
    let result: Bool
}

private enum TessieValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object(TessieObject)
    case array([TessieValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(TessieObject.self) {
            self = .object(value)
        } else if let value = try? container.decode([TessieValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported Tessie value")
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value):
            if let integer = Int64(exactly: value) {
                String(integer)
            } else {
                String(value)
            }
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value).flatMap { $0.isFinite ? $0 : nil }
        default: nil
        }
    }

    var int64Value: Int64? {
        guard let value = doubleValue,
              value.isFinite,
              value < Double(Int64.max),
              value >= Double(Int64.min) else {
            return nil
        }
        return Int64(value)
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value):
            switch value.lowercased() {
            case "true", "1", "yes", "on": true
            case "false", "0", "no", "off": false
            default: nil
            }
        default: nil
        }
    }

    var objectValue: TessieObject? {
        if case .object(let value) = self { return value }
        return nil
    }
}

private extension Dictionary where Key == String, Value == TessieValue {
    func object(_ key: String) -> TessieObject {
        self[key]?.objectValue ?? [:]
    }

    func string(_ key: String) -> String? {
        self[key]?.stringValue
    }

    func double(_ key: String) -> Double? {
        self[key]?.doubleValue
    }

    func int64(_ key: String) -> Int64? {
        self[key]?.int64Value
    }

    func bool(_ key: String) -> Bool? {
        self[key]?.boolValue
    }

    var displayName: String? {
        string("display_name") ?? object("vehicle_state").string("vehicle_name")
    }

    var usesFahrenheit: Bool {
        let settings = object("gui_settings")
        if let temperature = settings.string("gui_temperature_units")?.lowercased() {
            return temperature.hasPrefix("f")
        }
        if let distance = settings.string("gui_distance_units")?.lowercased() {
            return !distance.contains("km")
        }
        return true
    }

    func displayTemperature(_ celsius: Double?) -> Double? {
        guard let celsius else { return nil }
        return usesFahrenheit ? (celsius * 9 / 5) + 32 : celsius
    }

    var units: String? {
        let settings = object("gui_settings")
        if let temperature = settings.string("gui_temperature_units")?.lowercased() {
            return temperature.hasPrefix("f") ? "imperial" : "metric"
        }
        guard let distance = settings.string("gui_distance_units")?.lowercased() else { return nil }
        return distance.contains("km") ? "metric" : "imperial"
    }

    func snapshot(vin: String, tireState: TessieObject?) -> FleetSnapshotInfo {
        let charge = object("charge_state")
        let climate = object("climate_state")
        let drive = object("drive_state")
        let vehicle = object("vehicle_state")
        let timestamps = [
            charge.int64("timestamp"),
            climate.int64("timestamp"),
            drive.int64("timestamp"),
            vehicle.int64("timestamp")
        ].compactMap { $0 }.map(Self.milliseconds)

        return FleetSnapshotInfo(
            vin: vin,
            batteryLevel: charge.double("battery_level"),
            chargeLimitSOC: charge.double("charge_limit_soc"),
            chargingState: charge.string("charging_state"),
            locked: vehicle.bool("locked"),
            chargeRateMPH: charge.double("charge_rate"),
            timeToFullCharge: charge.double("time_to_full_charge"),
            insideTemp: displayTemperature(climate.double("inside_temp")),
            outsideTemp: displayTemperature(climate.double("outside_temp")),
            hvacOn: climate.bool("is_climate_on") ?? climate.bool("is_auto_conditioning_on"),
            latitude: drive.double("latitude"),
            longitude: drive.double("longitude"),
            odometer: vehicle.double("odometer"),
            speed: drive.double("speed"),
            updatedAt: timestamps.max(),
            climateKeeperMode: climate.string("climate_keeper_mode"),
            defrostMode: climate.string("defrost_mode"),
            tires: tireState?.tirePressures ?? vehicle.stateTirePressures
        )
    }

    var tirePressures: FleetTirePressuresInfo? {
        let frontLeft = double("front_left")
        let frontRight = double("front_right")
        let rearLeft = double("rear_left")
        let rearRight = double("rear_right")
        guard frontLeft != nil || frontRight != nil || rearLeft != nil || rearRight != nil else { return nil }
        return FleetTirePressuresInfo(
            frontLeftPSI: frontLeft,
            frontRightPSI: frontRight,
            rearLeftPSI: rearLeft,
            rearRightPSI: rearRight,
            lastMeasuredAt: int64("timestamp").map(Self.milliseconds)
        )
    }

    var stateTirePressures: FleetTirePressuresInfo? {
        func psi(_ key: String) -> Double? {
            double(key).map {
                Measurement(value: $0, unit: UnitPressure.bars).converted(to: .poundsForcePerSquareInch).value
            }
        }

        let frontLeft = psi("tpms_pressure_fl")
        let frontRight = psi("tpms_pressure_fr")
        let rearLeft = psi("tpms_pressure_rl")
        let rearRight = psi("tpms_pressure_rr")
        guard frontLeft != nil || frontRight != nil || rearLeft != nil || rearRight != nil else { return nil }
        return FleetTirePressuresInfo(
            frontLeftPSI: frontLeft,
            frontRightPSI: frontRight,
            rearLeftPSI: rearLeft,
            rearRightPSI: rearRight
        )
    }

    func drive(vin: String) -> FleetDriveInfo? {
        guard let rawID = string("id"), let started = int64("started_at") else { return nil }
        let ended = int64("ended_at")
        let startedMS = Self.milliseconds(started)
        let endedMS = ended.map(Self.milliseconds)
        return FleetDriveInfo(
            sessionID: "\(vin):\(rawID)",
            vin: vin,
            distanceMiles: double("odometer_distance"),
            durationMS: endedMS.map { Swift.max($0 - startedMS, 0) },
            avgSpeedMPH: double("average_speed"),
            maxSpeedMPH: double("max_speed"),
            energyUsedKWH: double("energy_used"),
            startedAt: startedMS,
            endedAt: endedMS,
            startAddress: string("starting_location"),
            endAddress: string("ending_location")
        )
    }

    var software: FleetSoftwareInfo {
        let vehicle = object("vehicle_state")
        let update = vehicle.object("software_update")
        let availableVersion = update.string("version")?.split(whereSeparator: \.isWhitespace).first.map(String.init)
        let status = update.string("status")
        let unavailableStatuses = ["", "idle", "unknown"]
        let available = availableVersion != nil
            || !unavailableStatuses.contains(status?.lowercased() ?? "")
        let currentVersion = vehicle.string("car_version")?.split(whereSeparator: \.isWhitespace).first.map(String.init)
        let expectedSeconds = update.double("expected_duration_sec")

        return FleetSoftwareInfo(
            currentVersion: currentVersion,
            availableVersion: availableVersion,
            updateAvailable: available,
            installable: available,
            status: status,
            downloadPercent: update.double("download_perc"),
            installPercent: update.double("install_perc"),
            expectedDurationMinutes: expectedSeconds.map { $0 / 60 }
        )
    }

    static func milliseconds(_ value: Int64) -> Int64 {
        value.magnitude < 10_000_000_000 ? value * 1_000 : value
    }
}
