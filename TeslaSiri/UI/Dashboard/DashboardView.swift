import SwiftUI

struct DashboardView: View {
    let store: FleetDataStore
    let isSignedIn: Bool
    let isAuthenticating: Bool
    let onSignIn: () -> Void
    let onReload: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !isSignedIn {
                    SignInBanner(onSignIn: onSignIn, isAuthenticating: isAuthenticating)
                }

                content
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Dashboard")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onReload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.loadState.isLoading || store.isRefreshing)
                .accessibilityLabel("Refresh")
            }
        }
        .refreshable {
            await store.refresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.loadState.isLoading && store.vehicles.isEmpty {
            LoadingStateView(message: "Loading fleet data…")
        } else if case .failed(let message) = store.loadState, store.vehicles.isEmpty {
            ErrorStateView(message: message, retry: { Task { await store.loadInitialData() } })
        } else if store.vehicles.isEmpty {
            EmptyStateView(
                title: "No vehicles",
                systemImage: "car",
                description: "No linked vehicles were returned."
            )
        } else {
            if store.isShowingCachedData {
                CachedDataCard(cacheDate: store.cacheDate)
            }

            VehiclePickerCard(
                vehicles: store.vehicles,
                selectedVIN: store.selectedVIN,
                onSelect: { vin in
                    store.selectVehicle(vin: vin)
                    Task { await FleetTokenBridge.sync(store: store) }
                }
            )

            if let vehicle = store.selectedVehicle {
                VehicleStatusCard(
                    vehicleName: vehicle.name,
                    snapshot: vehicle.latest,
                    units: store.user?.units
                )
            }

            if let softwareUpdate = store.selectedVehicleSoftwareUpdate {
                SoftwareUpdateCard(store: store, update: softwareUpdate, vin: store.selectedVIN)
            } else if store.isLoadingSoftware {
                LoadingCard(title: "Software", message: "Loading software…")
            }

            if let activeDrive = store.selectedVehicleActiveDrive {
                ActiveDriveCard(drive: activeDrive)
            } else if store.isLoadingActiveDrive {
                LoadingCard(title: "Active Drive", message: "Loading active drive…")
            }

            if !store.activeCharging.isEmpty || store.isLoadingCharging {
                ChargingCard(sessions: store.activeCharging)
            } else if store.isLoadingCharging {
                LoadingCard(title: "Charging", message: "Loading charging…")
            }

            AppIntentDiscoveryCard()
        }
    }
}

struct LoadingStateView: View {
    let message: String

    var body: some View {
        CardContainer {
            LoadingRow(label: message)
        }
    }
}

struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        CardContainer(title: "Unable to load fleet", systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 12) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    retry()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        CardContainer {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
                .frame(maxWidth: .infinity)
        }
    }
}

struct LoadingCard: View {
    let title: String
    let message: String

    var body: some View {
        CardContainer(title: title) {
            LoadingRow(label: message)
        }
    }
}

@MainActor
private struct DashboardPreviewer: View {
    let store: FleetDataStore
    let isSignedIn: Bool
    let isAuthenticating: Bool

    init(store: FleetDataStore? = nil,
         isSignedIn: Bool = true,
         isAuthenticating: Bool = false) {
        self.store = store ?? FleetDataStore.previewLoaded()
        self.isSignedIn = isSignedIn
        self.isAuthenticating = isAuthenticating
    }

    var body: some View {
        NavigationStack {
            DashboardView(
                store: store,
                isSignedIn: isSignedIn,
                isAuthenticating: isAuthenticating,
                onSignIn: {},
                onReload: {}
            )
        }
    }
}

#Preview("Loaded - signed in") {
    DashboardPreviewer()
}

#Preview("Loaded - signed out") {
    DashboardPreviewer(isSignedIn: false)
}

#Preview("LoadingStateView") {
    LoadingStateView(message: "Loading fleet data…")
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("ErrorStateView") {
    ErrorStateView(message: "Network request failed. Check your connection and try again.", retry: {})
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("EmptyStateView") {
    EmptyStateView(
        title: "No vehicles",
        systemImage: "car",
        description: "No linked vehicles were returned."
    )
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}
