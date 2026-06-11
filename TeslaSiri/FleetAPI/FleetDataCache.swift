import Foundation

nonisolated struct FleetCachedState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 5

    var activeCharging: [FleetChargeSession]
    var activeDrivesByVIN: [String: FleetActiveDriveSession]
    var capabilities: FleetCapabilities?
    var cursor: Int64?
    var driveRoutesBySessionID: [String: [FleetRoutePoint]]
    var locationHistoryByVIN: [String: [FleetRoutePoint]]
    var recentDrives: [FleetDriveSession]
    var savedAt: Date
    var schemaVersion: Int
    var selectedVIN: String?
    var softwareUpdatesByVIN: [String: FleetSoftwareUpdate]
    var telemetrySeriesByVIN: [String: [FleetTelemetrySeriesPoint]]
    var user: FleetUser?
    var vehicles: [FleetVehicle]

    enum CodingKeys: String, CodingKey {
        case activeCharging
        case activeDrivesByVIN
        case capabilities
        case cursor
        case driveRoutesBySessionID
        case locationHistoryByVIN
        case recentDrives
        case savedAt
        case schemaVersion
        case selectedVIN
        case softwareUpdatesByVIN
        case telemetrySeriesByVIN
        case user
        case vehicles
    }

    init(
        activeCharging: [FleetChargeSession] = [],
        activeDrivesByVIN: [String: FleetActiveDriveSession] = [:],
        capabilities: FleetCapabilities? = nil,
        cursor: Int64? = nil,
        driveRoutesBySessionID: [String: [FleetRoutePoint]] = [:],
        locationHistoryByVIN: [String: [FleetRoutePoint]] = [:],
        recentDrives: [FleetDriveSession] = [],
        savedAt: Date,
        schemaVersion: Int = FleetCachedState.currentSchemaVersion,
        selectedVIN: String? = nil,
        softwareUpdatesByVIN: [String: FleetSoftwareUpdate] = [:],
        telemetrySeriesByVIN: [String: [FleetTelemetrySeriesPoint]] = [:],
        user: FleetUser? = nil,
        vehicles: [FleetVehicle] = []
    ) {
        self.activeCharging = activeCharging
        self.activeDrivesByVIN = activeDrivesByVIN
        self.capabilities = capabilities
        self.cursor = cursor
        self.driveRoutesBySessionID = driveRoutesBySessionID
        self.locationHistoryByVIN = locationHistoryByVIN
        self.recentDrives = recentDrives
        self.savedAt = savedAt
        self.schemaVersion = schemaVersion
        self.selectedVIN = selectedVIN
        self.softwareUpdatesByVIN = softwareUpdatesByVIN
        self.telemetrySeriesByVIN = telemetrySeriesByVIN
        self.user = user
        self.vehicles = vehicles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeCharging = try container.decodeIfPresent([FleetChargeSession].self, forKey: .activeCharging) ?? []
        activeDrivesByVIN = try container.decodeIfPresent([String: FleetActiveDriveSession].self, forKey: .activeDrivesByVIN) ?? [:]
        capabilities = try container.decodeIfPresent(FleetCapabilities.self, forKey: .capabilities)
        cursor = try container.decodeIfPresent(Int64.self, forKey: .cursor)
        driveRoutesBySessionID = try container.decodeIfPresent([String: [FleetRoutePoint]].self, forKey: .driveRoutesBySessionID) ?? [:]
        locationHistoryByVIN = try container.decodeIfPresent([String: [FleetRoutePoint]].self, forKey: .locationHistoryByVIN) ?? [:]
        recentDrives = try container.decodeIfPresent([FleetDriveSession].self, forKey: .recentDrives) ?? []
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? .distantPast
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        selectedVIN = try container.decodeIfPresent(String.self, forKey: .selectedVIN)
        softwareUpdatesByVIN = try container.decodeIfPresent([String: FleetSoftwareUpdate].self, forKey: .softwareUpdatesByVIN) ?? [:]
        telemetrySeriesByVIN = try container.decodeIfPresent([String: [FleetTelemetrySeriesPoint]].self, forKey: .telemetrySeriesByVIN) ?? [:]
        user = try container.decodeIfPresent(FleetUser.self, forKey: .user)
        vehicles = try container.decodeIfPresent([FleetVehicle].self, forKey: .vehicles) ?? []
    }
}

protocol FleetDataCaching: Sendable {
    func load() async throws -> FleetCachedState?
    func save(_ state: FleetCachedState) async throws
    func clear() async throws
}

nonisolated struct FleetNoDataCache: FleetDataCaching {
    func load() async throws -> FleetCachedState? {
        nil
    }

    func save(_ state: FleetCachedState) async throws {}

    func clear() async throws {}
}

actor FleetDiskCache: FleetDataCaching {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileName: String

    init(fileName: String = "fleet-cache.json") {
        self.fileName = fileName
    }

    func load() async throws -> FleetCachedState? {
        let url = try cacheFileURL(createDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(FleetCachedState.self, from: data)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    func save(_ state: FleetCachedState) async throws {
        let url = try cacheFileURL(createDirectory: true)
        let data = try encoder.encode(state)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try? excludeFromBackup(url)
    }

    func clear() async throws {
        let url = try cacheFileURL(createDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    private func cacheFileURL(createDirectory: Bool) throws -> URL {
        let fileManager = FileManager.default
        let directory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createDirectory
        )
        .appendingPathComponent("Fleet", isDirectory: true)

        if createDirectory {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try? excludeFromBackup(directory)
        }

        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try mutableURL.setResourceValues(resourceValues)
    }
}
