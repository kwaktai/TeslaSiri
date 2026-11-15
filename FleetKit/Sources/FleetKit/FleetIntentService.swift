import AppIntents
import Foundation
import OSLog

/// Intent-facing service. Resolves the target vehicle and exposes the reads and
/// control actions the intents need. Reads are side-effect-free (safe for
/// repeatedly performed snippet intents); writes are used by control intents.
public struct FleetIntentService: Sendable {
    @TaskLocal static var testingOverride: FleetIntentService?
    @TaskLocal public static var sandboxConfirmationRecorder: (@Sendable (String) -> Void)?

    private let client: FleetIntentClient
    private let tokenStore: FleetSharedTokenStore
    private let sandbox: FleetSandboxStore?

    public init(
        client: FleetIntentClient = FleetIntentClient(),
        tokenStore: FleetSharedTokenStore = .shared,
        sandbox: FleetSandboxStore? = nil
    ) {
        self.client = client
        self.tokenStore = tokenStore
        self.sandbox = sandbox
    }

    public static func make() -> FleetIntentService {
        testingOverride ?? FleetIntentService(sandbox: .shared)
    }

    private var sandboxMode: FleetSandboxMode {
        sandbox?.mode() ?? .live
    }

    // MARK: - Resolution

    /// Resolves the vehicle an intent should act on. Falls back to the shared
    /// selected VIN, then to the first vehicle on the account.
    public func resolvedVehicle(_ requestedVIN: String?) async throws -> FleetVehicleInfo {
        let vehicles = try await self.vehicles()
        let preferred = requestedVIN ?? tokenStore.selectedVIN()
        if let preferred, let match = vehicles.first(where: { $0.vin == preferred }) {
            let source = requestedVIN != nil ? "intent parameter" : "shared selected VIN"
            FleetKitLog.intents.info("Resolved vehicle \(match.name, privacy: .public) (\(FleetKitLog.vin(match.vin), privacy: .public)) via \(source, privacy: .public)")
            return match
        }
        guard let first = vehicles.first else {
            FleetKitLog.intents.error("Vehicle resolution failed: account returned no vehicles")
            throw FleetKitError.api("No Tesla vehicles were found on your account.")
        }
        if let preferred {
            FleetKitLog.intents.warning("Preferred VIN \(FleetKitLog.vin(preferred), privacy: .public) not on account; falling back to \(first.name, privacy: .public)")
        } else {
            FleetKitLog.intents.info("Resolved vehicle \(first.name, privacy: .public) (first of \(vehicles.count, privacy: .public))")
        }
        return first
    }

    // MARK: - Reads

    public func vehicles() async throws -> [FleetVehicleInfo] {
        if let sandbox, sandbox.mode() == .demoVehicle {
            return [sandbox.demoState().vehicleInfo]
        }
        return try await client.vehicles()
    }

    public func snapshot(vin: String) async throws -> FleetSnapshotInfo {
        if let sandbox, sandbox.mode() == .demoVehicle {
            return sandbox.demoState().snapshotInfo
        }
        return try await client.snapshot(vin: vin)
    }

    func snapshotAndSoftware(vin: String) async throws -> (snapshot: FleetSnapshotInfo, software: FleetSoftwareInfo) {
        if let sandbox, sandbox.mode() == .demoVehicle {
            let state = sandbox.demoState()
            return (state.snapshotInfo, state.softwareInfo)
        }
        return try await client.snapshotAndSoftware(vin: vin)
    }

    public func units() async throws -> String? {
        if let sandbox, sandbox.mode() == .demoVehicle {
            return "imperial"
        }
        return try await client.user().units
    }

    public func drives(
        vin: String,
        limit: Int,
        from: Date? = nil,
        to: Date? = nil,
        tag: String? = nil
    ) async throws -> [FleetDriveInfo] {
        if let sandbox, sandbox.mode() == .demoVehicle {
            let normalizedTag = tag?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let filtered = FleetDemoVehicleState.demoDrives(vin: vin).filter { drive in
                if let from, drive.startedAtDate < from { return false }
                if let to, drive.startedAtDate > to { return false }
                if let normalizedTag, !normalizedTag.isEmpty {
                    guard drive.tag?.lowercased().contains(normalizedTag) == true else { return false }
                }
                return true
            }
            return Array(filtered.prefix(max(limit, 0)))
        }
        return try await client.drives(vin: vin, limit: limit, from: from, to: to, tag: tag)
    }

    public func drivePath(
        vin: String,
        driveID: String? = nil,
        from: Date,
        to: Date,
        maxPoints: Int = 72
    ) async throws -> [FleetDriveRoutePoint] {
        if let sandbox, sandbox.mode() == .demoVehicle {
            return FleetDemoVehicleState.demoDrivePath(driveID: driveID, from: from, to: to)
        }
        return try await client.drivePath(vin: vin, from: from, to: to, maxPoints: maxPoints)
    }

    public func charges(
        vin: String,
        limit: Int,
        from: Date? = nil,
        to: Date? = nil
    ) async throws -> [FleetChargeInfo] {
        if let sandbox, sandbox.mode() == .demoVehicle {
            let filtered = FleetDemoVehicleState.demoCharges(vin: vin).filter { charge in
                if let from, charge.startedAtDate < from { return false }
                if let to, charge.startedAtDate > to { return false }
                return true
            }
            return Array(filtered.prefix(max(limit, 0)))
        }
        return try await client.charges(vin: vin, limit: limit, from: from, to: to)
    }

    public func batteryHealth(vin: String) async throws -> FleetBatteryHealthInfo {
        if let sandbox, sandbox.mode() == .demoVehicle {
            let state = sandbox.demoState()
            return FleetDemoVehicleState.demoBatteryHealth(vin: vin, odometerMiles: state.odometerMiles)
        }
        return try await client.batteryHealth(vin: vin)
    }

    public func consumptionSinceCharge(vin: String) async throws -> FleetConsumptionInfo {
        if let sandbox, sandbox.mode() == .demoVehicle {
            return FleetDemoVehicleState.demoConsumption()
        }
        return try await client.consumptionSinceCharge(vin: vin)
    }

    public func software(vin: String) async throws -> FleetSoftwareInfo {
        if let sandbox, sandbox.mode() == .demoVehicle {
            return sandbox.demoState().softwareInfo
        }
        return try await client.software(vin: vin)
    }

    public func releaseNotes(vin: String, version: String) async throws -> [FleetReleaseNoteInfo] {
        if let sandbox, sandbox.mode() == .demoVehicle {
            return FleetDemoVehicleState.demoReleaseNotes(version: version)
        }
        return try await client.releaseNotes(vin: vin, version: version)
    }

    public func controlActions() async throws -> FleetControlActionsInfo {
        if let sandbox, sandbox.mode() == .demoVehicle {
            return FleetDemoVehicleState.supportedControlActions
        }
        return try await client.controlActions()
    }

    // MARK: - Writes

    /// Runs a control action after validating that the backend advertises it.
    public func runControl(
        action: String,
        vin: String,
        params: [String: FleetControlValue] = [:],
        humanName: String
    ) async throws {
        if let sandbox, sandbox.mode().interceptsWrites {
            let available: FleetControlActionsInfo
            if sandbox.mode() == .demoVehicle {
                available = FleetDemoVehicleState.supportedControlActions
            } else {
                available = (try? await client.controlActions()) ?? FleetDemoVehicleState.supportedControlActions
            }
            guard available.supports(action) else {
                FleetKitLog.intents.error("Sandbox control '\(action, privacy: .public)' rejected for \(FleetKitLog.vin(vin), privacy: .public): unsupported")
                throw FleetKitError.unsupportedAction(humanName)
            }
            let vehicleName = await resolveVehicleDisplayName(for: vin, sandbox: sandbox)
            sandbox.recordSimulatedControl(
                action: action,
                vin: vin,
                vehicleName: vehicleName,
                params: params,
                source: "Siri"
            )
            FleetKitLog.intents.notice("Sandbox (\(sandbox.mode().rawValue, privacy: .public)) simulated '\(action, privacy: .public)' for \(FleetKitLog.vin(vin), privacy: .public)")
            return
        }

        let available = try await client.controlActions()
        guard available.supports(action) else {
            FleetKitLog.intents.error("Control '\(action, privacy: .public)' rejected for \(FleetKitLog.vin(vin), privacy: .public): backend does not advertise it")
            throw FleetKitError.unsupportedAction(humanName)
        }
        let paramKeys = params.keys.sorted().joined(separator: ",")
        FleetKitLog.intents.notice("Control '\(action, privacy: .public)' running on \(FleetKitLog.vin(vin), privacy: .public) params: [\(paramKeys, privacy: .public)]")
        try await client.runControl(action: action, vin: vin, params: params)
        FleetKitLog.intents.notice("Control '\(action, privacy: .public)' accepted for \(FleetKitLog.vin(vin), privacy: .public)")
    }

    public func installSoftwareUpdate(vin: String, offsetSec: Int) async throws {
        if let sandbox, sandbox.mode().interceptsWrites {
            let vehicleName = await resolveVehicleDisplayName(for: vin, sandbox: sandbox)
            sandbox.recordSimulatedSoftwareAction(
                isInstall: true,
                vin: vin,
                vehicleName: vehicleName,
                offsetSec: offsetSec,
                source: "Siri"
            )
            FleetKitLog.intents.notice("Sandbox (\(sandbox.mode().rawValue, privacy: .public)) simulated software install for \(FleetKitLog.vin(vin), privacy: .public)")
            return
        }
        FleetKitLog.intents.notice("Software install requested for \(FleetKitLog.vin(vin), privacy: .public) (offset \(offsetSec, privacy: .public)s)")
        try await client.installSoftwareUpdate(vin: vin, offsetSec: offsetSec)
        FleetKitLog.intents.notice("Software install accepted for \(FleetKitLog.vin(vin), privacy: .public)")
    }

    public func cancelSoftwareUpdate(vin: String) async throws {
        if let sandbox, sandbox.mode().interceptsWrites {
            let vehicleName = await resolveVehicleDisplayName(for: vin, sandbox: sandbox)
            sandbox.recordSimulatedSoftwareAction(
                isInstall: false,
                vin: vin,
                vehicleName: vehicleName,
                source: "Siri"
            )
            FleetKitLog.intents.notice("Sandbox (\(sandbox.mode().rawValue, privacy: .public)) simulated software cancel for \(FleetKitLog.vin(vin), privacy: .public)")
            return
        }
        FleetKitLog.intents.notice("Software install cancel requested for \(FleetKitLog.vin(vin), privacy: .public)")
        try await client.cancelSoftwareUpdate(vin: vin)
        FleetKitLog.intents.notice("Software install cancel accepted for \(FleetKitLog.vin(vin), privacy: .public)")
    }

    private func resolveVehicleDisplayName(for vin: String, sandbox: FleetSandboxStore) async -> String {
        if sandbox.mode() == .demoVehicle {
            return sandbox.demoState().displayName
        }
        if let match = try? await client.vehicles().first(where: { $0.vin == vin }) {
            return match.name
        }
        return FleetKitLog.vin(vin)
    }
}

extension AppIntent {
    func confirmWithSafetyGate(dialog: IntentDialog) async throws {
        let canAutoApprove = FleetIntentService.testingOverride != nil
            || FleetSandboxStore.shared.mode() != .live
        if canAutoApprove, let recorder = FleetIntentService.sandboxConfirmationRecorder {
            recorder(String(describing: dialog))
            return
        }
        try await requestConfirmation(dialog: dialog)
    }
}

extension LongRunningIntent {
    func performSandboxAwareBackgroundTask(_ work: @escaping @Sendable () async throws -> Void) async throws {
        let canRunInline = FleetIntentService.testingOverride != nil
            || FleetSandboxStore.shared.mode() != .live
        if canRunInline, FleetIntentService.sandboxConfirmationRecorder != nil {
            try await work()
            return
        }
        try await performBackgroundTask(operation: work)
    }
}

