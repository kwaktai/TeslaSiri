import Foundation

typealias TessieJSONObject = [String: JSONValue]

nonisolated struct TessieResults<Value: Decodable>: Decodable {
    var results: [Value]
}

nonisolated struct TessieVehicleRecord: Decodable {
    var vin: String
    var isActive: Bool
    var lastState: TessieJSONObject?

    enum CodingKeys: String, CodingKey {
        case vin
        case isActive = "is_active"
        case lastState = "last_state"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vin = try container.decode(String.self, forKey: .vin)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        lastState = try container.decodeIfPresent(TessieJSONObject.self, forKey: .lastState)
    }
}

nonisolated struct TessieCommandResponse: Decodable {
    var result: Bool
}

nonisolated enum TessieModelAdapter {
    static let controlActions = [
        "actuate_trunk",
        "auto_conditioning_start",
        "auto_conditioning_stop",
        "door_lock",
        "door_unlock",
        "flash_lights",
        "honk_horn",
        "navigation_request",
        "remote_defrost",
        "set_bioweapon_mode",
        "set_pet_mode",
        "set_temps",
        "window_control"
    ]

    static let chargeActions = ["set_charge_limit"]

    static var capabilities: FleetCapabilities {
        FleetCapabilities(
            chargeActions: chargeActions,
            controlActions: controlActions,
            events: [],
            notificationEvents: [],
            scopes: ["vehicles", "vehicle_commands", "vehicle_history"],
            software: ["provider": "tessie"]
        )
    }

    static var controlActionInfo: FleetControlActions {
        FleetControlActions(
            actions: controlActions,
            chargeActions: chargeActions,
            schemas: [
                "actuate_trunk": ["which_trunk"],
                "navigation_request": ["value"],
                "remote_defrost": ["on"],
                "set_bioweapon_mode": ["on"],
                "set_charge_limit": ["percent"],
                "set_pet_mode": ["on"],
                "set_temps": ["driver_temp", "passenger_temp"],
                "window_control": ["command"]
            ]
        )
    }

    static func vehicle(from record: TessieVehicleRecord) -> FleetVehicle {
        let state = record.lastState ?? [:]
        return FleetVehicle(
            displayName: state.displayName,
            hidden: !record.isActive,
            latest: snapshot(vin: record.vin, state: state),
            permissions: ["read", "control"],
            vehicleTag: nil,
            vin: record.vin
        )
    }

    static func user(from state: TessieJSONObject?) -> FleetUser {
        FleetUser(
            authType: "tessie_access_token",
            name: "Tessie",
            scopes: capabilities.scopes,
            units: state?.units
        )
    }

    static func snapshot(vin: String, state: TessieJSONObject) -> FleetLatestSnapshot {
        let charge = state.object("charge_state")
        let climate = state.object("climate_state")
        let drive = state.object("drive_state")
        let vehicle = state.object("vehicle_state")
        let timestamps = [
            charge.int64("timestamp"),
            climate.int64("timestamp"),
            drive.int64("timestamp"),
            vehicle.int64("timestamp")
        ].compactMap { $0 }.map(milliseconds)
        let updatedAt = timestamps.max()

        return FleetLatestSnapshot(
            batteryLevel: charge.double("battery_level"),
            batteryRange: charge.double("battery_range"),
            chargeLimitSOC: charge.double("charge_limit_soc"),
            chargeRateMPH: charge.double("charge_rate"),
            chargerPowerKW: charge.double("charger_power"),
            chargingState: charge.string("charging_state"),
            climateOn: climate.bool("is_climate_on"),
            freshnessMS: updatedAt.map { max(Int64(Date().timeIntervalSince1970 * 1_000) - $0, 0) },
            gear: drive.string("shift_state"),
            insideTemp: state.displayTemperature(climate.double("inside_temp")),
            latitude: drive.double("latitude"),
            locked: vehicle.bool("locked"),
            longitude: drive.double("longitude"),
            odometer: vehicle.double("odometer"),
            outsideTemp: state.displayTemperature(climate.double("outside_temp")),
            sentryMode: vehicle.bool("sentry_mode"),
            software: software(from: state),
            speed: drive.double("speed"),
            targetTemperature: state.displayTemperature(climate.double("driver_temp_setting")),
            timeToFullCharge: charge.double("time_to_full_charge"),
            timestamp: updatedAt,
            updatedAt: updatedAt,
            vin: vin
        )
    }

    static func software(from state: TessieJSONObject) -> FleetSoftwareUpdate {
        let vehicle = state.object("vehicle_state")
        let update = vehicle.object("software_update")
        let currentVersion = vehicle.string("car_version")?.split(separator: " ").first.map(String.init)
        let availableVersion = update.string("version")
        let status = update.string("status")
        let unavailableStatuses = ["", "idle", "unknown"]
        let isAvailable = availableVersion != nil
            || !unavailableStatuses.contains(status?.lowercased() ?? "")
        let expectedSeconds = update.int64("expected_duration_sec")
        let sourceTimestamp = vehicle.int64("timestamp").map(milliseconds)

        return FleetSoftwareUpdate(
            availableVersion: availableVersion,
            currentVersion: currentVersion,
            downloadPercent: update.double("download_perc"),
            expectedDurationMinutes: expectedSeconds.map { Double($0) / 60 },
            expectedDurationSec: expectedSeconds,
            installPercent: update.double("install_perc"),
            installable: isAvailable,
            releaseNotes: [],
            releaseNotesCount: 0,
            scheduledStartTimeMS: update.int64("scheduled_time_ms").map(milliseconds),
            sourceTimestamp: sourceTimestamp,
            status: status,
            updateAvailable: isAvailable,
            updatedAt: sourceTimestamp,
            warningTimeRemainingMS: update.int64("warning_time_remaining_ms")
        )
    }

    static func drive(from object: TessieJSONObject, vin: String) -> FleetDriveSession? {
        guard let id = object.string("id"), let startedAt = object.int64("started_at") else { return nil }
        let startedAtMS = milliseconds(startedAt)
        let endedAtMS = object.int64("ended_at").map(milliseconds)
        return FleetDriveSession(
            avgSpeedMPH: object.double("average_speed"),
            distanceMiles: object.double("odometer_distance"),
            durationMS: endedAtMS.map { max($0 - startedAtMS, 0) },
            endedAt: endedAtMS,
            energyUsedKWH: object.double("energy_used"),
            maxSpeedMPH: object.double("max_speed"),
            route: [],
            sessionID: "\(vin):\(id)",
            startAddress: object.string("starting_location"),
            endAddress: object.string("ending_location"),
            startedAt: startedAtMS,
            vin: vin
        )
    }

    static func completedCharge(from object: TessieJSONObject, vin: String) -> FleetChargeSession? {
        guard let id = object.string("id"), let startedAt = object.int64("started_at") else { return nil }
        let startedAtMS = milliseconds(startedAt)
        let endedAtMS = object.int64("ended_at").map(milliseconds)
        return FleetChargeSession(
            batteryLevelEnd: object.double("ending_battery"),
            batteryLevelStart: object.double("starting_battery"),
            cost: object.double("cost"),
            durationMS: endedAtMS.map { max($0 - startedAtMS, 0) },
            endedAt: endedAtMS,
            energyAddedKWH: object.double("energy_added"),
            sessionID: "\(vin):\(id)",
            startedAt: startedAtMS,
            status: "Completed",
            vin: vin
        )
    }

    static func activeCharge(vin: String, state: TessieJSONObject) -> FleetChargeSession? {
        let charge = state.object("charge_state")
        guard charge.string("charging_state")?.lowercased() == "charging" else { return nil }
        let timestamp = charge.int64("timestamp").map(milliseconds)
            ?? Int64(Date().timeIntervalSince1970 * 1_000)
        return FleetChargeSession(
            avgPowerKW: charge.double("charger_power"),
            batteryLevelStart: charge.double("battery_level"),
            energyAddedKWH: charge.double("charge_energy_added"),
            maxPowerKW: charge.double("charger_power"),
            sessionID: "active:\(vin)",
            startedAt: timestamp,
            status: "Charging",
            vin: vin
        )
    }

    static func activeDrive(vin: String, state: TessieJSONObject, route: [FleetRoutePoint] = []) -> FleetActiveDriveSession {
        let drive = state.object("drive_state")
        let gear = drive.string("shift_state")?.uppercased()
        let isActive = gear.map { $0 != "P" } ?? false
        guard isActive else { return FleetActiveDriveSession(active: false, vin: vin) }

        let latest = snapshot(vin: vin, state: state)
        let latestRoutePoint = route.last ?? FleetRoutePoint(
            latitude: drive.double("latitude"),
            longitude: drive.double("longitude"),
            odometer: state.object("vehicle_state").double("odometer"),
            speed: drive.double("speed"),
            timestamp: drive.int64("timestamp").map(milliseconds)
        )
        let startedAt = route.first?.timestamp ?? drive.int64("timestamp").map(milliseconds)

        return FleetActiveDriveSession(
            active: true,
            bufferedPoints: route,
            lastUpdate: drive.int64("timestamp").map(milliseconds),
            latest: latest,
            latestRoutePoint: latestRoutePoint,
            route: route,
            routePointCount: route.count,
            sessionID: "active:\(vin)",
            startBattery: nil,
            startLocation: FleetLocationCoordinate(
                latitude: route.first?.latitude ?? drive.double("latitude"),
                longitude: route.first?.longitude ?? drive.double("longitude")
            ),
            startOdometer: route.first?.odometer,
            startedAt: startedAt,
            status: "Driving",
            vin: vin
        )
    }

    static func routePoint(from object: TessieJSONObject) -> FleetRoutePoint? {
        guard object.double("latitude") != nil, object.double("longitude") != nil else { return nil }
        return FleetRoutePoint(
            latitude: object.double("latitude"),
            longitude: object.double("longitude"),
            odometer: object.double("odometer"),
            speed: object.double("speed"),
            timestamp: object.int64("timestamp").map(milliseconds)
        )
    }

    static func milliseconds(_ value: Int64) -> Int64 {
        abs(value) < 10_000_000_000 ? value * 1_000 : value
    }
}

nonisolated extension JSONValue {
    var tessieStringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .integer(let value):
            return String(value)
        case .double(let value):
            if value.rounded() == value, value <= Double(Int64.max), value >= Double(Int64.min) {
                return String(Int64(value))
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }

    var tessieDoubleValue: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .double(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }

    var tessieInt64Value: Int64? {
        switch self {
        case .integer(let value): return Int64(value)
        case .double(let value):
            guard value.isFinite, value < Double(Int64.max), value >= Double(Int64.min) else { return nil }
            return Int64(value)
        case .string(let value):
            return Int64(value) ?? Double(value).flatMap { double in
                guard double.isFinite, double < Double(Int64.max), double >= Double(Int64.min) else { return nil }
                return Int64(double)
            }
        default:
            return nil
        }
    }

    var tessieBoolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .integer(let value):
            return value != 0
        case .double(let value):
            return value != 0
        case .string(let value):
            switch value.lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    var tessieObjectValue: TessieJSONObject? {
        if case .object(let object) = self { return object }
        return nil
    }
}

nonisolated extension Dictionary where Key == String, Value == JSONValue {
    func object(_ key: String) -> TessieJSONObject {
        self[key]?.tessieObjectValue ?? [:]
    }

    func string(_ key: String) -> String? {
        self[key]?.tessieStringValue
    }

    func double(_ key: String) -> Double? {
        self[key]?.tessieDoubleValue
    }

    func int64(_ key: String) -> Int64? {
        self[key]?.tessieInt64Value
    }

    func bool(_ key: String) -> Bool? {
        self[key]?.tessieBoolValue
    }

    var displayName: String? {
        string("display_name") ?? object("vehicle_state").string("vehicle_name")
    }

    var usesFahrenheit: Bool {
        let settings = object("gui_settings")
        if let temperature = settings.string("gui_temperature_units")?.lowercased() {
            return temperature.hasPrefix("f")
        }
        if let distance = settings.string("gui_distance_units")?.lowercased() {
            return !distance.contains("km")
        }
        return true
    }

    func displayTemperature(_ celsius: Double?) -> Double? {
        guard let celsius else { return nil }
        return usesFahrenheit ? (celsius * 9 / 5) + 32 : celsius
    }

    var units: String? {
        let settings = object("gui_settings")
        if let temperature = settings.string("gui_temperature_units")?.lowercased() {
            return temperature.hasPrefix("f") ? "imperial" : "metric"
        }
        guard let distance = settings.string("gui_distance_units")?.lowercased() else { return nil }
        return distance.contains("km") ? "metric" : "imperial"
    }
}
