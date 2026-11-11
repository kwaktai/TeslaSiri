import Foundation
import OSLog

/// Intent-facing service. Resolves the target vehicle and exposes the reads and
/// control actions the intents need. Reads are side-effect-free (safe for
/// repeatedly performed snippet intents); writes are used by control intents.
public struct FleetIntentService: Sendable {
    private let client: FleetIntentClient
    private let tokenStore: FleetSharedTokenStore

    public init(client: FleetIntentClient = FleetIntentClient(), tokenStore: FleetSharedTokenStore = .shared) {
        self.client = client
        self.tokenStore = tokenStore
    }

    public static func make() -> FleetIntentService { FleetIntentService() }

    // MARK: - Resolution

    /// Resolves the vehicle an intent should act on. Falls back to the shared
    /// selected VIN, then to the first vehicle on the account.
    public func resolvedVehicle(_ requestedVIN: String?) async throws -> FleetVehicleInfo {
        let vehicles = try await client.vehicles()
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
        try await client.vehicles()
    }

    public func snapshot(vin: String) async throws -> FleetSnapshotInfo {
        try await client.snapshot(vin: vin)
    }

    public func units() async throws -> String? {
        try await client.user().units
    }

    public func drives(vin: String, limit: Int) async throws -> [FleetDriveInfo] {
        try await client.drives(vin: vin, limit: limit)
    }

    public func software(vin: String) async throws -> FleetSoftwareInfo {
        try await client.software(vin: vin)
    }

    public func releaseNotes(vin: String, version: String) async throws -> [FleetReleaseNoteInfo] {
        try await client.releaseNotes(vin: vin, version: version)
    }

    public func controlActions() async throws -> FleetControlActionsInfo {
        try await client.controlActions()
    }

    // MARK: - Writes

    /// Runs a control action after validating that the backend advertises it.
    public func runControl(
        action: String,
        vin: String,
        params: [String: FleetControlValue] = [:],
        humanName: String
    ) async throws {
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
        FleetKitLog.intents.notice("Software install requested for \(FleetKitLog.vin(vin), privacy: .public) (offset \(offsetSec, privacy: .public)s)")
        try await client.installSoftwareUpdate(vin: vin, offsetSec: offsetSec)
        FleetKitLog.intents.notice("Software install accepted for \(FleetKitLog.vin(vin), privacy: .public)")
    }

    public func cancelSoftwareUpdate(vin: String) async throws {
        FleetKitLog.intents.notice("Software install cancel requested for \(FleetKitLog.vin(vin), privacy: .public)")
        try await client.cancelSoftwareUpdate(vin: vin)
        FleetKitLog.intents.notice("Software install cancel accepted for \(FleetKitLog.vin(vin), privacy: .public)")
    }
}
