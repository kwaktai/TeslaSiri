import Foundation
import OSLog
import TeslaFleetTransport

enum FleetCopy {
    static var prefersKorean: Bool {
        if Locale.preferredLanguages.first?.hasPrefix("ko") == true { return true }
        return Locale.current.identifier.hasPrefix("ko")
    }

    static func text(_ english: String, _ korean: String) -> String {
        prefersKorean ? korean : english
    }
}

public enum FleetKitError: Swift.Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    case sessionExpired
    case api(String?)
    case badResponse
    case unsupportedAction(String)
    /// The self-hosted server has no equivalent of this Tessie history feature.
    case featureUnavailable(String)

    public var isUnavailableFeature: Bool {
        if case .featureUnavailable = self { return true }
        return false
    }

    public var errorDescription: String? {
        String(localized: localizedStringResource)
    }

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn:
            return LocalizedStringResource(stringLiteral: FleetCopy.text(
                "Open Wattie and add your Tesla server URL and API key.",
                "Wattie를 열고 Tesla 서버 주소와 API 키를 입력하세요."
            ))
        case .sessionExpired:
            return LocalizedStringResource(stringLiteral: FleetCopy.text(
                "Your Tesla server API key is invalid. Open Wattie and enter it again.",
                "Tesla 서버 API 키가 올바르지 않습니다. Wattie를 열고 다시 입력하세요."
            ))
        case .api(let message):
            if let message {
                return LocalizedStringResource(stringLiteral: message)
            }
            return LocalizedStringResource(stringLiteral: FleetCopy.text(
                "The Tesla server returned an error.",
                "Tesla 서버가 오류를 반환했습니다."
            ))
        case .badResponse:
            return LocalizedStringResource(stringLiteral: FleetCopy.text(
                "The Tesla server returned an unexpected response.",
                "Tesla 서버가 예상과 다른 응답을 반환했습니다."
            ))
        case .unsupportedAction(let action):
            return LocalizedStringResource(stringLiteral: FleetCopy.text(
                "Your vehicle doesn't support \(action) right now.",
                "지금 이 차량에서는 \(action)을(를) 사용할 수 없습니다."
            ))
        case .featureUnavailable(let feature):
            return LocalizedStringResource(stringLiteral: FleetCopy.text(
                "\(feature) isn't available on this Tesla server. Drive history, charging history, battery health, and release notes need data this server does not provide.",
                "\(feature)은(는) 이 Tesla 서버에서 제공하지 않습니다. 주행 기록, 충전 기록, 배터리 건강, 릴리즈 노트는 이 서버에 없는 데이터입니다."
            ))
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
        try await listedVehicles().map { vehicle in
            FleetVehicleInfo(vin: vehicle.vin, displayName: vehicle.displayName)
        }
    }

    public func snapshot(vin: String) async throws -> FleetSnapshotInfo {
        try await snapshotState(vin: vin).snapshot
    }

    func snapshotAndSoftware(vin: String) async throws -> (snapshot: FleetSnapshotInfo, software: FleetSoftwareInfo) {
        let (snapshot, state) = try await snapshotState(vin: vin)
        return (snapshot, state?.software ?? .asleep)
    }

    /// `nil` state means the car is asleep or offline. The read stops there and does not wake it.
    private func snapshotState(vin: String) async throws -> (snapshot: FleetSnapshotInfo, state: TessieObject?) {
        guard let state = try await vehicleDataIfAwake(vin: vin) else {
            return (FleetSnapshotInfo(vin: vin), nil)
        }
        return (state.snapshot(vin: vin, tireState: nil), state)
    }

    public func user() async throws -> FleetUserInfo {
        let vehicles = try await listedVehicles()
        guard let awake = vehicles.first(where: { TeslaFleetReadPolicy.allowsVehicleDataFetch(state: $0.state) }),
              let state = try await vehicleData(id: awake.routeID) else {
            return FleetUserInfo(units: nil)
        }
        let settings = state.object("gui_settings")
        guard settings.string("gui_temperature_units") != nil || settings.string("gui_distance_units") != nil else {
            return FleetUserInfo(units: nil)
        }
        return FleetUserInfo(units: state.usesFahrenheit ? "imperial" : "metric")
    }

    public func drives(
        vin: String,
        limit: Int,
        from: Date? = nil,
        to: Date? = nil,
        tag: String? = nil
    ) async throws -> [FleetDriveInfo] {
        _ = (vin, limit, from, to, tag)
        throw FleetKitError.featureUnavailable("Drive history")
    }

    public func drivePath(
        vin: String,
        from: Date,
        to: Date,
        maxPoints: Int = 72
    ) async throws -> [FleetDriveRoutePoint] {
        _ = (vin, from, to, maxPoints)
        throw FleetKitError.featureUnavailable("Drive route playback")
    }

    public func charges(
        vin: String,
        limit: Int,
        from: Date? = nil,
        to: Date? = nil
    ) async throws -> [FleetChargeInfo] {
        _ = (vin, limit, from, to)
        throw FleetKitError.featureUnavailable("Charging history")
    }

    public func batteryHealth(vin: String) async throws -> FleetBatteryHealthInfo {
        _ = vin
        throw FleetKitError.featureUnavailable("Battery health")
    }

    public func consumptionSinceCharge(vin: String) async throws -> FleetConsumptionInfo {
        _ = vin
        throw FleetKitError.featureUnavailable("Energy used since the last charge")
    }

    public func software(vin: String) async throws -> FleetSoftwareInfo {
        guard let state = try await vehicleDataIfAwake(vin: vin) else {
            return .asleep
        }
        return state.software
    }

    public func releaseNotes(vin: String, version: String) async throws -> [FleetReleaseNoteInfo] {
        _ = (vin, version)
        throw FleetKitError.featureUnavailable("Release notes")
    }

    public func controlActions() async throws -> FleetControlActionsInfo {
        FleetControlActionsInfo(
            actions: [
                "actuate_trunk",
                "auto_conditioning_start",
                "auto_conditioning_stop",
                "charge_port_door_close",
                "charge_port_door_open",
                "charge_start",
                "charge_stop",
                "door_lock",
                "door_unlock",
                "flash_lights",
                "honk_horn",
                "navigation_request",
                "remote_defrost",
                "set_bioweapon_mode",
                "set_pet_mode",
                "set_seat_cool",
                "set_seat_heat",
                "set_sentry_mode",
                "set_temps",
                "steering_wheel_heater",
                "window_control"
            ],
            chargeActions: [
                "charge_port_door_close",
                "charge_port_door_open",
                "charge_start",
                "charge_stop",
                "set_charge_limit",
                "set_charging_amps"
            ],
            schemas: [
                "actuate_trunk": ["which_trunk"],
                "navigation_request": ["value"],
                "remote_defrost": ["on"],
                "set_bioweapon_mode": ["on"],
                "set_charge_limit": ["percent"],
                "set_charging_amps": ["amps"],
                "set_pet_mode": ["on"],
                "set_seat_cool": ["seat", "level"],
                "set_seat_heat": ["seat", "level"],
                "steering_wheel_heater": ["on"],
                "set_sentry_mode": ["on"],
                "set_temps": ["driver_temp", "passenger_temp"],
                "window_control": ["command"]
            ]
        )
    }

    // MARK: - Writes

    public func runControl(action: String, vin: String, params: [String: FleetControlValue]) async throws {
        var params = params
        if action == "window_control", params["lat"] == nil || params["lon"] == nil {
            if let state = try? await vehicleDataIfAwake(vin: vin) {
                let drive = state.object("drive_state")
                if params["lat"] == nil, let latitude = drive.double("latitude") {
                    params["lat"] = .double(latitude)
                }
                if params["lon"] == nil, let longitude = drive.double("longitude") {
                    params["lon"] = .double(longitude)
                }
            }
        }

        let command: TeslaFleetCommand
        do {
            command = try TeslaFleetCommands.build(
                action: action,
                params: params.mapValues(\.teslaJSON),
                locale: Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
            )
        } catch let error as TeslaFleetCommandError {
            switch error {
            case .unsupported(let name):
                throw FleetKitError.unsupportedAction(name)
            case .missingParameter:
                throw FleetKitError.badResponse
            }
        }
        try await postCommand(vin: vin, command: command)
    }

    public func installSoftwareUpdate(vin: String, offsetSec: Int) async throws {
        let command = try TeslaFleetCommands.build(
            action: "schedule_software_update",
            params: ["offset_sec": .int(max(offsetSec, 0))]
        )
        try await postCommand(vin: vin, command: command)
    }

    public func cancelSoftwareUpdate(vin: String) async throws {
        let command = try TeslaFleetCommands.build(action: "cancel_software_update", params: [:])
        try await postCommand(vin: vin, command: command)
    }

    // MARK: - Transport

    private func listedVehicles() async throws -> [TeslaFleetVehicle] {
        let spec = TeslaFleetRequests.vehicles(baseURL: tokenStore.serverBaseURL())
        let (data, status) = try await perform(try makeRequest(spec))
        guard (200..<300).contains(status) else {
            throw statusError(status, data: data)
        }
        do {
            return try TeslaFleetDecoding.vehicles(from: data)
        } catch {
            FleetKitLog.client.error("Vehicle list decode failed — \(error.localizedDescription, privacy: .private)")
            throw FleetKitError.badResponse
        }
    }

    private func vehicleDataIfAwake(vin: String) async throws -> TessieObject? {
        let listed = try await listedVehicles()
        guard let match = listed.first(where: { $0.vin.caseInsensitiveCompare(vin) == .orderedSame }) else {
            throw FleetKitError.api(FleetCopy.text(
                "That vehicle isn't on this Tesla server.",
                "이 Tesla 서버에서 그 차량을 찾지 못했습니다."
            ))
        }
        guard TeslaFleetReadPolicy.allowsVehicleDataFetch(state: match.state) else {
            FleetKitLog.client.info("Skipped vehicle_data for \(FleetKitLog.vin(vin), privacy: .public) because it is \(match.state ?? "unknown", privacy: .public)")
            return nil
        }
        return try await vehicleData(id: match.routeID)
    }

    private func vehicleData(id: String) async throws -> TessieObject? {
        let spec = TeslaFleetRequests.vehicleData(baseURL: tokenStore.serverBaseURL(), vehicleID: id)
        let (data, status) = try await perform(try makeRequest(spec))
        if TeslaFleetDecoding.isAsleep(statusCode: status, body: data) {
            return nil
        }
        guard (200..<300).contains(status) else {
            throw statusError(status, data: data)
        }
        if let box = try? JSONDecoder().decode(TeslaStateBox.self, from: data), let response = box.response {
            return response
        }
        do {
            return try JSONDecoder().decode(TessieObject.self, from: data)
        } catch {
            FleetKitLog.client.error("vehicle_data decode failed — \(error.localizedDescription, privacy: .private)")
            throw FleetKitError.badResponse
        }
    }

    private func postCommand(vin: String, command: TeslaFleetCommand) async throws {
        let spec = TeslaFleetRequests.command(
            baseURL: tokenStore.serverBaseURL(),
            vehicleID: vin,
            name: command.name,
            body: command.body
        )
        let (data, status) = try await perform(try makeRequest(spec))
        if status == 401 {
            throw FleetKitError.sessionExpired
        }
        switch TeslaFleetDecoding.commandOutcome(statusCode: status, body: data) {
        case .accepted:
            return
        case .rejected(let message):
            FleetKitLog.client.error("Command \(command.name, privacy: .public) was not accepted")
            throw FleetKitError.api(message)
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
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
                FleetKitLog.client.warning("Received 401 from the Tesla server — the saved API key is invalid")
                throw FleetKitError.sessionExpired
            }
            return (data, http.statusCode)
        } catch let error as FleetKitError {
            throw error
        } catch {
            let elapsed = FleetKitLog.milliseconds(since: start)
            FleetKitLog.client.error("\(method, privacy: .public) \(path, privacy: .public) failed after \(elapsed, privacy: .public) ms — \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    private func makeRequest(_ spec: TeslaFleetRequest) throws -> URLRequest {
        guard let token = tokenStore.accessToken(), !token.isEmpty else {
            throw FleetKitError.notSignedIn
        }
        return spec.urlRequest(apiKey: token, timeout: FleetKitConfig.requestTimeout)
    }

    private func statusError(_ status: Int, data: Data) -> FleetKitError {
        if status == 401 { return .sessionExpired }
        return .api(TeslaFleetDecoding.errorMessage(from: data) ?? FleetCopy.text(
            "Tesla server request failed with HTTP \(status).",
            "Tesla 서버 요청이 HTTP \(status)(으)로 실패했습니다."
        ))
    }

    private static func logPath(_ path: String) -> String {
        guard let marker = path.range(of: "/api/vehicles/") else { return path }
        let rest = path[marker.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return String(path[..<marker.upperBound]) + "{vin}" }
        return String(path[..<marker.upperBound]) + "{vin}" + rest[slash...]
    }
}

private struct TeslaStateBox: Decodable {
    let response: TessieObject?
}

extension FleetControlValue {
    var teslaJSON: TeslaFleetJSON {
        switch self {
        case .string(let value): .string(value)
        case .int(let value): .int(value)
        case .double(let value): .double(value)
        case .bool(let value): .bool(value)
        }
    }
}

extension FleetSoftwareInfo {
    static var asleep: FleetSoftwareInfo {
        FleetSoftwareInfo(
            currentVersion: nil,
            availableVersion: nil,
            updateAvailable: false,
            installable: false,
            status: "asleep",
            downloadPercent: nil,
            installPercent: nil,
            expectedDurationMinutes: nil
        )
    }
}

private typealias TessieObject = [String: TessieValue]

private struct TessieResults<Value: Decodable>: Decodable {
    let results: [Value]
}

private struct TessieVehicle: Decodable {
    let vin: String
    let lastState: RosterState?

    enum CodingKeys: String, CodingKey {
        case vin
        case lastState = "last_state"
    }
}

private struct RosterState: Decodable {
    let displayName: String?
    let carType: String?
    let exteriorColor: String?
    let units: String?

    private enum Field: String, CodingKey {
        case displayName = "display_name", vehicleState = "vehicle_state", vehicleName = "vehicle_name"
        case config = "vehicle_config", carType = "car_type", exteriorColor = "exterior_color"
        case settings = "gui_settings", temperature = "gui_temperature_units", distance = "gui_distance_units"
    }

    init(from decoder: Decoder) throws {
        let state = try decoder.container(keyedBy: Field.self)
        let vehicle = try? state.nestedContainer(keyedBy: Field.self, forKey: .vehicleState)
        let config = try? state.nestedContainer(keyedBy: Field.self, forKey: .config)
        let settings = try? state.nestedContainer(keyedBy: Field.self, forKey: .settings)
        func string(_ field: Field, in container: KeyedDecodingContainer<Field>?) throws -> String? {
            try container?.decodeIfPresent(TessieValue.self, forKey: field)?.stringValue
        }
        displayName = try string(.displayName, in: state) ?? string(.vehicleName, in: vehicle)
        carType = try string(.carType, in: config)
        exteriorColor = try string(.exteriorColor, in: config)
        if let temperature = try string(.temperature, in: settings) {
            units = temperature.lowercased().hasPrefix("f") ? "imperial" : "metric"
        } else {
            units = try string(.distance, in: settings).map { $0.lowercased().contains("km") ? "metric" : "imperial" }
        }
    }
}

private struct TessiePathSample: Decodable {
    let latitude: TessieValue?
    let longitude: TessieValue?
    let speed: TessieValue?
    let heading: TessieValue?
    let autopilot: TessieValue?
    let timestamp: TessieValue?

    var routePoint: FleetDriveRoutePoint? {
        guard let latitude = latitude?.doubleValue, let longitude = longitude?.doubleValue else { return nil }
        return FleetDriveRoutePoint(
            latitude: latitude,
            longitude: longitude,
            speedMPH: speed?.doubleValue,
            heading: heading?.doubleValue,
            autopilotState: autopilot?.stringValue,
            timestampMS: timestamp?.int64Value.map(TessieObject.milliseconds)
        )
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
            batteryRangeMiles: charge.double("battery_range"),
            chargeLimitSOC: charge.double("charge_limit_soc"),
            chargingState: charge.string("charging_state"),
            chargerPowerKW: charge.double("charger_power"),
            chargePortDoorOpen: charge.bool("charge_port_door_open"),
            locked: vehicle.bool("locked"),
            sentryModeOn: vehicle.bool("sentry_mode"),
            chargeRateMPH: charge.double("charge_rate"),
            timeToFullCharge: charge.double("time_to_full_charge"),
            insideTemp: displayTemperature(climate.double("inside_temp")),
            outsideTemp: displayTemperature(climate.double("outside_temp")),
            targetTemp: displayTemperature(climate.double("driver_temp_setting")),
            hvacOn: climate.bool("is_climate_on") ?? climate.bool("is_auto_conditioning_on"),
            latitude: drive.double("latitude"),
            longitude: drive.double("longitude"),
            odometer: vehicle.double("odometer"),
            speed: drive.double("speed"),
            updatedAt: timestamps.max(),
            climateKeeperMode: climate.string("climate_keeper_mode"),
            defrostMode: climate.string("defrost_mode"),
            tires: tireState?.tirePressures ?? vehicle.stateTirePressures,
            temperatureInFahrenheit: usesFahrenheit,
            shiftState: drive.string("shift_state"),
            openClosures: vehicle.openClosures,
            seatHeaterLevels: climate.seatHeaterLevels,
            steeringWheelHeaterOn: climate.bool("steering_wheel_heater")
        )
    }

    /// Open doors, windows, frunk, and trunk from `vehicle_state` (Tesla reports
    /// non-zero integers for open closures).
    var openClosures: [String]? {
        let closures: [(key: String, name: String)] = [
            ("df", "Driver door"), ("pf", "Passenger door"),
            ("dr", "Rear left door"), ("pr", "Rear right door"),
            ("ft", "Frunk"), ("rt", "Trunk"),
            ("fd_window", "Driver window"), ("fp_window", "Passenger window"),
            ("rd_window", "Rear left window"), ("rp_window", "Rear right window")
        ]
        var reported = false
        let open = closures.compactMap { closure -> String? in
            guard let isOpen = bool(closure.key) else { return nil }
            reported = true
            return isOpen ? closure.name : nil
        }
        return reported ? open : nil
    }

    /// Seat heater levels (0–3) from `climate_state`, keyed by readable seat name.
    var seatHeaterLevels: [String: Int]? {
        let seats: [(key: String, name: String)] = [
            ("seat_heater_left", "Driver"), ("seat_heater_right", "Passenger"),
            ("seat_heater_rear_left", "Rear left"), ("seat_heater_rear_center", "Rear center"),
            ("seat_heater_rear_right", "Rear right")
        ]
        var levels: [String: Int] = [:]
        for seat in seats {
            if let level = int64(seat.key) {
                levels[seat.name] = Int(level)
            }
        }
        return levels.isEmpty ? nil : levels
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
            endAddress: string("ending_location"),
            startLatitude: double("starting_latitude"),
            startLongitude: double("starting_longitude"),
            endLatitude: double("ending_latitude"),
            endLongitude: double("ending_longitude"),
            startingBatteryPercent: int64("starting_battery").map(Int.init),
            endingBatteryPercent: int64("ending_battery").map(Int.init),
            ratedRangeUsedMiles: double("rated_range_used"),
            autopilotDistanceMiles: double("autopilot_distance"),
            insideTempF: double("average_inside_temperature"),
            outsideTempF: double("average_outside_temperature"),
            tag: string("tag")
        )
    }

    func charge(vin: String) -> FleetChargeInfo? {
        guard let rawID = string("id"), let started = int64("started_at") else { return nil }
        let ended = int64("ended_at")
        let startedMS = Self.milliseconds(started)
        let endedMS = ended.map(Self.milliseconds)
        return FleetChargeInfo(
            sessionID: "\(vin):\(rawID)",
            vin: vin,
            startedAt: startedMS,
            endedAt: endedMS,
            location: string("location"),
            latitude: double("latitude"),
            longitude: double("longitude"),
            isSupercharger: bool("is_supercharger") ?? false,
            odometerMiles: double("odometer"),
            energyAddedKWH: double("energy_added"),
            energyUsedKWH: double("energy_used"),
            milesAdded: double("miles_added") ?? double("miles_added_ideal"),
            startingBatteryPercent: int64("starting_battery").map(Int.init),
            endingBatteryPercent: int64("ending_battery").map(Int.init),
            cost: double("cost")
        )
    }

    static func mergedBatteryHealth(
        vin: String,
        health: TessieObject?,
        battery: TessieObject?
    ) -> FleetBatteryHealthInfo {
        let minTempF = battery?.double("module_temp_min").map { ($0 * 9.0 / 5.0) + 32.0 }
        let maxTempF = battery?.double("module_temp_max").map { ($0 * 9.0 / 5.0) + 32.0 }
        let rawHealth = health?.double("health_percent")
        let rawDegradation = health?.double("degradation_percent")
        let computedHealth: Double? = rawHealth ?? rawDegradation.map { Swift.max(0, 100.0 - $0) }
        let computedDegradation: Double? = rawDegradation ?? rawHealth.map { Swift.max(0, 100.0 - $0) }

        return FleetBatteryHealthInfo(
            vin: vin,
            healthPercent: computedHealth,
            degradationPercent: computedDegradation,
            usableCapacityKWH: health?.double("capacity"),
            originalCapacityKWH: health?.double("original_capacity"),
            maxRangeMiles: health?.double("max_range"),
            maxIdealRangeMiles: health?.double("max_ideal_range"),
            odometerMiles: health?.double("odometer"),
            energyRemainingKWH: battery?.double("energy_remaining"),
            lifetimeEnergyUsedKWH: battery?.double("lifetime_energy_used"),
            phantomDrainPercent: battery?.double("phantom_drain_percent"),
            packVoltage: battery?.double("pack_voltage"),
            packCurrentAmps: battery?.double("pack_current"),
            moduleTempMinF: minTempF,
            moduleTempMaxF: maxTempF
        )
    }

    var consumptionSinceCharge: FleetConsumptionInfo {
        FleetConsumptionInfo(
            lastChargeAt: int64("last_charge_at").map(Self.milliseconds),
            distanceDrivenMiles: double("distance_driven"),
            batteryPercentUsed: double("battery_percent_used"),
            batteryPercentUsedByDriving: double("battery_percent_used_by_driving"),
            ratedRangeUsedMiles: double("rated_range_used"),
            ratedRangeUsedByDrivingMiles: double("rated_range_used_by_driving"),
            energyUsedKWH: double("energy_used"),
            energyUsedByDrivingKWH: double("energy_used_by_driving")
        )
    }

    var software: FleetSoftwareInfo {
        let vehicle = object("vehicle_state")
        let update = vehicle.object("software_update")
        let availableVersion = update.string("version")?.split(whereSeparator: \.isWhitespace).first.map(String.init)
        let status = update.string("status")
        let unavailableStatuses = ["", "idle", "unknown"]
        let normalizedStatus = status?.lowercased() ?? ""
        let available = availableVersion != nil
            || !unavailableStatuses.contains(normalizedStatus)
        // Tesla reports "available" once the update has downloaded and "scheduled"
        // during the install countdown; both can be (re)scheduled. "downloading",
        // "downloading_wifi_wait", and "installing" can't.
        let installable = available && ["available", "scheduled"].contains(normalizedStatus)
        let currentVersion = vehicle.string("car_version")?.split(whereSeparator: \.isWhitespace).first.map(String.init)
        let expectedSeconds = update.double("expected_duration_sec")

        return FleetSoftwareInfo(
            currentVersion: currentVersion,
            availableVersion: availableVersion,
            updateAvailable: available,
            installable: installable,
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
