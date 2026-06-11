import AppIntents
import CoreSpotlight

/// Donates the app's entities to a named Spotlight index so vehicles, drives,
/// status, and release notes are findable in Spotlight search. Self-contained:
/// fetches via `FleetIntentService` so the app can call it without mapping its
/// own models.
public enum FleetSpotlightIndexer {
    private static let indexName = "FleetEntities"

    public static func reindexAll() async {
        let service = FleetIntentService.make()
        guard let vehicles = try? await service.vehicles(), !vehicles.isEmpty else { return }

        var statuses: [VehicleStatusEntity] = []
        var drives: [DriveEntity] = []
        var software: [SoftwareUpdateEntity] = []
        var notes: [ReleaseNoteEntity] = []

        for vehicle in vehicles {
            if let snapshot = try? await service.snapshot(vin: vehicle.vin) {
                statuses.append(VehicleStatusEntity(snapshot: snapshot, vehicleName: vehicle.name))
            }
            if let recent = try? await service.drives(vin: vehicle.vin, limit: 20) {
                drives.append(contentsOf: recent.map(DriveEntity.init(info:)))
            }
            if let info = try? await service.software(vin: vehicle.vin) {
                software.append(SoftwareUpdateEntity(info: info, vin: vehicle.vin, vehicleName: vehicle.name))
                notes.append(contentsOf: info.releaseNotes.map(ReleaseNoteEntity.init(info:)))
            }
        }

        let index = CSSearchableIndex(name: indexName)
        try? await index.indexAppEntities(vehicles.map(VehicleEntity.init(info:)))
        try? await index.indexAppEntities(statuses)
        try? await index.indexAppEntities(drives)
        try? await index.indexAppEntities(software)
        try? await index.indexAppEntities(notes)
    }
}
