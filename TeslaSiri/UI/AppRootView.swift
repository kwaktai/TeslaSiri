import AuthenticationServices
import FleetKit
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
    let notificationWebhooks: FleetNotificationWebhookStore
    let notifications: FleetNotificationCenter
    let oauthClient: FleetOAuthClient
    let tokenStore: FleetOAuthTokenKeychain

    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.scenePhase) private var scenePhase

    @State private var authErrorMessage: String?
    @State private var diagnostics = BackendDiagnosticsState()
    @State private var selectedTab: AppTab = .dashboard
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
        .alert("Sign In Failed", isPresented: authErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(authErrorMessage ?? "Unknown error")
        }
        .task {
            refreshDiagnostics()
            await store.loadInitialDataIfNeeded()
            await notificationWebhooks.refresh()
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
                onSignIn: {
                    Task { await signIn() }
                },
                onReload: {
                    Task { await reloadFleet() }
                }
            )
        case .drives:
            DrivesView(store: store)
        case .diagnostics:
            DiagnosticsView(
                store: store,
                notificationWebhooks: notificationWebhooks,
                diagnostics: diagnostics,
                onProbeAccount: {
                    Task { await runBackendProbe() }
                },
                onReloadFleet: {
                    Task { await reloadFleet() }
                },
                onExportRawData: {
                    Task { await exportRawData() }
                },
                onSignOut: {
                    Task { await signOut() }
                },
                onRequestNotificationAuthorization: {
                    Task { await enableNotifications() }
                },
                onSendLocalNotificationTest: {
                    Task { await sendLocalNotificationTest() }
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

    private func signIn() async {
        isAuthenticating = true
        defer { isAuthenticating = false }

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
            await FleetTokenBridge.sync(store: store)
            await FleetSpotlightIndexer.reindexAll()
            await notificationWebhooks.refresh()
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
        await FleetSpotlightIndexer.reindexAll()
        await notificationWebhooks.refresh()
        refreshDiagnostics()
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
            FleetTokenBridge.clear()
            await store.reset(clearCache: true)
            notificationWebhooks.reset()
            store.stopPolling()
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

    // MARK: - Diagnostics

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

#Preview {
    AppRootView(
        store: .previewLoaded(),
        notificationWebhooks: FleetNotificationWebhookStore(),
        notifications: FleetNotificationCenter(),
        oauthClient: FleetOAuthClient(),
        tokenStore: FleetOAuthTokenKeychain()
    )
}
