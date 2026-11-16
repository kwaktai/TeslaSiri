import AppIntents
import Foundation

/// A seat in the car for seat heating and cooling commands.
public enum SeatPosition: String, AppEnum, Sendable {
    case driver
    case passenger
    case frontSeats
    case rearLeft
    case rearCenter
    case rearRight

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Seat")
    public static let caseDisplayRepresentations: [SeatPosition: DisplayRepresentation] = [
        .driver: DisplayRepresentation(title: "Driver Seat", subtitle: "Front left in left-hand-drive cars; \"my seat\""),
        .passenger: DisplayRepresentation(title: "Passenger Seat", subtitle: "Front passenger seat"),
        .frontSeats: DisplayRepresentation(title: "Both Front Seats", subtitle: "Driver and front passenger"),
        .rearLeft: DisplayRepresentation(title: "Rear Left Seat", subtitle: "Second row, behind the driver"),
        .rearCenter: DisplayRepresentation(title: "Rear Middle Seat", subtitle: "Second row, center"),
        .rearRight: DisplayRepresentation(title: "Rear Right Seat", subtitle: "Second row, behind the passenger")
    ]

    /// Tessie `seat` values this position maps to.
    var tessieSeats: [String] {
        switch self {
        case .driver: ["front_left"]
        case .passenger: ["front_right"]
        case .frontSeats: ["front_left", "front_right"]
        case .rearLeft: ["rear_left"]
        case .rearCenter: ["rear_center"]
        case .rearRight: ["rear_right"]
        }
    }

    var spokenName: String {
        switch self {
        case .driver: "driver seat"
        case .passenger: "passenger seat"
        case .frontSeats: "front seats"
        case .rearLeft: "rear left seat"
        case .rearCenter: "rear middle seat"
        case .rearRight: "rear right seat"
        }
    }

    var koreanName: String {
        switch self {
        case .driver: "운전석"
        case .passenger: "조수석"
        case .frontSeats: "앞좌석"
        case .rearLeft: "뒷좌석 왼쪽"
        case .rearCenter: "뒷좌석 가운데"
        case .rearRight: "뒷좌석 오른쪽"
        }
    }
}

/// Whether a seat command heats or cools (ventilates) the seat.
public enum SeatClimateMode: String, AppEnum, Sendable {
    case heat
    case cool

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Seat Climate Mode")
    public static let caseDisplayRepresentations: [SeatClimateMode: DisplayRepresentation] = [
        .heat: DisplayRepresentation(title: "Heat", subtitle: "Seat heater; every Tesla seat that has one"),
        .cool: DisplayRepresentation(title: "Cool", subtitle: "Ventilated (cooled) front seats; only on cars that have them")
    ]
}

@AppIntent(.tool)
public struct SetSeatClimateIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Set Tesla Seat Heater"
    public static let description = IntentDescription(
        "Warms (or cools, on cars with ventilated seats) one of the car's physical seats, from 0 (off) to 3 (high). Turns the car's climate on, since seat heat only runs while climate is on. To set the cabin temperature or several climate settings at once, use the Configure Tesla Cabin Climate tool instead.",
        searchKeywords: ["seat warmer", "heated seat", "seat heat", "cooled seat", "ventilated seat", "butt warmer"]
    )
    public static let isDiscoverable = true

    @Parameter(
        title: "Vehicle",
        description: "The Tesla to change. Leave empty to use the car the user has selected in the app.",
        requestValueDialog: IntentDialog("Which vehicle?"),
        requestDisambiguationDialog: IntentDialog("Which vehicle?"),
        optionsProvider: SelectedVehicleOptionsProvider()
    )
    public var vehicle: VehicleEntity?

    @Parameter(
        title: "Seat",
        description: "Which seat to change. \"My seat\" means the driver seat.",
        default: .driver
    )
    public var seat: SeatPosition

    @Parameter(
        title: "Level",
        description: "0 turns it off, 1 is low, 2 is medium, and 3 is high. \"Turn on my seat heater\" means 3.",
        default: 3,
        inclusiveRange: (0, 3)
    )
    public var level: Int

    @Parameter(
        title: "Mode",
        description: "Heat for the seat heater, or Cool for seat ventilation.",
        default: .heat
    )
    public var mode: SeatClimateMode

    public init() {}

    public init(vehicle: VehicleEntity? = nil, seat: SeatPosition, level: Int, mode: SeatClimateMode = .heat) {
        self.vehicle = vehicle
        self.seat = seat
        self.level = level
        self.mode = mode
    }

    public static var parameterSummary: some ParameterSummary {
        When(\.$vehicle, .hasAnyValue) {
            Summary("Set \(\.$seat) \(\.$mode) to \(\.$level) in \(\.$vehicle)")
        } otherwise: {
            Summary("Set \(\.$seat) \(\.$mode) to \(\.$level)")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle, \.$seat)) { vehicle, seat in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Heat the \(seat.spokenName) in", vehicle: vehicle))
        }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<VehicleCommandResultEntity> & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)
            let clamped = min(max(level, 0), 3)
            if mode == .cool, ![SeatPosition.driver, .passenger, .frontSeats].contains(seat) {
                throw FleetKitError.api("Only the front seats can be cooled. Try the driver or passenger seat.")
            }
            let action = mode == .heat ? "set_seat_heat" : "set_seat_cool"

            if clamped > 0 {
                try await service.runControl(action: "auto_conditioning_start", vin: resolved.vin, humanName: "starting climate")
            }
            for tessieSeat in seat.tessieSeats {
                try await service.runControl(
                    action: action,
                    vin: resolved.vin,
                    params: ["seat": .string(tessieSeat), "level": .int(clamped)],
                    humanName: mode == .heat ? "the seat heater" : "seat cooling"
                )
            }

            let seatName = seat.spokenName
            let koreanSeat = seat.koreanName
            let summary = clamped == 0
                ? FleetCopy.text(
                    "Turned off \(seatName) \(mode == .heat ? "heat" : "cooling") in \(resolved.name).",
                    "\(resolved.name) \(koreanSeat) \(mode == .heat ? "열선" : "통풍")을 껐습니다."
                )
                : FleetCopy.text(
                    "Set \(seatName) \(mode == .heat ? "heat" : "cooling") to \(clamped) in \(resolved.name).",
                    "\(resolved.name) \(koreanSeat) \(mode == .heat ? "열선" : "통풍")을 \(clamped)단계로 설정했습니다."
                )
            let result = VehicleCommandResultEntity(
                vehicle: resolved,
                action: action,
                appliedValue: "\(seat.spokenName) \(clamped)",
                summary: summary
            )
            log.success("\(action) \(seat.rawValue)=\(clamped) on \(resolved.name)")
            return .result(value: result, dialog: IntentDialog("\(summary)"))
        } catch {
            throw log.failure(error)
        }
    }
}

@AppIntent(.tool)
public struct SetSteeringWheelHeaterIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Set Tesla Steering Wheel Heater"
    public static let description = IntentDescription(
        "Turns the heated steering wheel on or off. Turning it on also turns on the car's climate. Not every Tesla has a heated steering wheel.",
        searchKeywords: ["heated steering wheel", "wheel warmer", "heat the wheel"]
    )
    public static let isDiscoverable = true

    @Parameter(
        title: "Vehicle",
        description: "The Tesla to change. Leave empty to use the car the user has selected in the app.",
        requestValueDialog: IntentDialog("Which vehicle?"),
        requestDisambiguationDialog: IntentDialog("Which vehicle?"),
        optionsProvider: SelectedVehicleOptionsProvider()
    )
    public var vehicle: VehicleEntity?

    @Parameter(title: "On", description: "true to turn the heater on, false to turn it off.", default: true)
    public var on: Bool

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        When(\.$vehicle, .hasAnyValue) {
            Summary("Turn steering wheel heater \(\.$on) in \(\.$vehicle)")
        } otherwise: {
            Summary("Turn steering wheel heater \(\.$on)")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle, \.$on)) { vehicle, on in
            let target = vehicle?.name ?? FleetIntentMetadata.myCar
            return DisplayRepresentation(title: LocalizedStringResource(stringLiteral: "Turn steering wheel heater \(on ? "on" : "off") in \(target)"))
        }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<VehicleCommandResultEntity> & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)
            if on {
                try await service.runControl(action: "auto_conditioning_start", vin: resolved.vin, humanName: "starting climate")
            }
            try await service.runControl(
                action: "steering_wheel_heater",
                vin: resolved.vin,
                params: ["on": .bool(on)],
                humanName: "the steering wheel heater"
            )
            let summary = on
                ? FleetCopy.text("The steering wheel heater is on in \(resolved.name).", "\(resolved.name) 스티어링 휠 열선을 켰습니다.")
                : FleetCopy.text("The steering wheel heater is off in \(resolved.name).", "\(resolved.name) 스티어링 휠 열선을 껐습니다.")
            let result = VehicleCommandResultEntity(
                vehicle: resolved,
                action: "steering_wheel_heater",
                appliedValue: on ? "on" : "off",
                summary: summary
            )
            log.success("steering wheel heater \(on ? "on" : "off") on \(resolved.name)")
            return .result(value: result, dialog: IntentDialog("\(summary)"))
        } catch {
            throw log.failure(error)
        }
    }
}

@AppIntent(.tool)
public struct SetChargingAmpsIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Set Tesla Charging Amps"
    public static let description = IntentDescription(
        "Sets the maximum current the car draws while AC charging, in amps, to charge more slowly or share a circuit. It doesn't change the charge limit; use the Set Tesla Charge Limit tool for that. Doesn't affect Supercharging.",
        searchKeywords: ["charge speed", "charging current", "amperage", "slow charge"]
    )
    public static let isDiscoverable = true

    @Parameter(
        title: "Vehicle",
        description: "The Tesla to change. Leave empty to use the car the user has selected in the app.",
        requestValueDialog: IntentDialog("Which vehicle?"),
        requestDisambiguationDialog: IntentDialog("Which vehicle?"),
        optionsProvider: SelectedVehicleOptionsProvider()
    )
    public var vehicle: VehicleEntity?

    @Parameter(
        title: "Amps",
        description: "Charging current in amps, from 5 to 48, such as 16. The car won't exceed what the charger allows.",
        inclusiveRange: (5, 48),
        requestValueDialog: IntentDialog("How many amps?")
    )
    public var amps: Int

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        When(\.$vehicle, .hasAnyValue) {
            Summary("Set \(\.$vehicle) charging current to \(\.$amps) A")
        } otherwise: {
            Summary("Set my car charging current to \(\.$amps) A")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle)) { vehicle in
            DisplayRepresentation(title: VehicleEntity.predictionTitle(verb: "Set charging amps for", vehicle: vehicle))
        }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<VehicleCommandResultEntity> & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)
            let clamped = min(max(amps, 5), 48)
            try await service.runControl(
                action: "set_charging_amps",
                vin: resolved.vin,
                params: ["amps": .int(clamped)],
                humanName: "setting charging amps"
            )
            let summary = FleetCopy.text(
                "\(resolved.name) will charge at up to \(clamped) amps.",
                "\(resolved.name) 충전 전류를 최대 \(clamped)A로 설정했습니다."
            )
            let result = VehicleCommandResultEntity(
                vehicle: resolved,
                action: "set_charging_amps",
                appliedValue: "\(clamped) A",
                summary: summary
            )
            log.success("set charging amps \(clamped) on \(resolved.name)")
            return .result(value: result, dialog: IntentDialog("\(summary)"))
        } catch {
            throw log.failure(error)
        }
    }
}
