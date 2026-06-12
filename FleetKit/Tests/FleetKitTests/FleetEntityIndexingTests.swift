import CoreSpotlight
import Foundation
import Testing
@testable import FleetKit

struct FleetEntityIndexingTests {
    @Test func `vehicle entity indexes car control and status keywords`() {
        let entity = VehicleEntity(id: "VIN-1", name: "Roadrunner")
        let attributes = entity.attributeSet

        #expect(entity.id == "VIN-1")
        #expect(entity.name == "Roadrunner")
        #expect(attributes.contentDescription?.contains("status") == true)
        #expect(attributes.contentDescription?.contains("honk") == true)
        #expect(attributes.keywords?.contains("tire pressure") == true)
        #expect(attributes.keywords?.contains("release notes") == true)
        #expect(attributes.keywords?.contains("unlock") == true)
    }

    @Test func `vehicle status entity formats mileage tires location and searchable metadata`() throws {
        let snapshot = try FleetKitFixtures.decode(FleetSnapshotInfo.self, from: FleetKitFixtures.snapshotJSON)
        let entity = VehicleStatusEntity(snapshot: snapshot, vehicleName: "Roadrunner")
        let attributes = entity.attributeSet

        #expect(entity.id == "VIN-1")
        #expect(entity.batteryPercent == 82)
        #expect(entity.chargeLimitPercent == 90)
        #expect(entity.odometerDisplay == "12346 mi")
        #expect(entity.statusSummary.contains("Battery 82%"))
        #expect(entity.statusSummary.contains("Odometer 12346 mi"))
        #expect(entity.statusSummary.contains("Tires FL 39 PSI"))
        #expect(attributes.contentDescription?.contains("Charge limit 90%") == true)
        #expect(attributes.contentDescription?.contains("Speed 41 mph") == true)
        #expect(attributes.keywords?.contains("mileage") == true)
        #expect(attributes.keywords?.contains("PSI") == true)
        #expect(attributes.latitude == NSNumber(value: 37.3317))
        #expect(attributes.longitude == NSNumber(value: -122.0301))
        #expect(attributes.supportsNavigation == NSNumber(value: true))
    }

    @Test func `drive entity indexes distance duration locations and average speed`() throws {
        let drive = try FleetKitFixtures.decode(FleetDriveInfo.self, from: FleetKitFixtures.driveJSON)
        let entity = DriveEntity(info: drive)
        let attributes = entity.attributeSet

        #expect(entity.id == "drive-1")
        #expect(entity.durationMinutes == 31)
        #expect(entity.distanceText == "12.3 mi")
        #expect(entity.routeText == "1 Infinite Loop to 3500 Deer Creek Road")
        #expect(entity.detailText.contains("31 min"))
        #expect(entity.detailText.contains("avg 24 mph"))
        #expect(entity.detailText.contains("max 55 mph"))
        #expect(entity.detailText.contains("3.4 kWh"))
        #expect(attributes.contentDescription?.contains("Tesla drive for VIN VIN-1") == true)
        #expect(attributes.keywords?.contains("average speed") == true)
        #expect(attributes.keywords?.contains("1 Infinite Loop") == true)
        #expect(attributes.contentCreationDate == Date(timeIntervalSince1970: 1_710_000_000))
    }

    @Test func `software update entity indexes current available and release versions`() throws {
        let software = try FleetKitFixtures.decode(FleetSoftwareInfo.self, from: FleetKitFixtures.softwareJSON)
        let entity = SoftwareUpdateEntity(info: software, vin: "VIN-1", vehicleName: "Roadrunner")
        let attributes = entity.attributeSet

        #expect(entity.id == "VIN-1")
        #expect(entity.headline == "Update available: 2026.8.4")
        #expect(entity.detailText == "Downloading • 100%")
        #expect(attributes.contentDescription?.contains("Current version 2026.2.1") == true)
        #expect(attributes.contentDescription?.contains("Available version 2026.8.4") == true)
        #expect(attributes.contentDescription?.contains("Installable now") == true)
        #expect(attributes.keywords?.contains("release version") == true)
        #expect(attributes.keywords?.contains("2026.8.4") == true)
    }

    @Test func `release note entity indexes version title and details`() throws {
        let software = try FleetKitFixtures.decode(FleetSoftwareInfo.self, from: FleetKitFixtures.softwareJSON)
        let note = try #require(software.releaseNotes.first)
        let entity = ReleaseNoteEntity(info: note, vin: "VIN-1", version: software.availableVersion)
        let attributes = entity.attributeSet

        #expect(entity.id == "VIN-1:2026.8.4:Better routingNavigation")
        #expect(entity.title == "Better routing")
        #expect(entity.details == "Route planning improvements")
        #expect(attributes.contentDescription?.contains("Version 2026.8.4") == true)
        #expect(attributes.contentDescription?.contains("Better routing") == true)
        #expect(attributes.keywords?.contains("release note") == true)
        #expect(attributes.keywords?.contains("Route planning improvements") == true)
    }
}
