import AppIntents
import Foundation
import SwiftUI

// MARK: - Interactive Drive Route Snippet Intent

/// Presents an interactive Apple Maps drive route widget in Siri, supporting live
/// Map/Satellite toggling and stepping through multiple matched drives in place.
public struct DriveRouteSnippetIntent: SnippetIntent {
    public static let title: LocalizedStringResource = "Drive Route Card"
    public static let isDiscoverable = false

    @Parameter(title: "Drives")
    public var drives: [DriveEntity]

    @Parameter(title: "Vehicle Name")
    public var vehicleName: String

    @Parameter(title: "Session Key")
    public var sessionKey: String

    public init() {
        self.drives = []
        self.vehicleName = "My Car"
        self.sessionKey = "default"
    }

    public init(drives: [DriveEntity], vehicleName: String, sessionKey: String = "latest") {
        self.drives = drives
        self.vehicleName = vehicleName
        self.sessionKey = sessionKey
        SiriSnippetStateStore.shared.setSelectedDriveIndex(0, for: sessionKey)
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ShowsSnippetView {
        guard !drives.isEmpty else {
            return .result(
                view: EmptyDriveSnippetView(vehicleName: vehicleName)
            )
        }

        let store = SiriSnippetStateStore.shared
        let index = store.selectedDriveIndex(for: sessionKey, count: drives.count)
        let activeDrive = drives[index]
        let style = store.mapStyle(for: "drive")
        let allowMap = FleetIntentService.testingOverride == nil

        let mapData = await SiriMapSnapshotRenderer.renderDriveRoute(
            for: activeDrive,
            service: .make(),
            style: style,
            allowNetworkSnapshot: allowMap
        )

        return .result(
            view: DriveSnippetView(
                drive: activeDrive,
                allDrives: drives,
                selectedIndex: index,
                sessionKey: sessionKey,
                vehicleName: vehicleName,
                mapData: mapData
            )
        )
    }
}

// MARK: - Interactive Charge Session Snippet Intent

/// Presents an interactive charging session card with Apple Maps charger location,
/// battery fill bar, and multi-session stepping inside Siri.
public struct ChargeSessionSnippetIntent: SnippetIntent {
    public static let title: LocalizedStringResource = "Charging Session Card"
    public static let isDiscoverable = false

    @Parameter(title: "Sessions")
    public var sessions: [ChargeSessionEntity]

    @Parameter(title: "Vehicle Name")
    public var vehicleName: String

    @Parameter(title: "Session Key")
    public var sessionKey: String

    public init() {
        self.sessions = []
        self.vehicleName = "My Car"
        self.sessionKey = "charge-default"
    }

    public init(sessions: [ChargeSessionEntity], vehicleName: String, sessionKey: String = "charge-latest") {
        self.sessions = sessions
        self.vehicleName = vehicleName
        self.sessionKey = sessionKey
        SiriSnippetStateStore.shared.setSelectedDriveIndex(0, for: sessionKey)
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ShowsSnippetView {
        guard !sessions.isEmpty else {
            return .result(
                view: EmptyChargeSnippetView(vehicleName: vehicleName)
            )
        }

        let store = SiriSnippetStateStore.shared
        let index = store.selectedDriveIndex(for: sessionKey, count: sessions.count)
        let active = sessions[index]
        let style = store.mapStyle(for: "charge")
        let allowMap = FleetIntentService.testingOverride == nil
        let accent: UInt32 = active.isSupercharger ? 0xFF3B30 : 0x30D158

        let mapData = await SiriMapSnapshotRenderer.renderLocationPin(
            latitude: active.latitude,
            longitude: active.longitude,
            fallbackPlaceQuery: active.location,
            style: style,
            accentHex: accent,
            allowNetworkSnapshot: allowMap
        )

        return .result(
            view: ChargeSessionSnippetView(
                session: active,
                allSessions: sessions,
                selectedIndex: index,
                sessionKey: sessionKey,
                vehicleName: vehicleName,
                mapData: mapData
            )
        )
    }
}

// MARK: - Interactive Cabin Climate Snippet Intent

/// Presents a live Cabin Climate widget in Siri after warming up, cooling down,
/// or configuring cabin climate, with interactive temperature +/- and off controls.
public struct ClimateControlSnippetIntent: SnippetIntent {
    public static let title: LocalizedStringResource = "Cabin Climate Card"
    public static let isDiscoverable = false

    @Parameter(title: "Vehicle")
    public var vehicle: VehicleEntity

    @Parameter(title: "Applied Summary")
    public var appliedSummary: String

    public init() {
        self.vehicle = VehicleEntity(id: "", name: "My Car")
        self.appliedSummary = "Climate updated"
    }

    public init(vehicle: VehicleEntity, appliedSummary: String) {
        self.vehicle = vehicle
        self.appliedSummary = appliedSummary
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ShowsSnippetView {
        let service = FleetIntentService.make()
        let snapshot = try? await service.snapshot(vin: vehicle.id)
        let status = snapshot.map { VehicleStatusEntity(snapshot: $0, vehicleName: vehicle.name) }
        return .result(
            view: ClimateControlSnippetView(
                vehicle: vehicle,
                status: status,
                appliedSummary: appliedSummary
            )
        )
    }
}

// MARK: - Snippet In-Place Interactive Button Intents

/// Toggles Standard vs Satellite Apple Maps imagery inside Siri snippets and reloads in place.
public struct ToggleSnippetMapStyleIntent: AppIntent {
    public static let title: LocalizedStringResource = "Toggle Snippet Map Style"
    public static let isDiscoverable = false

    @Parameter(title: "Scope")
    public var scope: String

    public init() {
        self.scope = "drive"
    }

    public init(scope: String) {
        self.scope = scope
    }

    public func perform() async throws -> some IntentResult {
        SiriSnippetStateStore.shared.toggleMapStyle(for: scope)
        switch scope {
        case "drive": DriveRouteSnippetIntent.reload()
        case "charge": ChargeSessionSnippetIntent.reload()
        case "vehicle": GetVehicleStatusIntent.reload()
        default:
            DriveRouteSnippetIntent.reload()
            ChargeSessionSnippetIntent.reload()
            GetVehicleStatusIntent.reload()
        }
        return .result()
    }
}

/// Steps between multiple drives or charging sessions directly inside a Siri snippet card.
public struct SelectSnippetItemIntent: AppIntent {
    public static let title: LocalizedStringResource = "Select Snippet Item"
    public static let isDiscoverable = false

    @Parameter(title: "Session Key")
    public var sessionKey: String

    @Parameter(title: "Target Index")
    public var targetIndex: Int

    @Parameter(title: "Card Type")
    public var cardType: String?

    public init() {
        self.sessionKey = "latest"
        self.targetIndex = 0
    }

    public init(sessionKey: String, targetIndex: Int, cardType: String? = nil) {
        self.sessionKey = sessionKey
        self.targetIndex = targetIndex
        self.cardType = cardType
    }

    public func perform() async throws -> some IntentResult {
        SiriSnippetStateStore.shared.setSelectedDriveIndex(targetIndex, for: sessionKey)
        switch cardType {
        case "drive": DriveRouteSnippetIntent.reload()
        case "charge": ChargeSessionSnippetIntent.reload()
        default:
            DriveRouteSnippetIntent.reload()
            ChargeSessionSnippetIntent.reload()
        }
        return .result()
    }
}

/// Nudges target cabin temperature up/down or turns HVAC off from inside the Siri Climate snippet.
public struct AdjustSnippetClimateIntent: AppIntent {
    public static let title: LocalizedStringResource = "Adjust Cabin Climate"
    public static let isDiscoverable = false

    @Parameter(title: "Vehicle")
    public var vehicle: VehicleEntity

    @Parameter(title: "Target Fahrenheit")
    public var targetFahrenheit: Double

    @Parameter(title: "Turn Off")
    public var turnOff: Bool

    public init() {
        self.vehicle = VehicleEntity(id: "", name: "My Car")
        self.targetFahrenheit = 70
        self.turnOff = false
    }

    public init(vehicle: VehicleEntity, targetFahrenheit: Double = 70, turnOff: Bool = false) {
        self.vehicle = vehicle
        self.targetFahrenheit = targetFahrenheit
        self.turnOff = turnOff
    }

    public func perform() async throws -> some IntentResult {
        let service = FleetIntentService.make()
        if turnOff {
            try await service.runControl(
                action: "auto_conditioning_stop",
                vin: vehicle.id,
                humanName: "stopping climate"
            )
        } else {
            let celsius = SetCabinTemperatureIntent.targetCelsius(
                for: Measurement(value: targetFahrenheit, unit: UnitTemperature.fahrenheit)
            )
            try await service.runControl(
                action: "auto_conditioning_start",
                vin: vehicle.id,
                humanName: "starting climate"
            )
            try await service.runControl(
                action: "set_temps",
                vin: vehicle.id,
                params: [
                    "driver_temp": .double(celsius),
                    "passenger_temp": .double(celsius)
                ],
                humanName: "setting the cabin temperature"
            )
        }
        SiriSnippetStateStore.shared.notifyChanged(.vehicleStatus(vin: vehicle.id))
        ClimateControlSnippetIntent.reload()
        GetVehicleStatusIntent.reload()
        return .result()
    }
}
