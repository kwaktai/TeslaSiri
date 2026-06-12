import Foundation

/// Minimal, decode-tolerant models for the endpoints the intents use. These
/// mirror a subset of the app's `FleetAPIModels`, kept independent so the
/// package stays self-contained.

public struct FleetVehicleInfo: Decodable, Sendable, Identifiable {
    public let vin: String
    public let displayName: String?
    public let vehicleTag: String?

    public var id: String { vin }
    public var name: String { displayName ?? vehicleTag ?? vin }

    enum CodingKeys: String, CodingKey {
        case vin
        case displayName = "display_name"
        case vehicleTag = "vehicle_tag"
    }
}

public struct FleetSnapshotInfo: Decodable, Sendable {
    public let vin: String
    public let batteryLevel: Double?
    public let chargeLimitSOC: Double?
    public let chargingState: String?
    public let locked: Bool?
    public let chargeRateMPH: Double?
    public let timeToFullCharge: Double?
    public let insideTemp: Double?
    public let outsideTemp: Double?
    public let hvacOn: Bool?
    public let latitude: Double?
    public let longitude: Double?
    public let odometer: Double?
    public let speed: Double?
    public let updatedAt: Int64?
    /// Raw climate keeper state: a telemetry enum string (e.g. `ClimateKeeperModeDog`)
    /// or the vehicle_data string/number form (`2` = dog, `0` = off).
    public let climateKeeperMode: String?
    public let defrostMode: String?
    public let tires: FleetTirePressuresInfo?

    public var updatedAtDate: Date? {
        updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    /// Whether climate keeper reports pet (dog) mode.
    public var petModeOn: Bool? {
        guard let climateKeeperMode else { return nil }
        let lowered = climateKeeperMode.lowercased()
        return lowered.contains("dog") || lowered == "2"
    }

    enum CodingKeys: String, CodingKey {
        case vin
        case batteryLevel = "battery_level"
        case chargeLimitSOC = "charge_limit_soc"
        case chargingState = "charging_state"
        case locked
        case chargeRateMPH = "charge_rate_mph"
        case timeToFullCharge = "time_to_full_charge"
        case insideTemp = "inside_temp"
        case outsideTemp = "outside_temp"
        case hvacOn = "hvac_on"
        case latitude
        case longitude
        case odometer
        case speed
        case updatedAt = "updated_at"
        case climateKeeperMode = "climate_keeper_mode"
        case defrostMode = "defrost_mode"
        case tires
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vin = try c.decodeIfPresent(String.self, forKey: .vin) ?? ""
        batteryLevel = c.flexibleDouble(.batteryLevel)
        chargeLimitSOC = c.flexibleDouble(.chargeLimitSOC)
        chargingState = try c.decodeIfPresent(String.self, forKey: .chargingState)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked)
        chargeRateMPH = c.flexibleDouble(.chargeRateMPH)
        timeToFullCharge = c.flexibleDouble(.timeToFullCharge)
        insideTemp = c.flexibleDouble(.insideTemp)
        outsideTemp = c.flexibleDouble(.outsideTemp)
        hvacOn = try c.decodeIfPresent(Bool.self, forKey: .hvacOn)
        latitude = c.flexibleDouble(.latitude)
        longitude = c.flexibleDouble(.longitude)
        odometer = c.flexibleDouble(.odometer)
        speed = c.flexibleDouble(.speed)
        updatedAt = c.flexibleInt64(.updatedAt)
        climateKeeperMode = c.flexibleEnumString(.climateKeeperMode)
        defrostMode = c.flexibleEnumString(.defrostMode)
        tires = try c.decodeIfPresent(FleetTirePressuresInfo.self, forKey: .tires)
    }
}

/// TPMS readings from the live snapshot. `nil` until the backend has received
/// a TPMS reading; PSI values are converted server-side from bar.
public struct FleetTirePressuresInfo: Decodable, Sendable {
    public let frontLeftPSI: Double?
    public let frontRightPSI: Double?
    public let rearLeftPSI: Double?
    public let rearRightPSI: Double?
    public let hardWarnings: Int?
    public let softWarnings: Int?
    public let lastMeasuredAt: Int64?

    public var measuredAtDate: Date? {
        lastMeasuredAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    public var displaySummary: String? {
        let readings = [
            frontLeftPSI.map { "FL \(Self.formatPSI($0))" },
            frontRightPSI.map { "FR \(Self.formatPSI($0))" },
            rearLeftPSI.map { "RL \(Self.formatPSI($0))" },
            rearRightPSI.map { "RR \(Self.formatPSI($0))" }
        ].compactMap { $0 }
        guard !readings.isEmpty else { return nil }
        return readings.joined(separator: ", ")
    }

    enum CodingKeys: String, CodingKey {
        case frontLeftPSI = "front_left_psi"
        case frontRightPSI = "front_right_psi"
        case rearLeftPSI = "rear_left_psi"
        case rearRightPSI = "rear_right_psi"
        case hardWarnings = "hard_warnings"
        case softWarnings = "soft_warnings"
        case lastMeasuredAt = "last_measured_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frontLeftPSI = c.flexibleDouble(.frontLeftPSI)
        frontRightPSI = c.flexibleDouble(.frontRightPSI)
        rearLeftPSI = c.flexibleDouble(.rearLeftPSI)
        rearRightPSI = c.flexibleDouble(.rearRightPSI)
        hardWarnings = c.flexibleInt64(.hardWarnings).map { Int($0) }
        softWarnings = c.flexibleInt64(.softWarnings).map { Int($0) }
        lastMeasuredAt = c.flexibleInt64(.lastMeasuredAt)
    }

    private static func formatPSI(_ value: Double) -> String {
        "\(Int(value.rounded())) PSI"
    }
}

public struct FleetUserInfo: Decodable, Sendable {
    public let units: String?
}

extension KeyedDecodingContainer {
    /// Tolerates values arriving as either JSON numbers or numeric strings.
    func flexibleDouble(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            return Double(string)
        }
        return nil
    }

    /// Tolerates enum-ish values arriving as either strings or numbers
    /// (e.g. `climate_keeper_mode`: "ClimateKeeperModeDog" or 2).
    func flexibleEnumString(_ key: Key) -> String? {
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            return string
        }
        if let int = try? decodeIfPresent(Int.self, forKey: key) {
            return String(int)
        }
        if let double = try? decodeIfPresent(Double.self, forKey: key) {
            return String(double)
        }
        return nil
    }
}
