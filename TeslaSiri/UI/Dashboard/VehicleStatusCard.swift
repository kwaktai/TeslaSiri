import AppIntents
import FleetKit
import SwiftUI

struct VehicleStatusCard: View {
    let vehicleName: String
    let snapshot: FleetLatestSnapshot?
    let units: String?

    var body: some View {
        Group {
            if let snapshot {
                VehicleStatusHero(
                    vehicleName: vehicleName,
                    snapshot: snapshot,
                    units: units
                )
            } else {
                CardContainer(title: vehicleName, systemImage: "car.side.fill") {
                    ContentUnavailableView(
                        "No live telemetry",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("Pull to refresh or check your connection.")
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .appEntityIdentifier(statusEntityIdentifier)
    }

    private var statusEntityIdentifier: EntityIdentifier? {
        guard let vin = snapshot?.vin, !vin.isEmpty else { return nil }
        return EntityIdentifier(for: VehicleStatusEntity.self, identifier: VehicleStatusEntity.entityID(forVIN: vin))
    }
}

private struct VehicleStatusHero: View {
    let vehicleName: String
    let snapshot: FleetLatestSnapshot
    let units: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VehicleHeroHeader(
                vehicleName: vehicleName,
                updatedAt: snapshot.updatedAtDate
            )

            BatterySummary(snapshot: snapshot)

            StatusBadgesRow(snapshot: snapshot)

            MetricsGrid(snapshot: snapshot, units: units)
        }
        .padding(20)
        .foregroundStyle(.white)
        .background {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.055, green: 0.065, blue: 0.085),
                                Color(red: 0.10, green: 0.12, blue: 0.17)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(Color.accentColor.opacity(0.28))
                    .frame(width: 190, height: 190)
                    .blur(radius: 36)
                    .offset(x: 75, y: -85)

                Image(systemName: "car.side.fill")
                    .font(.system(size: 116, weight: .regular))
                    .foregroundStyle(.white.opacity(0.055))
                    .offset(x: 48, y: 74)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
        }
        .shadow(color: Color.black.opacity(0.22), radius: 22, y: 12)
    }
}

private struct VehicleHeroHeader: View {
    let vehicleName: String
    let updatedAt: Date?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "car.side.fill")
                .font(.title3)
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(vehicleName)
                    .font(.title3.weight(.bold))
                Text("Vehicle overview")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }

            Spacer(minLength: 12)

            if let updatedAt {
                VStack(alignment: .trailing, spacing: 3) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct BatterySummary: View {
    let snapshot: FleetLatestSnapshot

    private var isCharging: Bool {
        snapshot.chargingState?.localizedCaseInsensitiveContains("charging") == true
    }

    private var batteryColor: Color {
        if isCharging {
            return .green
        }
        if let level = snapshot.batteryLevel, level <= 20 {
            return .orange
        }
        return .white
    }

    private var progress: Double {
        max(0, min((snapshot.batteryLevel ?? 0) / 100, 1))
    }

    private var summary: String {
        if isCharging, let timeToFull = snapshot.timeToFullCharge, timeToFull > 0 {
            return "Charging · \(formattedNumber(timeToFull, fractionLength: 1, suffix: " hr remaining"))"
        }
        if let speed = snapshot.speed, speed > 0 {
            return "Driving · \(formattedNumber(speed, fractionLength: 0, suffix: " mph"))"
        }
        return "Battery"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formattedNumber(snapshot.batteryLevel, suffix: "%"))
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(batteryColor)
                        .contentTransition(.numericText())

                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.70))
                }

                Spacer()

                if snapshot.chargeRateMPH != nil || snapshot.chargerPowerKW != nil {
                    VStack(alignment: .trailing, spacing: 3) {
                        if let rate = snapshot.chargeRateMPH {
                            Text(formattedNumber(rate, fractionLength: 0, suffix: " mi/hr"))
                                .font(.headline)
                                .monospacedDigit()
                        }
                        if let power = snapshot.chargerPowerKW {
                            Text(formattedNumber(power, fractionLength: 1, suffix: " kW"))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.62))
                        }
                    }
                }
            }

            ProgressView(value: progress)
                .tint(batteryColor)
                .background(Color.white.opacity(0.12), in: Capsule())
                .accessibilityLabel("Battery level")
                .accessibilityValue(formattedNumber(snapshot.batteryLevel, suffix: "%"))
        }
    }
}

private struct StatusBadgesRow: View {
    let snapshot: FleetLatestSnapshot

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let state = snapshot.chargingState {
                    StatusBadge(state.capitalized, systemImage: "bolt.fill", tint: .orange)
                }
                if let locked = snapshot.locked {
                    StatusBadge(
                        locked ? "Locked" : "Unlocked",
                        systemImage: locked ? "lock.fill" : "lock.open.fill",
                        tint: locked ? .green : .orange
                    )
                }
                if let sentry = snapshot.sentryMode {
                    StatusBadge(
                        sentry ? "Sentry on" : "Sentry off",
                        systemImage: "shield.lefthalf.filled",
                        tint: sentry ? .blue : .gray
                    )
                }
                if let gear = snapshot.gear {
                    StatusBadge(gear, systemImage: "car.fill", tint: .purple)
                }
            }
        }
        .contentMargins(.horizontal, 1, for: .scrollContent)
    }
}

private struct MetricsGrid: View {
    let snapshot: FleetLatestSnapshot
    let units: String?

    private struct Metric: Identifiable {
        let id: String
        let value: String
        let systemImage: String

        init(_ title: String, _ value: String, _ systemImage: String) {
            self.id = title
            self.value = value
            self.systemImage = systemImage
        }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 132), spacing: 10)
    ]

    private var temperatureSuffix: String {
        units == "metric" ? "°C" : "°F"
    }

    private var metrics: [Metric] {
        var items: [Metric] = []
        if let limit = snapshot.chargeLimitSOC {
            items.append(Metric("Charge limit", formattedNumber(limit, suffix: "%"), "battery.100"))
        }
        if let speed = snapshot.speed {
            items.append(Metric("Speed", formattedNumber(speed, fractionLength: 0, suffix: " mph"), "speedometer"))
        }
        if let inside = snapshot.insideTemp {
            items.append(Metric("Cabin", formattedNumber(inside, fractionLength: 0, suffix: temperatureSuffix), "thermometer.medium"))
        }
        if let outside = snapshot.outsideTemp {
            items.append(Metric("Outside", formattedNumber(outside, fractionLength: 0, suffix: temperatureSuffix), "thermometer.medium.slash"))
        }
        if let timeToFull = snapshot.timeToFullCharge, timeToFull > 0 {
            items.append(Metric("Time to full", formattedNumber(timeToFull, fractionLength: 1, suffix: " hr"), "clock"))
        }
        if let odometer = snapshot.odometer {
            items.append(Metric("Odometer", formattedNumber(odometer, fractionLength: 0, suffix: " mi"), "gauge.with.needle"))
        }
        if let freshness = snapshot.freshnessMS, freshness > 0 {
            items.append(Metric("Data age", formattedDuration(milliseconds: freshness), "antenna.radiowaves.left.and.right"))
        }
        if snapshot.latitude != nil, snapshot.longitude != nil {
            items.append(Metric("Location", formattedCoordinate(latitude: snapshot.latitude, longitude: snapshot.longitude), "location"))
        }
        return items
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(metrics) { metric in
                MetricTile(title: metric.id, value: metric.value, systemImage: metric.systemImage)
            }
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
        }
    }
}

#Preview("Control Center — Charging") {
    ZStack {
        AppScreenBackground()

        ScrollView {
            VehicleStatusCard(
                vehicleName: "Model 3",
                snapshot: PreviewData.snapshotFull,
                units: "imperial"
            )
            .padding()
        }
    }
}

#Preview("Control Center — Dark") {
    ZStack {
        AppScreenBackground()

        ScrollView {
            VehicleStatusCard(
                vehicleName: "Model 3",
                snapshot: PreviewData.snapshotFull,
                units: "imperial"
            )
            .padding()
        }
    }
    .preferredColorScheme(.dark)
}

#Preview("Driving") {
    ZStack {
        AppScreenBackground()

        ScrollView {
            VehicleStatusCard(
                vehicleName: "Model Y",
                snapshot: PreviewData.snapshotDriving,
                units: "imperial"
            )
            .padding()
        }
    }
}

#Preview("Metric units") {
    ZStack {
        AppScreenBackground()

        ScrollView {
            VehicleStatusCard(
                vehicleName: "Model 3",
                snapshot: PreviewData.snapshotFull,
                units: "metric"
            )
            .padding()
        }
    }
}

#Preview("No telemetry") {
    ZStack {
        AppScreenBackground()

        VehicleStatusCard(vehicleName: "Model 3", snapshot: nil, units: "imperial")
            .padding()
    }
}
