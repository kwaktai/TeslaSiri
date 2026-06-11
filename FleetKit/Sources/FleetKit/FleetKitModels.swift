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
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            return Double(string)
        }
        return nil
    }
}
