import AppIntents
import FleetKit
import SwiftUI

struct DrivesView: View {
    let store: FleetDataStore
    var requestedSessionID: String? = nil
    var onReload: (() async -> Void)? = nil

    @State private var endpointAddresses: [String: DriveEndpointAddresses] = [:]
    @State private var selectedPointIndex = 0
    @State private var selectedSessionID: String?

    private var drives: [FleetDriveSession] {
        var visible = Array(store.selectedVehicleRecentDrives.prefix(10))
        if let targetID = selectedSessionID ?? requestedSessionID,
           !targetID.isEmpty,
           !visible.contains(where: { $0.sessionID == targetID }),
           let matching = store.selectedVehicleRecentDrives.first(where: { $0.sessionID == targetID }) {
            visible.append(matching)
        }
        return visible
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                if drives.isEmpty && store.isLoadingDrives {
                    LoadingCard(title: "Drives", message: "Loading drives…")
                } else if drives.isEmpty {
                    CardContainer(title: "Drives", systemImage: "map.fill") {
                        ContentUnavailableView(
                            "No drives",
                            systemImage: "map",
                            description: Text("Recent drive sessions were not returned for this vehicle.")
                        )
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    DriveSessionPicker(
                        drives: drives,
                        endpointAddresses: endpointAddresses,
                        selectedSessionID: selectedSessionBinding
                    )

                    if let selectedDrive {
                        let route = resolvedRoute(for: selectedDrive)

                        DriveMapCard(
                            drive: selectedDrive,
                            route: route,
                            selectedPointIndex: $selectedPointIndex,
                            onLoadRoute: {
                                await store.refreshRoute(for: selectedDrive)
                            }
                        )

                        DriveSessionSummary(
                            drive: selectedDrive,
                            endpointAddresses: endpointAddresses[selectedDrive.sessionID],
                            hasRoute: !route.isEmpty
                        )

                        if route.isEmpty {
                            Button {
                                Task { await store.refreshRoute(for: selectedDrive) }
                            } label: {
                                Label("Load Route", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .appEntityIdentifier(driveEntityIdentifier(for: selectedDrive))
                        } else {
                            CardContainer(title: "Route playback", systemImage: "mappin.and.ellipse") {
                                VStack(alignment: .leading, spacing: 16) {
                                    DriveRoutePositionScrubber(
                                        sampleCount: route.count,
                                        selectedSampleIndex: $selectedPointIndex,
                                        driveSessionID: selectedDrive.sessionID
                                    )

                                    if let selectedPoint = route[safe: selectedPointIndex] {
                                        DriveRoutePositionSummary(
                                            point: selectedPoint,
                                            index: selectedPointIndex,
                                            count: route.count,
                                            driveSessionID: selectedDrive.sessionID
                                        )
                                    }
                                }
                            }
                            .appEntityIdentifier(driveEntityIdentifier(for: selectedDrive))
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .readableContentWidth()
        }
        .scrollIndicators(.hidden)
        .background(AppScreenBackground())
        .navigationTitle("Drives")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reloadDrives() }
                } label: {
                    if store.isLoadingDrives || store.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.isLoadingDrives || store.isRefreshing)
                .accessibilityLabel("Refresh drives")
            }
        }
        .refreshable {
            await reloadDrives()
        }
        .onChange(of: requestedSessionID, initial: true) { _, newValue in
            guard let newValue, !newValue.isEmpty else { return }
            selectedSessionID = newValue
            selectedPointIndex = 0
        }
        .task(id: endpointLookupKey) {
            await refreshEndpointAddresses()
        }
        .appEntityIdentifier(selectedDriveEntityIdentifier)
    }

    private func reloadDrives() async {
        if let onReload {
            await onReload()
        } else {
            await store.refresh()
        }
    }

    private var selectedSessionBinding: Binding<String> {
        Binding {
            selectedSessionID ?? requestedSessionID ?? drives.first?.sessionID ?? ""
        } set: { newValue in
            selectedSessionID = newValue
            selectedPointIndex = 0
        }
    }

    private var selectedDrive: FleetDriveSession? {
        let sessionID = selectedSessionID ?? requestedSessionID ?? drives.first?.sessionID
        return drives.first { $0.sessionID == sessionID } ?? drives.first
    }

    private var selectedDriveEntityIdentifier: EntityIdentifier? {
        guard let selectedDrive else { return nil }
        return driveEntityIdentifier(for: selectedDrive)
    }

    private func driveEntityIdentifier(for drive: FleetDriveSession) -> EntityIdentifier? {
        guard !drive.sessionID.isEmpty else { return nil }
        return EntityIdentifier(for: DriveEntity.self, identifier: drive.sessionID)
    }

    private var endpointLookupKey: String {
        drives.map { drive in
            let route = resolvedRoute(for: drive)
            return [
                drive.sessionID,
                drive.startAddress,
                drive.endAddress,
                route.first?.id,
                route.last?.id,
                String(route.count)
            ]
            .compactMap { $0 }
            .joined(separator: ":")
        }
        .joined(separator: "|")
    }

    private func resolvedRoute(for drive: FleetDriveSession) -> [FleetRoutePoint] {
        let cachedRoute = store.route(for: drive)
        return cachedRoute.isEmpty ? drive.route : cachedRoute
    }

    private func refreshEndpointAddresses() async {
        let visibleSessionIDs = Set(drives.map(\.sessionID))
        var resolvedAddresses = endpointAddresses.filter { visibleSessionIDs.contains($0.key) }

        for drive in drives {
            let route = resolvedRoute(for: drive)
            let addresses = await driveEndpointAddressGeocoder.addresses(for: drive, route: route)
            guard !Task.isCancelled else {
                return
            }
            resolvedAddresses[drive.sessionID] = addresses
            endpointAddresses = resolvedAddresses
        }
    }
}

private struct DriveMapCard: View {
    let drive: FleetDriveSession
    let route: [FleetRoutePoint]
    @Binding var selectedPointIndex: Int
    let onLoadRoute: () async -> Void

    var body: some View {
        DriveRouteMap(
            route: route,
            selectedPointIndex: selectedPointIndex,
            driveSessionID: drive.sessionID
        )
        .frame(height: 286)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
        .overlay(alignment: .topLeading) {
            if !route.isEmpty {
                Label(formattedNumber(drive.distanceMiles, fractionLength: 1, suffix: " mi route"), systemImage: "map.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(AppTheme.hairline, lineWidth: 0.75)
        }
        .shadow(color: AppTheme.surfaceShadow, radius: 10, y: 3)
        .task(id: drive.sessionID) {
            selectedPointIndex = 0
            if route.isEmpty {
                await onLoadRoute()
            }
        }
    }
}

#Preview("Drive detail — Light") {
    NavigationStack {
        DrivesView(store: FleetDataStore.previewLoaded())
    }
}

#Preview("Drive detail — Dark") {
    NavigationStack {
        DrivesView(store: FleetDataStore.previewLoaded())
    }
    .preferredColorScheme(.dark)
}

#Preview("Drive detail — Accessibility") {
    NavigationStack {
        DrivesView(store: FleetDataStore.previewLoaded())
    }
    .environment(\.dynamicTypeSize, .accessibility2)
}
