import SwiftUI

struct DrivesView: View {
    let store: FleetDataStore

    @State private var endpointAddresses: [String: DriveEndpointAddresses] = [:]
    @State private var selectedPointIndex = 0
    @State private var selectedSessionID: String?

    private var drives: [FleetDriveSession] {
        Array(store.selectedVehicleRecentDrives.prefix(10))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if drives.isEmpty && store.isLoadingDrives {
                    LoadingCard(title: "Drives", message: "Loading drives…")
                } else if drives.isEmpty {
                    CardContainer(title: "Drives", systemImage: "map") {
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
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                    if let selectedDrive {
                        let route = resolvedRoute(for: selectedDrive)
                        DriveRouteMap(route: route, selectedPointIndex: selectedPointIndex)
                            .frame(height: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(.horizontal, 16)
                            .task(id: selectedDrive.sessionID) {
                                selectedPointIndex = 0
                                if route.isEmpty {
                                    await store.refreshRoute(for: selectedDrive)
                                }
                            }

                        VStack(spacing: 16) {
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
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                            } else {
                                CardContainer(title: "Route Position", systemImage: "mappin.and.ellipse") {
                                    DriveRoutePositionScrubber(
                                        sampleCount: route.count,
                                        selectedSampleIndex: $selectedPointIndex
                                    )
                                }

                                if let selectedPoint = route[safe: selectedPointIndex] {
                                    CardContainer(title: "Selected Position", systemImage: "scope") {
                                        DriveRoutePositionSummary(
                                            point: selectedPoint,
                                            index: selectedPointIndex,
                                            count: route.count
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Drives")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.isLoadingDrives)
                .accessibilityLabel("Refresh drives")
            }
        }
        .task(id: endpointLookupKey) {
            await refreshEndpointAddresses()
        }
    }

    private var selectedSessionBinding: Binding<String> {
        Binding {
            selectedSessionID ?? drives.first?.sessionID ?? ""
        } set: { newValue in
            selectedSessionID = newValue
            selectedPointIndex = 0
        }
    }

    private var selectedDrive: FleetDriveSession? {
        let sessionID = selectedSessionID ?? drives.first?.sessionID
        return drives.first { $0.sessionID == sessionID } ?? drives.first
    }

    private var endpointLookupKey: String {
        drives.map { drive in
            let route = resolvedRoute(for: drive)
            return [drive.sessionID, drive.startAddress, drive.endAddress, route.first?.id, route.last?.id, String(route.count)]
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

#Preview {
    NavigationStack {
        DrivesView(store: FleetDataStore.previewLoaded())
    }
}
