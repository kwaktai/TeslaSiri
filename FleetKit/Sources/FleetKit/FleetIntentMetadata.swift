import AppIntents
import OSLog

/// Shared copy and helpers for vehicle-scoped App Intent metadata.
enum FleetIntentMetadata {
    static let vehicleParameterTitle: LocalizedStringResource = "Vehicle"
    static let vehicleParameterDescription: LocalizedStringResource =
        "The Tesla vehicle from the user's fleet account to target. Optional; omit to target the user's currently selected vehicle (or the first active vehicle on the account)."
    static let vehicleRequestDialog = IntentDialog("Which vehicle?")
    static let vehicleDisambiguationDialog = IntentDialog("Which vehicle?")
    static let myCar = "my car"
}

extension FleetCopy {
    /// A dialog whose text is already chosen for the user's language.
    /// `stringLiteral` displays that sentence as-is, so Korean does not depend on
    /// format-string extraction.
    static func dialog(_ english: String, _ korean: String) -> IntentDialog {
        IntentDialog(LocalizedStringResource(stringLiteral: text(english, korean)))
    }

    static func verb(_ english: String) -> String {
        let map = [
            "Lock": "잠그기",
            "Unlock": "잠금 해제",
            "Open": "열기",
            "Warm up": "예열",
            "Stop climate in": "공조 끄기",
            "Update": "업데이트",
            "Cancel update on": "업데이트 취소",
            "Flash": "라이트",
            "Honk": "경적",
            "Check": "확인",
            "Show": "보기",
            "Set": "설정",
            "Vent": "환기",
            "Close": "닫기",
            "Start": "시작",
            "Stop": "중지",
            "Read": "읽기",
            "Find": "찾기",
            "Get": "조회",
            "Install": "설치",
            "Cancel": "취소"
        ]
        return text(english, map[english] ?? english)
    }
}

/// Loads vehicles from the Fleet API for App Shortcut parameter pickers and
/// defaults to the app’s currently selected VIN.
public struct SelectedVehicleOptionsProvider: DynamicOptionsProvider {
    public init() {}

    public func results() async throws -> [VehicleEntity] {
        try await FleetIntentService.make().vehicles().map(VehicleEntity.init(info:))
    }

    public func defaultResult() async -> VehicleEntity? {
        let service = FleetIntentService.make()
        guard let vehicles = try? await service.vehicles(), !vehicles.isEmpty else {
            FleetKitLog.entities.warning("SelectedVehicleOptionsProvider has no vehicles for a default")
            return nil
        }
        if let vin = FleetSharedTokenStore.shared.selectedVIN(),
           let match = vehicles.first(where: { $0.vin == vin }) {
            FleetKitLog.entities.info("SelectedVehicleOptionsProvider default: \(match.name, privacy: .public) (shared selected VIN)")
            return VehicleEntity(info: match)
        }
        FleetKitLog.entities.info("SelectedVehicleOptionsProvider default: \(vehicles[0].name, privacy: .public) (first vehicle)")
        return VehicleEntity(info: vehicles[0])
    }
}

extension VehicleEntity {
    /// Siri/Shortcuts label for proactive suggestions when a vehicle is optional.
    static func predictionTitle(verb: String, vehicle: VehicleEntity?) -> LocalizedStringResource {
        let name = vehicle?.name ?? FleetCopy.text("my car", "내 차")
        let english = vehicle == nil ? "\(verb) my car" : "\(verb) \(name)"
        let korean = "\(name) \(FleetCopy.verb(verb))"
        return LocalizedStringResource(stringLiteral: FleetCopy.text(english, korean))
    }

    static func predictionTitle(verb: String, vehicle: VehicleEntity?, suffix: String) -> LocalizedStringResource {
        let name = vehicle?.name ?? FleetCopy.text("my car", "내 차")
        let englishSuffix = suffix
        let koreanSuffix = FleetCopy.text(suffix, FleetCopy.noun(suffix))
        let english = vehicle == nil ? "\(verb) my car \(englishSuffix)" : "\(verb) \(name) \(englishSuffix)"
        let korean = "\(name) \(koreanSuffix) \(FleetCopy.verb(verb))"
        return LocalizedStringResource(stringLiteral: FleetCopy.text(english, korean))
    }
}
