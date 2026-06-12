import Foundation
import Testing
@testable import FleetKit

struct FleetKitLogTests {
    @Test func `vin helper redacts to last six characters`() {
        #expect(FleetKitLog.vin("5YJ3E1EA7KF000316") == "…000316")
        #expect(FleetKitLog.vin("ABC123") == "ABC123")
        #expect(FleetKitLog.vin("") == "")
    }

    @Test func `milliseconds since a past instant is non-negative`() {
        let start = ContinuousClock.now
        #expect(FleetKitLog.milliseconds(since: start) >= 0)
    }

    @Test func `intent log failure returns the original error`() {
        let log = FleetIntentLog(LockVehicleIntent.self, vehicle: VehicleEntity(id: "5YJ3E1EA7KF000316", name: "Test Car"))
        let original = FleetKitError.sessionExpired
        let returned = log.failure(original)
        #expect((returned as? FleetKitError)?.localizedDescription == original.localizedDescription)
    }

    @Test func `intent log success does not crash without vehicle`() {
        let log = FleetIntentLog(GetBatteryLevelIntent.self)
        log.success("test detail")
    }
}
