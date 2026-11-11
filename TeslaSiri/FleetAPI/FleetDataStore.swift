import Foundation
import Observation

@MainActor
@Observable
final class FleetDataStore {
    // MARK: - Types

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

    // MARK: - Dependencies & Background Tasks

    @ObservationIgnored private let apiClient: any FleetDataLoading
    @ObservationIgnored private let cache: any FleetDataCaching
    @ObservationIgnored private var loadingCounts: [LoadingKind: Int] = [:]
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var selectionRefreshTask: Task<Void, Never>?

    // MARK: - Fleet Data State

    private(set) var user: FleetUser?
    private(set) var capabilities: FleetCapabilities?
    private(set) var vehicles: [FleetVehicle] = []
    var selectedVIN: String?

    private(set) var activeCharging: [FleetChargeSession] = []
    private(set) var activeDrivesByVIN: [String: FleetActiveDriveSession] = [:]
    private(set) var recentDrives: [FleetDriveSession] = []
    private(set) var driveRoutesBySessionID: [String: [FleetRoutePoint]] = [:]
    private(set) var softwareUpdatesByVIN: [String: FleetSoftwareUpdate] = [:]
    private(set) var locationHistoryByVIN: [String: [FleetRoutePoint]] = [:]
    private(set) var telemetrySeriesByVIN: [String: [FleetTelemetrySeriesPoint]] = [:]

    // MARK: - Sync & Cache Metadata

    private(set) var loadState: LoadState = .idle
    private(set) var cursor: Int64?
    private(set) var cacheDate: Date?
    private(set) var isShowingCachedData = false
    private(set) var lastRefreshDate: Date?
    private(set) var lastRequestID: String?
    private(set) var lastErrorMessage: String?

    // MARK: - Loading & Action State

    private(set) var isRefreshing = false
    private(set) var isLoadingActiveDrive = false
    private(set) var isLoadingCharging = false
    private(set) var isLoadingDrives = false
    private(set) var isLoadingSoftware = false
    private(set) var isLoadingTelemetry = false

    private(set) var isRunningControl = false
    private(set) var activeControlAction: String?
    private(set) var vehicleControlMessage: String?

    private(set) var isMutatingSoftware = false
    private(set) var softwareActionMessage = "Not run"

    private(set) var isExportingRawData = false
    private(set) var rawDataExportMessage = "Not run"
    private(set) var rawDataExportURL: URL?

    // MARK: - Selected Vehicle Computed State

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

    var selectedVehicleChargingSessions: [FleetChargeSession] {
        guard let vin = selectedVehicle?.vin else {
            return []
        }
        return activeCharging.filter { $0.vin == vin }
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

    // MARK: - Initialization & Polling

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

    // MARK: - Bootstrap, Sync & Selection

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
            await loadInitialSelectedVehicleDetailsIfNeeded()
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
            guard !Task.isCancelled, self.cursor == cursor else {
                return
            }

            if let roster = page.data.vehicles {
                applyVehicleRoster(roster)
            } else {
                mergeLatestSnapshots(page.data.latest)
            }
            self.cursor = page.cursor ?? cursor
            isShowingCachedData = false
            lastRequestID = page.requestID
            lastRefreshDate = Date()
            loadState = .loaded
            await refreshAllSelectedVehicleDetails()
            await saveCurrentState()
        } catch {
            guard !Task.isCancelled, self.cursor == cursor else {
                return
            }
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
            await refreshAllSelectedVehicleDetails()
        }
    }

    func reset(clearCache: Bool) async {
        stopPolling()
        selectionRefreshTask?.cancel()
        selectionRefreshTask = nil
        loadingCounts = [:]

        user = nil
        capabilities = nil
        vehicles = []
        selectedVIN = nil

        activeCharging = []
        activeDrivesByVIN = [:]
        recentDrives = []
        driveRoutesBySessionID = [:]
        softwareUpdatesByVIN = [:]
        locationHistoryByVIN = [:]
        telemetrySeriesByVIN = [:]

        loadState = .idle
        cursor = nil
        cacheDate = nil
        isShowingCachedData = false
        lastRefreshDate = nil
        lastRequestID = nil
        lastErrorMessage = nil

        isRefreshing = false
        isLoadingActiveDrive = false
        isLoadingCharging = false
        isLoadingDrives = false
        isLoadingSoftware = false
        isLoadingTelemetry = false

        isRunningControl = false
        activeControlAction = nil
        vehicleControlMessage = nil

        isMutatingSoftware = false
        softwareActionMessage = "Not run"

        isExportingRawData = false
        rawDataExportMessage = "Not run"
        rawDataExportURL = nil

        if clearCache {
            try? await cache.clear()
        }
    }

    func route(for drive: FleetDriveSession) -> [FleetRoutePoint] {
        driveRoutesBySessionID[drive.sessionID] ?? []
    }

    // MARK: - Vehicle Refresh & Control Actions

    func refreshSelectedVehicleLive() async {
        await performSelectedVehicleRefresh { vin in
            let page = try await apiClient.latestSnapshot(vin: vin)
            try validateReadResult(for: vin)
            var snapshot = page.data
            if FleetDataNormalizer.normalizedString(snapshot.vin) == nil {
                snapshot.vin = vin
            }
            mergeLatestSnapshots([snapshot])
            return page.requestID
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
        await performSelectedVehicleRefresh(loading: .activeDrive) { vin in
            let page = try await apiClient.activeDrive(
                vin: vin,
                includeRoute: includeRoute,
                routeMaxPoints: includeRoute ? routeMaxPoints : nil
            )
            try validateReadResult(for: vin)
            mergeActiveDrive(page.data, for: vin)
            return page.requestID
        }
    }

    func refreshSelectedVehicleChargingSessions(limit: Int = 10) async {
        await performSelectedVehicleRefresh(loading: .charging) { vin in
            let page = try await apiClient.chargingSessions(vin: vin, limit: limit)
            try validateReadResult(for: vin)
            mergeChargingSessions(page.data, for: vin)
            return page.requestID
        }
    }

    @discardableResult
    func refreshSelectedVehicleSoftware(includeReleaseNotes: Bool = true, forceRefresh: Bool = false) async -> Bool {
        await performSelectedVehicleRefresh(loading: .software) { vin in
            let page = try await apiClient.softwareUpdate(
                vin: vin,
                includeReleaseNotes: includeReleaseNotes,
                refresh: forceRefresh
            )
            try validateReadResult(for: vin)
            if let softwareUpdate = FleetDataNormalizer.softwareUpdate(page.data) {
                mergeSoftwareUpdates([vin: softwareUpdate])
            } else {
                softwareUpdatesByVIN.removeValue(forKey: vin)
            }
            return page.requestID
        }
    }

    @discardableResult
    func installSelectedVehicleSoftwareUpdate(offsetSec: Int = 0) async -> Bool {
        await performSoftwareMutation(
            progressMessage: "Scheduling software update.",
            successMessage: offsetSec == 0 ? "Requested software install." : "Scheduled software install."
        ) { vin in
            try await apiClient.installSoftwareUpdate(vin: vin, offsetSec: offsetSec)
        }
    }

    @discardableResult
    func cancelSelectedVehicleSoftwareUpdate() async -> Bool {
        await performSoftwareMutation(
            progressMessage: "Canceling software update.",
            successMessage: "Canceled software update."
        ) { vin in
            try await apiClient.cancelSoftwareUpdate(vin: vin)
        }
    }

    func refreshSelectedVehicleDrives(limit: Int = 10) async {
        await performSelectedVehicleRefresh(loading: .drives) { vin in
            let page = try await apiClient.drives(vin: vin, limit: limit, includeRoute: false)
            try validateReadResult(for: vin)
            mergeRecentDrives(page.data, for: vin)
            return page.requestID
        }
    }

    func refreshRoute(for drive: FleetDriveSession, maxPoints: Int = 500) async {
        guard !drive.sessionID.isEmpty,
              drive.startedAt > 0,
              let endedAt = drive.endedAt,
              endedAt > drive.startedAt,
              maxPoints > 0 else {
            return
        }

        do {
            let page = try await apiClient.driveRoute(
                sessionID: drive.sessionID,
                startTime: drive.startedAt,
                endTime: endedAt,
                limit: nil,
                maxPoints: maxPoints
            )
            try validateReadResult(for: drive.vin)
            let normalizedRoute = FleetDataNormalizer.routePoints(page.data, limit: maxPoints)
            if !normalizedRoute.isEmpty {
                driveRoutesBySessionID[drive.sessionID] = normalizedRoute
                recentDrives = FleetDataNormalizer.driveSessions(recentDrives.map { existingDrive in
                    guard existingDrive.sessionID == drive.sessionID else {
                        return existingDrive
                    }
                    var updatedDrive = existingDrive
                    updatedDrive.route = normalizedRoute
                    return updatedDrive
                })
            }
            await recordRefreshSuccess(requestID: page.requestID)
        } catch {
            if !Task.isCancelled, !(error is CancellationError) {
                lastErrorMessage = error.localizedDescription
            }
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
            try validateReadResult(for: vin)
            locationHistoryByVIN[vin] = FleetDataNormalizer.routePoints(page.data, limit: limit)
            latestRequestID = page.requestID ?? latestRequestID
            didRefresh = true
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
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
            try validateReadResult(for: vin)
            telemetrySeriesByVIN[vin] = FleetDataNormalizer.telemetrySeries(page.data, limit: limit)
            latestRequestID = page.requestID ?? latestRequestID
            didRefresh = true
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            latestErrorMessage = error.localizedDescription
        }

        if didRefresh {
            await recordRefreshSuccess(requestID: latestRequestID)
        }
        if let latestErrorMessage {
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
                try FleetRawDataExporter.write(export)
            }.value
            let summary = FleetRawDataExporter.summary(for: export)

            rawDataExportURL = exportURL
            rawDataExportMessage = summary.message
            lastErrorMessage = nil
            lastRequestID = summary.latestRequestID ?? lastRequestID
        } catch {
            let message = error.localizedDescription
            lastErrorMessage = message
            rawDataExportMessage = message
        }
    }

    // MARK: - Snapshot & Cache Hydration

    func applySnapshotState(_ state: FleetCachedState, isCached: Bool) {
        activeCharging = FleetDataNormalizer.chargeSessions(state.activeCharging)
        activeDrivesByVIN = FleetDataNormalizer.activeDrivesByVIN(state.activeDrivesByVIN)
        cacheDate = state.savedAt
        capabilities = FleetDataNormalizer.capabilities(state.capabilities)
        cursor = state.cursor
        driveRoutesBySessionID = FleetDataNormalizer.routePointsBySessionID(state.driveRoutesBySessionID)
        isShowingCachedData = isCached
        lastRefreshDate = state.savedAt
        lastRequestID = nil
        locationHistoryByVIN = FleetDataNormalizer.routePointsByVIN(state.locationHistoryByVIN)
        recentDrives = FleetDataNormalizer.driveSessions(state.recentDrives)
        selectedVIN = state.selectedVIN
        softwareUpdatesByVIN = [:]
        mergeSoftwareUpdates(state.softwareUpdatesByVIN, fromCachedState: isCached)
        telemetrySeriesByVIN = FleetDataNormalizer.telemetrySeriesByVIN(state.telemetrySeriesByVIN)
        user = FleetDataNormalizer.user(state.user)
        vehicles = FleetDataNormalizer.vehicles(state.vehicles)
        mergeSoftwareUpdates(FleetDataNormalizer.softwareUpdatesByVIN(from: vehicles), fromCachedState: isCached)
        loadState = .loaded

        keepValidSelectionOrSelectFirst()
    }

    // MARK: - Private Coordination & Execution Helpers

    private func validateReadResult(for vin: String) throws {
        try Task.checkCancellation()
        guard vehicles.contains(where: { $0.vin == vin }) else {
            throw CancellationError()
        }
    }

    @discardableResult
    private func performSelectedVehicleRefresh(
        loading kind: LoadingKind? = nil,
        operation: (String) async throws -> String?
    ) async -> Bool {
        guard let vin = selectedVehicle?.vin else {
            return false
        }

        if let kind {
            beginLoading(kind)
        }
        defer {
            if let kind {
                finishLoading(kind)
            }
        }

        do {
            let requestID = try await operation(vin)
            await recordRefreshSuccess(requestID: requestID)
            return true
        } catch {
            if !Task.isCancelled, !(error is CancellationError) {
                lastErrorMessage = error.localizedDescription
            }
            return false
        }
    }

    private func performSoftwareMutation(
        progressMessage: String,
        successMessage: String,
        operation: (String) async throws -> FleetAPIPage<[String: JSONValue]>
    ) async -> Bool {
        guard let vin = selectedVehicle?.vin, !isMutatingSoftware else {
            return false
        }

        isMutatingSoftware = true
        softwareActionMessage = progressMessage
        defer { isMutatingSoftware = false }

        do {
            let page = try await operation(vin)
            lastErrorMessage = nil
            lastRequestID = page.requestID ?? lastRequestID
            softwareActionMessage = successMessage
            await refreshSelectedVehicleSoftware(forceRefresh: true)
            return true
        } catch {
            let message = error.localizedDescription
            lastErrorMessage = message
            softwareActionMessage = message
            return false
        }
    }

    private func recordRefreshSuccess(requestID: String?) async {
        lastErrorMessage = nil
        lastRequestID = requestID ?? lastRequestID
        lastRefreshDate = Date()
        await saveCurrentState()
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
                try await Task.sleep(for: .seconds(max(interval, 0)))
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

    private func loadInitialSelectedVehicleDetailsIfNeeded() async {
        guard let vin = selectedVehicle?.vin else {
            return
        }

        if selectedVehicle?.latest?.tires == nil {
            await refreshSelectedVehicleLive()
        }
        if activeDrivesByVIN[vin] == nil {
            await refreshSelectedVehicleActiveDrive()
        }
        await refreshSelectedVehicleChargingSessions()
        await refreshSelectedVehicleSoftware()
        if selectedVehicleRecentDrives.isEmpty || selectedVehicleRecentDrives.contains(where: needsDriveDetails) {
            await refreshSelectedVehicleDrives()
        }
        if locationHistoryByVIN[vin, default: []].isEmpty || telemetrySeriesByVIN[vin, default: []].isEmpty {
            await refreshSelectedVehicleTelemetry()
        }
    }

    private func refreshAllSelectedVehicleDetails() async {
        let steps: [() async -> Void] = [
            { await self.refreshSelectedVehicleLive() },
            { await self.refreshSelectedVehicleActiveDrive() },
            { await self.refreshSelectedVehicleChargingSessions() },
            {
                if self.selectedVehicleSoftwareUpdate?.releaseNotesCount == nil {
                    await self.refreshSelectedVehicleSoftware()
                }
            },
            { await self.refreshSelectedVehicleDrives() },
            { await self.refreshSelectedVehicleTelemetry() }
        ]

        for step in steps {
            guard !Task.isCancelled else { return }
            await step()
        }
    }

    private func needsDriveDetails(_ drive: FleetDriveSession) -> Bool {
        drive.route.isEmpty && (drive.distanceMiles == nil || drive.avgSpeedMPH == nil || drive.maxSpeedMPH == nil)
    }

    // MARK: - Private State Merging & Persistence

    private func hydrateFromCacheIfAvailable() async {
        guard vehicles.isEmpty else {
            return
        }

        do {
            guard let cachedState = try await cache.load() else {
                return
            }
            applySnapshotState(cachedState, isCached: true)
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

    private func applyVehicleRoster(_ roster: [FleetVehicle]) {
        let previousSnapshots = latestSnapshotsByVIN
        let nextVehicles = FleetDataNormalizer.vehicles(roster)
        let currentVINs = Set(nextVehicles.map(\.vin))
        let removedVINs = Set(vehicles.map(\.vin)).subtracting(currentVINs)

        vehicles = nextVehicles.map { vehicle in
            guard let previous = previousSnapshots[vehicle.vin] else {
                return vehicle
            }
            if let previousTimestamp = previous.updatedAt,
               (vehicle.latest?.updatedAt ?? 0) < previousTimestamp {
                var updatedVehicle = vehicle
                updatedVehicle.latest = previous
                return updatedVehicle
            }
            if vehicle.latest?.tires == nil, let previousTires = previous.tires {
                var updatedVehicle = vehicle
                updatedVehicle.latest?.tires = previousTires
                return updatedVehicle
            }
            return vehicle
        }
        if !removedVINs.isEmpty {
            let removedSessionIDs = Set(recentDrives.lazy.filter { removedVINs.contains($0.vin) }.map(\.sessionID))
                .union(activeDrivesByVIN.values.lazy.filter { removedVINs.contains($0.vin) }.map(\.sessionID))
            driveRoutesBySessionID = driveRoutesBySessionID.filter { sessionID, _ in
                !removedSessionIDs.contains(sessionID) && !removedVINs.contains { vin in
                    sessionID.hasPrefix("\(vin):")
                        || sessionID.hasPrefix("drive:\(vin):")
                        || sessionID == "active:\(vin)"
                }
            }
            activeCharging.removeAll { removedVINs.contains($0.vin) }
            recentDrives.removeAll { removedVINs.contains($0.vin) }
            for vin in removedVINs {
                activeDrivesByVIN.removeValue(forKey: vin)
                softwareUpdatesByVIN.removeValue(forKey: vin)
                locationHistoryByVIN.removeValue(forKey: vin)
                telemetrySeriesByVIN.removeValue(forKey: vin)
            }
        }

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

    private func mergeSoftwareUpdates(_ updates: [String: FleetSoftwareUpdate], fromCachedState: Bool = false) {
        for (vin, incoming) in FleetDataNormalizer.softwareUpdatesByVIN(updates) {
            var update = incoming
            if fromCachedState, update.releaseNotesCount == 0, update.releaseNotes.isEmpty {
                // Older builds used zero for release notes they had never requested.
                update.releaseNotesCount = nil
            }
            if let previous = softwareUpdatesByVIN[vin] {
                if let incomingTimestamp = update.sourceTimestamp,
                   let previousTimestamp = previous.sourceTimestamp,
                   incomingTimestamp < previousTimestamp {
                    continue
                }
                if update.releaseNotesCount == nil,
                   update.releaseNotes.isEmpty,
                   update.currentVersion == previous.currentVersion,
                   update.availableVersion == previous.availableVersion {
                    update.releaseNotes = previous.releaseNotes
                    update.releaseNotesCount = previous.releaseNotesCount
                }
            }
            softwareUpdatesByVIN[vin] = update
        }
    }

    private func mergeActiveDrive(_ drive: FleetActiveDriveSession, for vin: String) {
        guard let normalizedDrive = FleetDataNormalizer.activeDrive(drive, fallbackVIN: vin) else {
            activeDrivesByVIN.removeValue(forKey: vin)
            return
        }

        guard normalizedDrive.active else {
            activeDrivesByVIN.removeValue(forKey: normalizedDrive.vin.isEmpty ? vin : normalizedDrive.vin)
            return
        }

        activeDrivesByVIN[normalizedDrive.vin] = normalizedDrive
        if let latest = normalizedDrive.latest {
            mergeLatestSnapshots([latest])
        }
        if !normalizedDrive.sessionID.isEmpty, !normalizedDrive.route.isEmpty {
            driveRoutesBySessionID[normalizedDrive.sessionID] = normalizedDrive.route
        }
    }

    private func mergeLatestSnapshots(_ snapshots: [FleetLatestSnapshot]) {
        let previousSnapshots = latestSnapshotsByVIN
        let knownVINs = Set(vehicles.map(\.vin))
        let normalizedSnapshots = FleetDataNormalizer.latestSnapshots(snapshots).filter { snapshot in
            knownVINs.contains(snapshot.vin)
                && (snapshot.updatedAt ?? 0) >= (previousSnapshots[snapshot.vin]?.updatedAt ?? 0)
        }
        guard !normalizedSnapshots.isEmpty else {
            return
        }

        var snapshotsByVIN: [String: FleetLatestSnapshot] = [:]
        var nestedSoftwareUpdates: [String: FleetSoftwareUpdate] = [:]
        for var snapshot in normalizedSnapshots {
            if snapshot.tires == nil {
                snapshot.tires = previousSnapshots[snapshot.vin]?.tires
            }
            snapshotsByVIN[snapshot.vin] = snapshot
            if let software = snapshot.software {
                nestedSoftwareUpdates[snapshot.vin] = software
            }
        }
        mergeSoftwareUpdates(nestedSoftwareUpdates)

        vehicles = FleetDataNormalizer.vehicles(vehicles.map { vehicle in
            guard let snapshot = snapshotsByVIN[vehicle.vin] else {
                return vehicle
            }

            var updatedVehicle = vehicle
            updatedVehicle.latest = snapshot
            return updatedVehicle
        })
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
