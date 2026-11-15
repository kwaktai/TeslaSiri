import AppIntents
import FleetKit
import Intents
import IntentsUI
import SwiftUI

/// Siri tip + 1-tap natural "my car" phrase pinners + Shortcuts link card at the bottom of the Vehicle tab.
struct AppIntentDiscoveryCard: View {
    var vehicle: FleetVehicle? = nil
    @State private var isStatusTipVisible = true
    @State private var voiceShortcutsByType: [String: INVoiceShortcut] = [:]
    @State private var activeSheet: VoiceShortcutSheetItem?
    @State private var isShowingWidgetGallery = CommandLine.arguments.contains("--preview-siri-widgets")

    private let columns = [
        GridItem(.flexible(minimum: 130), spacing: 8),
        GridItem(.flexible(minimum: 130), spacing: 8)
    ]

    var body: some View {
        DashboardCard("Siri & Shortcuts", systemImage: "waveform") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Say \"Warm up my car\", \"Show my last drive\", or \"How's my car?\" for live Apple Maps route and telemetry widgets right inside Siri.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    isShowingWidgetGallery = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "map.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(
                                LinearGradient(
                                    colors: [.blue, .cyan],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Preview Dynamic Siri Widgets")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Embedded Apple Maps drive routes, live cabin & charger cards")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(CarSiriVoicePhrase.allCases) { item in
                        phraseButton(for: item)
                    }
                }

                SiriTipView(intent: climateIntent, isVisible: $isStatusTipVisible)
                    .siriTipViewStyle(.automatic)

                ShortcutsLink()
                    .shortcutsLinkStyle(.automatic)
                    .frame(maxWidth: .infinity)
            }
        }
        .task {
            await reloadVoiceShortcuts()
        }
        .sheet(isPresented: $isShowingWidgetGallery) {
            NavigationStack {
                SiriDynamicWidgetsPreviewSheet(preferredVIN: vehicle?.vin)
            }
        }
        .sheet(item: $activeSheet) { sheet in
            VoiceShortcutSheetPresenter(item: sheet) {
                activeSheet = nil
                Task { await reloadVoiceShortcuts() }
            }
            .ignoresSafeArea()
        }
    }

    private func phraseButton(for item: CarSiriVoicePhrase) -> some View {
        let existing = voiceShortcutsByType[item.rawValue]
        let isAdded = existing != nil

        return Button {
            if let existing {
                activeSheet = .edit(existing)
            } else {
                activeSheet = .add(item.makeShortcut(for: vehicle), id: item.rawValue)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isAdded ? "checkmark" : item.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isAdded ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                    .frame(width: 18)

                Text("\"\(existing?.invocationPhrase ?? item.phrase)\"")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isAdded ? "Edit Siri phrase \(existing?.invocationPhrase ?? item.phrase)" : "Add Siri phrase \(item.phrase)")
    }

    private var climateIntent: StartClimateIntent {
        let intent = StartClimateIntent()
        if let vehicle, !vehicle.vin.isEmpty {
            intent.vehicle = VehicleEntity(id: vehicle.vin, name: vehicle.name)
        }
        return intent
    }

    private func reloadVoiceShortcuts() async {
        let shortcuts: [INVoiceShortcut] = await withCheckedContinuation { continuation in
            INVoiceShortcutCenter.shared.getAllVoiceShortcuts { fetched, _ in
                continuation.resume(returning: fetched ?? [])
            }
        }
        var mapped: [String: INVoiceShortcut] = [:]
        for shortcut in shortcuts {
            if let activityType = shortcut.shortcut.userActivity?.activityType {
                mapped[activityType] = shortcut
            }
        }
        voiceShortcutsByType = mapped
    }
}

// MARK: - Live Siri Dynamic Widgets Gallery

private struct SiriDynamicWidgetsPreviewSheet: View {
    let preferredVIN: String?
    @Environment(\.dismiss) private var dismiss

    enum FilterSection: String, CaseIterable, Identifiable {
        case all = "All"
        case drives = "Drives"
        case vehicle = "Car & Climate"
        case charging = "Charging"

        var id: String { rawValue }
    }

    @State private var selectedSection: FilterSection = .all
    @State private var vehicleName = "Midnight"
    @State private var vehicleEntity = VehicleEntity(id: FleetDemoVehicleState.demoVIN, name: "Midnight")
    @State private var drives: [DriveEntity] = []
    @State private var selectedDriveIndex = 0
    @State private var driveMapData: SiriRenderedMapData?
    @State private var statusEntity: VehicleStatusEntity?
    @State private var vehicleMapData: SiriRenderedMapData?
    @State private var charges: [ChargeSessionEntity] = []
    @State private var selectedChargeIndex = 0
    @State private var chargeMapData: SiriRenderedMapData?
    @State private var drivingStats: DrivingStatsEntity?
    @State private var previewService: FleetIntentService?
    @State private var refreshRevision: Int?

    private let previewDriveSessionKey = "preview-drives"
    private let previewChargeSessionKey = "preview-charges"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Widget Category", selection: $selectedSection) {
                    ForEach(FilterSection.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)

                if selectedSection == .all || selectedSection == .drives {
                    if !drives.isEmpty {
                        let safeIndex = min(max(selectedDriveIndex, 0), drives.count - 1)
                        siriPlatterCard(
                            prompt: "\"Show my recent drives\" or \"How was my last drive?\"",
                            subtitle: "Interactive Apple Maps route, start & end timeline, Autopilot segments, Satellite toggle & multi-drive stepper"
                        ) {
                            DriveSnippetView(
                                drive: drives[safeIndex],
                                allDrives: drives,
                                selectedIndex: safeIndex,
                                sessionKey: previewDriveSessionKey,
                                vehicleName: vehicleName,
                                mapData: driveMapData
                            )
                        }
                    }

                    if let drivingStats {
                        siriPlatterCard(
                            prompt: "\"What are my driving stats this week?\"",
                            subtitle: "Autopilot share progress bar & Wh/mi efficiency breakdown"
                        ) {
                            DrivingStatsSnippetView(stats: drivingStats)
                        }
                    }
                }

                if selectedSection == .all || selectedSection == .vehicle {
                    if let statusEntity {
                        siriPlatterCard(
                            prompt: "\"How's my car?\" or \"Where is my car?\"",
                            subtitle: "Battery & charge-limit gauge, Apple Maps parked-car pin, Directions link & live controls"
                        ) {
                            VehicleStatusSnippetView(status: statusEntity, mapData: vehicleMapData)
                        }

                        siriPlatterCard(
                            prompt: "\"Warm up my car\"",
                            subtitle: "Interactive cabin temperature +/- controls & active comfort badges"
                        ) {
                            ClimateControlSnippetView(
                                vehicle: vehicleEntity,
                                status: statusEntity,
                                appliedSummary: "Climate on · warming cabin"
                            )
                        }
                    }
                }

                if selectedSection == .all || selectedSection == .charging {
                    if !charges.isEmpty {
                        let safeChargeIdx = min(max(selectedChargeIndex, 0), charges.count - 1)
                        siriPlatterCard(
                            prompt: "\"How much did my last charge cost?\"",
                            subtitle: "Apple Maps charger pin, battery-added fill bar & session stepper"
                        ) {
                            ChargeSessionSnippetView(
                                session: charges[safeChargeIdx],
                                allSessions: charges,
                                selectedIndex: safeChargeIdx,
                                sessionKey: previewChargeSessionKey,
                                vehicleName: vehicleName,
                                mapData: chargeMapData
                            )
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Siri Dynamic Widgets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .task {
            refreshRevision = nil
            SiriSnippetStateStore.shared.setSelectedDriveIndex(0, for: previewDriveSessionKey)
            SiriSnippetStateStore.shared.setSelectedDriveIndex(0, for: previewChargeSessionKey)
            await loadWidgetData()
        }
        .onReceive(NotificationCenter.default.publisher(for: SiriSnippetStateStore.stateDidChangeNotification)) { _ in
            if let refreshRevision {
                self.refreshRevision = refreshRevision + 1
            }
        }
        .task(id: refreshRevision) { [refreshRevision] in
            guard let refreshRevision, let previewService else { return }
            await refreshInteractiveState(service: previewService, refreshStatus: refreshRevision > 0)
        }
    }

    private func siriPlatterCard<Content: View>(
        prompt: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.purple)
                Text(prompt)
                    .font(.subheadline.weight(.semibold))
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            content()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 0.75)
                )
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
    }

    private func resolvedPreviewService() -> FleetIntentService {
        let liveService = FleetIntentService.make()
        if FleetSandboxStore.shared.mode() == .demoVehicle || FleetSharedTokenStore.shared.accessToken() != nil {
            return liveService
        }
        let fallbackSandbox = FleetSandboxStore(appGroup: "TeslaSiri.WidgetPreviewFallback")
        fallbackSandbox.setMode(.demoVehicle)
        return FleetIntentService(sandbox: fallbackSandbox)
    }

    private func loadWidgetData() async {
        let service = resolvedPreviewService()
        do {
            let resolved = try await service.resolvedVehicle(preferredVIN)
            vehicleName = resolved.name
            vehicleEntity = VehicleEntity(id: resolved.vin, name: resolved.name)

            async let driveRead = service.drives(vin: resolved.vin, limit: 5)
            async let statusRead = service.snapshot(vin: resolved.vin)
            async let chargeRead = service.charges(vin: resolved.vin, limit: 5)
            let (rawDrives, snapshot, rawCharges) = try await (driveRead, statusRead, chargeRead)
            guard !Task.isCancelled else { return }
            drives = rawDrives.map(DriveEntity.init(info:))
            drivingStats = DrivingStatsEntity(vehicle: resolved, period: .last7Days, drives: rawDrives)

            statusEntity = VehicleStatusEntity(
                snapshot: snapshot,
                vehicleName: resolved.name,
                locationAddress: "Apple Park Way, Cupertino"
            )

            charges = rawCharges.map(ChargeSessionEntity.init(info:))
            previewService = service
            refreshRevision = 0
        } catch {
            guard !Task.isCancelled else { return }
            let demoSandbox = FleetSandboxStore(appGroup: "TeslaSiri.WidgetPreviewDemo")
            demoSandbox.setMode(.demoVehicle)
            let demoService = FleetIntentService(sandbox: demoSandbox)
            if let resolved = try? await demoService.resolvedVehicle(nil) {
                vehicleName = resolved.name
                vehicleEntity = VehicleEntity(id: resolved.vin, name: resolved.name)
                let rawDrives = (try? await demoService.drives(vin: resolved.vin, limit: 5)) ?? []
                drives = rawDrives.map(DriveEntity.init(info:))
                drivingStats = DrivingStatsEntity(vehicle: resolved, period: .last7Days, drives: rawDrives)
                if let snap = try? await demoService.snapshot(vin: resolved.vin) {
                    statusEntity = VehicleStatusEntity(
                        snapshot: snap,
                        vehicleName: resolved.name,
                        locationAddress: "Apple Park Way, Cupertino"
                    )
                }
                let rawCharges = (try? await demoService.charges(vin: resolved.vin, limit: 5)) ?? []
                charges = rawCharges.map(ChargeSessionEntity.init(info:))
                guard !Task.isCancelled else { return }
                previewService = demoService
                refreshRevision = 0
            }
        }
    }

    private func refreshInteractiveState(service: FleetIntentService, refreshStatus: Bool) async {
        let store = SiriSnippetStateStore.shared

        if refreshStatus, let snap = try? await service.snapshot(vin: vehicleEntity.id) {
            guard !Task.isCancelled else { return }
            statusEntity = VehicleStatusEntity(
                snapshot: snap,
                vehicleName: vehicleName,
                locationAddress: statusEntity?.locationAddress ?? "Apple Park Way, Cupertino"
            )
        }

        guard !Task.isCancelled else { return }
        if !drives.isEmpty {
            let idx = store.selectedDriveIndex(for: previewDriveSessionKey, count: drives.count)
            selectedDriveIndex = idx
            let map = await SiriMapSnapshotRenderer.renderDriveRoute(
                for: drives[idx],
                service: service,
                style: store.mapStyle(for: "drive"),
                allowNetworkSnapshot: true
            )
            guard !Task.isCancelled else { return }
            driveMapData = map
        }

        if let statusEntity {
            let map = await SiriMapSnapshotRenderer.renderLocationPin(
                latitude: statusEntity.latitude,
                longitude: statusEntity.longitude,
                fallbackPlaceQuery: statusEntity.locationAddress,
                style: store.mapStyle(for: "vehicle"),
                accentHex: 0x0A84FF,
                allowNetworkSnapshot: true
            )
            guard !Task.isCancelled else { return }
            vehicleMapData = map
        }

        if !charges.isEmpty {
            let idx = store.selectedChargeIndexFallback(for: previewChargeSessionKey, count: charges.count)
            selectedChargeIndex = idx
            let activeCharge = charges[idx]
            let map = await SiriMapSnapshotRenderer.renderLocationPin(
                latitude: activeCharge.latitude,
                longitude: activeCharge.longitude,
                fallbackPlaceQuery: activeCharge.location,
                style: store.mapStyle(for: "charge"),
                accentHex: activeCharge.isSupercharger ? 0xFF3B30 : 0x30D158,
                allowNetworkSnapshot: true
            )
            guard !Task.isCancelled else { return }
            chargeMapData = map
        }
    }
}

private extension SiriSnippetStateStore {
    func selectedChargeIndexFallback(for sessionKey: String, count: Int) -> Int {
        selectedDriveIndex(for: sessionKey, count: count)
    }
}

private enum VoiceShortcutSheetItem: Identifiable {
    case add(INShortcut, id: String)
    case edit(INVoiceShortcut)

    var id: String {
        switch self {
        case .add(_, let id): "add-\(id)"
        case .edit(let voiceShortcut): "edit-\(voiceShortcut.identifier.uuidString)"
        }
    }
}

private struct VoiceShortcutSheetPresenter: UIViewControllerRepresentable {
    let item: VoiceShortcutSheetItem
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        switch item {
        case .add(let shortcut, _):
            let controller = INUIAddVoiceShortcutViewController(shortcut: shortcut)
            controller.delegate = context.coordinator
            return controller
        case .edit(let voiceShortcut):
            let controller = INUIEditVoiceShortcutViewController(voiceShortcut: voiceShortcut)
            controller.delegate = context.coordinator
            return controller
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, INUIAddVoiceShortcutViewControllerDelegate, INUIEditVoiceShortcutViewControllerDelegate {
        let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func addVoiceShortcutViewController(_ controller: INUIAddVoiceShortcutViewController, didFinishWith voiceShortcut: INVoiceShortcut?, error: (any Error)?) {
            onDismiss()
        }

        func addVoiceShortcutViewControllerDidCancel(_ controller: INUIAddVoiceShortcutViewController) {
            onDismiss()
        }

        func editVoiceShortcutViewController(_ controller: INUIEditVoiceShortcutViewController, didUpdate voiceShortcut: INVoiceShortcut?, error: (any Error)?) {
            onDismiss()
        }

        func editVoiceShortcutViewController(_ controller: INUIEditVoiceShortcutViewController, didDeleteVoiceShortcutWithIdentifier deletedVoiceShortcutIdentifier: UUID) {
            onDismiss()
        }

        func editVoiceShortcutViewControllerDidCancel(_ controller: INUIEditVoiceShortcutViewController) {
            onDismiss()
        }
    }
}

