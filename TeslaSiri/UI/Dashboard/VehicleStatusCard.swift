import AppIntents
import FleetKit
import SwiftUI

struct VehicleStatusCard: View {
    let vehicleName: String
    let snapshot: FleetLatestSnapshot?
    let units: String?

    var body: some View {
        CardContainer(title: vehicleName, systemImage: "gauge.with.dots.needle.bottom.50percent") {
            if let snapshot {
                VStack(alignment: .leading, spacing: 16) {
                    BatteryHeader(snapshot: snapshot)

                    StatusBadgesRow(snapshot: snapshot)

                    MetricsGrid(snapshot: snapshot, units: units)

                    if let updatedAt = snapshot.updatedAtDate {
                        Text("Updated \(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("No live telemetry available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .appEntityIdentifier(statusEntityIdentifier)
    }

    private var temperatureSuffix: String {
        units == "metric" ? "°C" : "°F"
    }

    private var statusEntityIdentifier: EntityIdentifier? {
        guard let vin = snapshot?.vin, !vin.isEmpty else { return nil }
        return EntityIdentifier(for: VehicleStatusEntity.self, identifier: vin)
    }
}

private struct BatteryHeader: View {
    let snapshot: FleetLatestSnapshot

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(formattedNumber(snapshot.batteryLevel, suffix: "%"))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("Battery")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let range = snapshot.chargeRateMPH {
                    Text(formattedNumber(range, fractionLength: 0, suffix: " mph"))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text("Charge rate")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let power = snapshot.chargerPowerKW {
                    Text(formattedNumber(power, fractionLength: 1, suffix: " kW"))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct StatusBadgesRow: View {
    let snapshot: FleetLatestSnapshot

    var body: some View {
        HStack(spacing: 8) {
            if let state = snapshot.chargingState {
                StatusBadge(state.capitalized, systemImage: "bolt.fill", tint: .orange)
            }
            if let locked = snapshot.locked {
                StatusBadge(locked ? "Locked" : "Unlocked", systemImage: locked ? "lock.fill" : "lock.open.fill", tint: locked ? .green : .secondary)
            }
            if let sentry = snapshot.sentryMode {
                StatusBadge(sentry ? "Sentry" : "Sentry off", systemImage: "shield.lefthalf.filled", tint: sentry ? .blue : .secondary)
            }
            if let gear = snapshot.gear {
                StatusBadge(gear, systemImage: "car", tint: .purple)
            }
        }
    }
}

private struct MetricsGrid: View {
    let snapshot: FleetLatestSnapshot
    let units: String?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var temperatureSuffix: String {
        units == "metric" ? "°C" : "°F"
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            MetricTile(title: "Charge limit", value: formattedNumber(snapshot.chargeLimitSOC, suffix: "%"), systemImage: "battery.100")
            MetricTile(title: "Speed", value: formattedNumber(snapshot.speed, fractionLength: 0, suffix: " mph"), systemImage: "speedometer")
            MetricTile(title: "Cabin", value: formattedNumber(snapshot.insideTemp, fractionLength: 0, suffix: temperatureSuffix), systemImage: "thermometer.medium")
            MetricTile(title: "Outside", value: formattedNumber(snapshot.outsideTemp, fractionLength: 0, suffix: temperatureSuffix), systemImage: "thermometer.medium.slash")
            MetricTile(title: "Time to full", value: formattedNumber(snapshot.timeToFullCharge, fractionLength: 1, suffix: " hr"), systemImage: "clock")
            MetricTile(title: "Odometer", value: formattedNumber(snapshot.odometer, fractionLength: 0, suffix: " mi"), systemImage: "gauge.with.needle")
            MetricTile(title: "Freshness", value: formattedDuration(milliseconds: snapshot.freshnessMS), systemImage: "antenna.radiowaves.left.and.right")
            MetricTile(title: "Location", value: formattedCoordinate(latitude: snapshot.latitude, longitude: snapshot.longitude), systemImage: "location")
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

#Preview("Full snapshot - charging") {
    VehicleStatusCard(
        vehicleName: "Model 3",
        snapshot: PreviewData.snapshotFull,
        units: "imperial"
    )
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Driving snapshot") {
    VehicleStatusCard(
        vehicleName: "Model Y",
        snapshot: PreviewData.snapshotDriving,
        units: "imperial"
    )
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Metric units") {
    VehicleStatusCard(
        vehicleName: "Model 3",
        snapshot: PreviewData.snapshotFull,
        units: "metric"
    )
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("No snapshot") {
    VehicleStatusCard(vehicleName: "Model 3", snapshot: nil, units: "imperial")
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}
