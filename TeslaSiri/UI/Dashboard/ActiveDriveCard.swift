import SwiftUI

struct ActiveDriveCard: View {
    let drive: FleetActiveDriveSession

    var body: some View {
        CardContainer(title: "Active Drive", systemImage: "location.north.line.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StatusBadge("Active", systemImage: "play.fill", tint: .green)
                    if let status = drive.status {
                        StatusBadge(status, systemImage: "info.circle", tint: .blue)
                    }
                }

                MetricRow(label: "Speed", value: formattedNumber(drive.latestRoutePoint?.speed ?? drive.latest?.speed, fractionLength: 0, suffix: " mph"))
                MetricRow(label: "Distance", value: formattedNumber(drive.distanceMiles, fractionLength: 1, suffix: " mi"))
                MetricRow(label: "Duration", value: formattedDuration(milliseconds: drive.durationMS))
                MetricRow(label: "Start battery", value: formattedNumber(drive.startBattery, suffix: "%"))
                MetricRow(label: "Start odometer", value: formattedNumber(drive.startOdometer, fractionLength: 0, suffix: " mi"))
                MetricRow(label: "Started", value: drive.startedAtDate?.formatted(date: .abbreviated, time: .shortened) ?? "--")
                MetricRow(label: "Last update", value: drive.lastUpdateDate?.formatted(date: .abbreviated, time: .shortened) ?? "--")
                MetricRow(label: "Start", value: formattedCoordinate(latitude: drive.startLocation?.latitude, longitude: drive.startLocation?.longitude))
                MetricRow(label: "Latest", value: formattedCoordinate(latitude: drive.latestRoutePoint?.latitude ?? drive.latest?.latitude, longitude: drive.latestRoutePoint?.longitude ?? drive.latest?.longitude))

                DiagnosticMonospacedValue(title: "Session", value: drive.sessionID.isEmpty ? "--" : drive.sessionID)
            }
        }
    }
}

private struct MetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }
}

#Preview {
    ActiveDriveCard(drive: PreviewData.activeDrive)
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}
