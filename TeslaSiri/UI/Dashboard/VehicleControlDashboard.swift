import AppIntents
import CoreLocation
import FleetKit
import MapKit
import SwiftUI

struct VehicleControlDashboard: View {
    let vehicle: FleetVehicle
    let vehicles: [FleetVehicle]
    let selectedVIN: String?
    let units: String?
    let isRefreshing: Bool
    let isRunningControl: Bool
    let activeControlAction: String?
    let controlMessage: String?
    let controlsEnabled: Bool
    let onSelectVehicle: (String) -> Void
    let onRefresh: () async -> Void
    let onControl: (String, [String: JSONValue]) async -> Bool

    @State private var selectedMode: VehicleDashboardMode = .overview
    @State private var pendingCommand: VehicleControlCommand?
    @State private var isShowingConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            VehicleDashboardHeader(
                vehicleName: vehicle.name,
                vin: vehicle.vin,
                vehicles: vehicles,
                selectedVIN: selectedVIN,
                isLocked: snapshot?.locked ?? true,
                isRefreshing: isRefreshing,
                isRunningControl: isRunningControl,
                onSelectVehicle: onSelectVehicle,
                onRefresh: onRefresh,
                onLockToggle: {
                    request(.lock(shouldLock: !(snapshot?.locked ?? true)))
                }
            )
            .frame(maxWidth: 720)

            if let snapshot {
                VehicleRangeSummary(snapshot: snapshot, units: units)
                    .frame(maxWidth: 720)

                VehicleHeroArtwork(
                    vehicleName: vehicle.name,
                    vin: vehicle.vin
                )
                .frame(maxWidth: 720)

                VehicleModeSelector(selection: $selectedMode)
                    .frame(maxWidth: 720)

                VehicleModePanel(
                    mode: selectedMode,
                    snapshot: snapshot,
                    units: units,
                    isRunningControl: isRunningControl,
                    activeControlAction: activeControlAction,
                    controlsEnabled: controlsEnabled,
                    onCommand: request
                )
                .frame(maxWidth: 720)

                if let controlMessage {
                    VehicleControlMessage(
                        message: controlMessage,
                        isRunning: isRunningControl
                    )
                    .padding(.top, 12)
                }
            } else {
                VehicleUnavailableStage(vehicleName: vehicle.name)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .top)
        .appEntityIdentifier(statusEntityIdentifier)
        .confirmationDialog(
            "Confirm vehicle command",
            isPresented: $isShowingConfirmation,
            titleVisibility: .visible
        ) {
            if let pendingCommand {
                Button(role: pendingCommand.buttonRole) {
                    perform(pendingCommand)
                } label: {
                    Text(pendingCommand.title)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let pendingCommand {
                Text(pendingCommand.confirmationMessage(vehicleName: vehicle.name))
            }
        }
    }

    private var snapshot: FleetLatestSnapshot? {
        vehicle.latest
    }

    private var statusEntityIdentifier: EntityIdentifier? {
        guard let vin = snapshot?.vin, !vin.isEmpty else { return nil }
        return EntityIdentifier(
            for: VehicleStatusEntity.self,
            identifier: VehicleStatusEntity.entityID(forVIN: vin)
        )
    }

    private func request(_ command: VehicleControlCommand) {
        guard controlsEnabled, !isRunningControl else { return }
        if command.requiresConfirmation {
            pendingCommand = command
            isShowingConfirmation = true
        } else {
            perform(command)
        }
    }

    private func perform(_ command: VehicleControlCommand) {
        pendingCommand = nil
        Task {
            _ = await onControl(command.action, command.parameters)
        }
    }
}

private enum VehicleDashboardMode: String, CaseIterable, Identifiable {
    case overview
    case climate
    case location
    case energy
    case security

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .overview: "Controls"
        case .climate: "Climate"
        case .location: "Location"
        case .energy: "Energy"
        case .security: "Security"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "car.side.fill"
        case .climate: "fan.fill"
        case .location: "location.fill"
        case .energy: "bolt.fill"
        case .security: "shield.fill"
        }
    }
}

private enum VehicleControlCommand: Hashable, Identifiable {
    case climate(shouldTurnOn: Bool)
    case defrost(shouldTurnOn: Bool)
    case flashLights
    case honk
    case lock(shouldLock: Bool)
    case petMode(shouldTurnOn: Bool)
    case trunk(isFront: Bool)
    case ventWindows

    var id: String {
        switch self {
        case .climate(let shouldTurnOn): "climate-\(shouldTurnOn)"
        case .defrost(let shouldTurnOn): "defrost-\(shouldTurnOn)"
        case .flashLights: "flash-lights"
        case .honk: "honk"
        case .lock(let shouldLock): "lock-\(shouldLock)"
        case .petMode(let shouldTurnOn): "pet-mode-\(shouldTurnOn)"
        case .trunk(let isFront): isFront ? "front-trunk" : "rear-trunk"
        case .ventWindows: "vent-windows"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .climate(let shouldTurnOn): shouldTurnOn ? "Start climate" : "Stop climate"
        case .defrost(let shouldTurnOn): shouldTurnOn ? "Start defrost" : "Stop defrost"
        case .flashLights: "Flash lights"
        case .honk: "Honk horn"
        case .lock(let shouldLock): shouldLock ? "Lock vehicle" : "Unlock vehicle"
        case .petMode(let shouldTurnOn): shouldTurnOn ? "Turn on Dog Mode" : "Turn off Dog Mode"
        case .trunk(let isFront): isFront ? "Open front trunk" : "Open rear trunk"
        case .ventWindows: "Vent windows"
        }
    }

    var action: String {
        switch self {
        case .climate(let shouldTurnOn):
            shouldTurnOn ? "auto_conditioning_start" : "auto_conditioning_stop"
        case .defrost: "remote_defrost"
        case .flashLights: "flash_lights"
        case .honk: "honk_horn"
        case .lock(let shouldLock): shouldLock ? "door_lock" : "door_unlock"
        case .petMode: "set_pet_mode"
        case .trunk: "actuate_trunk"
        case .ventWindows: "window_control"
        }
    }

    var parameters: [String: JSONValue] {
        switch self {
        case .defrost(let shouldTurnOn):
            ["on": .bool(shouldTurnOn)]
        case .petMode(let shouldTurnOn):
            ["on": .bool(shouldTurnOn)]
        case .trunk(let isFront):
            ["which_trunk": .string(isFront ? "front" : "rear")]
        case .ventWindows:
            ["command": .string("vent")]
        default:
            [:]
        }
    }

    var requiresConfirmation: Bool {
        switch self {
        case .lock(shouldLock: false), .trunk:
            true
        case .climate, .defrost, .flashLights, .honk, .lock, .petMode, .ventWindows:
            false
        }
    }

    var buttonRole: ButtonRole? {
        switch self {
        case .lock(shouldLock: false):
            .destructive
        default:
            nil
        }
    }

    func confirmationMessage(vehicleName: String) -> LocalizedStringResource {
        switch self {
        case .lock(shouldLock: false):
            "Unlock \(vehicleName)?"
        case .trunk(let isFront):
            isFront
                ? "Open the front trunk on \(vehicleName)?"
                : "Open the rear trunk on \(vehicleName)?"
        default:
            "Send this command to \(vehicleName)?"
        }
    }
}

private struct VehicleDashboardHeader: View {
    let vehicleName: String
    let vin: String
    let vehicles: [FleetVehicle]
    let selectedVIN: String?
    let isLocked: Bool
    let isRefreshing: Bool
    let isRunningControl: Bool
    let onSelectVehicle: (String) -> Void
    let onRefresh: () async -> Void
    let onLockToggle: () -> Void

    var body: some View {
        HStack {
            Button(action: onLockToggle) {
                Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isLocked ? Color.primary : Color.orange)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .appSurface(cornerRadius: 22)
            }
            .buttonStyle(.plain)
            .disabled(isRunningControl)
            .accessibilityLabel(isLocked ? "Unlock vehicle" : "Lock vehicle")
            .accessibilityValue(isLocked ? "Locked" : "Unlocked")

            Spacer(minLength: 8)

            Menu {
                ForEach(vehicles, id: \.vin) { vehicle in
                    Button {
                        onSelectVehicle(vehicle.vin)
                    } label: {
                        if vehicle.vin == selectedVIN {
                            Label(vehicle.name, systemImage: "checkmark")
                        } else {
                            Text(vehicle.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Text(vehicleName)
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .appSurface(cornerRadius: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select vehicle")
            .accessibilityValue(vehicleName)

            Spacer(minLength: 8)

            Button {
                Task { await onRefresh() }
            } label: {
                Group {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.body.weight(.semibold))
                    }
                }
                .frame(width: 44, height: 44)
                .appSurface(cornerRadius: 22)
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .accessibilityLabel("Refresh vehicle")
        }
        .appEntityIdentifier(vehicleEntityIdentifier)
    }

    private var vehicleEntityIdentifier: EntityIdentifier? {
        guard !vin.isEmpty else { return nil }
        return EntityIdentifier(for: VehicleEntity.self, identifier: vin)
    }
}

private struct VehicleRangeSummary: View {
    let snapshot: FleetLatestSnapshot
    let units: String?

    @ScaledMetric(relativeTo: .largeTitle) private var rangeFontSize: CGFloat = 62

    var body: some View {
        VStack(spacing: 7) {
            HStack(alignment: .lastTextBaseline, spacing: 7) {
                Text(rangeValue)
                    .font(.system(size: rangeFontSize, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(rangeUnit)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(statusSummary)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let updatedAt = snapshot.updatedAtDate {
                Label {
                    RelativeTimeText(date: updatedAt, style: .updated)
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 4)
        .appEntityIdentifier(statusEntityIdentifier)
    }

    private var rangeValue: String {
        guard let batteryRange = snapshot.batteryRange else {
            return formattedNumber(snapshot.batteryLevel, fractionLength: 0)
        }
        let value = units == "metric" ? batteryRange * 1.609_344 : batteryRange
        return formattedNumber(value, fractionLength: 0)
    }

    private var rangeUnit: String {
        snapshot.batteryRange == nil ? "%" : (units == "metric" ? "km" : "mi")
    }

    private var statusSummary: String {
        if snapshot.chargingState?.localizedCaseInsensitiveContains("charging") == true {
            if let remaining = snapshot.timeToFullCharge, remaining > 0 {
                return "Charging · \(formattedNumber(remaining, fractionLength: 1, suffix: " hr remaining"))"
            }
            return "Charging"
        }
        if let speed = snapshot.speed, speed > 0 {
            return "Driving · \(formattedNumber(speed, fractionLength: 0, suffix: " mph"))"
        }
        return "Parked · \(formattedNumber(snapshot.batteryLevel, fractionLength: 0, suffix: "% battery"))"
    }

    private var statusEntityIdentifier: EntityIdentifier? {
        guard !snapshot.vin.isEmpty else { return nil }
        return EntityIdentifier(
            for: VehicleStatusEntity.self,
            identifier: VehicleStatusEntity.entityID(forVIN: snapshot.vin)
        )
    }
}

private struct VehicleModeSelector: View {
    @Binding var selection: VehicleDashboardMode

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Namespace private var selectionNamespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(VehicleDashboardMode.allCases) { mode in
                let isSelected = selection == mode

                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                        selection = mode
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: mode.systemImage)
                            .font(.body.weight(.semibold))
                            .frame(height: 22)

                        // Labels are dropped at accessibility sizes so five segments still fit;
                        // the accessibility label keeps the mode name available to VoiceOver.
                        if !dynamicTypeSize.isAccessibilitySize {
                            Text(mode.title)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(AppTheme.raisedSurface)
                                .shadow(color: AppTheme.surfaceShadow, radius: 4, y: 1)
                                .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(mode.title))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(AppTheme.segmentTrack, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        .padding(.vertical, 12)
    }
}

private struct VehicleModePanel: View {
    let mode: VehicleDashboardMode
    let snapshot: FleetLatestSnapshot
    let units: String?
    let isRunningControl: Bool
    let activeControlAction: String?
    let controlsEnabled: Bool
    let onCommand: (VehicleControlCommand) -> Void

    var body: some View {
        switch mode {
        case .overview:
            VehicleOverviewPanel(
                snapshot: snapshot,
                units: units,
                isRunningControl: isRunningControl,
                activeControlAction: activeControlAction,
                controlsEnabled: controlsEnabled,
                onCommand: onCommand
            )
        case .climate:
            VehicleClimatePanel(
                snapshot: snapshot,
                units: units,
                isRunningControl: isRunningControl,
                activeControlAction: activeControlAction,
                controlsEnabled: controlsEnabled,
                onCommand: onCommand
            )
        case .location:
            VehicleLocationPanel(snapshot: snapshot)
        case .energy:
            VehicleEnergyPanel(snapshot: snapshot, units: units)
        case .security:
            VehicleSecurityPanel(
                snapshot: snapshot,
                isRunningControl: isRunningControl,
                activeControlAction: activeControlAction,
                controlsEnabled: controlsEnabled,
                onCommand: onCommand
            )
        }
    }
}

private struct VehicleOverviewPanel: View {
    let snapshot: FleetLatestSnapshot
    let units: String?
    let isRunningControl: Bool
    let activeControlAction: String?
    let controlsEnabled: Bool
    let onCommand: (VehicleControlCommand) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stackedLayout
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ClimateControlTile(
                        snapshot: snapshot,
                        units: units,
                        isBusy: isBusy(climateCommand),
                        isEnabled: controlsEnabled,
                        action: { onCommand(climateCommand) }
                    )
                    .frame(minWidth: 160)

                    VehicleQuickControlsGrid(
                        commands: quickCommands,
                        isRunningControl: isRunningControl,
                        activeControlAction: activeControlAction,
                        controlsEnabled: controlsEnabled,
                        onCommand: onCommand,
                        singleColumn: false
                    )
                    .frame(minWidth: 160)
                }

                stackedLayout
            }
        }
    }

    private var stackedLayout: some View {
        VStack(spacing: 10) {
            ClimateControlTile(
                snapshot: snapshot,
                units: units,
                isBusy: isBusy(climateCommand),
                isEnabled: controlsEnabled,
                action: { onCommand(climateCommand) }
            )

            VehicleQuickControlsGrid(
                commands: quickCommands,
                isRunningControl: isRunningControl,
                activeControlAction: activeControlAction,
                controlsEnabled: controlsEnabled,
                onCommand: onCommand,
                singleColumn: dynamicTypeSize.isAccessibilitySize
            )
        }
    }

    private var quickCommands: [VehicleQuickControlsGrid.Item] {
        [
            (.ventWindows, "Vent", "rectangle.split.3x1.fill", .blue),
            (.flashLights, "Flash", "light.max", .yellow),
            (.trunk(isFront: true), "Frunk", "archivebox.fill", .orange),
            (.trunk(isFront: false), "Trunk", "shippingbox.fill", .orange)
        ]
    }

    private var climateCommand: VehicleControlCommand {
        .climate(shouldTurnOn: snapshot.climateOn != true)
    }

    private func isBusy(_ command: VehicleControlCommand) -> Bool {
        isRunningControl && activeControlAction == command.action
    }
}

private struct VehicleClimatePanel: View {
    let snapshot: FleetLatestSnapshot
    let units: String?
    let isRunningControl: Bool
    let activeControlAction: String?
    let controlsEnabled: Bool
    let onCommand: (VehicleControlCommand) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 10) {
            ClimateControlTile(
                snapshot: snapshot,
                units: units,
                isBusy: isBusy(climateCommand),
                isEnabled: controlsEnabled,
                action: { onCommand(climateCommand) }
            )

            VehicleQuickControlsGrid(
                commands: [
                    (.defrost(shouldTurnOn: true), "Defrost", "sun.max.fill", .orange),
                    (.petMode(shouldTurnOn: true), "Dog Mode", "pawprint.fill", .yellow),
                    (.ventWindows, "Vent", "rectangle.split.3x1.fill", .blue),
                    (.climate(shouldTurnOn: false), "Climate off", "fan.slash.fill", .secondary)
                ],
                isRunningControl: isRunningControl,
                activeControlAction: activeControlAction,
                controlsEnabled: controlsEnabled,
                onCommand: onCommand,
                singleColumn: dynamicTypeSize.isAccessibilitySize
            )
        }
    }

    private var climateCommand: VehicleControlCommand {
        .climate(shouldTurnOn: snapshot.climateOn != true)
    }

    private func isBusy(_ command: VehicleControlCommand) -> Bool {
        isRunningControl && activeControlAction == command.action
    }
}

private struct VehicleLocationPanel: View {
    let snapshot: FleetLatestSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Location", systemImage: "location.fill")
                .font(.headline)

            if let coordinate {
                Map(
                    initialPosition: .camera(MapCamera(centerCoordinate: coordinate, distance: 1_400)),
                    interactionModes: []
                ) {
                    Marker("Vehicle", systemImage: "car.fill", coordinate: coordinate)
                        .tint(.blue)
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityLabel("Map showing the vehicle's location")

                HStack(alignment: .firstTextBaseline) {
                    Text(formattedCoordinate(latitude: snapshot.latitude, longitude: snapshot.longitude))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Spacer(minLength: 12)

                    if let mapsURL {
                        Link(destination: mapsURL) {
                            Label("Open in Maps", systemImage: "arrow.up.right")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Location unavailable",
                    systemImage: "location.slash",
                    description: Text("The vehicle hasn't reported a location yet.")
                )
            }

            Text("Ask Siri to send a destination to your car, or open Drives for route history.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(VehiclePanelBackground())
    }

    private var coordinate: CLLocationCoordinate2D? {
        guard let latitude = snapshot.latitude, let longitude = snapshot.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var mapsURL: URL? {
        guard let latitude = snapshot.latitude, let longitude = snapshot.longitude else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "q", value: "Vehicle")
        ]
        return components?.url
    }
}

private struct VehicleEnergyPanel: View {
    let snapshot: FleetLatestSnapshot
    let units: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label("Energy", systemImage: "bolt.fill")
                    .font(.headline)
                Spacer()
                Text(formattedNumber(snapshot.batteryLevel, fractionLength: 0, suffix: "%"))
                    .font(.headline)
                    .monospacedDigit()
            }

            ProgressView(value: max(0, min((snapshot.batteryLevel ?? 0) / 100, 1)))
                .tint(.green)

            LazyVGrid(columns: columns, spacing: 10) {
                VehicleMetricTile(
                    title: "Range",
                    value: formattedRange,
                    systemImage: "road.lanes"
                )
                VehicleMetricTile(
                    title: "Charge limit",
                    value: formattedNumber(snapshot.chargeLimitSOC, fractionLength: 0, suffix: "%"),
                    systemImage: "battery.100"
                )
                VehicleMetricTile(
                    title: "Charge power",
                    value: formattedNumber(snapshot.chargerPowerKW, fractionLength: 1, suffix: " kW"),
                    systemImage: "bolt.badge.clock"
                )
                VehicleMetricTile(
                    title: "Time remaining",
                    value: formattedNumber(snapshot.timeToFullCharge, fractionLength: 1, suffix: " hr"),
                    systemImage: "clock"
                )
            }
        }
        .padding(18)
        .background(VehiclePanelBackground())
    }

    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]
    }

    private var formattedRange: String {
        guard let range = snapshot.batteryRange else { return "--" }
        let value = units == "metric" ? range * 1.609_344 : range
        return formattedNumber(value, fractionLength: 0, suffix: units == "metric" ? " km" : " mi")
    }
}

private struct VehicleSecurityPanel: View {
    let snapshot: FleetLatestSnapshot
    let isRunningControl: Bool
    let activeControlAction: String?
    let controlsEnabled: Bool
    let onCommand: (VehicleControlCommand) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(
                    snapshot.locked == true ? "Vehicle secured" : "Vehicle unlocked",
                    systemImage: snapshot.locked == true ? "lock.fill" : "lock.open.fill"
                )
                .font(.headline)

                Spacer()

                StatusBadge(
                    snapshot.sentryMode == true ? "Sentry on" : "Sentry off",
                    systemImage: snapshot.sentryMode == true ? "eye.fill" : "eye.slash",
                    tint: snapshot.sentryMode == true ? .red : .secondary
                )
            }

            VehicleQuickControlsGrid(
                commands: [
                    (
                        .lock(shouldLock: snapshot.locked != true),
                        snapshot.locked == true ? "Unlock" : "Lock",
                        snapshot.locked == true ? "lock.open.fill" : "lock.fill",
                        snapshot.locked == true ? .orange : .green
                    ),
                    (.flashLights, "Flash", "light.max", .yellow),
                    (.honk, "Honk", "speaker.wave.3.fill", .blue),
                    (.trunk(isFront: false), "Trunk", "shippingbox.fill", .orange)
                ],
                isRunningControl: isRunningControl,
                activeControlAction: activeControlAction,
                controlsEnabled: controlsEnabled,
                onCommand: onCommand,
                singleColumn: dynamicTypeSize.isAccessibilitySize
            )

            if let tires = snapshot.tires, tires.hasAnyReading {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Tire pressure", systemImage: "tirepressure")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    LazyVGrid(columns: tireColumns, spacing: 10) {
                        VehicleMetricTile(
                            title: "Front left",
                            value: formattedNumber(tires.frontLeftPSI, fractionLength: 1, suffix: " psi"),
                            systemImage: "circle.dotted"
                        )
                        VehicleMetricTile(
                            title: "Front right",
                            value: formattedNumber(tires.frontRightPSI, fractionLength: 1, suffix: " psi"),
                            systemImage: "circle.dotted"
                        )
                        VehicleMetricTile(
                            title: "Rear left",
                            value: formattedNumber(tires.rearLeftPSI, fractionLength: 1, suffix: " psi"),
                            systemImage: "circle.dotted"
                        )
                        VehicleMetricTile(
                            title: "Rear right",
                            value: formattedNumber(tires.rearRightPSI, fractionLength: 1, suffix: " psi"),
                            systemImage: "circle.dotted"
                        )
                    }
                }
            }
        }
        .padding(18)
        .background(VehiclePanelBackground())
    }

    private var tireColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]
    }
}

private struct ClimateControlTile: View {
    let snapshot: FleetLatestSnapshot
    let units: String?
    let isBusy: Bool
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center) {
                    Image(systemName: isOn ? "fan.fill" : "fan")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isOn ? Color.white : Color.blue)
                        .frame(width: 38, height: 38)
                        .background(isOn ? Color.blue : Color.blue.opacity(0.14), in: Circle())
                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isOn && !reduceMotion)

                    Spacer()

                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(isOn ? "On" : "Off")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isOn ? Color.blue : Color.secondary)
                    }
                }

                Spacer(minLength: 14)

                Text(headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(primaryTemperature)
                    .font(.system(.largeTitle, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .leading)
            .padding(16)
            .appSurface(cornerRadius: AppTheme.tileCornerRadius)
            .overlay {
                if isOn {
                    RoundedRectangle(cornerRadius: AppTheme.tileCornerRadius, style: .continuous)
                        .strokeBorder(Color.blue.opacity(0.6), lineWidth: 1.5)
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isOn ? "Stop climate" : "Start climate")
        .accessibilityValue("\(headline) \(primaryTemperature). \(caption)")
    }

    private var isOn: Bool {
        snapshot.climateOn == true
    }

    private var temperatureSuffix: String {
        units == "metric" ? "°C" : "°F"
    }

    private var headline: String {
        guard isOn else { return "Inside" }
        guard let target = snapshot.targetTemperature, let inside = snapshot.insideTemp else {
            return "Climate on"
        }
        if target < inside - 0.5 { return "Cooling to" }
        if target > inside + 0.5 { return "Heating to" }
        return "Holding at"
    }

    private var primaryTemperature: String {
        let value = isOn
            ? (snapshot.targetTemperature ?? snapshot.insideTemp)
            : (snapshot.insideTemp ?? snapshot.targetTemperature)
        return formattedNumber(value, fractionLength: 0, suffix: temperatureSuffix)
    }

    private var caption: String {
        if isOn {
            return formattedNumber(snapshot.insideTemp, fractionLength: 0, suffix: "\(temperatureSuffix) inside")
        }
        return "Tap to start climate"
    }
}

private struct VehicleQuickControlsGrid: View {
    typealias Item = (
        command: VehicleControlCommand,
        title: LocalizedStringResource,
        systemImage: String,
        tint: Color
    )

    let commands: [Item]
    let isRunningControl: Bool
    let activeControlAction: String?
    let controlsEnabled: Bool
    let onCommand: (VehicleControlCommand) -> Void
    let singleColumn: Bool

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(commands, id: \.command.id) { item in
                VehicleActionTile(
                    title: item.title,
                    systemImage: item.systemImage,
                    tint: item.tint,
                    isBusy: isRunningControl && activeControlAction == item.command.action,
                    isEnabled: controlsEnabled,
                    action: { onCommand(item.command) }
                )
            }
        }
    }

    private var columns: [GridItem] {
        singleColumn
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]
    }
}

private struct VehicleActionTile: View {
    let title: LocalizedStringResource
    let systemImage: String
    let tint: Color
    let isBusy: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Group {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: systemImage)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.2), in: Circle())

                Text(title)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 79)
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .appSurface(cornerRadius: 18)
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .accessibilityLabel(Text(title))
    }
}

private struct VehicleMetricTile: View {
    let title: LocalizedStringResource
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(12)
        .background(AppTheme.insetSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct VehicleControlMessage: View {
    let message: String
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct VehiclePanelBackground: View {
    var body: some View {
        Color.clear
            .appSurface()
    }
}

private struct VehicleUnavailableStage: View {
    let vehicleName: String

    var body: some View {
        ContentUnavailableView(
            "No live telemetry",
            systemImage: "antenna.radiowaves.left.and.right.slash",
            description: Text("Refresh \(vehicleName) to load its latest state.")
        )
        .frame(maxWidth: .infinity, minHeight: 500)
    }
}

#Preview("Showroom — Light") {
    ScrollView {
        VehicleControlDashboard(
            vehicle: PreviewData.vehicles[0],
            vehicles: PreviewData.vehicles,
            selectedVIN: PreviewData.vin1,
            units: "imperial",
            isRefreshing: false,
            isRunningControl: false,
            activeControlAction: nil,
            controlMessage: nil,
            controlsEnabled: true,
            onSelectVehicle: { _ in },
            onRefresh: {},
            onControl: { _, _ in true }
        )
    }
    .background(AppScreenBackground())
}

#Preview("Showroom — Dark") {
    ScrollView {
        VehicleControlDashboard(
            vehicle: PreviewData.vehicles[0],
            vehicles: PreviewData.vehicles,
            selectedVIN: PreviewData.vin1,
            units: "imperial",
            isRefreshing: false,
            isRunningControl: false,
            activeControlAction: nil,
            controlMessage: nil,
            controlsEnabled: true,
            onSelectVehicle: { _ in },
            onRefresh: {},
            onControl: { _, _ in true }
        )
    }
    .background(AppScreenBackground())
    .preferredColorScheme(.dark)
}

#Preview("Showroom — Accessibility") {
    ScrollView {
        VehicleControlDashboard(
            vehicle: PreviewData.vehicles[0],
            vehicles: PreviewData.vehicles,
            selectedVIN: PreviewData.vin1,
            units: "imperial",
            isRefreshing: false,
            isRunningControl: false,
            activeControlAction: nil,
            controlMessage: "Command sent",
            controlsEnabled: true,
            onSelectVehicle: { _ in },
            onRefresh: {},
            onControl: { _, _ in true }
        )
    }
    .background(AppScreenBackground())
    .environment(\.dynamicTypeSize, .accessibility2)
}
