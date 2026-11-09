import AppIntents
import FleetKit
import Foundation
import SwiftUI

enum AppTab: Hashable, Identifiable, CaseIterable {
    case dashboard
    case drives
    case diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .drives: "Drives"
        case .diagnostics: "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "rectangle.grid.2x2"
        case .drives: "map"
        case .diagnostics: "stethoscope"
        }
    }
}

struct BackendDiagnosticsState: Equatable {
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

struct AppRootView: View {
    let store: FleetDataStore
    let tokenStore: TessieAccessTokenStore

    @Environment(\.scenePhase) private var scenePhase

    @State private var authErrorMessage: String?
    @State private var diagnostics = BackendDiagnosticsState()
    @State private var selectedTab: AppTab = .dashboard
    @State private var spotlightSearchTerm = ""
    @State private var isAuthenticating = false

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack {
                    tabContent(for: tab)
                }
                .tabItem {
                    Label(tab.title, systemImage: tab.systemImage)
                }
                .tag(tab)
            }
        }
        .onAppIntentExecution(OpenVehicleIntent.self) { intent in
            openVehicle(intent.target.id, tab: .dashboard)
        }
        .onAppIntentExecution(OpenVehicleStatusIntent.self) { intent in
            openVehicle(intent.target.vin, tab: .dashboard)
        }
        .onAppIntentExecution(OpenSoftwareUpdateIntent.self) { intent in
            openVehicle(intent.target.vin, tab: .dashboard)
        }
        .onAppIntentExecution(OpenReleaseNoteIntent.self) { intent in
            openVehicle(intent.target.vin, tab: .dashboard)
        }
        .onAppIntentExecution(OpenDriveIntent.self) { intent in
            openVehicle(intent.target.vin, tab: .drives)
        }
        .onAppIntentExecution(SearchFleetIntent.self) { intent in
            spotlightSearchTerm = intent.criteria.term
            selectedTab = .diagnostics
        }
        .alert("Connection Failed", isPresented: authErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(authErrorMessage ?? "Unknown error")
        }
        .task {
            refreshDiagnostics()
            await store.loadInitialDataIfNeeded()
            configureFleetPolling(for: scenePhase)
        }
        .onChange(of: scenePhase) { _, newPhase in
            configureFleetPolling(for: newPhase)
        }
    }

    @ViewBuilder
    private func tabContent(for tab: AppTab) -> some View {
        switch tab {
        case .dashboard:
            DashboardView(
                store: store,
                isSignedIn: diagnostics.isSignedIn,
                isAuthenticating: isAuthenticating,
                onSignIn: { token in
                    Task { await signIn(accessToken: token) }
                },
                onReload: {
                    await reloadFleet()
                }
            )
        case .drives:
            DrivesView(store: store)
        case .diagnostics:
            DiagnosticsView(
                store: store,
                diagnostics: diagnostics,
                spotlightSearchTerm: spotlightSearchTerm,
                onProbeAccount: {
                    Task { await runBackendProbe() }
                },
                onReloadFleet: {
                    await reloadFleet()
                },
                onExportRawData: {
                    Task { await exportRawData() }
                },
                onSignOut: {
                    Task { await signOut() }
                }
            )
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

    // MARK: - Actions

    private func signIn(accessToken: String) async {
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let validationClient = FleetAPIClient(accessTokenProvider: StaticFleetAccessTokenProvider(token: accessToken))
            let vehicles = try await validationClient.vehicles(includeLive: true)
            try tokenStore.saveAccessToken(accessToken)
            await store.reset(clearCache: true)
            diagnostics.probeMessage = "Connected to Tessie. Loading \(vehicles.data.count) vehicle(s)."
            refreshDiagnostics()
            await store.loadInitialData()
            await FleetTokenBridge.sync(store: store)
            _ = await FleetSpotlightIndexer.reindexAll()
            refreshDiagnostics()
            configureFleetPolling(for: scenePhase)
        } catch {
            authErrorMessage = error.localizedDescription
            diagnostics.probeMessage = error.localizedDescription
            refreshDiagnostics()
        }
    }

    private func reloadFleet() async {
        await store.refresh()
        await FleetTokenBridge.sync(store: store)
        _ = await FleetSpotlightIndexer.reindexAll()
        await FleetIntentDonations.donateManualStatusRefresh(for: store.selectedVehicle)
        refreshDiagnostics()
    }

    private func openVehicle(_ vin: String, tab: AppTab) {
        if !vin.isEmpty {
            store.selectVehicle(vin: vin)
            Task { await FleetTokenBridge.sync(store: store) }
        }
        selectedTab = tab
    }

    private func configureFleetPolling(for phase: ScenePhase) {
        if phase == .active, diagnostics.isSignedIn {
            store.startPolling()
        } else {
            store.stopPolling()
        }
    }

    private func runBackendProbe() async {
        diagnostics.isProbeRunning = true
        diagnostics.probeMessage = "Checking Tessie API access."
        defer {
            diagnostics.isProbeRunning = false
            refreshDiagnostics()
        }

        do {
            let apiClient = FleetBackend.makeAPIClient()
            let vehiclePage = try await apiClient.vehicles(includeLive: true)
            diagnostics.probeMessage = backendProbeMessage(
                vehicleCount: vehiclePage.data.count,
                requestID: vehiclePage.requestID
            )
        } catch {
            diagnostics.probeMessage = error.localizedDescription
        }
    }

    private func signOut() async {
        do {
            try tokenStore.deleteAccessToken()
            FleetTokenBridge.clear()
            try? await FleetSpotlightIndexer.deleteAllIndexedEntities()
            await store.reset(clearCache: true)
            store.stopPolling()
            diagnostics.probeMessage = "Disconnected Tessie and cleared cached fleet data."
            refreshDiagnostics()
        } catch {
            authErrorMessage = error.localizedDescription
            diagnostics.probeMessage = error.localizedDescription
            refreshDiagnostics()
        }
    }

    private func exportRawData() async {
        await store.exportSelectedVehicleRawData()
        refreshDiagnostics()
    }

    // MARK: - Diagnostics

    private func refreshDiagnostics() {
        do {
            let token = try tokenStore.loadAccessToken()
            diagnostics.isSignedIn = token != nil
            diagnostics.tokenExpiresAt = nil

            if token != nil {
                diagnostics.tokenAudience = ["https://api.tessie.com"]
                diagnostics.tokenFormat = "Tessie access token"
                diagnostics.tokenIssuer = "Tessie Developer Settings"
                diagnostics.tokenScopes = TessieModelAdapter.capabilities.scopes
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

    private func backendProbeMessage(vehicleCount: Int, requestID: String?) -> String {
        var message = "Tessie API OK. Vehicles: \(vehicleCount)."
        if let requestID {
            message += " Request ID: \(requestID)."
        }
        return message
    }
}

#Preview {
    AppRootView(
        store: .previewLoaded(),
        tokenStore: TessieAccessTokenStore()
    )
}
