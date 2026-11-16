import Foundation
import Testing
@testable import FleetKit

// Serialized: every test routes through the shared MockURLProtocol responder,
// so parallel execution would cross-wire fixtures between tests.
@Suite(.serialized)
struct FleetIntentClientTests {
    @Test func `vehicles request uses the Tesla server API key`() async throws {
        let client = makeMockClient { request in
            #expect(request.url?.path == "/api/vehicles")
            #expect(request.url?.query == nil)
            #expect(request.value(forHTTPHeaderField: "X-API-Key") == "test-token")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, Data(FleetKitFixtures.tessieVehiclesJSON.utf8))
        }

        let vehicles = try await client.vehicles()

        #expect(vehicles.map(\.vin) == ["VIN-1", "VIN-2"])
        #expect(vehicles[1].name == "Blue Y")
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test func `snapshot reads vehicle data without waking and without a tire endpoint`() async throws {
        let listed = Data(#"{"response":[{"id":"VIN/ABC 123","vin":"VIN/ABC 123","display_name":"Roadrunner","state":"online"}]}"#.utf8)
        let client = makeMockClient { request in
            switch request.url?.path(percentEncoded: true) {
            case "/api/vehicles":
                return (200, listed)
            case "/api/vehicles/VIN%2FABC%20123/vehicle_data":
                #expect(request.httpMethod == "GET")
                #expect(request.url?.query?.contains("wake") != true)
                return (200, Data(FleetKitFixtures.tessieStateJSON.utf8))
            default:
                Issue.record("Unexpected path: \(request.url?.absoluteString ?? "nil")")
                return (404, Data())
            }
        }

        let snapshot = try await client.snapshot(vin: "VIN/ABC 123")

        #expect(MockURLProtocol.requests.compactMap { $0.url?.path(percentEncoded: true) } == [
            "/api/vehicles",
            "/api/vehicles/VIN%2FABC%20123/vehicle_data"
        ])
        #expect(snapshot.vin == "VIN/ABC 123")
        #expect(snapshot.batteryLevel == 82.4)
        #expect(abs((snapshot.insideTemp ?? 0) - 68.9) < 0.001)
        #expect(snapshot.outsideTemp == 50)
        #expect(snapshot.petModeOn == true)
        #expect(snapshot.tires == nil)
    }

    @Test func rosterDecodesVehicleIdentityAndAccountUnitsFromVehicleData() async throws {
        let list = """
            {"response":[
              {"id":1,"vin":"A","display_name":42,"state":"online"},
              {"vin":"B","display_name":"Fallback","state":"asleep"},
              {"vin":"C","state":"offline"}
            ]}
            """
        let state = #"{"gui_settings":{"gui_temperature_units":"F","gui_distance_units":"km"}}"#
        let client = makeMockClient { request in
            request.url?.path == "/api/vehicles" ? (200, Data(list.utf8)) : (200, Data(state.utf8))
        }
        let vehicles = try await client.vehicles()
        #expect(vehicles.map(\.vin) == ["A", "B", "C"])
        #expect(vehicles.map(\.displayName) == ["42", "Fallback", nil])
        #expect(try await client.user().units == "imperial")
        #expect(MockURLProtocol.requests.map { $0.url?.path } == ["/api/vehicles", "/api/vehicles", "/api/vehicles/A/vehicle_data"])
    }

    @Test func drivePathIsUnavailableWithoutARequest() async throws {
        let client = makeMockClient { _ in
            Issue.record("Drive routes must not call the server")
            return (500, Data())
        }
        let start = Date(timeIntervalSince1970: 1710000000)
        let end = start.addingTimeInterval(3)
        await #expect(throws: FleetKitError.self) {
            _ = try await client.drivePath(vin: "A", from: start, to: end, maxPoints: 1)
        }
        #expect(MockURLProtocol.requests.isEmpty)
    }

    @Test func snapshotPreservesRequiredStateErrorWhenBothReadsFail() async {
        let client = makeMockClient { request in
            if request.url?.path == "/api/vehicles" {
                return (200, Data(#"{"response":[{"vin":"A","state":"online"}]}"#.utf8))
            }
            return (503, Data(#"{"error":"state unavailable"}"#.utf8))
        }
        let error = await #expect(throws: FleetKitError.self) {
            try await client.snapshot(vin: "A")
        }
        #expect(error?.localizedDescription == "state unavailable")
    }

    @Test func routeImageIdentityIncludesGeometryAndVisibleAutopilotSegments() {
        let a = FleetDriveRoutePoint(latitude: 1, longitude: 2)
        func key(_ b: FleetDriveRoutePoint, width: Double = 380) -> SiriMapImageKey {
            .route(driveID: "A:1", style: .standard, size: CGSize(width: width, height: 172),
                   points: [a, b].map(SiriMapImageKey.Point.init))
        }
        let original = key(a)
        #expect(key(FleetDriveRoutePoint(latitude: 1, longitude: 3)) != original)
        #expect(key(FleetDriveRoutePoint(latitude: 1, longitude: 2, autopilotState: "FSD")) != original)
        #expect(key(a, width: 380.5) != original)
        #expect(key(FleetDriveRoutePoint(latitude: 1, longitude: 2, speedMPH: 50)) == original)
    }

    @Test func spotlightStatusAndSoftwareUseOneStateResponse() async throws {
        let client = makeMockClient { request in
            if request.url?.path == "/api/vehicles" {
                return (200, Data(#"{"response":[{"vin":"VIN-1","display_name":"Roadrunner","state":"online"}]}"#.utf8))
            }
            return (200, Data(FleetKitFixtures.tessieStateJSON.utf8))
        }
        let result = try await FleetIntentService(client: client).snapshotAndSoftware(vin: "VIN-1")
        #expect(result.snapshot.batteryLevel == 82.4)
        #expect(result.software.availableVersion == "2026.8.4")
        #expect(MockURLProtocol.requests.compactMap { $0.url?.path } == ["/api/vehicles", "/api/vehicles/VIN-1/vehicle_data"])
    }

    @Test func batteryHealthIsUnavailableWithoutARequest() async throws {
        try await withIsolatedFleetService { request in
            Issue.record("Battery health must not call the server")
            return (500, Data())
        } body: { requests in
            let error = await #expect(throws: FleetKitError.self) {
                try await FleetIntentService.make().batteryHealth(vin: "VIN-1")
            }
            #expect(error?.isUnavailableFeature == true)
            #expect(requests().isEmpty)
        }
    }

    @Test func `control request maps action and parameters to Tessie command`() async throws {
        let client = makeMockClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/vehicles/VIN-1/command/set_charge_limit")
            #expect(request.url?.query?.contains("wake=1") == true)
            #expect(request.value(forHTTPHeaderField: "X-API-Key") == "test-token")
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(body.contains("\"percent\":80"))
            return (200, FleetKitFixtures.commandResponse())
        }

        try await client.runControl(
            action: "set_charge_limit",
            vin: "VIN-1",
            params: ["percent": .int(80)]
        )
    }

    @Test func `parameterless controls map to direct Tessie commands`() async throws {
        let client = makeMockClient { request in
            #expect(request.url?.path == "/api/vehicles/VIN-1/command/honk_horn")
            #expect(request.url?.query?.contains("wake=1") == true)
            return (200, FleetKitFixtures.commandResponse())
        }

        try await client.runControl(action: "honk_horn", vin: "VIN-1", params: [:])
    }

    @Test func `401 responses surface session expired`() async throws {
        let client = makeMockClient { _ in
            (401, Data("{\"error\":\"invalid token\"}".utf8))
        }

        let error = await #expect(throws: FleetKitError.self) {
            try await client.user()
        }
        #expect(error?.localizedDescription == FleetKitError.sessionExpired.localizedDescription)
    }

    @Test func `Tessie errors surface API message`() async throws {
        let client = makeMockClient { _ in
            (400, Data("{\"error\":\"not ready\"}".utf8))
        }

        let error = await #expect(throws: FleetKitError.self) {
            try await client.cancelSoftwareUpdate(vin: "VIN-1")
        }
        #expect(error?.localizedDescription == "not ready")
    }

    @Test func `software state maps Tessie version and progress`() async throws {
        let client = makeMockClient { request in
            if request.url?.path == "/api/vehicles" {
                return (200, Data(#"{"response":[{"vin":"VIN-1","state":"online"}]}"#.utf8))
            }
            #expect(request.url?.path == "/api/vehicles/VIN-1/vehicle_data")
            return (200, Data(FleetKitFixtures.tessieStateJSON.utf8))
        }

        let software = try await client.software(vin: "VIN-1")

        #expect(software.currentVersion == "2026.2.1")
        #expect(software.availableVersion == "2026.8.4")
        #expect(software.updateAvailable)
        #expect(software.expectedDurationMinutes == 25)
    }

    @Test func `snapshot falls back to state tire pressures in bar`() async throws {
        let client = makeMockClient { request in
            switch request.url?.path {
            case "/api/vehicles":
                return (200, Data(#"{"response":[{"vin":"VIN-1","state":"online"}]}"#.utf8))
            case "/api/vehicles/VIN-1/vehicle_data":
                return (200, Data("""
                    {"vehicle_state":{"tpms_pressure_fl":"2.7","tpms_pressure_fr":"NaN","tpms_pressure_rr":2.9}}
                    """.utf8))
            default:
                Issue.record("Unexpected request")
                return (404, Data())
            }
        }

        let snapshot = try await client.snapshot(vin: "VIN-1")
        let tires = try #require(snapshot.tires)
        #expect(abs((tires.frontLeftPSI ?? 0) - 39.16) < 0.01)
        #expect(abs((tires.rearRightPSI ?? 0) - 42.06) < 0.01)
        #expect(tires.frontRightPSI == nil)
        #expect(tires.lastMeasuredAt == nil)
    }

    @Test func `snapshot reports an expired session from vehicle data`() async throws {
        let client = makeMockClient { request in
            if request.url?.path == "/api/vehicles" {
                return (200, Data(#"{"response":[{"vin":"VIN-1","state":"online"}]}"#.utf8))
            }
            return (401, Data())
        }

        let error = await #expect(throws: FleetKitError.self) {
            try await client.snapshot(vin: "VIN-1")
        }
        #expect(error?.localizedDescription == FleetKitError.sessionExpired.localizedDescription)
    }

    @Test func `drives requests a miles based limit and returns newest sessions first`() async throws {
        let client = makeMockClient { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/VIN-1/drives")
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
            #expect(query?.contains(URLQueryItem(name: "distance_format", value: "mi")) == true)
            #expect(query?.contains(URLQueryItem(name: "limit", value: "10")) == true)
            return (200, Data("""
                {"results":[
                    {"id":1,"started_at":1710000000,"ended_at":1710000600},
                    {"id":2,"started_at":1710001200,"ended_at":1710001500,"odometer_distance":12.5,
                     "average_speed":30,"max_speed":60,"energy_used":4.2}
                ]}
                """.utf8))
        }

        let error = await #expect(throws: FleetKitError.self) {
            _ = try await client.drives(vin: "VIN-1", limit: 10)
        }
        #expect(error?.isUnavailableFeature == true)
        #expect(MockURLProtocol.requests.isEmpty)
    }

    @Test(.serialized, arguments: ["2026.8.4", ""])
    func `release note suggestions use staged or installed software version`(stagedVersion: String) async throws {
        let expectedVersion = stagedVersion.isEmpty ? "2026.2.1" : stagedVersion
        let client = makeMockClient { request in
            switch request.url?.path {
            case "/api/vehicles":
                return (200, Data(FleetKitFixtures.tessieVehiclesJSON.utf8))
            case "/api/vehicles/VIN-1/vehicle_data":
                return (200, Data("""
                    {"vehicle_state":{"car_version":"2026.2.1 build","software_update":{"version":"\(stagedVersion)"}}}
                    """.utf8))
            case "/VIN-1/release_notes/\(expectedVersion)":
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
                return (200, Data("""
                    {"release_notes":[{"title":"Route updates","subtitle":null,"description":"Better directions",
                                       "customer_version":"\(expectedVersion)"}]}
                    """.utf8))
            default:
                Issue.record("Unexpected request")
                return (404, Data())
            }
        }
        let query = ReleaseNoteEntityQuery(service: FleetIntentService(client: client))

        let notes = try await query.suggestedEntities()
        #expect(notes.isEmpty)
        #expect(MockURLProtocol.requests.allSatisfy { $0.url?.path.contains("release_notes") != true })
        _ = expectedVersion
    }

    @Test func `saved release notes resolve by exact version for authorized vehicles`() async throws {
        let client = makeMockClient { request in
            switch request.url?.path {
            case "/api/vehicles":
                return (200, Data(FleetKitFixtures.tessieVehiclesJSON.utf8))
            case "/VIN-2/release_notes/2025.44":
                return (200, Data("""
                    {"release_notes":[
                        {"title":"Changes: Navigation","customer_version":"2025.44"},
                        {"title":"Changes: Navigation","customer_version":"2025.40"}
                    ]}
                    """.utf8))
            default:
                Issue.record("Unexpected request")
                return (404, Data())
            }
        }
        let query = ReleaseNoteEntityQuery(service: FleetIntentService(client: client))
        let id = "VIN-2:2025.44:2025.40:Changes: Navigation"

        let notes = try await query.entities(for: [id, "UNKNOWN:2025.44:Missing"])
        #expect(notes.isEmpty)
        #expect(MockURLProtocol.requests.map { $0.url?.path } == ["/api/vehicles"])
    }

    @Test(.serialized, arguments: ["", ".", ".."])
    func `release notes rejects empty and dot segment versions`(invalidVersion: String) async {
        let client = makeMockClient { request in
            Issue.record("Unexpected request: \(request.url?.absoluteString ?? "nil")")
            return (500, Data())
        }

        await #expect(throws: FleetKitError.self) {
            _ = try await client.releaseNotes(vin: "VIN-1", version: invalidVersion)
        }
        #expect(MockURLProtocol.requests.isEmpty)
    }
}
