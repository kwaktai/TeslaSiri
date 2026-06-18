import Foundation
import Testing
@testable import FleetKit

// Serialized: every test routes through the shared MockURLProtocol responder,
// so parallel execution would cross-wire fixtures between tests.
@Suite(.serialized)
struct FleetIntentClientTests {
    @Test func `vehicles request uses Tessie bearer token and active query`() async throws {
        let client = makeMockClient { request in
            #expect(request.url?.path == "/vehicles")
            #expect(request.url?.query?.contains("only_active=true") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            return (200, Data(FleetKitFixtures.tessieVehiclesJSON.utf8))
        }

        let vehicles = try await client.vehicles()

        #expect(vehicles.map(\.vin) == ["VIN-1", "VIN-2"])
        #expect(vehicles[1].name == "Blue Y")
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test func `snapshot maps Tessie state and optional tire pressure`() async throws {
        let client = makeMockClient { request in
            switch request.url?.path(percentEncoded: true) {
            case "/VIN%2FABC%20123/state":
                return (200, Data(FleetKitFixtures.tessieStateJSON.utf8))
            case "/VIN%2FABC%20123/tire_pressure":
                #expect(request.url?.query?.contains("pressure_format=psi") == true)
                return (200, Data(FleetKitFixtures.tessieTiresJSON.utf8))
            default:
                Issue.record("Unexpected path: \(request.url?.absoluteString ?? "nil")")
                return (404, Data())
            }
        }

        let snapshot = try await client.snapshot(vin: "VIN/ABC 123")

        #expect(MockURLProtocol.requests.map { $0.url?.path(percentEncoded: true) } == [
            "/VIN%2FABC%20123/state",
            "/VIN%2FABC%20123/tire_pressure"
        ])
        #expect(snapshot.vin == "VIN/ABC 123")
        #expect(snapshot.batteryLevel == 82.4)
        #expect(abs((snapshot.insideTemp ?? 0) - 68.9) < 0.001)
        #expect(snapshot.outsideTemp == 50)
        #expect(snapshot.petModeOn == true)
        #expect(abs((snapshot.tires?.frontLeftPSI ?? 0) - 39.4) < 0.001)
    }

    @Test func `control request maps action and parameters to Tessie command`() async throws {
        let client = makeMockClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/VIN-1/command/set_charge_limit")
            #expect(request.url?.query?.contains("percent=80") == true)
            #expect(request.httpBody == nil)
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
            #expect(request.url?.path == "/VIN-1/command/honk")
            #expect(request.url?.query == nil)
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
            #expect(request.url?.path == "/VIN-1/state")
            return (200, Data(FleetKitFixtures.tessieStateJSON.utf8))
        }

        let software = try await client.software(vin: "VIN-1")

        #expect(software.currentVersion == "2026.2.1")
        #expect(software.availableVersion == "2026.8.4")
        #expect(software.updateAvailable)
        #expect(software.expectedDurationMinutes == 25)
    }
}
