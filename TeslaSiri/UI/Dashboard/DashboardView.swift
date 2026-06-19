import AppIntents
import FleetKit
import SwiftUI

struct DashboardView: View {
    let store: FleetDataStore
    let isSignedIn: Bool
    let isAuthenticating: Bool
    let onSignIn: (String) -> Void
    let onReload: () async -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                if !isSignedIn {
                    SignInBanner(
                        onSignIn: onSignIn,
                        isAuthenticating: isAuthenticating
                    )
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                }

                DashboardContent(
                    store: store,
                    isSignedIn: isSignedIn,
                    onReload: onReload
                )
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable {
            guard isSignedIn else { return }
            await onReload()
        }
        .appEntityIdentifier(selectedVehicleEntityIdentifier)
    }

    private var selectedVehicleEntityIdentifier: EntityIdentifier? {
        guard let vin = store.selectedVehicle?.vin, !vin.isEmpty else { return nil }
        return EntityIdentifier(for: VehicleEntity.self, identifier: vin)
    }
}

private struct DashboardContent: View {
    let store: FleetDataStore
    let isSignedIn: Bool
    let onReload: () async -> Void

    var body: some View {
        if store.loadState.isLoading && store.vehicles.isEmpty {
            LoadingStateView(message: "Loading fleet data…")
                .padding(.horizontal, 18)
                .padding(.top, 12)
        } else if case .failed(let message) = store.loadState, store.vehicles.isEmpty {
            ErrorStateView(
                message: message,
                retry: { Task { await store.loadInitialData() } }
            )
            .padding(.horizontal, 18)
            .padding(.top, 12)
        } else if store.vehicles.isEmpty {
            if isSignedIn {
                EmptyStateView(
                    title: "No vehicles",
                    systemImage: "car.side",
                    description: "No linked vehicles were returned."
                )
                .padding(.horizontal, 18)
                .padding(.top, 12)
            }
        } else {
            DashboardLoadedContent(store: store, onReload: onReload)
        }
    }
}

private struct DashboardLoadedContent: View {
    let store: FleetDataStore
    let onReload: () async -> Void

    var body: some View {
        VStack(spacing: 20) {
            if store.isShowingCachedData {
                CachedDataCard(cacheDate: store.cacheDate)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
            }

            if let vehicle = store.selectedVehicle {
                VehicleControlDashboard(
                    vehicle: vehicle,
                    vehicles: store.vehicles,
                    selectedVIN: store.selectedVIN,
                    units: store.user?.units,
                    isRefreshing: store.isRefreshing,
                    isRunningControl: store.isRunningControl,
                    activeControlAction: store.activeControlAction,
                    controlMessage: store.vehicleControlMessage,
                    controlsEnabled: vehicle.permissions.contains("control"),
                    onSelectVehicle: { vin in
                        store.selectVehicle(vin: vin)
                        Task { await FleetTokenBridge.sync(store: store) }
                    },
                    onRefresh: onReload,
                    onControl: { action, params in
                        await store.runSelectedVehicleControl(action: action, params: params)
                    }
                )
                .id(vehicle.vin)
            }

            DashboardSecondaryContent(store: store)
                .padding(.horizontal, 18)
        }
    }
}

private struct DashboardSecondaryContent: View {
    let store: FleetDataStore

    var body: some View {
        VStack(spacing: 20) {
            if let activeDrive = store.selectedVehicleActiveDrive {
                ActiveDriveCard(drive: activeDrive)
            } else if store.isLoadingActiveDrive {
                LoadingCard(title: "Active drive", message: "Loading active drive…")
            }

            if let softwareUpdate = store.selectedVehicleSoftwareUpdate {
                SoftwareUpdateCard(
                    store: store,
                    update: softwareUpdate,
                    vin: store.selectedVIN
                )
            } else if store.isLoadingSoftware {
                LoadingCard(title: "Software", message: "Loading software…")
            }

            if !store.activeCharging.isEmpty {
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
        CardContainer(title: "Unable to load fleet", systemImage: "exclamationmark.triangle.fill") {
            VStack(alignment: .leading, spacing: 14) {
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
            ContentUnavailableView(
                title,
                systemImage: systemImage,
                description: Text(description)
            )
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

    @State private var rendererDebugSettings = VehicleRendererDebugSettings()

    init(
        store: FleetDataStore? = nil,
        isSignedIn: Bool = true,
        isAuthenticating: Bool = false
    ) {
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
                onSignIn: { _ in },
                onReload: {}
            )
        }
        .environment(rendererDebugSettings)
    }
}

#Preview("Control Center — Light") {
    DashboardPreviewer()
}

#Preview("Control Center — Dark") {
    DashboardPreviewer()
        .preferredColorScheme(.dark)
}

#Preview("Control Center — Accessibility") {
    DashboardPreviewer()
        .environment(\.dynamicTypeSize, .accessibility2)
}

#Preview("Signed out with cached data") {
    DashboardPreviewer(isSignedIn: false)
}

#Preview("Loading") {
    ZStack {
        AppScreenBackground()

        LoadingStateView(message: "Loading fleet data…")
            .padding()
    }
}

#Preview("Error") {
    ZStack {
        AppScreenBackground()

        ErrorStateView(
            message: "Network request failed. Check your connection and try again.",
            retry: {}
        )
        .padding()
    }
}

#Preview("Empty") {
    ZStack {
        AppScreenBackground()

        EmptyStateView(
            title: "No vehicles",
            systemImage: "car.side",
            description: "No linked vehicles were returned."
        )
        .padding()
    }
}
