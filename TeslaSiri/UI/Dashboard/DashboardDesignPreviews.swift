#if DEBUG
import SwiftUI

private struct QuietUtilityDashboardPreview: View {
    private let snapshot = PreviewData.snapshotFull

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    QuietVehicleHeader(snapshot: snapshot)

                    VStack(alignment: .leading, spacing: 0) {
                        Text("At a glance")
                            .font(.title2.weight(.bold))
                            .padding(.bottom, 8)

                        QuietMetricRow(
                            title: "Cabin",
                            value: formattedNumber(snapshot.insideTemp, fractionLength: 0, suffix: "°F"),
                            systemImage: "thermometer.medium"
                        )
                        Divider()
                        QuietMetricRow(
                            title: "Outside",
                            value: formattedNumber(snapshot.outsideTemp, fractionLength: 0, suffix: "°F"),
                            systemImage: "thermometer.medium.slash"
                        )
                        Divider()
                        QuietMetricRow(
                            title: "Odometer",
                            value: formattedNumber(snapshot.odometer, fractionLength: 0, suffix: " mi"),
                            systemImage: "gauge.with.needle"
                        )
                        Divider()
                        QuietMetricRow(
                            title: "Charge limit",
                            value: formattedNumber(snapshot.chargeLimitSOC, suffix: "%"),
                            systemImage: "battery.100"
                        )
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Next")
                            .font(.title2.weight(.bold))

                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Software 2026.20")
                                    .font(.headline)
                                Text("Ready to install · about 25 minutes")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.blue)
                        }

                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Siri & Shortcuts")
                                    .font(.headline)
                                Text("Control the car hands-free")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "sparkles")
                                .font(.title2)
                                .foregroundStyle(.purple)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Model 3")
        }
    }
}

private struct QuietVehicleHeader: View {
    let snapshot: FleetLatestSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "car.side.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)

                Spacer()

                StatusBadge("Locked", systemImage: "lock.fill", tint: .green)
            }

            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(formattedNumber(snapshot.batteryLevel, suffix: "%"))
                        .font(.system(size: 62, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("Charging")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(formattedNumber(snapshot.chargerPowerKW, fractionLength: 1, suffix: " kW"))
                        .font(.title3.weight(.semibold))
                    Text("1.4 hr remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: (snapshot.batteryLevel ?? 0) / 100)
                .tint(.green)
        }
    }
}

private struct QuietMetricRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)

            Text(title)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .padding(.vertical, 13)
    }
}

private struct ModularDashboardPreview: View {
    private let snapshot = PreviewData.snapshotFull
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ModularBatteryTile(snapshot: snapshot)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ModularTile(
                            title: "Locked",
                            value: "Secure",
                            systemImage: "lock.fill",
                            tint: .green
                        )
                        ModularTile(
                            title: "Cabin",
                            value: formattedNumber(snapshot.insideTemp, fractionLength: 0, suffix: "°F"),
                            systemImage: "thermometer.medium",
                            tint: .orange
                        )
                        ModularTile(
                            title: "Software",
                            value: "2026.20",
                            systemImage: "arrow.down.circle.fill",
                            tint: .blue
                        )
                        ModularTile(
                            title: "Shortcuts",
                            value: "Ready",
                            systemImage: "sparkles",
                            tint: .purple
                        )
                    }
                }
                .padding(18)
            }
            .background(Color.black)
            .navigationTitle("Garage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}

private struct ModularBatteryTile: View {
    let snapshot: FleetLatestSnapshot

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 7) {
                Label("Model 3", systemImage: "car.side.fill")
                    .font(.headline)

                Text(formattedNumber(snapshot.batteryLevel, suffix: "%"))
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .monospacedDigit()

                Text("Charging · 1.4 hr remaining")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }

            Spacer()

            Image(systemName: "bolt.fill")
                .font(.system(size: 46))
                .foregroundStyle(.green)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.13, blue: 0.23),
                    Color(red: 0.13, green: 0.07, blue: 0.20)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
        }
    }
}

private struct ModularTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)

            Spacer()

            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}

#Preview("Direction B — Quiet Utility") {
    QuietUtilityDashboardPreview()
}

#Preview("Direction C — Modular Grid") {
    ModularDashboardPreview()
}
#endif
