import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Request building and response decoding for the owner's self-hosted Tesla Fleet API
/// (`kwaktai/teslafleetapi`). Reads never include a wake. Commands may.
public enum TeslaFleetAPI {
    public static let defaultBaseURLString = "https://t.kwakhome.com"
    public static let apiKeyHeader = "X-API-Key"

    public static var defaultBaseURL: URL {
        guard let url = URL(string: defaultBaseURLString) else {
            preconditionFailure("Invalid default Tesla server URL.")
        }
        return url
    }

    /// Accepts `https://host`, `host`, and a trailing slash. Drops query and fragment.
    public static func normalizedBaseURL(from raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://\(trimmed)"
        }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        if components.path == "/" {
            components.path = ""
        } else if components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url
    }
}

/// A sleeping or offline car must not be woken by a read.
public enum TeslaFleetReadPolicy {
    public static func allowsVehicleDataFetch(state: String?) -> Bool {
        guard let state = state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !state.isEmpty else {
            return true
        }
        switch state {
        case "online":
            return true
        case "asleep", "offline", "suspended":
            return false
        default:
            return false
        }
    }
}

public struct TeslaFleetVehicle: Equatable, Sendable {
    public var id: String
    public var vin: String
    public var displayName: String?
    public var state: String?

    public init(id: String, vin: String, displayName: String?, state: String?) {
        self.id = id
        self.vin = vin
        self.displayName = displayName
        self.state = state
    }

    /// VIN, alias, or numeric id. The server accepts all three. VIN keeps paths account-safe.
    public var routeID: String {
        vin.isEmpty ? id : vin
    }
}

public enum TeslaFleetJSON: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: TeslaFleetJSON])

    public var queryString: String {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        case .object: ""
        }
    }
}

extension TeslaFleetJSON: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public struct TeslaFleetRequest: Equatable, Sendable {
    public var method: String
    public var url: URL
    public var body: Data?
    /// True only for `wake_up` and commands sent with `?wake=1`.
    public var wakesVehicle: Bool

    public func urlRequest(apiKey: String, timeout: TimeInterval = 30) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: TeslaFleetAPI.apiKeyHeader)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

public enum TeslaFleetRequests {
    public static func vehicles(baseURL: URL) -> TeslaFleetRequest {
        TeslaFleetRequest(
            method: "GET",
            url: makeURL(baseURL: baseURL, path: ["api", "vehicles"], query: []),
            body: nil,
            wakesVehicle: false
        )
    }

    public static func vehicleData(baseURL: URL, vehicleID: String) -> TeslaFleetRequest {
        TeslaFleetRequest(
            method: "GET",
            url: makeURL(
                baseURL: baseURL,
                path: ["api", "vehicles", vehicleID, "vehicle_data"],
                query: []
            ),
            body: nil,
            wakesVehicle: false
        )
    }

    public static func wake(baseURL: URL, vehicleID: String) -> TeslaFleetRequest {
        TeslaFleetRequest(
            method: "POST",
            url: makeURL(baseURL: baseURL, path: ["api", "vehicles", vehicleID, "wake_up"], query: []),
            body: Data("{}".utf8),
            wakesVehicle: true
        )
    }

    public static func command(
        baseURL: URL,
        vehicleID: String,
        name: String,
        body: TeslaFleetJSON,
        wake: Bool = true
    ) -> TeslaFleetRequest {
        let payload = (try? JSONEncoder().encode(body)) ?? Data("{}".utf8)
        let query = wake ? [URLQueryItem(name: "wake", value: "1")] : []
        return TeslaFleetRequest(
            method: "POST",
            url: makeURL(
                baseURL: baseURL,
                path: ["api", "vehicles", vehicleID, "command", name],
                query: query
            ),
            body: payload,
            wakesVehicle: wake
        )
    }

    static func makeURL(baseURL: URL, path: [String], query: [URLQueryItem]) -> URL {
        // Build the URL as a string. Assigning `queryItems` after `percentEncodedPath`
        // re-parses the path and turns `%20` back into a raw space.
        let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let scheme = components?.scheme ?? "https"
        let host = components?.host ?? ""
        let port = components?.port.map { ":\($0)" } ?? ""
        let prefix = (components?.path == "/" ? "" : components?.path) ?? ""
        let trimmedPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var parts = path.map(encodePathComponent)
        if !trimmedPrefix.isEmpty {
            parts.insert(trimmedPrefix, at: 0)
        }
        var absolute = "\(scheme)://\(host)\(port)/\(parts.joined(separator: "/"))"
        if !query.isEmpty {
            var queryComponents = URLComponents()
            queryComponents.queryItems = query
            if let encoded = queryComponents.percentEncodedQuery, !encoded.isEmpty {
                absolute += "?\(encoded)"
            }
        }
        return URL(string: absolute) ?? baseURL
    }

    static func encodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

public enum TeslaFleetCommandError: Error, Equatable, Sendable {
    case unsupported(String)
    case missingParameter(String)
}

public struct TeslaFleetCommand: Equatable, Sendable {
    public var name: String
    public var body: TeslaFleetJSON

    public init(name: String, body: TeslaFleetJSON) {
        self.name = name
        self.body = body
    }
}

/// Maps the app's existing control action names onto Tesla Fleet command names and JSON bodies.
public enum TeslaFleetCommands {
    public static func build(
        action: String,
        params: [String: TeslaFleetJSON],
        locale: String = "en-US",
        now: Date = Date()
    ) throws -> TeslaFleetCommand {
        switch action {
        case "door_lock":
            return TeslaFleetCommand(name: "door_lock", body: .object([:]))
        case "door_unlock":
            return TeslaFleetCommand(name: "door_unlock", body: .object([:]))
        case "auto_conditioning_start":
            return TeslaFleetCommand(name: "auto_conditioning_start", body: .object([:]))
        case "auto_conditioning_stop":
            return TeslaFleetCommand(name: "auto_conditioning_stop", body: .object([:]))
        case "window_control":
            let command = params["command"]?.queryString ?? ""
            guard command == "vent" || command == "close" else {
                throw TeslaFleetCommandError.unsupported("that window command")
            }
            let lat = params["lat"] ?? .double(0)
            let lon = params["lon"] ?? .double(0)
            return TeslaFleetCommand(
                name: "window_control",
                body: .object(["command": .string(command), "lat": lat, "lon": lon])
            )
        case "actuate_trunk":
            let which = params["which_trunk"]?.queryString == "front" ? "front" : "rear"
            return TeslaFleetCommand(name: "actuate_trunk", body: .object(["which_trunk": .string(which)]))
        case "charge_start":
            return TeslaFleetCommand(name: "charge_start", body: .object([:]))
        case "charge_stop":
            return TeslaFleetCommand(name: "charge_stop", body: .object([:]))
        case "charge_port_door_open":
            return TeslaFleetCommand(name: "charge_port_door_open", body: .object([:]))
        case "charge_port_door_close":
            return TeslaFleetCommand(name: "charge_port_door_close", body: .object([:]))
        case "set_charge_limit":
            guard let percent = params["percent"] else {
                throw TeslaFleetCommandError.missingParameter("percent")
            }
            return TeslaFleetCommand(name: "set_charge_limit", body: .object(["percent": percent]))
        case "set_charging_amps":
            guard let amps = params["amps"] ?? params["charging_amps"] else {
                throw TeslaFleetCommandError.missingParameter("charging_amps")
            }
            return TeslaFleetCommand(name: "set_charging_amps", body: .object(["charging_amps": amps]))
        case "set_seat_heat":
            guard let seat = params["seat"]?.queryString, let level = params["level"] else {
                throw TeslaFleetCommandError.missingParameter("seat")
            }
            guard let heater = seatHeaterIndex(seat) else {
                throw TeslaFleetCommandError.unsupported(seat)
            }
            return TeslaFleetCommand(
                name: "remote_seat_heater_request",
                body: .object(["heater": .int(heater), "level": level])
            )
        case "set_seat_cool":
            guard let seat = params["seat"]?.queryString, let level = params["level"] else {
                throw TeslaFleetCommandError.missingParameter("seat")
            }
            guard let position = seatCoolerIndex(seat) else {
                throw TeslaFleetCommandError.unsupported(seat)
            }
            return TeslaFleetCommand(
                name: "remote_seat_cooler_request",
                body: .object(["seat_position": .int(position), "seat_cooler_level": level])
            )
        case "steering_wheel_heater":
            let on = params["on"] != .bool(false)
            return TeslaFleetCommand(
                name: "remote_steering_wheel_heater_request",
                body: .object(["on": .bool(on)])
            )
        case "set_temps":
            guard let temperature = params["driver_temp"] ?? params["passenger_temp"] else {
                throw TeslaFleetCommandError.missingParameter("driver_temp")
            }
            let passenger = params["passenger_temp"] ?? temperature
            let driver = params["driver_temp"] ?? temperature
            return TeslaFleetCommand(
                name: "set_temps",
                body: .object(["driver_temp": driver, "passenger_temp": passenger])
            )
        case "remote_defrost":
            let on = params["on"] != .bool(false)
            return TeslaFleetCommand(
                name: "set_preconditioning_max",
                body: .object(["on": .bool(on), "manual_override": .bool(true)])
            )
        case "set_pet_mode":
            let mode = params["on"] == .bool(false) ? 0 : 2
            return TeslaFleetCommand(
                name: "set_climate_keeper_mode",
                body: .object([
                    "climate_keeper_mode": .int(mode),
                    "manual_override": .bool(false)
                ])
            )
        case "set_bioweapon_mode":
            let on = params["on"] != .bool(false)
            return TeslaFleetCommand(
                name: "set_bioweapon_mode",
                body: .object(["on": .bool(on), "manual_override": .bool(false)])
            )
        case "set_sentry_mode":
            let on = params["on"] != .bool(false)
            return TeslaFleetCommand(name: "set_sentry_mode", body: .object(["on": .bool(on)]))
        case "flash_lights":
            return TeslaFleetCommand(name: "flash_lights", body: .object([:]))
        case "honk_horn":
            return TeslaFleetCommand(name: "honk_horn", body: .object([:]))
        case "navigation_request":
            guard let destination = params["value"]?.queryString, !destination.isEmpty else {
                throw TeslaFleetCommandError.missingParameter("value")
            }
            let resolvedLocale: String
            if let suppliedLocale = params["locale"]?.queryString, !suppliedLocale.isEmpty {
                resolvedLocale = suppliedLocale
            } else {
                resolvedLocale = locale
            }
            let timestamp = String(Int64(now.timeIntervalSince1970 * 1000))
            return TeslaFleetCommand(
                name: "navigation_request",
                body: .object([
                    "type": .string("share_ext_content_raw"),
                    "locale": .string(resolvedLocale),
                    "timestamp_ms": .string(timestamp),
                    "value": .object(["android.intent.extra.TEXT": .string(destination)])
                ])
            )
        case "schedule_software_update":
            let offset = params["offset_sec"] ?? params["in_seconds"] ?? .int(0)
            return TeslaFleetCommand(name: "schedule_software_update", body: .object(["offset_sec": offset]))
        case "cancel_software_update":
            return TeslaFleetCommand(name: "cancel_software_update", body: .object([:]))
        default:
            throw TeslaFleetCommandError.unsupported(action)
        }
    }

    /// Tesla seat heater index: 0 driver, 1 passenger, 2 rear left, 4 rear center, 5 rear right.
    public static func seatHeaterIndex(_ seat: String) -> Int? {
        switch seat {
        case "front_left", "0": 0
        case "front_right", "1": 1
        case "rear_left", "2": 2
        case "rear_center", "4": 4
        case "rear_right", "5": 5
        default: nil
        }
    }

    public static func seatCoolerIndex(_ seat: String) -> Int? {
        switch seat {
        case "front_left", "0": 0
        case "front_right", "1": 1
        default: nil
        }
    }
}

public enum TeslaFleetCommandOutcome: Equatable, Sendable {
    case accepted
    case rejected(String)
}

public enum TeslaFleetDecoding {
    public static func vehicles(from data: Data) throws -> [TeslaFleetVehicle] {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        let list = root.object?["response"]?.array ?? root.array ?? []
        return list.compactMap(vehicle(from:))
    }

    public static func commandOutcome(statusCode: Int, body: Data) -> TeslaFleetCommandOutcome {
        guard (200..<300).contains(statusCode) else {
            return .rejected(errorMessage(from: body) ?? "Tesla server request failed with HTTP \(statusCode).")
        }
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            return .accepted
        }
        if let response = root.object?["response"]?.object {
            if response["result"]?.bool == false {
                return .rejected(response["reason"]?.string?.nilIfEmpty ?? "The vehicle rejected the command.")
            }
            return .accepted
        }
        if root.object?["result"]?.bool == false {
            return .rejected(root.object?["reason"]?.string?.nilIfEmpty ?? "The vehicle rejected the command.")
        }
        if let error = root.object?["error"]?.string?.nilIfEmpty, root.object?["result"] == nil {
            return .rejected(error)
        }
        return .accepted
    }

    public static func isAsleep(statusCode: Int, body: Data) -> Bool {
        if statusCode == 408 { return true }
        let message = errorMessage(from: body)?.lowercased() ?? ""
        return message.contains("asleep") || message.contains("offline") || message.contains("vehicle unavailable")
    }

    public static func errorMessage(from data: Data) -> String? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return root.object?["error"]?.string ?? root.object?["message"]?.string ?? root.object?["reason"]?.string
    }

    private static func vehicle(from value: JSONValue) -> TeslaFleetVehicle? {
        guard let object = value.object, let vin = object["vin"]?.string?.nilIfEmpty else { return nil }
        let id = object["id_s"]?.string?.nilIfEmpty
            ?? object["id"]?.string?.nilIfEmpty
            ?? object["vehicle_id"]?.string?.nilIfEmpty
            ?? vin
        return TeslaFleetVehicle(
            id: id,
            vin: vin,
            displayName: object["display_name"]?.string?.nilIfEmpty,
            state: object["state"]?.string?.nilIfEmpty
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

/// Minimal JSON so vehicle list and command bodies can be decoded without a second model layer.
private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
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
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON")
        }
    }

    var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var string: String? {
        switch self {
        case .string(let value): value
        case .number(let value):
            if let integer = Int64(exactly: value) { String(integer) } else { String(value) }
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value):
            switch value.lowercased() {
            case "true", "1", "yes": true
            case "false", "0", "no": false
            default: nil
            }
        default: nil
        }
    }
}
