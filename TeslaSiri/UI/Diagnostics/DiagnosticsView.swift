import SwiftUI

struct DiagnosticsView: View {
    let store: FleetDataStore
    let notificationWebhooks: FleetNotificationWebhookStore
    let diagnostics: BackendDiagnosticsState
    let onProbeAccount: () -> Void
    let onReloadFleet: () async -> Void
    let onExportRawData: () -> Void
    let onSignOut: () -> Void
    let onRequestNotificationAuthorization: () -> Void
    let onSendLocalNotificationTest: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                BackendSection(
                    store: store,
                    diagnostics: diagnostics,
                    onProbeAccount: onProbeAccount,
                    onReloadFleet: onReloadFleet,
                    onExportRawData: onExportRawData,
                    onSignOut: onSignOut
                )

                WebhooksSection(
                    store: notificationWebhooks,
                    capabilities: store.capabilities,
                    selectedVIN: store.selectedVIN,
                    onRequestAuthorization: onRequestNotificationAuthorization,
                    onSendLocalTest: onSendLocalNotificationTest
                )

                NormalizedDataSection(store: store)

                SpotlightDebugSection(isSignedIn: diagnostics.isSignedIn)

                if let user = store.user {
                    AccountSection(email: user.email, units: user.units, scopes: user.scopes)
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await onReloadFleet() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.loadState.isLoading || store.isRefreshing)
                .accessibilityLabel("Refresh diagnostics")
            }
        }
        .refreshable {
            await onReloadFleet()
        }
    }
}

@MainActor
private struct DiagnosticsPreviewer: View {
    var body: some View {
        let diagnostics = BackendDiagnosticsState(
            deviceID: "device-abc-123",
            isSignedIn: true,
            probeMessage: "Account OK: driver@example.com. Notification hooks: 2.",
            tokenAudience: ["https://fleet-api.tesla.com", "https://fleet.maxweinbach.com"],
            tokenExpiresAt: Date().addingTimeInterval(3600),
            tokenFormat: "JWT",
            tokenIssuer: "https://fleet.maxweinbach.com",
            tokenScopes: ["vehicles:read", "telemetry:read", "vehicle_control"]
        )
        return NavigationStack {
            DiagnosticsView(
                store: FleetDataStore.previewLoaded(),
                notificationWebhooks: FleetNotificationWebhookStore(),
                diagnostics: diagnostics,
                onProbeAccount: {},
                onReloadFleet: {},
                onExportRawData: {},
                onSignOut: {},
                onRequestNotificationAuthorization: {},
                onSendLocalNotificationTest: {}
            )
        }
    }
}

#Preview {
    DiagnosticsPreviewer()
}
