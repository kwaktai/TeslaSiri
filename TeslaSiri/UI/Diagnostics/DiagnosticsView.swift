import SwiftUI

struct DiagnosticsView: View {
    let store: FleetDataStore
    let diagnostics: BackendDiagnosticsState
    let onProbeAccount: () -> Void
    let onReloadFleet: () async -> Void
    let onExportRawData: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                BackendSection(
                    store: store,
                    diagnostics: diagnostics,
                    onProbeAccount: onProbeAccount,
                    onReloadFleet: onReloadFleet,
                    onExportRawData: onExportRawData,
                    onSignOut: onSignOut
                )

                NormalizedDataSection(store: store)

                SpotlightDebugSection(isSignedIn: diagnostics.isSignedIn)

                if let user = store.user {
                    AccountSection(
                        email: user.email,
                        units: user.units,
                        scopes: user.scopes
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(AppScreenBackground())
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await onReloadFleet() }
                } label: {
                    if store.loadState.isLoading || store.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
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
            probeMessage: "Tessie API OK. Vehicles: 2.",
            tokenAudience: ["https://api.tessie.com"],
            tokenFormat: "Tessie access token",
            tokenIssuer: "Tessie Developer Settings",
            tokenScopes: ["vehicles", "vehicle_commands", "vehicle_history"]
        )

        return NavigationStack {
            DiagnosticsView(
                store: FleetDataStore.previewLoaded(),
                diagnostics: diagnostics,
                onProbeAccount: {},
                onReloadFleet: {},
                onExportRawData: {},
                onSignOut: {}
            )
        }
    }
}

#Preview("Diagnostics — Light") {
    DiagnosticsPreviewer()
}

#Preview("Diagnostics — Dark") {
    DiagnosticsPreviewer()
        .preferredColorScheme(.dark)
}
