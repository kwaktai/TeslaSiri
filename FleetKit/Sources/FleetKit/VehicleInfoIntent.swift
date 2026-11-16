import AppIntents
import CoreLocation
import Foundation
import MapKit
import SwiftUI

/// Answers questions about one or more live readings in a single call, such as
/// "what's my tire pressure and mileage?" or "how much range do I have and is it locked?".
@AppIntent(.tool)
public struct GetVehicleInfoIntent: AppIntent, PredictableIntent {
    public static let title: LocalizedStringResource = "Get Tesla Vehicle Info"
    public static let description = IntentDescription(
        "Reads live data from the user's car (or Tesla) and answers only what was asked: battery, range, tire pressure, mileage, charging, cabin climate, locks and open doors, or where the car is. Pass every topic the user asked about in one call. Returns the full live status for follow-up questions.",
        searchKeywords: ["my car", "car battery", "battery", "range", "tire pressure", "PSI", "mileage", "odometer", "miles", "charging", "temperature", "locked", "is my car locked", "doors", "windows", "where is my car", "location"]
    )
    public static let isDiscoverable = true

    @Parameter(
        title: "Vehicle",
        description: "The car to read. Leave empty to use the car the user has selected in the app.",
        requestValueDialog: IntentDialog("Which vehicle?"),
        requestDisambiguationDialog: IntentDialog("Which vehicle?"),
        optionsProvider: SelectedVehicleOptionsProvider()
    )
    public var vehicle: VehicleEntity?

    @Parameter(
        title: "Topics",
        description: "Every reading the user asked about, for example battery and tire pressure for \"what's my battery and tire pressure?\". Include each topic once.",
        requestValueDialog: IntentDialog("What would you like to know about your car?")
    )
    public var topics: [VehicleInfoTopic]

    public init() {}

    public init(vehicle: VehicleEntity? = nil, topics: [VehicleInfoTopic]) {
        self.vehicle = vehicle
        self.topics = topics
    }

    public static var parameterSummary: some ParameterSummary {
        When(\.$vehicle, .hasAnyValue) {
            Summary("Get \(\.$topics) for \(\.$vehicle)")
        } otherwise: {
            Summary("Get \(\.$topics) for my car")
        }
    }

    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction(parameters: (\.$vehicle, \.$topics)) { vehicle, topics in
            let topicText = topics.map(\.spokenName).formatted(.list(type: .and))
            return DisplayRepresentation(
                title: VehicleEntity.predictionTitle(verb: "Get", vehicle: vehicle, suffix: topicText)
            )
        }
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<VehicleStatusEntity> & ShowsSnippetView & ProvidesDialog {
        let log = FleetIntentLog(Self.self, vehicle: vehicle)
        do {
            let service = FleetIntentService.make()
            let resolved = try await service.resolvedVehicle(vehicle?.id)
            let snapshot = try await service.snapshot(vin: resolved.vin)
            let requested = topics.isEmpty ? VehicleInfoTopic.allCases : topics
            let allowNetwork = FleetIntentService.testingOverride == nil

            var address: String?
            if requested.contains(.location) {
                address = await FleetLocationNamer.address(latitude: snapshot.latitude, longitude: snapshot.longitude)
            }

            let entity = VehicleStatusEntity(snapshot: snapshot, vehicleName: resolved.name, locationAddress: address)
            let mapData: SiriRenderedMapData?
            if requested.contains(.location) || allowNetwork {
                mapData = await SiriMapSnapshotRenderer.renderLocationPin(
                    latitude: snapshot.latitude,
                    longitude: snapshot.longitude,
                    fallbackPlaceQuery: address,
                    style: SiriSnippetStateStore.shared.mapStyle(for: "vehicle"),
                    accentHex: 0x0A84FF,
                    allowNetworkSnapshot: allowNetwork
                )
            } else {
                mapData = nil
            }

            let answer = entity.spokenAnswer(for: requested)
            log.success("answered \(requested.map(\.rawValue).joined(separator: ",")) for \(resolved.name)")
            return .result(
                value: entity,
                dialog: IntentDialog("\(answer)"),
                view: VehicleStatusSnippetView(status: entity, mapData: mapData)
            )
        } catch {
            throw log.failure(error)
        }
    }
}

/// A group of live readings the Get Tesla Vehicle Info tool can report.
public enum VehicleInfoTopic: String, AppEnum, CaseIterable, Sendable {
    case battery
    case range
    case charging
    case tirePressure
    case odometer
    case climate
    case security
    case location

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Vehicle Info Topic")
    public static let caseDisplayRepresentations: [VehicleInfoTopic: DisplayRepresentation] = [
        .battery: DisplayRepresentation(title: "Battery", subtitle: "Battery percent (state of charge)", image: .init(systemName: "battery.75percent")),
        .range: DisplayRepresentation(title: "Range", subtitle: "Estimated miles of driving left", image: .init(systemName: "road.lanes")),
        .charging: DisplayRepresentation(title: "Charging", subtitle: "Plugged in or not, charging speed, time to full, charge limit, and charge port", image: .init(systemName: "bolt.car")),
        .tirePressure: DisplayRepresentation(title: "Tire Pressure", subtitle: "PSI of each tire and any low tire", image: .init(systemName: "tirepressure")),
        .odometer: DisplayRepresentation(title: "Mileage", subtitle: "Odometer: total miles driven", image: .init(systemName: "gauge.with.dots.needle.33percent")),
        .climate: DisplayRepresentation(title: "Climate", subtitle: "Cabin and outside temperature, climate on or off, setpoint, seat and steering wheel heat, Dog Mode, defrost", image: .init(systemName: "thermometer.medium")),
        .security: DisplayRepresentation(title: "Locks & Security", subtitle: "Locked or unlocked, open doors, windows, trunk or frunk, and Sentry Mode", image: .init(systemName: "lock")),
        .location: DisplayRepresentation(title: "Location", subtitle: "Where the car is, and its speed if it's driving", image: .init(systemName: "location"))
    ]

    var spokenName: String {
        switch self {
        case .battery: FleetCopy.text("battery", "배터리")
        case .range: FleetCopy.text("range", "주행 가능 거리")
        case .charging: FleetCopy.text("charging", "충전")
        case .tirePressure: FleetCopy.text("tire pressure", "타이어 공기압")
        case .odometer: FleetCopy.text("mileage", "주행거리")
        case .climate: FleetCopy.text("climate", "공조")
        case .security: FleetCopy.text("locks", "잠금")
        case .location: FleetCopy.text("location", "위치")
        }
    }
}

extension VehicleStatusEntity {
    /// Natural-language answer covering only the requested topics, in the order given.
    public func spokenAnswer(for topics: [VehicleInfoTopic], now: Date = .now) -> String {
        var seen = Set<VehicleInfoTopic>()
        let ordered = topics.filter { seen.insert($0).inserted }
        var sentences: [String] = []

        // Battery and range read naturally as one sentence when both are asked.
        if ordered.contains(.battery), ordered.contains(.range),
           let batteryPercent, let batteryRangeMiles {
            let miles = Int(batteryRangeMiles.rounded())
            sentences.append(FleetCopy.text(
                "\(vehicleName) is at \(batteryPercent)% with about \(miles) miles of range.",
                "\(vehicleName) 배터리는 \(batteryPercent)%, 주행 가능 거리는 약 \(miles)마일입니다."
            ))
            seen = [.battery, .range]
        } else {
            seen = []
        }

        for topic in ordered where !seen.contains(topic) {
            if let sentence = sentence(for: topic) {
                sentences.append(sentence)
            }
        }

        if let updatedAt, now.timeIntervalSince(updatedAt) > 60 * 60 {
            let age = updatedAt.formatted(.relative(presentation: .named))
            sentences.append(FleetCopy.text(
                "These readings are from \(age), while the car was asleep.",
                "이 값은 \(age) 기록이며, 그때 차는 절전 상태였습니다."
            ))
        }

        return sentences.isEmpty
            ? FleetCopy.text(
                "\(vehicleName) didn't report that information. Try again once the car is awake.",
                "\(vehicleName)이(가) 그 정보를 보내지 않았습니다. 차가 깨어난 뒤 다시 시도하세요."
            )
            : sentences.joined(separator: " ")
    }

    private func sentence(for topic: VehicleInfoTopic) -> String? {
        switch topic {
        case .battery:
            return batteryPercent.map {
                FleetCopy.text("\(vehicleName) is at \($0)% battery.", "\(vehicleName) 배터리는 \($0)%입니다.")
            }
        case .range:
            return batteryRangeMiles.map {
                FleetCopy.text(
                    "Estimated range is \(Int($0.rounded())) miles.",
                    "주행 가능 거리는 약 \(Int($0.rounded()))마일입니다."
                )
            }
        case .charging:
            return chargingSentence
        case .tirePressure:
            return tireSentence
        case .odometer:
            return odometerMiles.map {
                FleetCopy.text(
                    "The odometer reads \(Int($0.rounded()).formatted()) miles.",
                    "누적 주행거리는 \(Int($0.rounded()).formatted())마일입니다."
                )
            }
        case .climate:
            return climateSentence
        case .security:
            return securitySentence
        case .location:
            return locationSentence
        }
    }

    private var chargingSentence: String? {
        guard let chargingState else { return nil }
        let limit = chargeLimitPercent.map {
            FleetCopy.text(" The charge limit is \($0)%.", " 충전 한도는 \($0)%입니다.")
        } ?? ""
        switch chargingState.lowercased() {
        case "charging", "starting":
            var text = FleetCopy.text("It's charging", "충전 중입니다")
            if let chargerPowerKW, chargerPowerKW > 0 {
                text += FleetCopy.text(
                    String(format: " at %.0f kW", chargerPowerKW),
                    String(format: ", %.0f kW", chargerPowerKW)
                )
            }
            if let chargeRateMPH, chargeRateMPH > 0 {
                let rate = Int(chargeRateMPH.rounded())
                text += FleetCopy.text(
                    ", adding about \(rate) miles of range per hour",
                    ", 시간당 약 \(rate)마일"
                )
            }
            if let minutesToFullCharge {
                let duration = Duration.seconds(minutesToFullCharge * 60)
                    .formatted(.units(allowed: [.hours, .minutes], width: .wide))
                text += FleetCopy.text(", with \(duration) to go", ", 약 \(duration) 남음")
            }
            return text + "." + limit
        case "complete":
            return FleetCopy.text("Charging is complete.", "충전이 끝났습니다.") + limit
        case "stopped", "nopower":
            return FleetCopy.text("It's plugged in but not charging.", "꽂혀 있지만 충전하지 않습니다.") + limit
        case "disconnected":
            let port = chargePortDoorOpen == true
                ? FleetCopy.text(" The charge port door is open.", " 충전구가 열려 있습니다.")
                : ""
            return FleetCopy.text("It's not plugged in.", "충전 케이블이 연결되어 있지 않습니다.") + limit + port
        default:
            return FleetCopy.text("Charging state: \(chargingState).", "충전 상태: \(chargingState).") + limit
        }
    }

    private var tireSentence: String? {
        let tires: [(String, String, Double?)] = [
            ("front left", "앞 왼쪽", frontLeftTirePSI),
            ("front right", "앞 오른쪽", frontRightTirePSI),
            ("rear left", "뒤 왼쪽", rearLeftTirePSI),
            ("rear right", "뒤 오른쪽", rearRightTirePSI)
        ]
        let readings = tires.compactMap { english, korean, psi in psi.map { (english, korean, Int($0.rounded())) } }
        guard !readings.isEmpty else {
            return FleetCopy.text(
                "There's no recent tire pressure reading. Tesla reports it after a short drive.",
                "최근 타이어 공기압이 없습니다. 짧게 주행한 뒤에 표시됩니다."
            )
        }
        if FleetCopy.prefersKorean {
            let list = readings.map { "\($0.1) \($0.2)" }.formatted(.list(type: .and))
            var text = "타이어 공기압은 \(list) PSI입니다."
            let low = readings.filter { $0.2 < 38 }.map(\.1)
            if !low.isEmpty {
                text += " \(low.formatted(.list(type: .and)))이(가) 낮습니다."
            }
            return text
        }
        let list = readings.map { "\($0.0) \($0.2)" }.formatted(.list(type: .and))
        var text = "Tire pressures are \(list) PSI."
        let low = readings.filter { $0.2 < 38 }.map(\.0)
        if !low.isEmpty {
            text += " The \(low.formatted(.list(type: .and))) \(low.count == 1 ? "tire looks" : "tires look") low."
        }
        return text
    }

    private var climateSentence: String? {
        var parts: [String] = []
        let unit = temperatureUnit ?? "°"
        func degrees(_ value: Double) -> String { "\(Int(value.rounded()))\(unit)" }

        if let insideTemp, let outsideTemp {
            parts.append(FleetCopy.text(
                "It's \(degrees(insideTemp)) inside and \(degrees(outsideTemp)) outside.",
                "실내 \(degrees(insideTemp)), 실외 \(degrees(outsideTemp))입니다."
            ))
        } else if let insideTemp {
            parts.append(FleetCopy.text("It's \(degrees(insideTemp)) inside.", "실내는 \(degrees(insideTemp))입니다."))
        } else if let outsideTemp {
            parts.append(FleetCopy.text("It's \(degrees(outsideTemp)) outside.", "실외는 \(degrees(outsideTemp))입니다."))
        }
        if let isClimateOn {
            if isClimateOn {
                parts.append(FleetCopy.text(
                    "Climate is on" + (targetTemp.map { ", set to \(degrees($0))." } ?? "."),
                    "공조가 켜져 있습니다" + (targetTemp.map { ", 설정 \(degrees($0))." } ?? ".")
                ))
            } else {
                parts.append(FleetCopy.text("Climate is off.", "공조가 꺼져 있습니다."))
            }
        }
        if dogModeOn == true { parts.append(FleetCopy.text("Dog Mode is on.", "펫 모드가 켜져 있습니다.")) }
        if maxDefrostOn == true { parts.append(FleetCopy.text("Max defrost is on.", "최대 성에 제거가 켜져 있습니다.")) }
        if let seatHeaterSummary, seatHeaterSummary.contains(where: { "123".contains($0) }) {
            parts.append(FleetCopy.text("Seat heat: \(seatHeaterSummary).", "시트 열선: \(seatHeaterSummary)."))
        }
        if steeringWheelHeaterOn == true {
            parts.append(FleetCopy.text("The steering wheel heater is on.", "핸들 열선이 켜져 있습니다."))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var securitySentence: String? {
        var parts: [String] = []
        if let isLocked {
            parts.append(isLocked
                ? FleetCopy.text("It's locked", "잠겨 있습니다")
                : FleetCopy.text("It's unlocked", "잠금이 해제되어 있습니다"))
        }
        if let sentryModeOn {
            parts.append(sentryModeOn
                ? FleetCopy.text("Sentry Mode is on", "감시 모드가 켜져 있습니다")
                : FleetCopy.text("Sentry Mode is off", "감시 모드가 꺼져 있습니다"))
        }
        let joiner = FleetCopy.text(" and ", ", ")
        var text = parts.isEmpty ? "" : parts.joined(separator: joiner) + "."
        if let openClosures {
            text += openClosures == "None"
                ? FleetCopy.text(
                    " All doors, windows, the trunk, and the frunk are closed.",
                    " 문, 창문, 트렁크, 프렁크가 모두 닫혀 있습니다."
                )
                : FleetCopy.text(" Open: \(openClosures).", " 열림: \(openClosures).")
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var locationSentence: String? {
        let englishPlace = locationAddress.map { "near \($0)" }
            ?? ((latitude != nil && longitude != nil) ? "at the location shown in the Wattie app" : nil)
        let koreanPlace = locationAddress.map { "\($0) 근처" }
            ?? ((latitude != nil && longitude != nil) ? "Wattie에 표시된 위치" : nil)
        guard let englishPlace, let koreanPlace else {
            return FleetCopy.text(
                "\(vehicleName) hasn't reported its location recently.",
                "\(vehicleName)이(가) 최근 위치를 보내지 않았습니다."
            )
        }
        if let speedMPH, speedMPH > 0, gear == "D" || gear == "R" {
            let speed = Int(speedMPH.rounded())
            return FleetCopy.text(
                "\(vehicleName) is driving \(englishPlace) at \(speed) mph.",
                "\(vehicleName)이(가) \(koreanPlace)를 \(speed) mph로 달리고 있습니다."
            )
        }
        return FleetCopy.text(
            "\(vehicleName) is parked \(englishPlace).",
            "\(vehicleName)은(는) \(koreanPlace)에 주차되어 있습니다."
        )
    }
}

/// Reverse-geocodes the car's coordinates for spoken answers. Uses MapKit, which
/// is available in the App Intents extension.
enum FleetLocationNamer {
    static func address(latitude: Double?, longitude: Double?) async -> String? {
        guard let latitude, let longitude,
              let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude)) else {
            return nil
        }
        do {
            guard let item = try await request.mapItems.first else { return nil }
            let candidates = [item.address?.shortAddress, item.name, item.address?.fullAddress]
            return candidates
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        } catch {
            return nil
        }
    }
}
