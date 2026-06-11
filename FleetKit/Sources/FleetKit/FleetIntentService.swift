import Foundation

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
            return match
        }
        guard let first = vehicles.first else {
            throw FleetKitError.api("No Tesla vehicles were found on your account.")
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
            throw FleetKitError.unsupportedAction(humanName)
        }
        try await client.runControl(action: action, vin: vin, params: params)
    }

    public func installSoftwareUpdate(vin: String, offsetSec: Int) async throws {
        try await client.installSoftwareUpdate(vin: vin, offsetSec: offsetSec)
    }

    public func cancelSoftwareUpdate(vin: String) async throws {
        try await client.cancelSoftwareUpdate(vin: vin)
    }
}
