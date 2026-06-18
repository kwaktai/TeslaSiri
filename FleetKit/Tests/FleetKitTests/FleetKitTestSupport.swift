import Foundation
import Testing
@testable import FleetKit

struct FleetKitFixtures {
    static func decode<Value: Decodable>(_ type: Value.Type, from json: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }

    static func envelope(_ json: String) -> Data {
        Data("""
        {"ok":true,"data":\(json)}
        """.utf8)
    }

    static func commandResponse(result: Bool = true) -> Data {
        Data("""
        {"result":\(result)}
        """.utf8)
    }

    static let tessieVehiclesJSON = """
    {
      "results": [
        {"vin":"VIN-1","is_active":true,"last_state":{"display_name":"Roadrunner"}},
        {"vin":"VIN-2","is_active":true,"last_state":{"display_name":"Blue Y"}}
      ]
    }
    """

    static let tessieStateJSON = """
    {
      "display_name":"Roadrunner",
      "drive_state":{"latitude":37.3317,"longitude":-122.0301,"speed":41.2,"timestamp":1710000000000},
      "charge_state":{"battery_level":82.4,"charge_limit_soc":90,"charging_state":"Charging","charge_rate":22.5,"time_to_full_charge":1.25,"timestamp":1710000000000},
      "climate_state":{"inside_temp":20.5,"outside_temp":10,"is_climate_on":true,"climate_keeper_mode":"dog","defrost_mode":2,"timestamp":1710000000000},
      "vehicle_state":{"locked":true,"odometer":12345.6,"car_version":"2026.2.1 abc123","timestamp":1710000000000,"software_update":{"status":"available","version":"2026.8.4","download_perc":100,"install_perc":0,"expected_duration_sec":1500}},
      "gui_settings":{"gui_distance_units":"mi/hr"}
    }
    """

    static let tessieTiresJSON = """
    {"front_left":39.4,"front_right":40,"rear_left":41.2,"rear_right":42,"timestamp":1710000001}
    """

    static let vehiclesJSON = """
    [
      {"vin":"VIN-1","display_name":"Roadrunner","vehicle_tag":"Model S"},
      {"vin":"VIN-2","display_name":null,"vehicle_tag":"Blue Y"}
    ]
    """

    static let snapshotJSON = """
    {
      "vin":"VIN-1",
      "battery_level":"82.4",
      "charge_limit_soc":90,
      "charging_state":"charging",
      "locked":true,
      "charge_rate_mph":"22.5",
      "time_to_full_charge":1.25,
      "inside_temp":"20.5",
      "outside_temp":10,
      "hvac_on":true,
      "latitude":"37.3317",
      "longitude":"-122.0301",
      "odometer":"12345.6",
      "speed":"41.2",
      "updated_at":"1710000000000",
      "climate_keeper_mode":"ClimateKeeperModeDog",
      "defrost_mode":2,
      "tires": {
        "front_left_psi":"39.4",
        "front_right_psi":40,
        "rear_left_psi":"41.2",
        "rear_right_psi":42,
        "hard_warnings":"1",
        "soft_warnings":0,
        "last_measured_at":"1710000001000"
      }
    }
    """

    static let driveJSON = """
    {
      "session_id":"drive-1",
      "vin":"VIN-1",
      "distance_miles":"12.34",
      "duration_ms":"1860000",
      "avg_speed_mph":"23.9",
      "max_speed_mph":55,
      "energy_used_kwh":"3.4",
      "started_at":"1710000000000",
      "ended_at":"1710001860000",
      "start_address":"1 Infinite Loop",
      "end_address":"3500 Deer Creek Road"
    }
    """

    static let softwareJSON = """
    {
      "current_version":"2026.2.1",
      "available_version":"2026.8.4",
      "update_available":true,
      "installable":true,
      "status":"downloaded",
      "download_percent":"100",
      "install_percent":null,
      "expected_duration_minutes":"25",
      "release_notes":[
        {"title":"Better routing","subtitle":"Navigation","description":"Route planning improvements"}
      ]
    }
    """

    static let actionsJSON = """
    {
      "actions":["door_lock","honk_horn","navigation_request"],
      "charge_actions":["set_charge_limit"],
      "schemas":{"set_charge_limit":["percent"]}
    }
    """
}

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var responder: ((URLRequest) throws -> (Int, Data))?

    static func reset() {
        requests = []
        responder = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        do {
            guard let responder = Self.responder else {
                throw FleetKitError.badResponse
            }
            let (statusCode, data) = try responder(request)
            guard let url = request.url else {
                throw FleetKitError.badResponse
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

func makeMockClient(
    selectedVIN: String? = nil,
    responder: @escaping (URLRequest) throws -> (Int, Data)
) -> FleetIntentClient {
    MockURLProtocol.reset()
    MockURLProtocol.responder = responder

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: configuration)

    let suiteName = "FleetKitTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set("test-token", forKey: FleetKitConfig.accessTokenDefaultsKey)
    if let selectedVIN {
        defaults.set(selectedVIN, forKey: FleetKitConfig.selectedVINDefaultsKey)
    }

    return FleetIntentClient(session: session, tokenStore: FleetSharedTokenStore(appGroup: suiteName))
}

func requestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        return Data()
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        if count > 0 {
            data.append(buffer, count: count)
        } else {
            break
        }
    }
    return data
}
