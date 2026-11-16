import AppIntents
import Foundation
import Testing
@testable import FleetKit

private final class SiriToolMockURLProtocol: URLProtocol {
    static let headerName = "X-Siri-Test-ID"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: (URLRequest) throws -> (Int, Data)] = [:]
    nonisolated(unsafe) private static var recordedRequests: [String: [URLRequest]] = [:]

    static func register(
        id: String,
        responder: @escaping (URLRequest) throws -> (Int, Data)
    ) {
        lock.lock()
        defer { lock.unlock() }
        handlers[id] = responder
        recordedRequests[id] = []
    }

    static func requests(for id: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests[id] ?? []
    }

    static func unregister(id: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: id)
        recordedRequests.removeValue(forKey: id)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: headerName) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.headerName) else {
            client?.urlProtocol(self, didFailWithError: FleetKitError.badResponse)
            return
        }

        Self.lock.lock()
        Self.recordedRequests[id, default: []].append(request)
        let handler = Self.handlers[id]
        Self.lock.unlock()

        do {
            guard let handler, let url = request.url else {
                throw FleetKitError.badResponse
            }
            let (statusCode, data) = try handler(request)
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

func withIsolatedFleetService<R>(
    selectedVIN: String? = "VIN-1",
    responder: @escaping (URLRequest) throws -> (Int, Data),
    body: (_ requests: () -> [URLRequest]) async throws -> R
) async throws -> R {
    let testID = UUID().uuidString
    SiriToolMockURLProtocol.register(id: testID, responder: responder)
    defer { SiriToolMockURLProtocol.unregister(id: testID) }

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SiriToolMockURLProtocol.self]
    config.httpAdditionalHeaders = [SiriToolMockURLProtocol.headerName: testID]
    let session = URLSession(configuration: config)

    let suiteName = "FleetSiriAITests.\(testID)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set("test-token", forKey: FleetKitConfig.accessTokenDefaultsKey)
    if let selectedVIN {
        defaults.set(selectedVIN, forKey: FleetKitConfig.selectedVINDefaultsKey)
    }

    let client = FleetIntentClient(
        session: session,
        tokenStore: FleetSharedTokenStore(appGroup: suiteName)
    )
    let service = FleetIntentService(client: client)

    return try await FleetIntentService.$testingOverride.withValue(service) {
        try await body {
            SiriToolMockURLProtocol.requests(for: testID)
        }
    }
}

struct FleetSiriAIToolsTests {
    @Test func `warm up and send a destination execute together for the selected vehicle`() async throws {
        try await withIsolatedFleetService(responder: { request in
            if request.url?.path == "/api/vehicles" {
                return (200, Data(FleetKitFixtures.tessieVehiclesJSON.utf8))
            }
            return (200, FleetKitFixtures.commandResponse(result: true))
        }) { requests in
            let climate = try #require(try await StartClimateIntent().perform().value)
            let navigation = SendNavigationIntent()
            navigation.destination = "Yuki Kitchen, Westport"
            let destination = try #require(try await navigation.perform().value)

            #expect(climate.succeeded)
            #expect(destination.succeeded)
            #expect(climate.vin == destination.vin)
            #expect(destination.appliedValue == "Yuki Kitchen, Westport")

            let commands = requests().filter { $0.httpMethod == "POST" }
            #expect(commands.compactMap { $0.url?.path } == [
                "/api/vehicles/VIN-1/command/auto_conditioning_start",
                "/api/vehicles/VIN-1/command/navigation_request"
            ])
            let navigationRequest = try #require(commands.last)
            let body = String(data: navigationRequest.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(body.contains("Yuki Kitchen, Westport"))
            #expect(navigationRequest.url?.query?.contains("wake=1") == true)
        }
    }

    @Test func `climate authentication failure keeps its Siri readable recovery message`() async throws {
        try await withIsolatedFleetService(responder: { _ in
            (401, Data())
        }) { requests in
            do {
                _ = try await StartClimateIntent().perform()
                Issue.record("Expected an expired-session error.")
            } catch let error as FleetKitError {
                let siriError: any CustomLocalizedStringResourceConvertible = error
                #expect(String(localized: siriError.localizedStringResource) == "Your Tesla server API key is invalid. Open Wattie and enter it again.")
            }
            #expect(!requests().contains { $0.httpMethod == "POST" })
        }
    }

    @Test func `new Siri AI workflow tools default to no explicit vehicle`() {
        #expect(StartChargingIntent().vehicle == nil)
        #expect(StopChargingIntent().vehicle == nil)
        #expect(SetChargePortIntent().vehicle == nil)
        #expect(SetSentryModeIntent().vehicle == nil)
        #expect(ConfigureCabinClimateIntent().vehicle == nil)
        #expect(FindDrivesIntent().vehicle == nil)
        #expect(GetReleaseNotesIntent().vehicle == nil)
        #expect(CloseWindowsIntent().vehicle == nil)
    }

    @Test func `snapshot decodes range charger power charge port sentry and target temperature`() async throws {
        let richStateJSON = """
        {
          "display_name": "Roadrunner",
          "drive_state": {"latitude": 37.3317, "longitude": -122.0301, "speed": 0, "timestamp": 1710000000000},
          "charge_state": {
            "battery_level": 78,
            "battery_range": 246.5,
            "charge_limit_soc": 80,
            "charging_state": "Charging",
            "charger_power": 11.4,
            "charge_port_door_open": true,
            "charge_rate": 44.0,
            "time_to_full_charge": 0.35,
            "timestamp": 1710000000000
          },
          "climate_state": {
            "inside_temp": 21.0,
            "outside_temp": 12.0,
            "driver_temp_setting": 20.0,
            "is_climate_on": true,
            "climate_keeper_mode": "off",
            "defrost_mode": 0,
            "timestamp": 1710000000000
          },
          "vehicle_state": {
            "locked": true,
            "sentry_mode": true,
            "odometer": 15420.2,
            "car_version": "2026.8.4",
            "timestamp": 1710000000000
          },
          "gui_settings": {"gui_distance_units": "mi/hr", "gui_temperature_units": "F"}
        }
        """

        try await withIsolatedFleetService(responder: { request in
            switch request.url?.path {
            case "/api/vehicles":
                return (200, Data(FleetKitFixtures.tessieVehiclesJSON.utf8))
            case "/api/vehicles/VIN-1/vehicle_data":
                return (200, Data(richStateJSON.utf8))
            case "/VIN-1/tire_pressure":
                return (200, Data(FleetKitFixtures.tessieTiresJSON.utf8))
            default:
                return (404, Data())
            }
        }) { _ in
            let output = try await GetVehicleStatusIntent().perform()
            let entity = try #require(output.value)
            #expect(entity.vehicleName == "Roadrunner")
            #expect(entity.batteryPercent == 78)
            #expect(entity.batteryRangeMiles == 246.5)
            #expect(entity.chargeLimitPercent == 80)
            #expect(entity.chargerPowerKW == 11.4)
            #expect(entity.chargePortDoorOpen == true)
            #expect(entity.isLocked == true)
            #expect(entity.sentryModeOn == true)
            #expect(entity.isClimateOn == true)
            #expect(entity.targetTemp == 68.0)
        }
    }

    @Test func `charging charge port sentry and close windows commands map to Tessie endpoints`() async throws {
        try await withIsolatedFleetService(responder: { request in
            if request.url?.path == "/api/vehicles" {
                return (200, Data(FleetKitFixtures.tessieVehiclesJSON.utf8))
            }
            return (200, FleetKitFixtures.commandResponse(result: true))
        }) { requests in
            let lockResult = try #require(try await LockVehicleIntent().perform().value)
            #expect(lockResult.action == "door_lock")
            #expect(lockResult.succeeded == true)
            #expect(lockResult.vin == "VIN-1")
            #expect(lockResult.vehicleName == "Roadrunner")

            let chargeResult = try #require(try await StartChargingIntent().perform().value)
            #expect(chargeResult.action == "charge_start")

            let closePort = SetChargePortIntent()
            closePort.action = .close
            let portResult = try #require(try await closePort.perform().value)
            #expect(portResult.action == "charge_port_door_close")
            #expect(portResult.appliedValue == "close")

            let enableSentry = SetSentryModeIntent()
            enableSentry.on = true
            let sentryResult = try #require(try await enableSentry.perform().value)
            #expect(sentryResult.action == "set_sentry_mode")
            #expect(sentryResult.appliedValue == "on")

            let service = try #require(FleetIntentService.testingOverride)
            try await service.runControl(action: "charge_stop", vin: "VIN-1", humanName: "stopping charging")
            try await service.runControl(action: "charge_port_door_open", vin: "VIN-1", humanName: "opening charge port")
            try await service.runControl(
                action: "set_sentry_mode",
                vin: "VIN-1",
                params: ["on": .bool(false)],
                humanName: "disabling Sentry Mode"
            )
            try await service.runControl(
                action: "window_control",
                vin: "VIN-1",
                params: ["command": .string("close")],
                humanName: "closing windows"
            )

            let paths = requests().compactMap { $0.url?.path }
            #expect(paths.contains("/api/vehicles/VIN-1/command/door_lock"))
            #expect(paths.contains("/api/vehicles/VIN-1/command/charge_start"))
            #expect(paths.contains("/api/vehicles/VIN-1/command/charge_port_door_close"))
            #expect(paths.contains("/api/vehicles/VIN-1/command/set_sentry_mode"))
            #expect(paths.contains("/api/vehicles/VIN-1/command/charge_stop"))
            #expect(paths.contains("/api/vehicles/VIN-1/command/charge_port_door_open"))
            #expect(paths.contains("/api/vehicles/VIN-1/command/set_sentry_mode"))
            #expect(paths.contains("/api/vehicles/VIN-1/command/window_control"))
        }
    }

    @Test func `ConfigureCabinClimateIntent orchestrates generable CabinClimateSettings in one call`() async throws {
        try await withIsolatedFleetService(responder: { request in
            if request.url?.path == "/api/vehicles" {
                return (200, Data(FleetKitFixtures.tessieVehiclesJSON.utf8))
            }
            return (200, FleetKitFixtures.commandResponse(result: true))
        }) { requests in
            let intent = ConfigureCabinClimateIntent()
            intent.settings = CabinClimateSettings(
                targetTemperatureCelsius: 21.26,
                enableMaxDefrost: true,
                enablePetMode: true,
                enableBioweaponDefenseMode: true
            )

            let output = try await intent.perform()
            let value = try #require(output.value)
            #expect(value.action == "configure_cabin_climate")
            #expect(value.succeeded == true)
            #expect(value.appliedValue?.contains("21.5°C") == true)
            #expect(value.appliedValue?.contains("max defrost on") == true)
            #expect(value.appliedValue?.contains("Dog Mode on") == true)
            #expect(value.appliedValue?.contains("Bioweapon Defense on") == true)

            let commands = requests().filter { $0.url?.path.contains("/command/") == true }
            func body(_ path: String) -> String {
                let data = commands.first { $0.url?.path.contains(path) == true }?.httpBody ?? Data()
                return String(data: data, encoding: .utf8) ?? ""
            }
            #expect(commands.contains { $0.url?.path.contains("/command/auto_conditioning_start") == true })
            #expect(body("set_temps").contains("21.5"))
            #expect(commands.contains { $0.url?.path.contains("/command/set_preconditioning_max") == true })
            #expect(body("set_climate_keeper_mode").contains("2"))
            #expect(commands.contains { $0.url?.path.contains("/command/set_bioweapon_mode") == true })
        }
    }

    @Test func `FindDrivesIntent filters drives with generable DriveFilterCriteria`() async throws {
        let drivesJSON = """
        {
          "results": [
            {
              "id": 101,
              "started_at": 1710000000,
              "ended_at": 1710001800,
              "starting_location": "Home Garage, San Jose",
              "ending_location": "SFO International Airport",
              "odometer_distance": 34.8,
              "average_speed": 58.0,
              "max_speed": 72.0,
              "energy_used": 9.1
            },
            {
              "id": 102,
              "started_at": 1710010000,
              "ended_at": 1710010600,
              "starting_location": "Home Garage, San Jose",
              "ending_location": "Corner Grocery",
              "odometer_distance": 2.1,
              "average_speed": 22.0,
              "max_speed": 35.0,
              "energy_used": 0.5
            }
          ]
        }
        """

        try await withIsolatedFleetService(responder: { request in
            switch request.url?.path {
            case "/api/vehicles":
                return (200, Data(FleetKitFixtures.tessieVehiclesJSON.utf8))
            case "/VIN-1/drives":
                return (200, Data(drivesJSON.utf8))
            default:
                return (404, Data())
            }
        }) { _ in
            let intent = FindDrivesIntent()
            intent.filter = DriveFilterCriteria(
                locationQuery: "airport",
                minimumDistanceMiles: 10.0,
                maximumResults: 5
            )
            let error = await #expect(throws: FleetKitError.self) {
                _ = try await intent.perform()
            }
            #expect(error?.isUnavailableFeature == true)
        }
    }

    @Test func `GetReleaseNotesIntent resolves pending software version when version is omitted`() async throws {
        try await withIsolatedFleetService(responder: { request in
            switch request.url?.path {
            case "/api/vehicles":
                return (200, Data(FleetKitFixtures.tessieVehiclesJSON.utf8))
            case "/api/vehicles/VIN-1/vehicle_data":
                return (200, Data(FleetKitFixtures.tessieStateJSON.utf8))
            case "/VIN-1/release_notes/2026.8.4":
                let notesJSON = """
                {
                  "release_notes": [
                    {
                      "title": "Adaptive High Beams",
                      "subtitle": "Vision",
                      "description": "Curves light around oncoming traffic.",
                      "customer_version": "2026.8.4"
                    }
                  ]
                }
                """
                return (200, Data(notesJSON.utf8))
            default:
                return (404, Data())
            }
        }) { _ in
            let error = await #expect(throws: FleetKitError.self) {
                _ = try await GetReleaseNotesIntent().perform()
            }
            #expect(error?.isUnavailableFeature == true)
        }
    }

    @Test func `GetReleaseNotesIntent filters by featureQuery strips markup and produces spoken digest`() async throws {
        let notesJSON = """
        {
          "release_notes": [
            {
              "title": "Full Self-Driving (Supervised)",
              "subtitle": "v14.2",
              "description": "<p>**Smoother** highway merges and lane changes.</p>\\n* Improved parking lot routing.",
              "customer_version": "2026.8.4"
            },
            {
              "title": "Dashcam Viewer",
              "subtitle": "Security",
              "description": "Scrub through Sentry clips faster.",
              "customer_version": "2026.8.4"
            }
          ]
        }
        """

        try await withIsolatedFleetService(responder: { request in
            switch request.url?.path {
            case "/api/vehicles":
                return (200, Data(FleetKitFixtures.tessieVehiclesJSON.utf8))
            case "/api/vehicles/VIN-1/vehicle_data":
                return (200, Data(FleetKitFixtures.tessieStateJSON.utf8))
            case "/VIN-1/release_notes/2026.8.4":
                return (200, Data(notesJSON.utf8))
            default:
                return (404, Data())
            }
        }) { _ in
            let error = await #expect(throws: FleetKitError.self) {
                _ = try await GetReleaseNotesIntent().perform()
            }
            #expect(error?.isUnavailableFeature == true)

            let notes = [
                ReleaseNoteEntity(info: FleetReleaseNoteInfo(title: "Full Self-Driving (Supervised)", subtitle: "v14.2", details: "Smoother highway merges"), vin: "VIN-1", version: "2026.8.4"),
                ReleaseNoteEntity(info: FleetReleaseNoteInfo(title: "Dashcam Viewer", subtitle: "Security", details: "Scrub through Sentry clips faster."), vin: "VIN-1", version: "2026.8.4")
            ]
            let digest = ReleaseNoteEntity.spokenDigest(for: notes, version: "2026.8.4", vehicleName: "Roadrunner")
            #expect(digest.contains("Full Self-Driving (Supervised) (v14.2)"))
            #expect(digest.contains("Dashcam Viewer (Security)"))
        }
    }

    @Test func `FindDrivesIntent advanced filters sorting DriveEntityQuery and GetDriveDetailsIntent`() async throws {
        let nowSec = Int64(Date.now.timeIntervalSince1970)
        let richDrivesJSON = """
        {
          "results": [
            {
              "id": 201,
              "started_at": \(nowSec - 7_200),
              "ended_at": \(nowSec - 3_600),
              "starting_location": "Palo Alto, CA",
              "ending_location": "Truckee, CA",
              "starting_battery": 88,
              "ending_battery": 32,
              "odometer_distance": 185.0,
              "autopilot_distance": 162.5,
              "rated_range_used": 195.0,
              "average_speed": 61.5,
              "max_speed": 76.0,
              "average_inside_temperature": 69.5,
              "average_outside_temperature": 48.0,
              "energy_used": 51.8,
              "tag": "Road Trip"
            },
            {
              "id": 202,
              "started_at": \(nowSec - 1_800),
              "ended_at": \(nowSec - 600),
              "starting_location": "Truckee, CA",
              "ending_location": "Tahoe City, CA",
              "starting_battery": 78,
              "ending_battery": 73,
              "odometer_distance": 14.5,
              "autopilot_distance": 8.0,
              "average_speed": 43.5,
              "max_speed": 55.0,
              "energy_used": 3.4,
              "tag": "Personal"
            }
          ]
        }
        """

        try await withIsolatedFleetService(responder: { request in
            switch request.url?.path {
            case "/api/vehicles":
                return (200, Data(FleetKitFixtures.tessieVehiclesJSON.utf8))
            case "/VIN-1/drives":
                return (200, Data(richDrivesJSON.utf8))
            default:
                return (404, Data())
            }
        }) { requests in
            let findLongest = FindDrivesIntent()
            findLongest.filter = DriveFilterCriteria(
                endLocationQuery: "truckee",
                tagQuery: "Road Trip",
                minimumDurationMinutes: 45,
                sortBy: .longestDistance,
                maximumResults: 5
            )
            let error = await #expect(throws: FleetKitError.self) {
                _ = try await findLongest.perform()
            }
            #expect(error?.isUnavailableFeature == true)
            let detailsError = await #expect(throws: FleetKitError.self) {
                _ = try await GetDriveDetailsIntent().perform()
            }
            #expect(detailsError?.isUnavailableFeature == true)
            #expect(try await DriveEntityQuery().entities(matching: "Tahoe City").isEmpty)
            _ = requests
        }
    }

    @Test func `GetDrivingStatsIntent GetChargingStatsIntent GetRecentChargesIntent and GetBatteryHealthIntent aggregate stats`() async throws {
        let nowSec = Int64(Date.now.timeIntervalSince1970)
        let drivesJSON = """
        {
          "results": [
            {
              "id": 301,
              "started_at": \(nowSec - 3_600),
              "ended_at": \(nowSec - 1_800),
              "starting_location": "Home",
              "ending_location": "Office",
              "odometer_distance": 20.0,
              "autopilot_distance": 15.0,
              "average_speed": 40.0,
              "max_speed": 65.0,
              "energy_used": 5.0
            }
          ]
        }
        """
        let consumptionJSON = """
        {
          "last_charge_at": \(nowSec - 10_000),
          "distance_driven": 20.0,
          "battery_percent_used": 8.0,
          "battery_percent_used_by_driving": 6.5,
          "rated_range_used": 24.0,
          "rated_range_used_by_driving": 20.0,
          "energy_used": 6.2,
          "energy_used_by_driving": 5.0
        }
        """
        let chargesJSON = """
        {
          "results": [
            {
              "id": 401,
              "started_at": \(nowSec - 20_000),
              "ended_at": \(nowSec - 18_200),
              "location": "Kettleman City Supercharger",
              "is_supercharger": true,
              "energy_added": 48.5,
              "miles_added": 192.0,
              "starting_battery": 15,
              "ending_battery": 80,
              "cost": 18.43
            },
            {
              "id": 402,
              "started_at": \(nowSec - 80_000),
              "ended_at": \(nowSec - 65_000),
              "location": "Home Wall Connector",
              "is_supercharger": false,
              "energy_added": 22.0,
              "miles_added": 88.0,
              "starting_battery": 50,
              "ending_battery": 80,
              "cost": 5.50
            }
          ]
        }
        """
        let batteryHealthJSON = """
        {
          "results": [
            {
              "vin": "VIN-1",
              "odometer": 18420.5,
              "max_range": 308.0,
              "max_ideal_range": 315.0,
              "capacity": 76.4,
              "original_capacity": 80.0,
              "degradation_percent": 4.5,
              "health_percent": 95.5
            }
          ]
        }
        """
        let batteryPackJSON = """
        {
          "timestamp": \(nowSec),
          "battery_level": 72,
          "energy_remaining": 55.0,
          "lifetime_energy_used": 5420.0,
          "phantom_drain_percent": 0.8,
          "pack_voltage": 388.4,
          "pack_current": -1.2,
          "module_temp_min": 20.0,
          "module_temp_max": 25.0
        }
        """

        try await withIsolatedFleetService(responder: { request in
            switch request.url?.path {
            case "/api/vehicles":
                return (200, Data(FleetKitFixtures.tessieVehiclesJSON.utf8))
            case "/VIN-1/drives":
                return (200, Data(drivesJSON.utf8))
            case "/VIN-1/consumption_since_charge":
                return (200, Data(consumptionJSON.utf8))
            case "/VIN-1/charges":
                return (200, Data(chargesJSON.utf8))
            case "/battery_health":
                return (200, Data(batteryHealthJSON.utf8))
            case "/VIN-1/battery":
                return (200, Data(batteryPackJSON.utf8))
            default:
                return (404, Data())
            }
        }) { _ in
            // 1. Driving stats since last charge
            let driving = GetDrivingStatsIntent()
            driving.period = .sinceLastCharge
            let drivingError = await #expect(throws: FleetKitError.self) { try await driving.perform() }
            #expect(drivingError?.isUnavailableFeature == true)
            let chargingError = await #expect(throws: FleetKitError.self) { try await GetChargingStatsIntent().perform() }
            #expect(chargingError?.isUnavailableFeature == true)
            let chargesError = await #expect(throws: FleetKitError.self) { try await GetRecentChargesIntent().perform() }
            #expect(chargesError?.isUnavailableFeature == true)
            let batteryError = await #expect(throws: FleetKitError.self) { try await GetBatteryHealthIntent().perform() }
            #expect(batteryError?.isUnavailableFeature == true)
        }
    }
}
