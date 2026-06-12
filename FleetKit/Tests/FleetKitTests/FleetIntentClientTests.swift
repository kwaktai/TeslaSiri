import Foundation
import Testing
@testable import FleetKit

struct FleetIntentClientTests {
    @Test func `vehicles request uses bearer token and include live query`() async throws {
        let client = makeMockClient { request in
            #expect(request.url?.path == "/api/v1/vehicles")
            #expect(request.url?.query?.contains("include_live=true") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            return (200, FleetKitFixtures.envelope(FleetKitFixtures.vehiclesJSON))
        }

        let vehicles = try await client.vehicles()

        #expect(vehicles.map(\.vin) == ["VIN-1", "VIN-2"])
        #expect(vehicles[1].name == "Blue Y")
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test func `snapshot request preserves encoded VIN path separators`() async throws {
        let client = makeMockClient { request in
            #expect(request.url?.percentEncodedPath == "/api/v1/vehicles/VIN%2FABC%20123/live")
            return (200, FleetKitFixtures.envelope(FleetKitFixtures.snapshotJSON))
        }

        let snapshot = try await client.snapshot(vin: "VIN/ABC 123")

        #expect(snapshot.vin == "VIN-1")
        #expect(snapshot.batteryLevel == 82.4)
    }

    @Test func `control request posts action and parameters as JSON`() async throws {
        let client = makeMockClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/v1/vehicles/VIN-1/controls")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

            let body = try requestBodyData(request)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["action"] as? String == "set_charge_limit")
            #expect((json?["params"] as? [String: Any])?["percent"] as? Int == 80)
            return (200, FleetKitFixtures.statusEnvelope())
        }

        try await client.runControl(
            action: "set_charge_limit",
            vin: "VIN-1",
            params: ["percent": .int(80)]
        )
    }

    @Test func `empty control parameters are omitted from request body`() async throws {
        let client = makeMockClient { request in
            let body = try requestBodyData(request)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["action"] as? String == "honk_horn")
            #expect(json?["params"] == nil)
            return (200, FleetKitFixtures.statusEnvelope())
        }

        try await client.runControl(action: "honk_horn", vin: "VIN-1", params: [:])
    }

    @Test func `401 responses surface session expired`() async throws {
        let client = makeMockClient { _ in
            (401, FleetKitFixtures.statusEnvelope(ok: false, error: "expired"))
        }

        let error = await #expect(throws: FleetKitError.self) {
            try await client.user()
        }
        #expect(error?.localizedDescription == FleetKitError.sessionExpired.localizedDescription)
    }

    @Test func `backend envelope errors surface API message`() async throws {
        let client = makeMockClient { _ in
            (200, FleetKitFixtures.statusEnvelope(ok: false, error: "not ready"))
        }

        let error = await #expect(throws: FleetKitError.self) {
            try await client.cancelSoftwareUpdate(vin: "VIN-1")
        }
        #expect(error?.localizedDescription == "not ready")
    }
}
