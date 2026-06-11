import AuthenticationServices
import SwiftUI

@main
struct TeslaSiriApp: App {
    @State private var notificationWebhooks = FleetNotificationWebhookStore()
    @State private var notifications = FleetNotificationCenter()
    @State private var oauthClient = FleetBackend.makeOAuthClient()
    @State private var store = FleetBackend.makeDataStore()
    @State private var tokenStore = FleetBackend.makeOAuthTokenStore()

    var body: some Scene {
        WindowGroup {
            ContentView(
                store: store,
                notificationWebhooks: notificationWebhooks,
                notifications: notifications,
                oauthClient: oauthClient,
                tokenStore: tokenStore
            )
        }
    }
}

struct ContentView: View {
    let store: FleetDataStore
    let notificationWebhooks: FleetNotificationWebhookStore
    let notifications: FleetNotificationCenter
    let oauthClient: FleetOAuthClient
    let tokenStore: FleetOAuthTokenKeychain

    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var authErrorMessage: String?
    @State private var diagnostics = BackendDiagnosticsState()

    var body: some View {
        NavigationStack {
            FleetDashboardView(
                store: store,
                notificationWebhooks: notificationWebhooks,
                diagnostics: diagnostics,
                onProbeAccount: {
                    Task { await runBackendProbe() }
                },
                onReloadFleet: {
                    Task { await reloadFleet() }
                },
                onRequestNotificationAuthorization: {
                    Task { await enableNotifications() }
                },
                onSendLocalNotificationTest: {
                    Task { await sendLocalNotificationTest() }
                },
                onExportRawData: {
                    Task { await exportRawData() }
                },
                onSignOut: {
                    Task { await signOut() }
                }
            )
            .navigationTitle("Tesla")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await signIn() }
                    } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                    }
                    .accessibilityLabel("Sign In")

                    Button {
                        Task { await enableNotifications() }
                    } label: {
                        Image(systemName: "bell")
                    }
                    .accessibilityLabel("Enable Notifications")

                    Button {
                        Task { await reloadFleet() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.loadState.isLoading || store.isRefreshing)
                    .accessibilityLabel("Refresh")
                }
            }
        }
        .alert("Sign In Failed", isPresented: authErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(authErrorMessage ?? "Unknown error")
        }
        .task {
            refreshDiagnostics()
            await store.loadInitialDataIfNeeded()
            await notificationWebhooks.refresh()
        }
    }

    private var authErrorBinding: Binding<Bool> {
        Binding {
            authErrorMessage != nil
        } set: { isPresented in
            if !isPresented {
                authErrorMessage = nil
            }
        }
    }

    private func signIn() async {
        do {
            let flow = try oauthClient.makeAuthorizationFlow()
            let callbackURL = try await webAuthenticationSession.authenticate(
                using: flow.authorizationURL,
                callbackURLScheme: oauthClient.callbackURLScheme
            )
            let tokenSet = try await oauthClient.exchangeCode(from: callbackURL, flow: flow)
            try tokenStore.saveTokenSet(tokenSet)
            diagnostics.probeMessage = "Signed in. Loading fleet data."
            refreshDiagnostics()
            await store.loadInitialData()
            await notificationWebhooks.refresh()
            refreshDiagnostics()
        } catch {
            authErrorMessage = error.localizedDescription
            diagnostics.probeMessage = error.localizedDescription
            refreshDiagnostics()
        }
    }

    private func reloadFleet() async {
        await store.refresh()
        await notificationWebhooks.refresh()
        refreshDiagnostics()
    }

    private func runBackendProbe() async {
        diagnostics.isProbeRunning = true
        diagnostics.probeMessage = "Checking account and notification hooks."
        defer {
            diagnostics.isProbeRunning = false
            refreshDiagnostics()
        }

        do {
            let apiClient = FleetBackend.makeAPIClient()
            let userPage = try await apiClient.currentUser()
            let deviceID = try FleetBackend.makeDeviceIdentity().deviceID()
            let webhookPage = try await apiClient.notificationWebhooks(forDeviceID: deviceID, includeDisabled: true)
            let accountName = userPage.data.email ?? userPage.data.name ?? "signed in"
            let requestID = webhookPage.requestID ?? userPage.requestID
            diagnostics.probeMessage = backendProbeMessage(accountName: accountName, webhookCount: webhookPage.data.count, requestID: requestID)
        } catch {
            diagnostics.probeMessage = error.localizedDescription
        }
    }

    private func signOut() async {
        do {
            try tokenStore.deleteTokenSet()
            await store.reset(clearCache: true)
            notificationWebhooks.reset()
            diagnostics.probeMessage = "Signed out and cleared cached fleet data."
            refreshDiagnostics()
        } catch {
            authErrorMessage = error.localizedDescription
            diagnostics.probeMessage = error.localizedDescription
            refreshDiagnostics()
        }
    }

    private func enableNotifications() async {
        await notificationWebhooks.requestAuthorization()
    }

    private func sendLocalNotificationTest() async {
        let payload = FleetWebhookNotificationPayload(
            id: "teslasiri-local-test-\(Int(Date().timeIntervalSince1970))",
            event: FleetNotificationEvent.driveStarted,
            vin: store.selectedVIN,
            vehicleName: store.selectedVehicle?.name,
            title: "TeslaSiri notification test",
            body: "Local notification scheduling is working.",
            timestamp: Int64(Date().timeIntervalSince1970 * 1_000)
        )

        do {
            try await notifications.scheduleNotification(for: payload)
            notificationWebhooks.recordLocalNotificationResult("Scheduled local notification test.")
        } catch {
            notificationWebhooks.recordLocalNotificationResult(error.localizedDescription, error: error.localizedDescription)
        }
    }

    private func exportRawData() async {
        await store.exportSelectedVehicleRawData()
        refreshDiagnostics()
    }

    private func refreshDiagnostics() {
        do {
            let tokenSet = try tokenStore.loadTokenSet()
            diagnostics.isSignedIn = tokenSet != nil
            diagnostics.tokenExpiresAt = tokenSet?.expiresAt

            if let tokenSet {
                let inspection = tokenSet.inspection
                diagnostics.tokenAudience = inspection.audience
                diagnostics.tokenFormat = inspection.format
                diagnostics.tokenIssuer = inspection.issuer
                diagnostics.tokenScopes = inspection.scopes
            } else {
                diagnostics.clearTokenInspection()
            }
        } catch {
            diagnostics.isSignedIn = false
            diagnostics.tokenExpiresAt = nil
            diagnostics.clearTokenInspection()
            diagnostics.probeMessage = error.localizedDescription
        }

        do {
            diagnostics.deviceID = try FleetBackend.makeDeviceIdentity().deviceID()
        } catch {
            diagnostics.deviceID = "--"
            diagnostics.probeMessage = error.localizedDescription
        }
    }

    private func backendProbeMessage(accountName: String, webhookCount: Int, requestID: String?) -> String {
        var message = "Account OK: \(accountName). Notification hooks: \(webhookCount)."
        if let requestID {
            message += " Request ID: \(requestID)."
        }
        return message
    }
}

private struct BackendDiagnosticsState: Equatable {
    var deviceID = "--"
    var isProbeRunning = false
    var isSignedIn = false
    var probeMessage = "Not run"
    var tokenAudience: [String] = []
    var tokenExpiresAt: Date?
    var tokenFormat = "--"
    var tokenIssuer: String?
    var tokenScopes: [String] = []

    mutating func clearTokenInspection() {
        tokenAudience = []
        tokenFormat = "--"
        tokenIssuer = nil
        tokenScopes = []
    }
}

private struct FleetDashboardView: View {
    let store: FleetDataStore
    let notificationWebhooks: FleetNotificationWebhookStore
    let diagnostics: BackendDiagnosticsState
    let onProbeAccount: () -> Void
    let onReloadFleet: () -> Void
    let onRequestNotificationAuthorization: () -> Void
    let onSendLocalNotificationTest: () -> Void
    let onExportRawData: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        List {
            BackendDiagnosticsSection(
                store: store,
                diagnostics: diagnostics,
                onProbeAccount: onProbeAccount,
                onReloadFleet: onReloadFleet,
                onExportRawData: onExportRawData,
                onSignOut: onSignOut
            )

            NotificationWebhookDebugSection(
                store: notificationWebhooks,
                capabilities: store.capabilities,
                selectedVIN: store.selectedVIN,
                onRequestAuthorization: onRequestNotificationAuthorization,
                onSendLocalTest: onSendLocalNotificationTest
            )

            NormalizedDataDebugSection(store: store)

            FleetContentSections(store: store)
        }
        .refreshable {
            await store.refresh()
        }
    }
}

private struct FleetContentSections: View {
    let store: FleetDataStore

    var body: some View {
        if store.loadState.isLoading && store.vehicles.isEmpty {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading fleet")
                }
            }
        } else if case .failed(let message) = store.loadState, store.vehicles.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Unable to load fleet", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await store.loadInitialData() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            }
        } else if store.vehicles.isEmpty {
            Section {
                ContentUnavailableView("No vehicles", systemImage: "car", description: Text("No linked vehicles were returned."))
            }
        } else {
            if store.isShowingCachedData {
                CachedDataSection(cacheDate: store.cacheDate)
            }

            Section("Vehicles") {
                ForEach(store.vehicles) { vehicle in
                    Button {
                        store.selectVehicle(vin: vehicle.vin)
                    } label: {
                        VehicleRow(
                            name: vehicle.name,
                            vin: vehicle.vin,
                            batteryLevel: vehicle.latest?.batteryLevel,
                            chargingState: vehicle.latest?.chargingState,
                            isLocked: vehicle.latest?.locked,
                            isSelected: store.selectedVIN == vehicle.vin
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let vehicle = store.selectedVehicle {
                VehicleStatusSection(vehicleName: vehicle.name, snapshot: vehicle.latest, units: store.user?.units)
            }

            if let softwareUpdate = store.selectedVehicleSoftwareUpdate {
                SoftwareUpdateSection(store: store, update: softwareUpdate)
            } else if store.isLoadingSoftware {
                Section("Software") {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading software")
                    }
                }
            }

            if let activeDrive = store.selectedVehicleActiveDrive {
                ActiveDriveSection(drive: activeDrive)
            } else if store.isLoadingActiveDrive {
                Section("Active Drive") {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading active drive")
                    }
                }
            }

            let selectedDrives = Array(store.selectedVehicleRecentDrives.prefix(5))
            if !selectedDrives.isEmpty || store.isLoadingDrives {
                RecentDrivesSection(drives: selectedDrives, isLoading: store.isLoadingDrives)
            }

            if !store.activeCharging.isEmpty || store.isLoadingCharging {
                Section("Charging") {
                    if store.isLoadingCharging && store.activeCharging.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Loading charging")
                        }
                    }

                    ForEach(store.activeCharging) { session in
                        ChargingSessionRow(
                            status: session.status,
                            startedAt: session.startedAtDate,
                            energyAddedKWH: session.energyAddedKWH,
                            avgPowerKW: session.avgPowerKW
                        )
                    }
                }
            }

            if let user = store.user {
                AccountSection(email: user.email, units: user.units, scopes: user.scopes)
            }
        }
    }
}

private struct BackendDiagnosticsSection: View {
    let store: FleetDataStore
    let diagnostics: BackendDiagnosticsState
    let onProbeAccount: () -> Void
    let onReloadFleet: () -> Void
    let onExportRawData: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        Section("Backend") {
            LabeledContent("Auth", value: diagnostics.isSignedIn ? "Signed in" : "Not signed in")

            if let tokenExpiresAt = diagnostics.tokenExpiresAt {
                LabeledContent("Token expires", value: tokenExpiresAt.formatted(date: .abbreviated, time: .shortened))
            }

            if diagnostics.isSignedIn {
                LabeledContent("Token", value: diagnostics.tokenFormat)

                if let tokenIssuer = diagnostics.tokenIssuer {
                    DiagnosticMonospacedValue(title: "Issuer", value: tokenIssuer)
                }

                if !diagnostics.tokenAudience.isEmpty {
                    DiagnosticMonospacedValue(title: "Audience", value: diagnostics.tokenAudience.joined(separator: ", "))
                }

                if !diagnostics.tokenScopes.isEmpty {
                    DiagnosticMonospacedValue(title: "Token scopes", value: diagnostics.tokenScopes.joined(separator: ", "))
                }
            }

            DiagnosticMonospacedValue(title: "Device ID", value: diagnostics.deviceID)
            LabeledContent("Data", value: dataStatus)

            if let lastRefreshDate = store.lastRefreshDate {
                LabeledContent("Last refresh", value: lastRefreshDate.formatted(date: .abbreviated, time: .shortened))
            }

            LabeledContent("Cursor", value: store.cursor.map(String.init) ?? "--")
            LabeledContent("Vehicles", value: "\(store.vehicles.count)")
            LabeledContent("Active drives", value: "\(store.activeDrivesByVIN.count)")
            LabeledContent("Software states", value: "\(store.softwareUpdatesByVIN.count)")
            LabeledContent("Recent drives", value: "\(store.recentDrives.count)")
            LabeledContent("Locations", value: "\(store.selectedVehicleLocationHistory.count)")
            LabeledContent("Telemetry points", value: "\(store.selectedVehicleTelemetrySeries.count)")
            LabeledContent("Drive route points", value: "\(store.cachedDriveRouteCount)")
            LabeledContent("Raw export", value: store.rawDataExportMessage)

            if let rawDataExportURL = store.rawDataExportURL {
                DiagnosticMonospacedValue(title: "Export file", value: rawDataExportURL.path)
            }

            if let capabilities = store.capabilities {
                LabeledContent("Capabilities", value: capabilitiesSummary(capabilities))
            }

            if let lastRequestID = store.lastRequestID {
                DiagnosticMonospacedValue(title: "Request ID", value: lastRequestID)
            }

            if let lastErrorMessage = store.lastErrorMessage {
                Label(lastErrorMessage, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Probe")
                Spacer(minLength: 12)
                if diagnostics.isProbeRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(diagnostics.probeMessage)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    onProbeAccount()
                } label: {
                    Label("Probe Account", systemImage: "network")
                }
                .disabled(diagnostics.isProbeRunning)

                Button {
                    onReloadFleet()
                } label: {
                    Label("Reload Fleet", systemImage: "arrow.clockwise")
                }
                .disabled(store.loadState.isLoading || store.isRefreshing)
            }

            Button {
                onExportRawData()
            } label: {
                if store.isExportingRawData {
                    Label("Exporting Raw Data", systemImage: "hourglass")
                } else {
                    Label("Export Raw Data", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(!diagnostics.isSignedIn || store.selectedVehicle == nil || store.isExportingRawData)

            if diagnostics.isSignedIn {
                Button(role: .destructive) {
                    onSignOut()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
    }

    private func capabilitiesSummary(_ capabilities: FleetCapabilities) -> String {
        "\(capabilities.scopes.count) scopes, \(capabilities.controlActions.count) controls, \(capabilities.notificationEvents.count) notifications"
    }

    private var dataStatus: String {
        if store.loadState.isLoading {
            return "Loading"
        }
        if store.isRefreshing {
            return "Refreshing"
        }
        if store.isLoadingActiveDrive {
            return "Loading active drive"
        }
        if store.isLoadingCharging {
            return "Loading charging"
        }
        if store.isLoadingDrives {
            return "Loading drives"
        }
        if store.isMutatingSoftware {
            return "Updating software"
        }
        if store.isLoadingSoftware {
            return "Loading software"
        }
        if store.isLoadingTelemetry {
            return "Loading telemetry"
        }
        if store.isExportingRawData {
            return "Exporting raw data"
        }
        if store.isShowingCachedData {
            return "Cached"
        }
        if store.vehicles.isEmpty {
            return "Empty"
        }
        return "Live"
    }
}

private struct NormalizedDataDebugSection: View {
    let store: FleetDataStore

    var body: some View {
        Section("Normalized Data") {
            if let vehicle = store.selectedVehicle {
                DiagnosticMonospacedValue(title: "Selected VIN", value: vehicle.vin)
                LabeledContent("Units", value: unitDescription)
                LabeledContent("Temperature display", value: temperatureSuffix.trimmingCharacters(in: .whitespaces))
                LabeledContent("Live snapshot", value: snapshotSummary(vehicle.latest))
                LabeledContent("Software source", value: softwareSource(for: vehicle))

                if let software = store.selectedVehicleSoftwareUpdate {
                    LabeledContent("Software", value: softwareSummary(software))
                }

                if let activeDrive = store.selectedVehicleActiveDrive {
                    LabeledContent("Active drive", value: activeDriveSummary(activeDrive))
                    LabeledContent("Route samples", value: routeSampleSummary(activeDrive.route))
                    LabeledContent("Buffered samples", value: "\(activeDrive.bufferedPoints.count)")
                    LabeledContent("Start location", value: formattedCoordinate(latitude: activeDrive.startLocation?.latitude, longitude: activeDrive.startLocation?.longitude))
                    LabeledContent("Latest route point", value: formattedCoordinate(latitude: activeDrive.latestRoutePoint?.latitude, longitude: activeDrive.latestRoutePoint?.longitude))
                } else {
                    LabeledContent("Active drive", value: store.isLoadingActiveDrive ? "Loading" : "None")
                }

                LabeledContent("Location history", value: routeSampleSummary(store.selectedVehicleLocationHistory))
                LabeledContent("Telemetry series", value: telemetrySummary)

                ForEach(telemetryFieldRows) { row in
                    DiagnosticMonospacedValue(title: row.key, value: row.value)
                }
            } else {
                Label("No selected vehicle", systemImage: "car")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var unitDescription: String {
        store.user?.units?.capitalized ?? "--"
    }

    private var temperatureSuffix: String {
        store.user?.units == "metric" ? " C" : " F"
    }

    private var telemetrySummary: String {
        let points = store.selectedVehicleTelemetrySeries
        guard let firstPoint = points.first else {
            return points.isEmpty ? "No points" : "\(points.count) points"
        }
        let keys = firstPoint.fields.keys.sorted().prefix(6).joined(separator: ", ")
        return keys.isEmpty ? "\(points.count) points" : "\(points.count) points; \(keys)"
    }

    private var telemetryFieldRows: [DiagnosticFieldRow] {
        guard let point = store.selectedVehicleTelemetrySeries.first else {
            return []
        }
        return point.fields.keys.sorted().prefix(8).compactMap { key in
            point.fields[key].map { DiagnosticFieldRow(key: key, value: formattedJSONValue($0)) }
        }
    }

    private func snapshotSummary(_ snapshot: FleetLatestSnapshot?) -> String {
        guard let snapshot else {
            return "None"
        }
        let updated = snapshot.updatedAtDate?.formatted(date: .abbreviated, time: .shortened) ?? "--"
        let battery = formattedNumber(snapshot.batteryLevel, suffix: "%")
        return "\(battery), updated \(updated)"
    }

    private func softwareSource(for vehicle: FleetVehicle) -> String {
        let hasDedicatedSoftware = store.softwareUpdatesByVIN[vehicle.vin] != nil
        let hasSnapshotSoftware = vehicle.latest?.software != nil
        switch (hasDedicatedSoftware, hasSnapshotSoftware) {
        case (true, true):
            return "Dedicated + live"
        case (true, false):
            return "Dedicated endpoint"
        case (false, true):
            return "Live snapshot"
        case (false, false):
            return "None"
        }
    }

    private func softwareSummary(_ software: FleetSoftwareUpdate) -> String {
        if let availableVersion = software.availableVersion, availableVersion != software.currentVersion {
            return "\(software.currentVersion ?? "--") -> \(availableVersion)"
        }
        return software.currentVersion ?? software.status ?? "Present"
    }

    private func activeDriveSummary(_ drive: FleetActiveDriveSession) -> String {
        let routeCount = drive.routePointCount ?? drive.route.count
        let duration = formattedDuration(milliseconds: drive.durationMS)
        return "\(routeCount) route, \(duration)"
    }

    private func routeSampleSummary(_ points: [FleetRoutePoint]) -> String {
        guard let first = points.first, let last = points.last else {
            return "No points"
        }
        if first.id == last.id {
            return formattedCoordinate(latitude: first.latitude, longitude: first.longitude)
        }
        return "\(formattedCoordinate(latitude: first.latitude, longitude: first.longitude)) -> \(formattedCoordinate(latitude: last.latitude, longitude: last.longitude))"
    }
}

private struct DiagnosticFieldRow: Identifiable {
    let key: String
    let value: String

    var id: String { key }
}

private struct NotificationWebhookDebugSection: View {
    @Bindable var store: FleetNotificationWebhookStore
    let capabilities: FleetCapabilities?
    let selectedVIN: String?
    let onRequestAuthorization: () -> Void
    let onSendLocalTest: () -> Void

    var body: some View {
        Section("Notification Webhooks") {
            LabeledContent("Authorization", value: store.authorizationStatusDescription)
            DiagnosticMonospacedValue(title: "Device ID", value: store.deviceID)
            LabeledContent("Hooks", value: "\(store.activeWebhooks.count) active / \(store.webhooks.count) total")

            if let configuredCallbackURL = store.configuredCallbackURL {
                DiagnosticMonospacedValue(title: "Configured URL", value: configuredCallbackURL.absoluteString)
            }

            TextField("Callback URL", text: $store.draftCallbackURLString)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()

            if let lastRequestID = store.lastRequestID {
                DiagnosticMonospacedValue(title: "Hook request", value: lastRequestID)
            }

            if let lastErrorMessage = store.lastErrorMessage {
                Label(lastErrorMessage, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }

            LabeledContent("Hook action", value: store.lastActionMessage)

            HStack {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading || store.isMutating)

                Button {
                    Task { await store.ensureWebhook(capabilities: capabilities, vins: selectedVIN.map { [$0] } ?? []) }
                } label: {
                    Label("Ensure Hook", systemImage: "link.badge.plus")
                }
                .disabled(store.isLoading || store.isMutating)
            }

            HStack {
                Button {
                    onRequestAuthorization()
                } label: {
                    Label("Authorize", systemImage: "bell.badge")
                }

                Button {
                    onSendLocalTest()
                } label: {
                    Label("Local Test", systemImage: "bell.and.waves.left.and.right")
                }
            }

            ForEach(store.webhooks) { webhook in
                NotificationWebhookRow(
                    webhook: webhook,
                    isMutating: store.isMutating,
                    selectedVIN: selectedVIN,
                    onToggle: {
                        Task { await store.setWebhook(webhook, enabled: !webhook.enabled) }
                    },
                    onRefreshEvents: {
                        Task { await store.refreshEvents(for: webhook, capabilities: capabilities) }
                    },
                    onTest: {
                        Task { await store.testWebhook(webhook, vin: selectedVIN) }
                    },
                    onDelete: {
                        Task { await store.deleteWebhook(webhook) }
                    }
                )
            }
        }
    }
}

private struct NotificationWebhookRow: View {
    let webhook: FleetDeviceNotificationWebhook
    let isMutating: Bool
    let selectedVIN: String?
    let onToggle: () -> Void
    let onRefreshEvents: () -> Void
    let onTest: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(webhook.enabled ? "Enabled" : "Disabled", systemImage: webhook.enabled ? "bell.badge.fill" : "bell.slash")
                    .font(.headline)
                Spacer(minLength: 12)
                Text(webhook.updatedAtDate, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(webhook.url.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            Text(webhook.events.isEmpty ? "No events" : webhook.events.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !webhook.vins.isEmpty {
                Text("VINs " + webhook.vins.map { String($0.suffix(6)) }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(webhook.enabled ? "Disable" : "Enable", action: onToggle)
                Button("Events", action: onRefreshEvents)
                Button("Test", action: onTest)
                Button("Delete", role: .destructive, action: onDelete)
            }
            .buttonStyle(.borderless)
            .disabled(isMutating)
        }
        .padding(.vertical, 4)
    }
}

private struct DiagnosticMonospacedValue: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(title)
        }
    }
}

private struct CachedDataSection: View {
    let cacheDate: Date?

    var body: some View {
        Section {
            Label {
                if let cacheDate {
                    Text("Showing cached data from \(cacheDate.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Showing cached data")
                }
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct VehicleRow: View {
    let name: String
    let vin: String
    let batteryLevel: Double?
    let chargingState: String?
    let isLocked: Bool?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "car.side")
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                Text("VIN " + String(vin.suffix(6)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text(formattedNumber(batteryLevel, suffix: "%"))
                    .font(.headline)
                HStack(spacing: 6) {
                    if let isLocked {
                        Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                    }
                    Text(chargingState ?? "--")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct VehicleStatusSection: View {
    let vehicleName: String
    let snapshot: FleetLatestSnapshot?
    let units: String?

    var body: some View {
        Section(vehicleName) {
            if let snapshot {
                LabeledContent("Battery", value: formattedNumber(snapshot.batteryLevel, suffix: "%"))
                LabeledContent("Charge limit", value: formattedNumber(snapshot.chargeLimitSOC, suffix: "%"))
                LabeledContent("Charging", value: snapshot.chargingState ?? "--")
                LabeledContent("Charger power", value: formattedNumber(snapshot.chargerPowerKW, fractionLength: 1, suffix: " kW"))
                LabeledContent("Range rate", value: formattedNumber(snapshot.chargeRateMPH, fractionLength: 0, suffix: " mph"))
                LabeledContent("Speed", value: formattedNumber(snapshot.speed, fractionLength: 0, suffix: " mph"))
                LabeledContent("Gear", value: snapshot.gear ?? "--")
                LabeledContent("Locked", value: lockState(snapshot.locked))
                LabeledContent("Sentry mode", value: boolState(snapshot.sentryMode))
                LabeledContent("Cabin temp", value: formattedNumber(snapshot.insideTemp, fractionLength: 0, suffix: temperatureSuffix))
                LabeledContent("Outside temp", value: formattedNumber(snapshot.outsideTemp, fractionLength: 0, suffix: temperatureSuffix))
                LabeledContent("Time to full", value: formattedNumber(snapshot.timeToFullCharge, fractionLength: 1, suffix: " hr"))
                LabeledContent("Odometer", value: formattedNumber(snapshot.odometer, fractionLength: 0, suffix: " mi"))
                LabeledContent("Freshness", value: formattedDuration(milliseconds: snapshot.freshnessMS))
                LabeledContent("Location", value: formattedCoordinate(latitude: snapshot.latitude, longitude: snapshot.longitude))
                LabeledContent("Updated", value: snapshot.updatedAtDate?.formatted(date: .abbreviated, time: .shortened) ?? "--")
            } else {
                Text("No live telemetry available")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var temperatureSuffix: String {
        units == "metric" ? " C" : " F"
    }

    private func lockState(_ locked: Bool?) -> String {
        guard let locked else {
            return "--"
        }
        return locked ? "Locked" : "Unlocked"
    }

    private func boolState(_ value: Bool?) -> String {
        guard let value else {
            return "--"
        }
        return value ? "On" : "Off"
    }
}

private struct SoftwareUpdateSection: View {
    let store: FleetDataStore
    let update: FleetSoftwareUpdate

    @State private var pendingAction: SoftwareAction?

    var body: some View {
        Section("Software") {
            LabeledContent("Current", value: update.currentVersion ?? "--")
            LabeledContent("Available", value: update.availableVersion ?? "--")
            LabeledContent("Status", value: update.status ?? "--")
            LabeledContent("Update", value: update.updateAvailable ? "Available" : "None")
            LabeledContent("Installable", value: update.installable ? "Yes" : "No")

            if let downloadPercent = update.downloadPercent {
                LabeledContent("Downloaded", value: formattedNumber(downloadPercent, fractionLength: 0, suffix: "%"))
            }
            if let installPercent = update.installPercent {
                LabeledContent("Installed", value: formattedNumber(installPercent, fractionLength: 0, suffix: "%"))
            }
            if let expectedDurationSec = update.expectedDurationSec {
                LabeledContent("Expected duration", value: formattedDuration(milliseconds: expectedDurationSec * 1_000))
            } else if let expectedDurationMinutes = update.expectedDurationMinutes {
                LabeledContent("Expected duration", value: formattedNumber(expectedDurationMinutes, fractionLength: 0, suffix: " min"))
            }
            if let scheduledStartDate = update.scheduledStartDate {
                LabeledContent("Scheduled", value: scheduledStartDate.formatted(date: .abbreviated, time: .shortened))
            }
            if let warningTimeRemainingMS = update.warningTimeRemainingMS {
                LabeledContent("Warning remaining", value: formattedDuration(milliseconds: warningTimeRemainingMS))
            }
            if let updatedAtDate = update.updatedAtDate {
                LabeledContent("Updated", value: updatedAtDate.formatted(date: .abbreviated, time: .shortened))
            }
            if let sourceDate = update.sourceDate {
                LabeledContent("Source", value: sourceDate.formatted(date: .abbreviated, time: .shortened))
            }

            LabeledContent("Software action", value: store.softwareActionMessage)

            HStack {
                Button {
                    Task { await store.refreshSelectedVehicleSoftware(forceRefresh: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoadingSoftware || store.isMutatingSoftware)

                if update.installable {
                    Button(role: .destructive) {
                        pendingAction = .installNow
                    } label: {
                        Label("Install Now", systemImage: "arrow.down.circle")
                    }
                    .disabled(store.isLoadingSoftware || store.isMutatingSoftware)
                }

                if canCancelUpdate {
                    Button {
                        pendingAction = .cancel
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .disabled(store.isLoadingSoftware || store.isMutatingSoftware)
                }
            }
            .buttonStyle(.borderless)

            if !update.releaseNotes.isEmpty {
                LabeledContent("Changelog", value: "\(update.releaseNotesCount ?? update.releaseNotes.count) notes")
                ForEach(Array(update.releaseNotes.prefix(5))) { note in
                    SoftwareReleaseNoteRow(note: note)
                }
            } else if let releaseNotesCount = update.releaseNotesCount, releaseNotesCount > 0 {
                LabeledContent("Changelog", value: "\(releaseNotesCount) notes")
            }
        }
        .confirmationDialog("Software Update", item: $pendingAction) { action in
            switch action {
            case .installNow:
                Button("Install Now", role: .destructive) {
                    Task { await store.installSelectedVehicleSoftwareUpdate(offsetSec: 0) }
                }
            case .cancel:
                Button("Cancel Update") {
                    Task { await store.cancelSelectedVehicleSoftwareUpdate() }
                }
            }
        } message: { action in
            switch action {
            case .installNow:
                Text("Schedule the available software update to install as soon as the vehicle accepts the command.")
            case .cancel:
                Text("Cancel the pending software update countdown for this vehicle.")
            }
        }
    }

    private var canCancelUpdate: Bool {
        update.scheduledStartTimeMS != nil || update.warningTimeRemainingMS != nil || update.status?.localizedCaseInsensitiveContains("scheduled") == true || update.status?.localizedCaseInsensitiveContains("pending") == true
    }

    private enum SoftwareAction: String, Identifiable {
        case cancel
        case installNow

        var id: String { rawValue }
    }
}

private struct SoftwareReleaseNoteRow: View {
    let note: FleetSoftwareReleaseNote

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.title)
                .font(.headline)
            if let subtitle = note.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let description = note.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let imageURL = note.imageURL {
                DiagnosticMonospacedValue(title: "Image", value: imageURL.absoluteString)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ChargingSessionRow: View {
    let status: String?
    let startedAt: Date
    let energyAddedKWH: Double?
    let avgPowerKW: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(status ?? "Charging", systemImage: "bolt.fill")
                    .font(.headline)
                Spacer()
                Text(startedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Text(formattedNumber(energyAddedKWH, fractionLength: 1, suffix: " kWh"))
                Text(formattedNumber(avgPowerKW, fractionLength: 1, suffix: " kW avg"))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }
}

private struct ActiveDriveSection: View {
    let drive: FleetActiveDriveSession

    var body: some View {
        Section("Active Drive") {
            Label("Active", systemImage: "location.north.line.fill")
                .font(.headline)
            DiagnosticMonospacedValue(title: "Session", value: drive.sessionID.isEmpty ? "--" : drive.sessionID)
            LabeledContent("Status", value: drive.status ?? "--")
            LabeledContent("Started", value: drive.startedAtDate?.formatted(date: .abbreviated, time: .shortened) ?? "--")
            LabeledContent("Last update", value: drive.lastUpdateDate?.formatted(date: .abbreviated, time: .shortened) ?? "--")
            LabeledContent("Duration", value: formattedDuration(milliseconds: drive.durationMS))
            LabeledContent("Distance", value: formattedNumber(drive.distanceMiles, fractionLength: 1, suffix: " mi"))
            LabeledContent("Start battery", value: formattedNumber(drive.startBattery, suffix: "%"))
            LabeledContent("Start odometer", value: formattedNumber(drive.startOdometer, fractionLength: 0, suffix: " mi"))
            LabeledContent("Start location", value: formattedCoordinate(latitude: drive.startLocation?.latitude, longitude: drive.startLocation?.longitude))
            LabeledContent("Speed", value: formattedNumber(drive.latestRoutePoint?.speed ?? drive.latest?.speed, fractionLength: 0, suffix: " mph"))
            LabeledContent("Route points", value: "\(drive.routePointCount ?? drive.route.count)")
            LabeledContent("Buffered points", value: "\(drive.bufferedPoints.count)")
            LabeledContent("Latest point", value: formattedCoordinate(latitude: drive.latestRoutePoint?.latitude ?? drive.latest?.latitude, longitude: drive.latestRoutePoint?.longitude ?? drive.latest?.longitude))
        }
    }
}

private struct RecentDrivesSection: View {
    let drives: [FleetDriveSession]
    let isLoading: Bool

    var body: some View {
        Section("Recent Drives") {
            if isLoading && drives.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading drives")
                }
            }

            ForEach(drives) { drive in
                DriveSessionRow(drive: drive)
            }
        }
    }
}

private struct DriveSessionRow: View {
    let drive: FleetDriveSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Drive", systemImage: "car.side")
                    .font(.headline)
                Spacer(minLength: 12)
                Text(drive.startedAtDate, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Text(formattedNumber(drive.distanceMiles, fractionLength: 1, suffix: " mi"))
                Text(formattedDuration(milliseconds: drive.durationMS))
                Text(formattedNumber(drive.energyUsedKWH, fractionLength: 1, suffix: " kWh"))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Text("Avg " + formattedNumber(drive.avgSpeedMPH, fractionLength: 0, suffix: " mph"))
                Text("Max " + formattedNumber(drive.maxSpeedMPH, fractionLength: 0, suffix: " mph"))
                if let endedAtDate = drive.endedAtDate {
                    Text("Ended " + endedAtDate.formatted(date: .omitted, time: .shortened))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct AccountSection: View {
    let email: String?
    let units: String?
    let scopes: [String]

    var body: some View {
        Section("Account") {
            if let email {
                LabeledContent("Email", value: email)
            }
            if let units {
                LabeledContent("Units", value: units.capitalized)
            }
            LabeledContent("Scopes", value: scopes.isEmpty ? "--" : scopes.sorted().joined(separator: ", "))
        }
    }
}

private func formattedNumber(_ value: Double?, fractionLength: Int = 0, suffix: String = "") -> String {
    guard let value else {
        return "--"
    }

    return value.formatted(.number.precision(.fractionLength(fractionLength))) + suffix
}

private func formattedDuration(milliseconds: Int64?) -> String {
    guard let milliseconds, milliseconds > 0 else {
        return "--"
    }

    let totalSeconds = Int(milliseconds / 1_000)
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
        return "\(hours) hr \(minutes) min"
    }
    if minutes > 0 {
        return "\(minutes) min"
    }
    return "\(seconds) sec"
}

private func formattedCoordinate(latitude: Double?, longitude: Double?) -> String {
    guard let latitude, let longitude else {
        return "--"
    }

    let lat = latitude.formatted(.number.precision(.fractionLength(4)))
    let lon = longitude.formatted(.number.precision(.fractionLength(4)))
    return "\(lat), \(lon)"
}

private func formattedJSONValue(_ value: JSONValue) -> String {
    switch value {
    case .string(let value):
        return value
    case .integer(let value):
        return String(value)
    case .double(let value):
        return value.formatted(.number.precision(.fractionLength(0...3)))
    case .bool(let value):
        return value ? "true" : "false"
    case .array(let values):
        return "[\(values.count) values]"
    case .object(let object):
        return "{\(object.count) fields}"
    case .null:
        return "null"
    }
}

#Preview {
    ContentView(
        store: .previewLoaded(),
        notificationWebhooks: FleetNotificationWebhookStore(),
        notifications: FleetNotificationCenter(),
        oauthClient: FleetOAuthClient(),
        tokenStore: FleetOAuthTokenKeychain()
    )
}
