import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import TeslaFleetTransport

@Test func normalizesTheDefaultServerAndStripsSecretsFromTheURL() {
    let url = TeslaFleetAPI.normalizedBaseURL(from: "  t.kwakhome.com/  ")
    #expect(url?.absoluteString == "https://t.kwakhome.com")
    let keyed = TeslaFleetAPI.normalizedBaseURL(from: "https://t.kwakhome.com/api?key=secret#frag")
    #expect(keyed?.absoluteString == "https://t.kwakhome.com/api")
    #expect(TeslaFleetAPI.normalizedBaseURL(from: "   ") == nil)
}

@Test func vehicleDataReadDoesNotWakeAndUsesTheAPIKeyHeader() throws {
    let base = try #require(TeslaFleetAPI.normalizedBaseURL(from: TeslaFleetAPI.defaultBaseURLString))
    let spec = TeslaFleetRequests.vehicleData(baseURL: base, vehicleID: "5YJ3E1EA7HF000001")
    let request = spec.urlRequest(apiKey: "personal-key")

    #expect(spec.wakesVehicle == false)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/api/vehicles/5YJ3E1EA7HF000001/vehicle_data")
    #expect(request.url?.query == nil)
    #expect(request.value(forHTTPHeaderField: "X-API-Key") == "personal-key")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.url?.absoluteString.contains("personal-key") == false)
}

@Test func asleepAndOfflineCarsAreNotRead() {
    #expect(TeslaFleetReadPolicy.allowsVehicleDataFetch(state: "online"))
    #expect(TeslaFleetReadPolicy.allowsVehicleDataFetch(state: "ONLINE"))
    #expect(TeslaFleetReadPolicy.allowsVehicleDataFetch(state: nil))
    #expect(!TeslaFleetReadPolicy.allowsVehicleDataFetch(state: "asleep"))
    #expect(!TeslaFleetReadPolicy.allowsVehicleDataFetch(state: "offline"))
    #expect(!TeslaFleetReadPolicy.allowsVehicleDataFetch(state: "suspended"))
}

@Test func commandsWakeOnlyWhenAskedAndEncodeTeslaBodies() throws {
    let base = try #require(URL(string: "https://t.kwakhome.com"))
    let limit = try TeslaFleetCommands.build(action: "set_charge_limit", params: ["percent": .int(80)])
    let spec = TeslaFleetRequests.command(
        baseURL: base,
        vehicleID: "VIN/ABC 123",
        name: limit.name,
        body: limit.body
    )
    let request = spec.urlRequest(apiKey: "k")

    #expect(spec.wakesVehicle)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString == "https://t.kwakhome.com/api/vehicles/VIN%2FABC%20123/command/set_charge_limit?wake=1")
    #expect(request.url?.query?.contains("wake=1") == true)
    let body = try JSONDecoder().decode([String: Int].self, from: try #require(request.httpBody))
    #expect(body["percent"] == 80)

    let quiet = TeslaFleetRequests.command(
        baseURL: base,
        vehicleID: "3",
        name: "door_lock",
        body: .object([:]),
        wake: false
    )
    #expect(quiet.wakesVehicle == false)
    #expect(quiet.url.query == nil)
}

@Test func mapsEachSupportedIntentOntoTheServerCommand() throws {
    let lock = try TeslaFleetCommands.build(action: "door_lock", params: [:])
    #expect(lock.name == "door_lock")

    let unlock = try TeslaFleetCommands.build(action: "door_unlock", params: [:])
    #expect(unlock.name == "door_unlock")

    let climate = try TeslaFleetCommands.build(action: "auto_conditioning_start", params: [:])
    #expect(climate.name == "auto_conditioning_start")

    let temps = try TeslaFleetCommands.build(
        action: "set_temps",
        params: ["driver_temp": .double(21.5)]
    )
    #expect(temps.name == "set_temps")
    #expect(temps.body == .object(["driver_temp": .double(21.5), "passenger_temp": .double(21.5)]))

    let defrost = try TeslaFleetCommands.build(action: "remote_defrost", params: ["on": .bool(false)])
    #expect(defrost.name == "set_preconditioning_max")
    #expect(defrost.body == .object(["on": .bool(false), "manual_override": .bool(true)]))

    let dog = try TeslaFleetCommands.build(action: "set_pet_mode", params: ["on": .bool(true)])
    #expect(dog.body == .object(["climate_keeper_mode": .int(2), "manual_override": .bool(false)]))

    let seat = try TeslaFleetCommands.build(
        action: "set_seat_heat",
        params: ["seat": .string("front_right"), "level": .int(3)]
    )
    #expect(seat.name == "remote_seat_heater_request")
    #expect(seat.body == .object(["heater": .int(1), "level": .int(3)]))

    let wheel = try TeslaFleetCommands.build(action: "steering_wheel_heater", params: ["on": .bool(false)])
    #expect(wheel.name == "remote_steering_wheel_heater_request")
    #expect(wheel.body == .object(["on": .bool(false)]))

    let amps = try TeslaFleetCommands.build(action: "set_charging_amps", params: ["amps": .int(16)])
    #expect(amps.name == "set_charging_amps")
    #expect(amps.body == .object(["charging_amps": .int(16)]))

    let sentry = try TeslaFleetCommands.build(action: "set_sentry_mode", params: ["on": .bool(false)])
    #expect(sentry.body == .object(["on": .bool(false)]))

    let windows = try TeslaFleetCommands.build(action: "window_control", params: ["command": .string("close")])
    #expect(windows.body == .object(["command": .string("close"), "lat": .double(0), "lon": .double(0)]))

    let trunk = try TeslaFleetCommands.build(action: "actuate_trunk", params: ["which_trunk": .string("front")])
    #expect(trunk.body == .object(["which_trunk": .string("front")]))

    let horn = try TeslaFleetCommands.build(action: "honk_horn", params: [:])
    #expect(horn.name == "honk_horn")

    let port = try TeslaFleetCommands.build(action: "charge_port_door_open", params: [:])
    #expect(port.name == "charge_port_door_open")

    let now = Date(timeIntervalSince1970: 1_710_000_000)
    let navigation = try TeslaFleetCommands.build(
        action: "navigation_request",
        params: ["value": .string("서울역")],
        locale: "ko-KR",
        now: now
    )
    #expect(navigation.name == "navigation_request")
    #expect(navigation.body == .object([
        "type": .string("share_ext_content_raw"),
        "locale": .string("ko-KR"),
        "timestamp_ms": .string("1710000000000"),
        "value": .object(["android.intent.extra.TEXT": .string("서울역")])
    ]))

    let install = try TeslaFleetCommands.build(action: "schedule_software_update", params: ["offset_sec": .int(60)])
    #expect(install.body == .object(["offset_sec": .int(60)]))
}

@Test func decodesTheVehicleListWithoutWakingFields() throws {
    let json = """
    {"response":[
      {"id":123456789012345,"vin":"5YJ3E1EA7HF000001","display_name":"와티","state":"asleep"},
      {"id_s":"9","vin":"7SA00000000000002","display_name":"","state":"online"}
    ],"count":2}
    """
    let vehicles = try TeslaFleetDecoding.vehicles(from: Data(json.utf8))
    #expect(vehicles.count == 2)
    #expect(vehicles[0].id == "123456789012345")
    #expect(vehicles[0].displayName == "와티")
    #expect(vehicles[0].state == "asleep")
    #expect(vehicles[1].displayName == nil)
    #expect(vehicles[1].id == "9")
}

@Test func commandResultsAndAsleepResponsesStayExplicit() {
    let accepted = TeslaFleetDecoding.commandOutcome(
        statusCode: 200,
        body: Data(#"{"response":{"result":true,"reason":""}}"#.utf8)
    )
    #expect(accepted == .accepted)

    let rejected = TeslaFleetDecoding.commandOutcome(
        statusCode: 200,
        body: Data(#"{"response":{"result":false,"reason":"door open"}}"#.utf8)
    )
    #expect(rejected == .rejected("door open"))

    let unauthorized = TeslaFleetDecoding.commandOutcome(statusCode: 401, body: Data("401 인증 필요".utf8))
    #expect(unauthorized == .rejected("Tesla server request failed with HTTP 401."))

    #expect(TeslaFleetDecoding.isAsleep(statusCode: 408, body: Data()))
    #expect(TeslaFleetDecoding.isAsleep(
        statusCode: 200,
        body: Data(#"{"error":"vehicle unavailable: vehicle is asleep"}"#.utf8)
    ))
    #expect(!TeslaFleetDecoding.isAsleep(statusCode: 500, body: Data(#"{"error":"proxy down"}"#.utf8)))
}
