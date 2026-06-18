import Foundation
import Observation

protocol FleetDataLoading {
    func activeDrive(vin: String, includeRoute: Bool, routeMaxPoints: Int?) async throws -> FleetAPIPage<FleetActiveDriveSession>
    func bootstrap() async throws -> FleetAPIPage<FleetBootstrap>
    func chargingSessions(vin: String, limit: Int?) async throws -> FleetAPIPage<[FleetChargeSession]>
    func capabilities() async throws -> FleetAPIPage<FleetCapabilities>
    func changes(since cursor: Int64) async throws -> FleetAPIPage<FleetSyncChanges>
    func driveRoute(sessionID: String, startTime: Int64?, endTime: Int64?, limit: Int?, maxPoints: Int?) async throws -> FleetAPIPage<[FleetRoutePoint]>
    func drives(vin: String, limit: Int?, includeRoute: Bool) async throws -> FleetAPIPage<[FleetDriveSession]>
    func latestSnapshot(vin: String) async throws -> FleetAPIPage<FleetLatestSnapshot>
    func locations(vin: String, startTime: Int64?, endTime: Int64?, limit: Int?) async throws -> FleetAPIPage<[FleetRoutePoint]>
    func softwareUpdate(vin: String, includeReleaseNotes: Bool, refresh: Bool) async throws -> FleetAPIPage<FleetSoftwareUpdate>
    func installSoftwareUpdate(vin: String, offsetSec: Int) async throws -> FleetAPIPage<[String: JSONValue]>
    func cancelSoftwareUpdate(vin: String) async throws -> FleetAPIPage<[String: JSONValue]>
    func rawVehicleDataExport(vin: String) async throws -> FleetRawDataExport
    func runControl(
        action: String,
        vin: String,
        params: [String: JSONValue]
    ) async throws -> FleetAPIPage<[String: JSONValue]>
    func telemetrySeries(
        vin: String,
        topic: String?,
        startTime: Int64?,
        endTime: Int64?,
        limit: Int?,
        maxPoints: Int?,
        fields: [String]
    ) async throws -> FleetAPIPage<[FleetTelemetrySeriesPoint]>
}

extension FleetAPIClient: FleetDataLoading {}

@MainActor
@Observable
final class FleetDataStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)

        var isLoading: Bool {
            if case .loading = self {
                return true
            }
            return false
        }
    }

    private enum LoadingKind: Hashable {
        case activeDrive
        case charging
        case drives
        case software
        case telemetry
    }

    @ObservationIgnored private let apiClient: any FleetDataLoading
    @ObservationIgnored private let cache: any FleetDataCaching
    @ObservationIgnored private var loadingCounts: [LoadingKind: Int] = [:]
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var selectionRefreshTask: Task<Void, Never>?

    private(set) var activeCharging: [FleetChargeSession] = []
    private(set) var activeControlAction: String?
    private(set) var activeDrivesByVIN: [String: FleetActiveDriveSession] = [:]
    private(set) var cacheDate: Date?
    private(set) var capabilities: FleetCapabilities?
    private(set) var cursor: Int64?
    private(set) var driveRoutesBySessionID: [String: [FleetRoutePoint]] = [:]
    private(set) var isExportingRawData = false
    private(set) var isLoadingActiveDrive = false
    private(set) var isLoadingCharging = false
    private(set) var isLoadingDrives = false
    private(set) var isLoadingSoftware = false
    private(set) var isLoadingTelemetry = false
    private(set) var isMutatingSoftware = false
    private(set) var isRefreshing = false
    private(set) var isRunningControl = false
    private(set) var isShowingCachedData = false
    private(set) var lastErrorMessage: String?
    private(set) var lastRefreshDate: Date?
    private(set) var lastRequestID: String?
    private(set) var loadState: LoadState = .idle
    private(set) var locationHistoryByVIN: [String: [FleetRoutePoint]] = [:]
    private(set) var rawDataExportMessage = "Not run"
    private(set) var rawDataExportURL: URL?
    private(set) var recentDrives: [FleetDriveSession] = []
    private(set) var softwareActionMessage = "Not run"
    private(set) var softwareUpdatesByVIN: [String: FleetSoftwareUpdate] = [:]
    private(set) var telemetrySeriesByVIN: [String: [FleetTelemetrySeriesPoint]] = [:]
    private(set) var user: FleetUser?
    private(set) var vehicleControlMessage: String?
    private(set) var vehicles: [FleetVehicle] = []

    var selectedVIN: String?

    var latestSnapshotsByVIN: [String: FleetLatestSnapshot] {
        Dictionary(uniqueKeysWithValues: vehicles.compactMap { vehicle in
            guard let latest = vehicle.latest else {
                return nil
            }
            return (vehicle.vin, latest)
        })
    }

    var selectedVehicle: FleetVehicle? {
        guard let selectedVIN else {
            return vehicles.first
        }
        return vehicles.first { $0.vin == selectedVIN } ?? vehicles.first
    }

    var selectedVehicleRecentDrives: [FleetDriveSession] {
        guard let selectedVIN = selectedVehicle?.vin else {
            return recentDrives
        }
        return recentDrives.filter { $0.vin == selectedVIN }
    }

    var selectedVehicleActiveDrive: FleetActiveDriveSession? {
        guard let selectedVIN = selectedVehicle?.vin else {
            return nil
        }
        return activeDrivesByVIN[selectedVIN]
    }

    var selectedVehicleLocationHistory: [FleetRoutePoint] {
        guard let selectedVIN = selectedVehicle?.vin else {
            return []
        }
        return locationHistoryByVIN[selectedVIN] ?? []
    }

    var selectedVehicleTelemetrySeries: [FleetTelemetrySeriesPoint] {
        guard let selectedVIN = selectedVehicle?.vin else {
            return []
        }
        return telemetrySeriesByVIN[selectedVIN] ?? []
    }

    var selectedVehicleSoftwareUpdate: FleetSoftwareUpdate? {
        guard let selectedVehicle else {
            return nil
        }
        return softwareUpdatesByVIN[selectedVehicle.vin] ?? selectedVehicle.latest?.software
    }

    var cachedDriveRouteCount: Int {
        driveRoutesBySessionID.values.reduce(0) { $0 + $1.count }
    }

    init(apiClient: any FleetDataLoading, cache: any FleetDataCaching = FleetNoDataCache()) {
        self.apiClient = apiClient
        self.cache = cache
    }

    func startPolling(interval: TimeInterval = 60) {
        guard pollingTask == nil else {
            return
        }

        let pollingInterval = max(interval, 15)
        pollingTask = Task { [weak self] in
            await self?.pollFleetData(every: pollingInterval)
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func loadInitialDataIfNeeded() async {
        guard vehicles.isEmpty, !loadState.isLoading else {
            return
        }

        await hydrateFromCacheIfAvailable()

        if vehicles.isEmpty {
            await loadInitialData()
        } else {
            await refresh()
        }
    }

    func loadInitialData() async {
        guard !loadState.isLoading else {
            return
        }

        loadState = .loading
        lastErrorMessage = nil

        do {
            let page = try await apiClient.bootstrap()
            applyBootstrap(page.data, cursor: page.cursor, requestID: page.requestID, isCached: false)
            await refreshCapabilitiesIfNeeded()
            await loadSelectedVehicleActiveDriveIfNeeded()
            await loadSelectedVehicleChargingSessionsIfNeeded()
            await loadSelectedVehicleSoftwareIfNeeded()
            await loadSelectedVehicleDrivesIfNeeded()
            await loadSelectedVehicleTelemetryIfNeeded()
            await saveCurrentState()
            loadState = .loaded
        } catch {
            let message = error.localizedDescription
            lastErrorMessage = message
            loadState = vehicles.isEmpty ? .failed(message) : .loaded
        }
    }

    func refresh() async {
        guard let cursor else {
            await loadInitialData()
            return
        }

        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        lastErrorMessage = nil
        defer { isRefreshing = false }

        do {
            let page = try await apiClient.changes(since: cursor)
            mergeLatestSnapshots(page.data.latest)
            self.cursor = page.cursor ?? cursor
            isShowingCachedData = false
            lastRequestID = page.requestID
            lastRefreshDate = Date()
            loadState = .loaded
            await refreshSelectedVehicleLive()
            await refreshSelectedVehicleActiveDrive()
            await refreshSelectedVehicleChargingSessions()
            await refreshSelectedVehicleSoftware()
            await refreshSelectedVehicleDrives()
            await refreshSelectedVehicleTelemetry()
            await saveCurrentState()
        } catch {
            let message = error.localizedDescription
            lastErrorMessage = message
            if vehicles.isEmpty {
                loadState = .failed(message)
            }
        }
    }

    func selectVehicle(vin: String) {
        guard vehicles.contains(where: { $0.vin == vin }) else {
            return
        }
        selectedVIN = vin
        selectionRefreshTask?.cancel()
        selectionRefreshTask = Task {
            await saveCurrentState()
            guard !Task.isCancelled else { return }
            await refreshSelectedVehicleLive()
            guard !Task.isCancelled else { return }
            await refreshSelectedVehicleActiveDrive()
            guard !Task.isCancelled else { return }
            await refreshSelectedVehicleChargingSessions()
            guard !Task.isCancelled else { return }
            await refreshSelectedVehicleSoftware()
            guard !Task.isCancelled else { return }
            await refreshSelectedVehicleDrives()
            guard !Task.isCancelled else { return }
            await refreshSelectedVehicleTelemetry()
        }
    }

    func refreshSelectedVehicleLive() async {
        guard let vin = selectedVehicle?.vin else {
            return
        }

        do {
            let page = try await apiClient.latestSnapshot(vin: vin)
            var snapshot = page.data
            if snapshot.vin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                snapshot.vin = vin
            }
            mergeLatestSnapshots([snapshot])
            lastErrorMessage = nil
            lastRequestID = page.requestID ?? lastRequestID
            lastRefreshDate = Date()
            await saveCurrentState()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func runSelectedVehicleControl(
        action: String,
        params: [String: JSONValue] = [:]
    ) async -> Bool {
        guard let vin = selectedVehicle?.vin, !isRunningControl else {
            return false
        }

        activeControlAction = action
        isRunningControl = true
        vehicleControlMessage = "Sending command…"
        defer {
            activeControlAction = nil
            isRunningControl = false
        }

        do {
            let page = try await apiClient.runControl(action: action, vin: vin, params: params)
            lastErrorMessage = nil
            lastRequestID = page.requestID ?? lastRequestID
            vehicleControlMessage = "Command sent"
            await refreshSelectedVehicleLive()
            return true
        } catch {
            let message = error.localizedDescription
            lastErrorMessage = message
            vehicleControlMessage = message
            return false
        }
    }

    func refreshSelectedVehicleActiveDrive(includeRoute: Bool = false, routeMaxPoints: Int = 200) async {
        guard let vin = selectedVehicle?.vin else {
            return
        }

        beginLoading(.activeDrive)
        defer { finishLoading(.activeDrive) }

        do {
            let page = try await apiClient.activeDrive(
                vin: vin,
                includeRoute: includeRoute,
                routeMaxPoints: includeRoute ? routeMaxPoints : nil
            )
            mergeActiveDrive(page.data, for: vin)
            lastErrorMessage = nil
            lastRequestID = page.requestID ?? lastRequestID
            lastRefreshDate = Date()
            await saveCurrentState()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func refreshSelectedVehicleChargingSessions(limit: Int = 10) async {
        guard let vin = selectedVehicle?.vin else {
            return
        }

        beginLoading(.charging)
        defer { finishLoading(.charging) }

        do {
            let page = try await apiClient.chargingSessions(vin: vin, limit: limit)
            mergeChargingSessions(page.data, for: vin)
            lastErrorMessage = nil
            lastRequestID = page.requestID ?? lastRequestID
            lastRefreshDate = Date()
            await saveCurrentState()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func refreshSelectedVehicleSoftware(includeReleaseNotes: Bool = true, forceRefresh: Bool = false) async -> Bool {
        guard let vin = selectedVehicle?.vin else {
            return false
        }

        beginLoading(.software)
        defer { finishLoading(.software) }

        do {
            let page = try await apiClient.softwareUpdate(
                vin: vin,
                includeReleaseNotes: includeReleaseNotes,
                refresh: forceRefresh
            )
            if let softwareUpdate = FleetDataNormalizer.softwareUpdate(page.data) {
                mergeSoftwareUpdates([vin: softwareUpdate])
            } else {
                softwareUpdatesByVIN.removeValue(forKey: vin)
            }
            lastErrorMessage = nil
            lastRequestID = page.requestID ?? lastRequestID
            lastRefreshDate = Date()
            await saveCurrentState()
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func installSelectedVehicleSoftwareUpdate(offsetSec: Int = 0) async -> Bool {
        guard let vin = selectedVehicle?.vin, !isMutatingSoftware else {
            return false
        }

        isMutatingSoftware = true
        softwareActionMessage = "Scheduling software update."
        defer { isMutatingSoftware = false }

        do {
            let page = try await apiClient.installSoftwareUpdate(vin: vin, offsetSec: offsetSec)
            lastErrorMessage = nil
            lastRequestID = page.requestID ?? lastRequestID
            softwareActionMessage = offsetSec == 0 ? "Requested software install." : "Scheduled software install."
            await refreshSelectedVehicleSoftware(forceRefresh: true)
            return true
        } catch {
            let message = error.localizedDescription
            lastErrorMessage = message
            softwareActionMessage = message
            return false
        }
    }

    @discardableResult
    func cancelSelectedVehicleSoftwareUpdate() async -> Bool {
        guard let vin = selectedVehicle?.vin, !isMutatingSoftware else {
            return false
        }

        isMutatingSoftware = true
        softwareActionMessage = "Canceling software update."
        defer { isMutatingSoftware = false }

        do {
            let page = try await apiClient.cancelSoftwareUpdate(vin: vin)
            lastErrorMessage = nil
            lastRequestID = page.requestID ?? lastRequestID
            softwareActionMessage = "Canceled software update."
            await refreshSelectedVehicleSoftware(forceRefresh: true)
            return true
        } catch {
            let message = error.localizedDescription
            lastErrorMessage = message
            softwareActionMessage = message
            return false
        }
    }

    func refreshSelectedVehicleDrives(limit: Int = 10) async {
        guard let vin = selectedVehicle?.vin else {
            return
        }

        beginLoading(.drives)
        defer { finishLoading(.drives) }

        do {
            let page = try await apiClient.drives(vin: vin, limit: limit, includeRoute: true)
            mergeRecentDrives(page.data, for: vin)
            lastErrorMessage = nil
            lastRequestID = page.requestID ?? lastRequestID
            lastRefreshDate = Date()
            await saveCurrentState()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func refreshRoute(for drive: FleetDriveSession, maxPoints: Int = 500) async {
        guard !drive.sessionID.isEmpty else {
            return
        }

        do {
            let page = try await apiClient.driveRoute(
                sessionID: drive.sessionID,
                startTime: drive.startedAt,
                endTime: drive.endedAt,
                limit: nil,
                maxPoints: maxPoints
            )
            let normalizedRoute = FleetDataNormalizer.routePoints(page.data, limit: maxPoints)
            if normalizedRoute.isEmpty {
                driveRoutesBySessionID.removeValue(forKey: drive.sessionID)
            } else {
                driveRoutesBySessionID[drive.sessionID] = normalizedRoute
            }
            recentDrives = FleetDataNormalizer.driveSessions(recentDrives.map { existingDrive in
                guard existingDrive.sessionID == drive.sessionID else {
                    return existingDrive
                }
                var updatedDrive = existingDrive
                updatedDrive.route = normalizedRoute
                return updatedDrive
            })
            lastErrorMessage = nil
            lastRequestID = page.requestID ?? lastRequestID
            lastRefreshDate = Date()
            await saveCurrentState()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func refreshSelectedVehicleTelemetry(limit: Int = 100) async {
        guard let vin = selectedVehicle?.vin else {
            return
        }

        beginLoading(.telemetry)
        defer { finishLoading(.telemetry) }

        var didRefresh = false
        var latestRequestID: String?
        var latestErrorMessage: String?

        do {
            let page = try await apiClient.locations(vin: vin, startTime: nil, endTime: nil, limit: limit)
            locationHistoryByVIN[vin] = FleetDataNormalizer.routePoints(page.data, limit: limit)
            latestRequestID = page.requestID ?? latestRequestID
            didRefresh = true
        } catch {
            latestErrorMessage = error.localizedDescription
        }

        do {
            let page = try await apiClient.telemetrySeries(
                vin: vin,
                topic: nil,
                startTime: nil,
                endTime: nil,
                limit: limit,
                maxPoints: limit,
                fields: []
            )
            telemetrySeriesByVIN[vin] = FleetDataNormalizer.telemetrySeries(page.data, limit: limit)
            latestRequestID = page.requestID ?? latestRequestID
            didRefresh = true
        } catch {
            latestErrorMessage = error.localizedDescription
        }

        if didRefresh {
            lastErrorMessage = nil
            lastRequestID = latestRequestID ?? lastRequestID
            lastRefreshDate = Date()
            await saveCurrentState()
        } else if let latestErrorMessage {
            lastErrorMessage = latestErrorMessage
        }
    }

    func exportSelectedVehicleRawData() async {
        guard let vin = selectedVehicle?.vin, !isExportingRawData else {
            return
        }

        isExportingRawData = true
        rawDataExportMessage = "Exporting raw Tessie data."
        defer { isExportingRawData = false }

        do {
            let export = try await apiClient.rawVehicleDataExport(vin: vin)
            let exportURL = try await Task.detached(priority: .utility) {
                try Self.writeRawDataExport(export)
            }.value
            let successfulResponseCount = export.responses.filter { response in
                guard let statusCode = response.statusCode else {
                    return false
                }
                return (200..<300).contains(statusCode)
            }.count
            let failedResponseCount = export.responses.count - successfulResponseCount

            rawDataExportURL = exportURL
            rawDataExportMessage = failedResponseCount == 0
                ? "Exported \(export.responses.count) raw responses."
                : "Exported \(successfulResponseCount)/\(export.responses.count) raw responses."
            lastErrorMessage = nil
            lastRequestID = export.responses.reversed().first { $0.requestID != nil }?.requestID ?? lastRequestID
        } catch {
            let message = error.localizedDescription
            lastErrorMessage = message
            rawDataExportMessage = message
        }
    }

    func reset(clearCache: Bool) async {
        stopPolling()
        selectionRefreshTask?.cancel()
        selectionRefreshTask = nil
        loadingCounts = [:]
        activeCharging = []
        activeControlAction = nil
        activeDrivesByVIN = [:]
        cacheDate = nil
        capabilities = nil
        cursor = nil
        driveRoutesBySessionID = [:]
        isExportingRawData = false
        isLoadingActiveDrive = false
        isLoadingCharging = false
        isLoadingDrives = false
        isLoadingSoftware = false
        isLoadingTelemetry = false
        isMutatingSoftware = false
        isRefreshing = false
        isRunningControl = false
        isShowingCachedData = false
        lastErrorMessage = nil
        lastRefreshDate = nil
        lastRequestID = nil
        loadState = .idle
        locationHistoryByVIN = [:]
        rawDataExportMessage = "Not run"
        rawDataExportURL = nil
        recentDrives = []
        selectedVIN = nil
        softwareActionMessage = "Not run"
        softwareUpdatesByVIN = [:]
        telemetrySeriesByVIN = [:]
        user = nil
        vehicleControlMessage = nil
        vehicles = []

        if clearCache {
            try? await cache.clear()
        }
    }

    func route(for drive: FleetDriveSession) -> [FleetRoutePoint] {
        driveRoutesBySessionID[drive.sessionID] ?? []
    }

    private func beginLoading(_ kind: LoadingKind) {
        loadingCounts[kind, default: 0] += 1
        setLoading(true, for: kind)
    }

    private func finishLoading(_ kind: LoadingKind) {
        let remainingCount = max(loadingCounts[kind, default: 0] - 1, 0)
        loadingCounts[kind] = remainingCount == 0 ? nil : remainingCount
        setLoading(remainingCount > 0, for: kind)
    }

    private func setLoading(_ isLoading: Bool, for kind: LoadingKind) {
        switch kind {
        case .activeDrive:
            isLoadingActiveDrive = isLoading
        case .charging:
            isLoadingCharging = isLoading
        case .drives:
            isLoadingDrives = isLoading
        case .software:
            isLoadingSoftware = isLoading
        case .telemetry:
            isLoadingTelemetry = isLoading
        }
    }

    private func pollFleetData(every interval: TimeInterval) async {
        while !Task.isCancelled {
            await refreshIfNeededForPolling()

            do {
                try await Task.sleep(nanoseconds: nanoseconds(from: interval))
            } catch {
                return
            }
        }
    }

    private func refreshIfNeededForPolling() async {
        guard !isRefreshing, !loadState.isLoading else {
            return
        }

        if vehicles.isEmpty {
            await loadInitialDataIfNeeded()
            return
        }

        if let lastRefreshDate, Date().timeIntervalSince(lastRefreshDate) < 15 {
            return
        }

        await refresh()
    }

    private nonisolated func nanoseconds(from seconds: TimeInterval) -> UInt64 {
        UInt64(max(seconds, 0) * 1_000_000_000)
    }

    private nonisolated static func writeRawDataExport(_ export: FleetRawDataExport) throws -> URL {
        let fileManager = FileManager.default
        let documentsURL = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = documentsURL.appendingPathComponent("Fleet Raw Exports", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var excludedDirectoryURL = directoryURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? excludedDirectoryURL.setResourceValues(resourceValues)

        let fileURL = directoryURL.appendingPathComponent(rawDataExportFileName(vin: export.vin, generatedAt: export.generatedAt))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(export)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        return fileURL
    }

    private nonisolated static func rawDataExportFileName(vin: String, generatedAt: Int64) -> String {
        let safeVINSuffix = vin.suffix(6).filter { $0.isLetter || $0.isNumber }
        let suffix = safeVINSuffix.isEmpty ? "vehicle" : String(safeVINSuffix)
        return "fleet-raw-\(suffix)-\(generatedAt / 1_000).json"
    }

    private func hydrateFromCacheIfAvailable() async {
        guard vehicles.isEmpty else {
            return
        }

        do {
            guard let cachedState = try await cache.load() else {
                return
            }
            applyCachedState(cachedState)
            loadState = .loaded
        } catch {
            try? await cache.clear()
        }
    }

    private func applyBootstrap(_ bootstrap: FleetBootstrap, cursor: Int64?, requestID: String?, isCached: Bool) {
        activeCharging = FleetDataNormalizer.chargeSessions(bootstrap.activeCharging)
        capabilities = FleetDataNormalizer.capabilities(bootstrap.capabilities)
        self.cursor = cursor
        cacheDate = nil
        isShowingCachedData = isCached
        lastRefreshDate = Date()
        lastRequestID = requestID
        recentDrives = FleetDataNormalizer.driveSessions(bootstrap.recentDrives)
        user = FleetDataNormalizer.user(bootstrap.user)
        vehicles = FleetDataNormalizer.vehicles(bootstrap.vehicles)
        mergeSoftwareUpdates(FleetDataNormalizer.softwareUpdatesByVIN(from: vehicles))

        keepValidSelectionOrSelectFirst()
    }

    private func applyCachedState(_ cachedState: FleetCachedState) {
        activeCharging = FleetDataNormalizer.chargeSessions(cachedState.activeCharging)
        activeDrivesByVIN = FleetDataNormalizer.activeDrivesByVIN(cachedState.activeDrivesByVIN)
        cacheDate = cachedState.savedAt
        capabilities = FleetDataNormalizer.capabilities(cachedState.capabilities)
        cursor = cachedState.cursor
        driveRoutesBySessionID = FleetDataNormalizer.routePointsBySessionID(cachedState.driveRoutesBySessionID)
        isShowingCachedData = true
        lastRefreshDate = cachedState.savedAt
        lastRequestID = nil
        locationHistoryByVIN = FleetDataNormalizer.routePointsByVIN(cachedState.locationHistoryByVIN)
        recentDrives = FleetDataNormalizer.driveSessions(cachedState.recentDrives)
        selectedVIN = cachedState.selectedVIN
        softwareUpdatesByVIN = FleetDataNormalizer.softwareUpdatesByVIN(cachedState.softwareUpdatesByVIN)
        telemetrySeriesByVIN = FleetDataNormalizer.telemetrySeriesByVIN(cachedState.telemetrySeriesByVIN)
        user = FleetDataNormalizer.user(cachedState.user)
        vehicles = FleetDataNormalizer.vehicles(cachedState.vehicles)
        mergeSoftwareUpdates(FleetDataNormalizer.softwareUpdatesByVIN(from: vehicles))

        keepValidSelectionOrSelectFirst()
    }

    private func keepValidSelectionOrSelectFirst() {
        if let selectedVIN, vehicles.contains(where: { $0.vin == selectedVIN }) {
            return
        }

        selectedVIN = vehicles.first?.vin
    }

    private func refreshCapabilitiesIfNeeded() async {
        guard capabilities == nil else {
            return
        }

        do {
            let page = try await apiClient.capabilities()
            capabilities = FleetDataNormalizer.capabilities(page.data)
            lastRequestID = page.requestID ?? lastRequestID
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func loadSelectedVehicleActiveDriveIfNeeded() async {
        guard let selectedVIN = selectedVehicle?.vin, activeDrivesByVIN[selectedVIN] == nil else {
            return
        }
        await refreshSelectedVehicleActiveDrive()
    }

    private func loadSelectedVehicleChargingSessionsIfNeeded() async {
        guard selectedVehicle != nil else {
            return
        }
        await refreshSelectedVehicleChargingSessions()
    }

    private func loadSelectedVehicleSoftwareIfNeeded() async {
        guard let selectedVIN = selectedVehicle?.vin, softwareUpdatesByVIN[selectedVIN] == nil else {
            return
        }
        await refreshSelectedVehicleSoftware()
    }

    private func loadSelectedVehicleDrivesIfNeeded() async {
        guard selectedVehicle != nil else {
            return
        }
        guard selectedVehicleRecentDrives.isEmpty || selectedVehicleRecentDrives.contains(where: needsDriveDetails) else {
            return
        }
        await refreshSelectedVehicleDrives()
    }

    private func needsDriveDetails(_ drive: FleetDriveSession) -> Bool {
        drive.route.isEmpty && (drive.distanceMiles == nil || drive.avgSpeedMPH == nil || drive.maxSpeedMPH == nil)
    }

    private func loadSelectedVehicleTelemetryIfNeeded() async {
        guard let vin = selectedVehicle?.vin else {
            return
        }
        guard locationHistoryByVIN[vin, default: []].isEmpty || telemetrySeriesByVIN[vin, default: []].isEmpty else {
            return
        }
        await refreshSelectedVehicleTelemetry()
    }

    private func mergeChargingSessions(_ sessions: [FleetChargeSession], for vin: String) {
        let normalizedSessions = FleetDataNormalizer.chargeSessions(sessions, fallbackVIN: vin)
        let otherSessions = activeCharging.filter { $0.vin != vin }
        activeCharging = FleetDataNormalizer.chargeSessions(otherSessions + normalizedSessions)
    }

    private func mergeRecentDrives(_ drives: [FleetDriveSession], for vin: String) {
        let normalizedDrives = FleetDataNormalizer.driveSessions(drives, fallbackVIN: vin)
        for drive in normalizedDrives where !drive.route.isEmpty {
            driveRoutesBySessionID[drive.sessionID] = drive.route
        }

        let otherDrives = recentDrives.filter { $0.vin != vin }
        recentDrives = FleetDataNormalizer.driveSessions(otherDrives + normalizedDrives)
    }

    private func mergeSoftwareUpdates(_ updates: [String: FleetSoftwareUpdate]) {
        for (vin, update) in FleetDataNormalizer.softwareUpdatesByVIN(updates) {
            softwareUpdatesByVIN[vin] = update
        }
    }

    private func mergeActiveDrive(_ drive: FleetActiveDriveSession, for vin: String) {
        guard let normalizedDrive = FleetDataNormalizer.activeDrive(drive, fallbackVIN: vin) else {
            activeDrivesByVIN.removeValue(forKey: vin)
            return
        }

        if normalizedDrive.active {
            activeDrivesByVIN[normalizedDrive.vin] = normalizedDrive
            if let latest = normalizedDrive.latest {
                mergeLatestSnapshots([latest])
            }
            if !normalizedDrive.sessionID.isEmpty, !normalizedDrive.route.isEmpty {
                driveRoutesBySessionID[normalizedDrive.sessionID] = normalizedDrive.route
            }
        } else {
            activeDrivesByVIN.removeValue(forKey: normalizedDrive.vin.isEmpty ? vin : normalizedDrive.vin)
        }
    }

    private func mergeLatestSnapshots(_ snapshots: [FleetLatestSnapshot]) {
        let normalizedSnapshots = FleetDataNormalizer.latestSnapshots(snapshots)
        guard !normalizedSnapshots.isEmpty else {
            return
        }

        var snapshotsByVIN: [String: FleetLatestSnapshot] = [:]
        var nestedSoftwareUpdates: [String: FleetSoftwareUpdate] = [:]
        for snapshot in normalizedSnapshots {
            snapshotsByVIN[snapshot.vin] = snapshot
            if let software = snapshot.software {
                nestedSoftwareUpdates[snapshot.vin] = software
            }
        }
        mergeSoftwareUpdates(nestedSoftwareUpdates)

        vehicles = vehicles.map { vehicle in
            guard let snapshot = snapshotsByVIN[vehicle.vin] else {
                return vehicle
            }

            var updatedVehicle = vehicle
            updatedVehicle.latest = snapshot
            return updatedVehicle
        }
        vehicles = FleetDataNormalizer.vehicles(vehicles)
    }

    private func saveCurrentState() async {
        let savedAt = Date()
        let state = FleetCachedState(
            activeCharging: FleetDataNormalizer.chargeSessions(activeCharging),
            activeDrivesByVIN: FleetDataNormalizer.activeDrivesByVIN(activeDrivesByVIN),
            capabilities: FleetDataNormalizer.capabilities(capabilities),
            cursor: cursor,
            driveRoutesBySessionID: FleetDataNormalizer.routePointsBySessionID(driveRoutesBySessionID),
            locationHistoryByVIN: FleetDataNormalizer.routePointsByVIN(locationHistoryByVIN),
            recentDrives: FleetDataNormalizer.driveSessions(recentDrives),
            savedAt: savedAt,
            selectedVIN: selectedVIN,
            softwareUpdatesByVIN: FleetDataNormalizer.softwareUpdatesByVIN(softwareUpdatesByVIN),
            telemetrySeriesByVIN: FleetDataNormalizer.telemetrySeriesByVIN(telemetrySeriesByVIN),
            user: FleetDataNormalizer.user(user),
            vehicles: FleetDataNormalizer.vehicles(vehicles)
        )

        do {
            try await cache.save(state)
            cacheDate = savedAt
        } catch {
            // Cache writes should never block live fleet data from rendering.
        }
    }
}

nonisolated private enum FleetDataNormalizer {
    private static let maxCachedDrivesPerVehicle = 50
    private static let maxCachedRoutePoints = 500
    private static let maxCachedTelemetryPoints = 250

    static func capabilities(_ capabilities: FleetCapabilities?) -> FleetCapabilities? {
        guard var capabilities else {
            return nil
        }
        capabilities.chargeActions = normalizedStrings(capabilities.chargeActions)
        capabilities.controlActions = normalizedStrings(capabilities.controlActions)
        capabilities.events = normalizedStrings(capabilities.events)
        capabilities.notificationEvents = normalizedStrings(capabilities.notificationEvents)
        capabilities.scopes = normalizedStrings(capabilities.scopes)
        capabilities.software = normalizedJSONObject(capabilities.software)
        return capabilities
    }

    static func user(_ user: FleetUser?) -> FleetUser? {
        guard var user else {
            return nil
        }
        user.authType = normalizedString(user.authType)
        user.email = normalizedString(user.email)
        user.id = normalizedString(user.id)
        user.name = normalizedString(user.name)
        user.role = normalizedString(user.role)
        user.scopes = normalizedStrings(user.scopes)
        user.units = normalizedString(user.units)?.lowercased()
        return user
    }

    static func vehicles(_ vehicles: [FleetVehicle]) -> [FleetVehicle] {
        var vehiclesByVIN: [String: FleetVehicle] = [:]

        for rawVehicle in vehicles {
            var vehicle = rawVehicle
            vehicle.vin = normalizedVIN(vehicle.vin)
            guard !vehicle.vin.isEmpty, !vehicle.hidden else {
                continue
            }

            vehicle.displayName = normalizedString(vehicle.displayName)
            vehicle.vehicleTag = normalizedString(vehicle.vehicleTag)
            vehicle.permissions = normalizedStrings(vehicle.permissions)
            if var latest = vehicle.latest {
                if latest.vin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    latest.vin = vehicle.vin
                }
                vehicle.latest = latestSnapshot(latest)
            }

            if let existingVehicle = vehiclesByVIN[vehicle.vin], isNewer(vehicle.latest, than: existingVehicle.latest) {
                vehiclesByVIN[vehicle.vin] = vehicle
            } else if vehiclesByVIN[vehicle.vin] == nil {
                vehiclesByVIN[vehicle.vin] = vehicle
            }
        }

        return vehiclesByVIN.values.sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func latestSnapshots(_ snapshots: [FleetLatestSnapshot]) -> [FleetLatestSnapshot] {
        var snapshotsByVIN: [String: FleetLatestSnapshot] = [:]
        for snapshot in snapshots.compactMap(latestSnapshot) {
            if let existingSnapshot = snapshotsByVIN[snapshot.vin], !isNewer(snapshot, than: existingSnapshot) {
                continue
            }
            snapshotsByVIN[snapshot.vin] = snapshot
        }
        return Array(snapshotsByVIN.values)
    }

    static func chargeSessions(_ sessions: [FleetChargeSession], fallbackVIN: String? = nil) -> [FleetChargeSession] {
        var sessionsByID: [String: FleetChargeSession] = [:]
        for rawSession in sessions {
            var session = rawSession
            let vin = normalizedVIN(session.vin).isEmpty ? normalizedVIN(fallbackVIN ?? "") : normalizedVIN(session.vin)
            guard let startedAt = normalizedEpochMilliseconds(session.startedAt), !vin.isEmpty else {
                continue
            }
            session.vin = vin
            session.startedAt = startedAt
            session.endedAt = normalizedEpochMilliseconds(session.endedAt)
            if let endedAt = session.endedAt, endedAt < session.startedAt {
                session.endedAt = nil
            }
            session.durationMS = normalizedDuration(session.durationMS, startedAt: session.startedAt, endedAt: session.endedAt)
            session.avgPowerKW = nonNegative(session.avgPowerKW)
            session.batteryLevelEnd = percent(session.batteryLevelEnd)
            session.batteryLevelStart = percent(session.batteryLevelStart)
            session.cost = nonNegative(session.cost)
            session.currency = normalizedString(session.currency)
            session.energyAddedKWH = nonNegative(session.energyAddedKWH)
            session.maxPowerKW = nonNegative(session.maxPowerKW)
            session.sessionID = normalizedSessionID(session.sessionID, fallback: "charge:\(session.vin):\(session.startedAt)")
            session.status = normalizedString(session.status)

            if let existingSession = sessionsByID[session.sessionID], existingSession.startedAt >= session.startedAt {
                continue
            }
            sessionsByID[session.sessionID] = session
        }
        return sessionsByID.values.sorted { $0.startedAt > $1.startedAt }
    }

    static func driveSessions(_ drives: [FleetDriveSession], fallbackVIN: String? = nil) -> [FleetDriveSession] {
        var drivesByID: [String: FleetDriveSession] = [:]
        for rawDrive in drives {
            var drive = rawDrive
            let vin = normalizedVIN(drive.vin).isEmpty ? normalizedVIN(fallbackVIN ?? "") : normalizedVIN(drive.vin)
            guard let startedAt = normalizedEpochMilliseconds(drive.startedAt), !vin.isEmpty else {
                continue
            }

            drive.vin = vin
            drive.startedAt = startedAt
            drive.endedAt = normalizedEpochMilliseconds(drive.endedAt)
            if let endedAt = drive.endedAt, endedAt < drive.startedAt {
                drive.endedAt = nil
            }
            drive.route = routePoints(drive.route)
            drive.durationMS = normalizedDuration(drive.durationMS, startedAt: drive.startedAt, endedAt: drive.endedAt)
            drive.distanceMiles = nonNegative(drive.distanceMiles) ?? derivedDistanceMiles(from: drive.route)
            drive.energyUsedKWH = nonNegative(drive.energyUsedKWH)
            drive.maxSpeedMPH = nonNegative(drive.maxSpeedMPH) ?? derivedMaxSpeedMPH(from: drive.route)
            drive.avgSpeedMPH = nonNegative(drive.avgSpeedMPH) ?? derivedAverageSpeedMPH(distanceMiles: drive.distanceMiles, durationMS: drive.durationMS, route: drive.route)
            drive.sessionID = normalizedSessionID(drive.sessionID, fallback: "drive:\(drive.vin):\(drive.startedAt)")
            drive.startAddress = normalizedString(drive.startAddress)
            drive.endAddress = normalizedString(drive.endAddress)

            if let existingDrive = drivesByID[drive.sessionID], existingDrive.startedAt >= drive.startedAt {
                continue
            }
            drivesByID[drive.sessionID] = drive
        }

        return drivesByID.values
            .sorted { $0.startedAt > $1.startedAt }
            .cappedPerVehicle(limit: maxCachedDrivesPerVehicle)
    }

    static func activeDrive(_ rawDrive: FleetActiveDriveSession, fallbackVIN: String? = nil) -> FleetActiveDriveSession? {
        var drive = rawDrive
        let vin = normalizedVIN(drive.vin).isEmpty ? normalizedVIN(fallbackVIN ?? "") : normalizedVIN(drive.vin)
        guard !vin.isEmpty else {
            return nil
        }

        drive.vin = vin
        drive.distanceMiles = nonNegative(drive.distanceMiles)
        drive.lastUpdate = normalizedEpochMilliseconds(drive.lastUpdate)
        drive.sessionID = normalizedString(drive.sessionID) ?? "active:\(vin)"
        drive.startBattery = percent(drive.startBattery)
        drive.startLocation = normalizedCoordinate(drive.startLocation)
        drive.startOdometer = nonNegative(drive.startOdometer)
        drive.startedAt = normalizedEpochMilliseconds(drive.startedAt)
        drive.status = normalizedString(drive.status)
        if let startedAt = drive.startedAt {
            drive.durationMS = normalizedDuration(drive.durationMS, startedAt: startedAt, endedAt: nil)
        } else {
            drive.durationMS = nonNegative(drive.durationMS)
        }
        if let routePointCount = drive.routePointCount, routePointCount < 0 {
            drive.routePointCount = nil
        }
        if var latest = drive.latest {
            if latest.vin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                latest.vin = vin
            }
            drive.latest = latestSnapshot(latest)
        }

        drive.bufferedPoints = routePoints(drive.bufferedPoints)
        drive.route = routePoints(drive.route + drive.bufferedPoints)
        let latestRoutePoint = drive.latestRoutePoint.flatMap { routePoints([$0], limit: 1).first }
        drive.latestRoutePoint = latestRoutePoint ?? drive.route.last
        if drive.routePointCount == nil, !drive.route.isEmpty {
            drive.routePointCount = drive.route.count
        }

        return drive
    }

    static func activeDrivesByVIN(_ values: [String: FleetActiveDriveSession]) -> [String: FleetActiveDriveSession] {
        var normalizedValues: [String: FleetActiveDriveSession] = [:]
        for (key, value) in values {
            guard let drive = activeDrive(value, fallbackVIN: key), drive.active else {
                continue
            }
            normalizedValues[drive.vin] = drive
        }
        return normalizedValues
    }

    static func softwareUpdate(_ rawUpdate: FleetSoftwareUpdate) -> FleetSoftwareUpdate? {
        var update = rawUpdate
        update.availableVersion = normalizedString(update.availableVersion)
        update.currentVersion = normalizedString(update.currentVersion)
        update.downloadPercent = percent(update.downloadPercent)
        update.expectedDurationMinutes = nonNegative(update.expectedDurationMinutes)
        update.expectedDurationSec = nonNegative(update.expectedDurationSec)
        update.installPercent = percent(update.installPercent)
        update.releaseNotes = softwareReleaseNotes(update.releaseNotes)
        if let releaseNotesCount = update.releaseNotesCount, releaseNotesCount < 0 {
            update.releaseNotesCount = nil
        }
        update.scheduledStartTimeMS = normalizedEpochMilliseconds(update.scheduledStartTimeMS)
        update.sourceTimestamp = normalizedEpochMilliseconds(update.sourceTimestamp)
        update.status = normalizedString(update.status)
        update.updatedAt = normalizedEpochMilliseconds(update.updatedAt)
        update.warningTimeRemainingMS = nonNegative(update.warningTimeRemainingMS)

        let hasDistinctAvailableVersion = update.availableVersion != nil && update.availableVersion != update.currentVersion
        if !hasDistinctAvailableVersion {
            update.availableVersion = nil
            update.downloadPercent = nil
            update.expectedDurationMinutes = nil
            update.expectedDurationSec = nil
            update.installPercent = nil
            update.installable = false
            update.updateAvailable = false
            if update.status == nil, update.currentVersion != nil {
                update.status = "Current"
            }
        }

        let hasSoftwareState = update.currentVersion != nil || update.availableVersion != nil || update.status != nil || update.updateAvailable || update.installable || !update.releaseNotes.isEmpty
        return hasSoftwareState ? update : nil
    }

    static func softwareUpdatesByVIN(_ values: [String: FleetSoftwareUpdate]) -> [String: FleetSoftwareUpdate] {
        var normalizedValues: [String: FleetSoftwareUpdate] = [:]
        for (key, value) in values {
            let vin = normalizedVIN(key)
            guard !vin.isEmpty, let softwareUpdate = softwareUpdate(value) else {
                continue
            }
            normalizedValues[vin] = softwareUpdate
        }
        return normalizedValues
    }

    private static func derivedDistanceMiles(from route: [FleetRoutePoint]) -> Double? {
        guard route.count > 1 else {
            return nil
        }

        let odometerValues = route.compactMap(\.odometer)
        if let firstOdometer = odometerValues.first,
           let lastOdometer = odometerValues.last,
           let odometerDistance = nonNegative(lastOdometer - firstOdometer),
           odometerDistance > 0 {
            return odometerDistance
        }

        let distanceMeters = zip(route, route.dropFirst()).reduce(0) { total, pair in
            total + distanceMeters(from: pair.0, to: pair.1)
        }
        let distanceMiles = distanceMeters / 1_609.344
        return distanceMiles > 0 ? distanceMiles : nil
    }

    private static func derivedAverageSpeedMPH(distanceMiles: Double?, durationMS: Int64?, route: [FleetRoutePoint]) -> Double? {
        if let distanceMiles,
           let durationMS,
           durationMS > 0 {
            let hours = Double(durationMS) / 3_600_000
            if hours > 0 {
                return nonNegative(distanceMiles / hours)
            }
        }

        let speeds = route.compactMap(\.speed).filter { $0.isFinite && $0 >= 0 }
        guard !speeds.isEmpty else {
            return nil
        }
        return speeds.reduce(0, +) / Double(speeds.count)
    }

    private static func derivedMaxSpeedMPH(from route: [FleetRoutePoint]) -> Double? {
        route.compactMap(\.speed).filter { $0.isFinite && $0 >= 0 }.max()
    }

    private static func distanceMeters(from start: FleetRoutePoint, to end: FleetRoutePoint) -> Double {
        guard let startLatitude = start.latitude,
              let startLongitude = start.longitude,
              let endLatitude = end.latitude,
              let endLongitude = end.longitude else {
            return 0
        }

        let earthRadiusMeters = 6_371_000.0
        let startLatitudeRadians = startLatitude * .pi / 180
        let endLatitudeRadians = endLatitude * .pi / 180
        let deltaLatitude = (endLatitude - startLatitude) * .pi / 180
        let deltaLongitude = (endLongitude - startLongitude) * .pi / 180
        let haversine = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
            + cos(startLatitudeRadians) * cos(endLatitudeRadians) * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
        let clampedHaversine = min(max(haversine, 0), 1)
        return earthRadiusMeters * 2 * atan2(sqrt(clampedHaversine), sqrt(1 - clampedHaversine))
    }

    static func routePoints(_ points: [FleetRoutePoint], limit: Int? = nil) -> [FleetRoutePoint] {
        let cappedLimit = min(limit ?? maxCachedRoutePoints, maxCachedRoutePoints)
        var seenIDs = Set<String>()
        let normalizedPoints: [FleetRoutePoint] = points.compactMap { rawPoint in
            var point = rawPoint
            guard let latitude = coordinate(point.latitude, min: -90, max: 90),
                  let longitude = coordinate(point.longitude, min: -180, max: 180) else {
                return nil
            }
            point.latitude = latitude
            point.longitude = longitude
            point.odometer = nonNegative(point.odometer)
            point.speed = nonNegative(point.speed)
            point.timestamp = normalizedEpochMilliseconds(point.timestamp)

            let id = point.id
            guard !id.isEmpty, !seenIDs.contains(id) else {
                return nil
            }
            seenIDs.insert(id)
            return point
        }
        .sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }

        guard normalizedPoints.count > cappedLimit else {
            return normalizedPoints
        }
        return Array(normalizedPoints.suffix(cappedLimit))
    }

    static func routePointsByVIN(_ values: [String: [FleetRoutePoint]]) -> [String: [FleetRoutePoint]] {
        normalizeDictionary(values) { routePoints($0) }
    }

    static func routePointsBySessionID(_ values: [String: [FleetRoutePoint]]) -> [String: [FleetRoutePoint]] {
        normalizeDictionary(values) { routePoints($0) }
    }

    static func telemetrySeries(_ points: [FleetTelemetrySeriesPoint], limit: Int? = nil) -> [FleetTelemetrySeriesPoint] {
        let cappedLimit = min(limit ?? maxCachedTelemetryPoints, maxCachedTelemetryPoints)
        return points
            .compactMap { rawPoint in
                var point = rawPoint
                point.fields = normalizedTelemetryFields(point.fields)
                return point.isEmpty ? nil : point
            }
            .sorted { telemetryTimestamp($0) > telemetryTimestamp($1) }
            .prefix(cappedLimit)
            .map { $0 }
    }

    static func telemetrySeriesByVIN(_ values: [String: [FleetTelemetrySeriesPoint]]) -> [String: [FleetTelemetrySeriesPoint]] {
        normalizeDictionary(values) { telemetrySeries($0) }
    }

    static func softwareUpdatesByVIN(from vehicles: [FleetVehicle]) -> [String: FleetSoftwareUpdate] {
        var updates: [String: FleetSoftwareUpdate] = [:]
        for vehicle in vehicles {
            guard let software = vehicle.latest?.software else {
                continue
            }
            updates[vehicle.vin] = software
        }
        return softwareUpdatesByVIN(updates)
    }

    private static func normalizedTelemetryFields(_ fields: [String: JSONValue]) -> [String: JSONValue] {
        var normalizedFields: [String: JSONValue] = [:]
        for (key, value) in fields {
            guard let normalizedKey = normalizedString(key) else {
                continue
            }
            let canonicalKey = normalizedKey.lowercased()

            switch canonicalKey {
            case "timestamp", "updated_at", "updatedat", "source_timestamp":
                if let milliseconds = jsonInt64(value).flatMap(normalizedEpochMilliseconds) {
                    normalizedFields[normalizedKey] = .integer(Int(milliseconds))
                }
            case "battery_level", "charge_limit_soc", "download_percent", "install_percent", "state_of_charge":
                if let percentValue = jsonDouble(value).flatMap(percent) {
                    normalizedFields[normalizedKey] = .double(percentValue)
                }
            case "latitude", "lat":
                if let latitude = jsonDouble(value).flatMap({ coordinate($0, min: -90, max: 90) }) {
                    normalizedFields[normalizedKey] = .double(latitude)
                }
            case "longitude", "lon", "lng":
                if let longitude = jsonDouble(value).flatMap({ coordinate($0, min: -180, max: 180) }) {
                    normalizedFields[normalizedKey] = .double(longitude)
                }
            case "speed", "odometer", "charge_rate_mph", "charger_power_kw", "energy_added_kwh", "energy_used_kwh", "inside_temp", "outside_temp", "time_to_full_charge":
                if let numericValue = jsonDouble(value).flatMap(nonNegative) {
                    normalizedFields[normalizedKey] = .double(numericValue)
                }
            default:
                normalizedFields[normalizedKey] = normalizedJSONValue(value)
            }
        }
        return normalizedFields
    }

    private static func normalizedJSONObject(_ object: [String: JSONValue]) -> [String: JSONValue] {
        guard case .object(let normalizedObject) = normalizedJSONValue(.object(object)) else {
            return [:]
        }
        return normalizedObject
    }

    private static func normalizedJSONValue(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let string):
            return normalizedString(string).map(JSONValue.string) ?? .null
        case .array(let values):
            return .array(values.map(normalizedJSONValue))
        case .object(let object):
            var normalizedObject: [String: JSONValue] = [:]
            for (key, value) in object {
                if let normalizedKey = normalizedString(key) {
                    normalizedObject[normalizedKey] = normalizedJSONValue(value)
                }
            }
            return .object(normalizedObject)
        default:
            return value
        }
    }

    private static func softwareReleaseNotes(_ notes: [FleetSoftwareReleaseNote]) -> [FleetSoftwareReleaseNote] {
        var seenIDs = Set<String>()
        return notes.compactMap { rawNote in
            let title = normalizedString(rawNote.title)
            let subtitle = normalizedString(rawNote.subtitle)
            let description = normalizedString(rawNote.description)
            guard let title else {
                return nil
            }

            let note = FleetSoftwareReleaseNote(
                description: description,
                imageURL: rawNote.imageURL,
                subtitle: subtitle,
                title: title
            )
            guard !seenIDs.contains(note.id) else {
                return nil
            }
            seenIDs.insert(note.id)
            return note
        }
    }

    private static func latestSnapshot(_ snapshot: FleetLatestSnapshot) -> FleetLatestSnapshot? {
        var snapshot = snapshot
        snapshot.vin = normalizedVIN(snapshot.vin)
        guard !snapshot.vin.isEmpty else {
            return nil
        }
        snapshot.batteryLevel = percent(snapshot.batteryLevel)
        snapshot.batteryRange = nonNegative(snapshot.batteryRange)
        snapshot.chargeLimitSOC = percent(snapshot.chargeLimitSOC)
        snapshot.chargeRateMPH = nonNegative(snapshot.chargeRateMPH)
        snapshot.chargerPowerKW = nonNegative(snapshot.chargerPowerKW)
        snapshot.chargingState = normalizedString(snapshot.chargingState)
        snapshot.freshnessMS = nonNegative(snapshot.freshnessMS)
        snapshot.gear = normalizedString(snapshot.gear)
        snapshot.insideTemp = finite(snapshot.insideTemp)
        snapshot.latitude = coordinate(snapshot.latitude, min: -90, max: 90)
        snapshot.longitude = coordinate(snapshot.longitude, min: -180, max: 180)
        snapshot.odometer = nonNegative(snapshot.odometer)
        snapshot.outsideTemp = finite(snapshot.outsideTemp)
        if let software = snapshot.software {
            snapshot.software = softwareUpdate(software)
        }
        snapshot.speed = nonNegative(snapshot.speed)
        snapshot.targetTemperature = finite(snapshot.targetTemperature)
        snapshot.timeToFullCharge = nonNegative(snapshot.timeToFullCharge)
        snapshot.timestamp = normalizedEpochMilliseconds(snapshot.timestamp)
        snapshot.updatedAt = normalizedEpochMilliseconds(snapshot.updatedAt) ?? snapshot.timestamp
        if snapshot.timestamp == nil {
            snapshot.timestamp = snapshot.updatedAt
        }
        return snapshot
    }

    private static func normalizedStrings(_ values: [String]) -> [String] {
        Array(Set(values.compactMap(normalizedString))).sorted()
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedVIN(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func normalizedSessionID(_ value: String, fallback: String) -> String {
        normalizedString(value) ?? fallback
    }

    private static func normalizedEpochMilliseconds(_ value: Int64?) -> Int64? {
        guard let value else {
            return nil
        }
        return normalizedEpochMilliseconds(value)
    }

    private static func normalizedEpochMilliseconds(_ value: Int64) -> Int64? {
        guard value > 0 else {
            return nil
        }
        if value >= 1_000_000_000 && value < 10_000_000_000 {
            return value * 1_000
        }
        return value
    }

    private static func normalizedDuration(_ value: Int64?, startedAt: Int64, endedAt: Int64?) -> Int64? {
        if let value = nonNegative(value), value > 0 {
            return value
        }
        guard let endedAt, endedAt > startedAt else {
            return nil
        }
        return endedAt - startedAt
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else {
            return nil
        }
        return value
    }

    private static func nonNegative(_ value: Double?) -> Double? {
        guard let value = finite(value), value >= 0 else {
            return nil
        }
        return value
    }

    private static func nonNegative(_ value: Int64?) -> Int64? {
        guard let value, value >= 0 else {
            return nil
        }
        return value
    }

    private static func percent(_ value: Double?) -> Double? {
        guard let value = finite(value) else {
            return nil
        }
        return min(max(value, 0), 100)
    }

    private static func coordinate(_ value: Double?, min: Double, max: Double) -> Double? {
        guard let value = finite(value), value >= min, value <= max else {
            return nil
        }
        return value
    }

    private static func normalizedCoordinate(_ location: FleetLocationCoordinate?) -> FleetLocationCoordinate? {
        guard var location else {
            return nil
        }
        guard let latitude = coordinate(location.latitude, min: -90, max: 90),
              let longitude = coordinate(location.longitude, min: -180, max: 180) else {
            return nil
        }
        location.latitude = latitude
        location.longitude = longitude
        return location
    }

    private static func isNewer(_ lhs: FleetLatestSnapshot?, than rhs: FleetLatestSnapshot?) -> Bool {
        (lhs?.updatedAt ?? lhs?.timestamp ?? 0) >= (rhs?.updatedAt ?? rhs?.timestamp ?? 0)
    }

    private static func telemetryTimestamp(_ point: FleetTelemetrySeriesPoint) -> Int64 {
        jsonInt64(point["timestamp"]) ?? jsonInt64(point["updated_at"]) ?? jsonInt64(point["updatedAt"]) ?? 0
    }

    private static func jsonInt64(_ value: JSONValue?) -> Int64? {
        switch value {
        case .integer(let value):
            return Int64(value)
        case .double(let value):
            return safeInt64(from: value)
        case .string(let value):
            return Int64(value) ?? Double(value).flatMap { safeInt64(from: $0) }
        default:
            return nil
        }
    }

    private static func safeInt64(from value: Double) -> Int64? {
        guard value.isFinite,
              value >= Double(Int64.min),
              value < Double(Int64.max) else {
            return nil
        }
        return Int64(value)
    }

    private static func jsonDouble(_ value: JSONValue?) -> Double? {
        switch value {
        case .integer(let value):
            return Double(value)
        case .double(let value) where value.isFinite:
            return value
        case .string(let value):
            return Double(value)
        default:
            return nil
        }
    }

    private static func normalizeDictionary<Value>(_ values: [String: [Value]], normalize: ([Value]) -> [Value]) -> [String: [Value]] {
        var normalizedValues: [String: [Value]] = [:]
        for (key, value) in values {
            guard let normalizedKey = normalizedString(key) else {
                continue
            }
            let normalizedValue = normalize(value)
            if !normalizedValue.isEmpty {
                normalizedValues[normalizedKey] = normalizedValue
            }
        }
        return normalizedValues
    }
}

nonisolated private extension Array where Element == FleetDriveSession {
    func cappedPerVehicle(limit: Int) -> [FleetDriveSession] {
        var countsByVIN: [String: Int] = [:]
        return filter { drive in
            let count = countsByVIN[drive.vin, default: 0]
            guard count < limit else {
                return false
            }
            countsByVIN[drive.vin] = count + 1
            return true
        }
    }
}

extension FleetDataStore {
    static func previewLoaded() -> FleetDataStore {
        let store = FleetDataStore(apiClient: PreviewFleetDataClient())
        let previewRoute = PreviewFleetDataClient.previewDriveRoute
        store.activeCharging = [
            FleetChargeSession(
                avgPowerKW: 42.1,
                batteryLevelEnd: nil,
                batteryLevelStart: 38,
                cost: nil,
                currency: nil,
                durationMS: nil,
                endedAt: nil,
                energyAddedKWH: 18.4,
                maxPowerKW: 97.2,
                sessionID: "preview-charge",
                startedAt: 1_781_000_000_000,
                status: "active",
                vin: "5YJ3E1EA7JF000001"
            )
        ]
        store.activeDrivesByVIN = [
            "5YJ3E1EA7JF000001": FleetActiveDriveSession(
                durationMS: 540_000,
                latest: FleetLatestSnapshot(speed: 32, timestamp: 1_781_000_540_000, updatedAt: 1_781_000_540_000, vin: "5YJ3E1EA7JF000001"),
                latestRoutePoint: previewRoute.last,
                route: previewRoute,
                routePointCount: previewRoute.count,
                sessionID: "preview-active-drive",
                startedAt: 1_781_000_000_000,
                vin: "5YJ3E1EA7JF000001"
            )
        ]
        store.cacheDate = Date()
        store.capabilities = FleetCapabilities(
            chargeActions: ["set_charge_limit"],
            controlActions: ["wake", "flash_lights"],
            events: ["drive.started"],
            notificationEvents: ["drive.started", "charging.started"],
            scopes: ["vehicles:read", "telemetry:read"]
        )
        store.cursor = 1_781_000_100_000
        store.driveRoutesBySessionID = ["preview-drive": previewRoute]
        store.lastRefreshDate = Date()
        store.loadState = .loaded
        store.locationHistoryByVIN = [
            "5YJ3E1EA7JF000001": previewRoute
        ]
        store.recentDrives = [
            FleetDriveSession(
                avgSpeedMPH: 34,
                distanceMiles: 12.4,
                durationMS: 1_620_000,
                endedAt: 1_781_001_620_000,
                energyUsedKWH: 3.1,
                maxSpeedMPH: 58,
                route: previewRoute,
                sessionID: "preview-drive",
                startAddress: "1 Apple Park Way, Cupertino, CA",
                endAddress: "Infinite Loop, Cupertino, CA",
                startedAt: 1_781_000_000_000,
                vin: "5YJ3E1EA7JF000001"
            )
        ]
        store.softwareUpdatesByVIN = [
            "5YJ3E1EA7JF000001": FleetSoftwareUpdate(
                availableVersion: "2026.20",
                currentVersion: "2026.14.6",
                downloadPercent: 100,
                expectedDurationMinutes: 25,
                expectedDurationSec: 1_500,
                installPercent: 0,
                installable: true,
                releaseNotes: [
                    FleetSoftwareReleaseNote(
                        description: "Adds software update state and release notes to the debug backend view.",
                        subtitle: "Release notes",
                        title: "Software updates"
                    )
                ],
                releaseNotesCount: 1,
                status: "available",
                updateAvailable: true,
                updatedAt: 1_781_000_000_000
            )
        ]
        store.telemetrySeriesByVIN = [
            "5YJ3E1EA7JF000001": [["timestamp": 1_781_000_000_000, "speed": 0, "battery_level": 74]]
        ]
        store.user = FleetUser(email: "driver@example.com", name: "Driver", scopes: ["vehicles:read", "telemetry:read"], units: "imperial")
        store.vehicles = [
            FleetVehicle(
                displayName: "Model 3",
                latest: FleetLatestSnapshot(
                    batteryLevel: 74,
                    batteryRange: 260,
                    chargeLimitSOC: 80,
                    chargeRateMPH: 28,
                    chargerPowerKW: 7.2,
                    chargingState: "Charging",
                    climateOn: true,
                    freshnessMS: 1_500,
                    gear: nil,
                    insideTemp: 70,
                    latitude: 37.3349,
                    locked: true,
                    longitude: -122.0090,
                    odometer: 19_204,
                    outsideTemp: 64,
                    sentryMode: false,
                    speed: nil,
                    targetTemperature: 72,
                    timeToFullCharge: 1.4,
                    timestamp: 1_781_000_000_000,
                    updatedAt: 1_781_000_000_000,
                    vin: "5YJ3E1EA7JF000001"
                ),
                permissions: ["control"],
                vehicleTag: "daily",
                vin: "5YJ3E1EA7JF000001"
            )
        ]
        store.selectedVIN = store.vehicles.first?.vin
        return store
    }
}

private struct PreviewFleetDataClient: FleetDataLoading {
    static let previewDriveRoute = FleetDataNormalizer.routePoints([
        FleetRoutePoint(latitude: 37.3318, longitude: -122.0312, odometer: 19_204.0, speed: 0, timestamp: 1_781_000_000),
        FleetRoutePoint(latitude: 37.3324, longitude: -122.0307, odometer: 19_204.2, speed: 18, timestamp: 1_781_000_180_000),
        FleetRoutePoint(latitude: 37.3333, longitude: -122.0297, odometer: 19_204.5, speed: 32, timestamp: 1_781_000_360_000),
        FleetRoutePoint(latitude: 37.3342, longitude: -122.0282, odometer: 19_204.9, speed: 41, timestamp: 1_781_000_540_000),
        FleetRoutePoint(latitude: 37.3354, longitude: -122.0270, odometer: 19_205.2, speed: 37, timestamp: 1_781_000_720_000),
        FleetRoutePoint(latitude: 37.3361, longitude: -122.0259, odometer: 19_205.5, speed: 24, timestamp: 1_781_000_900_000),
        FleetRoutePoint(latitude: 37.3364, longitude: -122.0251, odometer: 19_205.7, speed: 0, timestamp: 1_781_001_080_000),
        FleetRoutePoint(latitude: 91, longitude: -122.0251, odometer: 19_205.8, speed: -4, timestamp: 1_781_001_090_000),
        FleetRoutePoint(latitude: 37.3364, longitude: -122.0251, odometer: 19_205.7, speed: 0, timestamp: 1_781_001_080_000)
    ])

    func activeDrive(vin: String, includeRoute: Bool, routeMaxPoints: Int?) async throws -> FleetAPIPage<FleetActiveDriveSession> {
        FleetAPIPage(
            data: FleetActiveDriveSession(active: false, vin: vin),
            cursor: nil,
            cached: false,
            stale: false,
            requestID: "preview-active-drive"
        )
    }

    func chargingSessions(vin: String, limit: Int?) async throws -> FleetAPIPage<[FleetChargeSession]> {
        FleetAPIPage(
            data: [],
            cursor: nil,
            cached: false,
            stale: false,
            requestID: "preview-charging"
        )
    }

    func softwareUpdate(vin: String, includeReleaseNotes: Bool, refresh: Bool) async throws -> FleetAPIPage<FleetSoftwareUpdate> {
        FleetAPIPage(
            data: FleetSoftwareUpdate(currentVersion: "2026.14.6", installable: false, updateAvailable: false),
            cursor: nil,
            cached: false,
            stale: false,
            requestID: "preview-software"
        )
    }

    func installSoftwareUpdate(vin: String, offsetSec: Int) async throws -> FleetAPIPage<[String: JSONValue]> {
        FleetAPIPage(
            data: ["requested": true],
            cursor: nil,
            cached: false,
            stale: false,
            requestID: "preview-software-install"
        )
    }

    func cancelSoftwareUpdate(vin: String) async throws -> FleetAPIPage<[String: JSONValue]> {
        FleetAPIPage(
            data: ["canceled": true],
            cursor: nil,
            cached: false,
            stale: false,
            requestID: "preview-software-cancel"
        )
    }

    func rawVehicleDataExport(vin: String) async throws -> FleetRawDataExport {
        FleetRawDataExport(
            apiBaseURL: "https://api.tessie.com",
            appSchemaVersion: 2,
            generatedAt: 1_781_000_000_000,
            responses: [
                FleetRawAPIResponse(
                    apiVersion: "1.0",
                    body: .object([
                        "ok": true,
                        "data": .object([
                            "vin": .string(vin),
                            "inside_temp": 70,
                            "outside_temp": 64,
                            "route_points": .array([
                                .object([
                                    "latitude": 37.3318,
                                    "longitude": -122.0312,
                                    "speed": 0,
                                    "timestamp": 1_781_000_000_000
                                ])
                            ])
                        ])
                    ]),
                    bodyText: nil,
                    cacheControl: "no-store",
                    durationMS: 12,
                    errorMessage: nil,
                    method: "GET",
                    path: "/\(vin)/state",
                    query: [:],
                    requestID: "preview-raw",
                    statusCode: 200,
                    timestamp: 1_781_000_000_000,
                    url: "https://api.tessie.com/\(vin)/state"
                )
            ],
            vin: vin
        )
    }

    func bootstrap() async throws -> FleetAPIPage<FleetBootstrap> {
        FleetAPIPage(
            data: FleetBootstrap(),
            cursor: 1_781_000_100_000,
            cached: false,
            stale: false,
            requestID: "preview"
        )
    }

    func capabilities() async throws -> FleetAPIPage<FleetCapabilities> {
        FleetAPIPage(
            data: FleetCapabilities(scopes: ["vehicles:read", "telemetry:read"]),
            cursor: nil,
            cached: false,
            stale: false,
            requestID: "preview-capabilities"
        )
    }

    func changes(since cursor: Int64) async throws -> FleetAPIPage<FleetSyncChanges> {
        FleetAPIPage(
            data: FleetSyncChanges(),
            cursor: cursor + 1,
            cached: false,
            stale: false,
            requestID: "preview"
        )
    }

    func driveRoute(sessionID: String, startTime: Int64?, endTime: Int64?, limit: Int?, maxPoints: Int?) async throws -> FleetAPIPage<[FleetRoutePoint]> {
        FleetAPIPage(
            data: Self.previewDriveRoute,
            cursor: nil,
            cached: false,
            stale: false,
            requestID: "preview-route"
        )
    }

    func drives(vin: String, limit: Int?, includeRoute: Bool) async throws -> FleetAPIPage<[FleetDriveSession]> {
        FleetAPIPage(
            data: [
                FleetDriveSession(
                    distanceMiles: 1.7,
                    durationMS: 1_080_000,
                    endedAt: 1_781_001_080_000,
                    energyUsedKWH: 0.6,
                    route: includeRoute ? Self.previewDriveRoute : [],
                    sessionID: "preview-drive",
                    startAddress: "1 Apple Park Way, Cupertino, CA",
                    endAddress: "Infinite Loop, Cupertino, CA",
                    startedAt: 1_781_000_000_000,
                    vin: vin
                )
            ],
            cursor: nil,
            cached: false,
            stale: false,
            requestID: "preview-drives"
        )
    }

    func latestSnapshot(vin: String) async throws -> FleetAPIPage<FleetLatestSnapshot> {
        FleetAPIPage(
            data: FleetLatestSnapshot(vin: vin),
            cursor: nil,
            cached: false,
            stale: false,
            requestID: "preview-live"
        )
    }

    func locations(vin: String, startTime: Int64?, endTime: Int64?, limit: Int?) async throws -> FleetAPIPage<[FleetRoutePoint]> {
        FleetAPIPage(
            data: [],
            cursor: nil,
            cached: false,
            stale: false,
            requestID: "preview-locations"
        )
    }

    func runControl(
        action: String,
        vin: String,
        params: [String: JSONValue]
    ) async throws -> FleetAPIPage<[String: JSONValue]> {
        FleetAPIPage(
            data: ["result": true],
            cursor: nil,
            cached: false,
            stale: false,
            requestID: "preview-control-\(action)"
        )
    }

    func telemetrySeries(
        vin: String,
        topic: String?,
        startTime: Int64?,
        endTime: Int64?,
        limit: Int?,
        maxPoints: Int?,
        fields: [String]
    ) async throws -> FleetAPIPage<[FleetTelemetrySeriesPoint]> {
        FleetAPIPage(
            data: [],
            cursor: nil,
            cached: false,
            stale: false,
            requestID: "preview-telemetry"
        )
    }
}
