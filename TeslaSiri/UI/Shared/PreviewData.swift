import Foundation

enum PreviewData {
    static let vin1 = "5YJ3E1EA7JF000001"
    static let vin2 = "5YJ3E1EA7JF000002"
    static let vin3 = "5YJ3E1EA7JF000003"

    static let previewRoute: [FleetRoutePoint] = [
        FleetRoutePoint(latitude: 37.3318, longitude: -122.0312, odometer: 19_204.0, speed: 0, timestamp: 1_781_000_000),
        FleetRoutePoint(latitude: 37.3324, longitude: -122.0307, odometer: 19_204.2, speed: 18, timestamp: 1_781_000_180_000),
        FleetRoutePoint(latitude: 37.3333, longitude: -122.0297, odometer: 19_204.5, speed: 32, timestamp: 1_781_000_360_000),
        FleetRoutePoint(latitude: 37.3342, longitude: -122.0282, odometer: 19_204.9, speed: 41, timestamp: 1_781_000_540_000),
        FleetRoutePoint(latitude: 37.3354, longitude: -122.0270, odometer: 19_205.2, speed: 37, timestamp: 1_781_000_720_000),
        FleetRoutePoint(latitude: 37.3361, longitude: -122.0259, odometer: 19_205.5, speed: 24, timestamp: 1_781_000_900_000),
        FleetRoutePoint(latitude: 37.3364, longitude: -122.0251, odometer: 19_205.7, speed: 0, timestamp: 1_781_001_080_000)
    ]

    static let snapshotFull: FleetLatestSnapshot = FleetLatestSnapshot(
        batteryLevel: 74,
        batteryRange: 260,
        chargeLimitSOC: 80,
        chargeRateMPH: 28,
        chargerPowerKW: 7.2,
        chargePortDoorOpen: true,
        chargingState: "Charging",
        climateOn: true,
        closures: FleetVehicleClosureState(
            frontDriverDoorOpen: false,
            frontDriverWindowOpen: false,
            frontPassengerDoorOpen: false,
            frontPassengerWindowOpen: false,
            frontTrunkOpen: false,
            rearDriverDoorOpen: false,
            rearDriverWindowOpen: false,
            rearPassengerDoorOpen: false,
            rearPassengerWindowOpen: false,
            rearTrunkOpen: false
        ),
        freshnessMS: 1_500,
        gear: "P",
        insideTemp: 70,
        latitude: 37.3364,
        locked: true,
        longitude: -122.0251,
        odometer: 19_204,
        outsideTemp: 64,
        sentryMode: true,
        software: nil,
        speed: 0,
        targetTemperature: 72,
        timeToFullCharge: 1.4,
        timestamp: 1_781_000_000_000,
        tires: FleetTirePressures(
            frontLeftPSI: 42.0,
            frontRightPSI: 42.0,
            lastMeasuredAt: 1_781_000_000_000,
            rearLeftPSI: 41.5,
            rearRightPSI: 41.5
        ),
        updatedAt: 1_781_000_000_000,
        vehicleConfiguration: FleetVehicleConfiguration(
            carType: "model3",
            chassisType: nil,
            exteriorColor: "UltraRed",
            fasciaType: "basePoppyseed",
            interiorTrimType: "BlackAndWhite",
            paintColorOverride: nil,
            rightHandDrive: false,
            trimBadging: "long_range",
            wheelType: "PinwheelRefresh18"
        ),
        vin: vin1
    )

    static let snapshotDriving: FleetLatestSnapshot = FleetLatestSnapshot(
        batteryLevel: 62,
        batteryRange: 218,
        chargeLimitSOC: 80,
        chargeRateMPH: nil,
        chargerPowerKW: nil,
        chargingState: nil,
        climateOn: true,
        freshnessMS: 3_200,
        gear: "D",
        insideTemp: 72,
        latitude: 37.3345,
        locked: true,
        longitude: -122.0280,
        odometer: 19_312,
        outsideTemp: 58,
        sentryMode: false,
        software: nil,
        speed: 47,
        targetTemperature: 72,
        timeToFullCharge: nil,
        timestamp: 1_781_000_000_000,
        updatedAt: 1_781_000_000_000,
        vin: vin1
    )

    static let snapshotEmpty: FleetLatestSnapshot? = nil

    static let vehicles: [FleetVehicle] = [
        FleetVehicle(
            displayName: "Model 3",
            hidden: false,
            latest: snapshotFull,
            permissions: ["control"],
            vehicleTag: "daily",
            vin: vin1
        ),
        FleetVehicle(
            displayName: "Model Y",
            hidden: false,
            latest: FleetLatestSnapshot(
                batteryLevel: 42,
                chargeLimitSOC: 90,
                chargeRateMPH: nil,
                chargerPowerKW: nil,
                chargingState: nil,
                freshnessMS: 8_000,
                gear: "P",
                insideTemp: 68,
                latitude: nil,
                locked: false,
                longitude: nil,
                odometer: 8_104,
                outsideTemp: 71,
                sentryMode: false,
                software: nil,
                speed: nil,
                timeToFullCharge: nil,
                timestamp: 1_781_000_000_000,
                updatedAt: 1_781_000_000_000,
                vin: vin2
            ),
            permissions: ["control"],
            vehicleTag: "weekend",
            vin: vin2
        ),
        FleetVehicle(
            displayName: nil,
            hidden: false,
            latest: nil,
            permissions: [],
            vehicleTag: nil,
            vin: vin3
        )
    ]

    static let chargeSessions: [FleetChargeSession] = [
        FleetChargeSession(
            avgPowerKW: 42.1,
            batteryLevelEnd: nil,
            batteryLevelStart: 38,
            cost: nil,
            currency: nil,
            durationMS: 2_700_000,
            endedAt: nil,
            energyAddedKWH: 18.4,
            maxPowerKW: 97.2,
            sessionID: "preview-charge-1",
            startedAt: 1_781_000_000_000,
            status: "charging",
            vin: vin1
        ),
        FleetChargeSession(
            avgPowerKW: 11.4,
            batteryLevelEnd: 78,
            batteryLevelStart: 64,
            cost: 4.20,
            currency: "USD",
            durationMS: 5_400_000,
            endedAt: 1_781_005_400_000,
            energyAddedKWH: 7.2,
            maxPowerKW: 11.5,
            sessionID: "preview-charge-2",
            startedAt: 1_781_000_000_000,
            status: "complete",
            vin: vin1
        )
    ]

    static let activeDrive: FleetActiveDriveSession = FleetActiveDriveSession(
        active: true,
        bufferedPoints: [],
        distanceMiles: 7.4,
        durationMS: 1_080_000,
        lastUpdate: 1_781_001_080_000,
        latest: snapshotDriving,
        latestRoutePoint: previewRoute.last,
        route: previewRoute,
        routePointCount: previewRoute.count,
        sessionID: "preview-active-drive",
        startBattery: 68,
        startLocation: FleetLocationCoordinate(latitude: 37.3318, longitude: -122.0312),
        startOdometer: 19_298,
        startedAt: 1_781_000_000_000,
        status: "in_progress",
        vin: vin1
    )

    static let driveSession: FleetDriveSession = FleetDriveSession(
        avgSpeedMPH: 34,
        distanceMiles: 12.4,
        durationMS: 1_620_000,
        endedAt: 1_781_001_620_000,
        energyUsedKWH: 3.1,
        maxSpeedMPH: 58,
        route: previewRoute,
        sessionID: "preview-drive",
        startAddress: "1 Apple Park Way, Cupertino, CA",
        endAddress: "Infinite Loop, Cupertino, CA",
        startedAt: 1_781_000_000_000,
        vin: vin1
    )

    static let softwareUpdateAvailable: FleetSoftwareUpdate = FleetSoftwareUpdate(
        availableVersion: "2026.20",
        currentVersion: "2026.14.6",
        downloadPercent: 100,
        expectedDurationMinutes: 25,
        expectedDurationSec: 1_500,
        installPercent: 0,
        installable: true,
        releaseNotes: [
            FleetSoftwareReleaseNote(
                description: "Adds software update state and release notes to the debug backend view.",
                imageURL: nil,
                subtitle: "Release notes",
                title: "Software updates"
            ),
            FleetSoftwareReleaseNote(
                description: "Improves efficiency of HVAC control while parked.",
                imageURL: nil,
                subtitle: "Improvements",
                title: "Cabin climate"
            )
        ],
        releaseNotesCount: 2,
        scheduledStartTimeMS: nil,
        sourceTimestamp: 1_781_000_000_000,
        status: "available",
        updateAvailable: true,
        updatedAt: 1_781_000_000_000,
        warningTimeRemainingMS: nil
    )

    static let softwareUpdateScheduled: FleetSoftwareUpdate = FleetSoftwareUpdate(
        availableVersion: "2026.20",
        currentVersion: "2026.14.6",
        downloadPercent: 100,
        expectedDurationMinutes: 25,
        expectedDurationSec: 1_500,
        installPercent: 0,
        installable: false,
        releaseNotes: [],
        releaseNotesCount: 2,
        scheduledStartTimeMS: 1_781_086_400_000,
        sourceTimestamp: 1_781_000_000_000,
        status: "scheduled",
        updateAvailable: true,
        updatedAt: 1_781_000_000_000,
        warningTimeRemainingMS: 1_800_000
    )

    static let softwareUpdateUpToDate: FleetSoftwareUpdate = FleetSoftwareUpdate(
        availableVersion: nil,
        currentVersion: "2026.14.6",
        downloadPercent: nil,
        expectedDurationMinutes: nil,
        expectedDurationSec: nil,
        installPercent: nil,
        installable: false,
        releaseNotes: [],
        releaseNotesCount: 0,
        scheduledStartTimeMS: nil,
        sourceTimestamp: 1_781_000_000_000,
        status: "up_to_date",
        updateAvailable: false,
        updatedAt: 1_781_000_000_000,
        warningTimeRemainingMS: nil
    )

    static let user: FleetUser = FleetUser(
        authType: "tesla",
        email: "driver@example.com",
        id: "user-1",
        name: "Max",
        role: "owner",
        scopes: ["vehicles:read", "telemetry:read", "vehicle_control"],
        units: "imperial"
    )

    static let userMetric: FleetUser = FleetUser(
        authType: "tesla",
        email: "driver@example.com",
        id: "user-1",
        name: "Max",
        role: "owner",
        scopes: ["vehicles:read", "telemetry:read", "vehicle_control"],
        units: "metric"
    )

    static let webhookEnabled: FleetDeviceNotificationWebhook = FleetDeviceNotificationWebhook(
        createdAt: 1_780_000_000_000,
        description: "Primary hook",
        deviceID: "device-1",
        deviceName: "iPhone",
        enabled: true,
        events: ["drive.started", "drive.completed", "charging.started"],
        failureCount: 0,
        id: "hook-1",
        lastFailureAt: nil,
        lastSuccessAt: 1_781_000_000_000,
        platform: "ios",
        secret: nil,
        updatedAt: 1_781_000_000_000,
        url: URL(string: "https://example.com/teslasiri/webhook/device-1")!,
        vins: [vin1, vin2]
    )

    static let webhookDisabled: FleetDeviceNotificationWebhook = FleetDeviceNotificationWebhook(
        createdAt: 1_780_000_000_000,
        description: nil,
        deviceID: "device-1",
        deviceName: nil,
        enabled: false,
        events: [],
        failureCount: 3,
        id: "hook-2",
        lastFailureAt: 1_780_900_000_000,
        lastSuccessAt: nil,
        platform: "ios",
        secret: nil,
        updatedAt: 1_780_900_000_000,
        url: URL(string: "https://example.com/teslasiri/webhook/legacy")!,
        vins: []
    )
}
