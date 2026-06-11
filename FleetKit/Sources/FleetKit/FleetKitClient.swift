import Foundation

public enum FleetKitError: Swift.Error, LocalizedError {
    case notSignedIn
    case sessionExpired
    case api(String?)
    case badResponse
    case unsupportedAction(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Open TeslaSiri and sign in to use this."
        case .sessionExpired:
            return "Your TeslaSiri session expired. Open the app to refresh it."
        case .api(let message):
            return message ?? "The Fleet backend returned an error."
        case .badResponse:
            return "The Fleet backend returned an unexpected response."
        case .unsupportedAction(let action):
            return "Your vehicle doesn't support \(action) right now."
        }
    }
}

/// A JSON-encodable control parameter value.
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
}

/// Minimal async client for the read and control endpoints the intents use.
/// Authenticates with the access token the app mirrors into the shared App Group.
public struct FleetIntentClient: Sendable {
    private let session: URLSession
    private let tokenStore: FleetSharedTokenStore

    public init(session: URLSession = .shared, tokenStore: FleetSharedTokenStore = .shared) {
        self.session = session
        self.tokenStore = tokenStore
    }

    // MARK: - Reads

    public func vehicles() async throws -> [FleetVehicleInfo] {
        try await get("/api/v1/vehicles", query: [URLQueryItem(name: "include_live", value: "true")])
    }

    public func snapshot(vin: String) async throws -> FleetSnapshotInfo {
        try await get("/api/v1/vehicles/\(encoded(vin))/live")
    }

    public func user() async throws -> FleetUserInfo {
        try await get("/api/v1/me")
    }

    public func drives(vin: String, limit: Int) async throws -> [FleetDriveInfo] {
        try await get(
            "/api/v1/vehicles/\(encoded(vin))/drives",
            query: [
                URLQueryItem(name: "include_route", value: "false"),
                URLQueryItem(name: "limit", value: String(limit))
            ]
        )
    }

    public func software(vin: String) async throws -> FleetSoftwareInfo {
        try await get(
            "/api/v1/vehicles/\(encoded(vin))/software",
            query: [URLQueryItem(name: "include_release_notes", value: "true")]
        )
    }

    public func controlActions() async throws -> FleetControlActionsInfo {
        try await get("/api/v1/controls/actions")
    }

    // MARK: - Writes

    private struct ControlBody: Encodable {
        let action: String
        let params: [String: FleetControlValue]?
    }

    private struct InstallBody: Encodable {
        let offsetSec: Int
        enum CodingKeys: String, CodingKey { case offsetSec = "offset_sec" }
    }

    public func runControl(action: String, vin: String, params: [String: FleetControlValue]) async throws {
        let body = ControlBody(action: action, params: params.isEmpty ? nil : params)
        try await post("/api/v1/vehicles/\(encoded(vin))/controls", body: body)
    }

    public func installSoftwareUpdate(vin: String, offsetSec: Int) async throws {
        try await post("/api/v1/vehicles/\(encoded(vin))/software/install", body: InstallBody(offsetSec: offsetSec))
    }

    public func cancelSoftwareUpdate(vin: String) async throws {
        try await postNoBody("/api/v1/vehicles/\(encoded(vin))/software/cancel")
    }

    // MARK: - Transport

    private struct Envelope<Value: Decodable>: Decodable {
        let ok: Bool
        let data: Value?
        let error: String?
    }

    private struct StatusEnvelope: Decodable {
        let ok: Bool
        let error: String?
    }

    private func get<Value: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Value {
        let request = try authorizedRequest(path: path, query: query, method: "GET")
        let (data, response) = try await session.data(for: request)
        try check(response)
        let envelope = try JSONDecoder().decode(Envelope<Value>.self, from: data)
        guard envelope.ok, let value = envelope.data else {
            throw FleetKitError.api(envelope.error)
        }
        return value
    }

    private func post(_ path: String, body: some Encodable) async throws {
        var request = try authorizedRequest(path: path, query: [], method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        try await send(request)
    }

    private func postNoBody(_ path: String) async throws {
        let request = try authorizedRequest(path: path, query: [], method: "POST")
        try await send(request)
    }

    private func send(_ request: URLRequest) async throws {
        let (data, response) = try await session.data(for: request)
        try check(response)
        if let status = try? JSONDecoder().decode(StatusEnvelope.self, from: data), !status.ok {
            throw FleetKitError.api(status.error)
        }
    }

    private func authorizedRequest(path: String, query: [URLQueryItem], method: String) throws -> URLRequest {
        guard let token = tokenStore.accessToken() else {
            throw FleetKitError.notSignedIn
        }
        guard var components = URLComponents(url: FleetKitConfig.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw FleetKitError.badResponse
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw FleetKitError.badResponse
        }
        var request = URLRequest(url: url, timeoutInterval: FleetKitConfig.requestTimeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
        return request
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 {
            throw FleetKitError.sessionExpired
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FleetKitError.api("HTTP \(http.statusCode)")
        }
    }

    private func encoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
