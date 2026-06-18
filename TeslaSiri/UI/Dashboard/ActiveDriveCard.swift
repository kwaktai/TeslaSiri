import SwiftUI

struct ActiveDriveCard: View {
    let drive: FleetActiveDriveSession

    var body: some View {
        CardContainer(title: "Live drive", systemImage: "location.north.fill") {
            VStack(alignment: .leading, spacing: 16) {
                ActiveDriveHeadline(drive: drive)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 88), spacing: 10)],
                    spacing: 10
                ) {
                    DriveSummaryTile(
                        title: "Distance",
                        value: formattedNumber(drive.distanceMiles, fractionLength: 1, suffix: " mi"),
                        systemImage: "point.topleft.down.to.point.bottomright.curvepath"
                    )
                    DriveSummaryTile(
                        title: "Duration",
                        value: formattedDuration(milliseconds: drive.durationMS),
                        systemImage: "timer"
                    )
                    DriveSummaryTile(
                        title: "Start battery",
                        value: formattedNumber(drive.startBattery, suffix: "%"),
                        systemImage: "battery.75"
                    )
                }

                if let startedAt = drive.startedAtDate {
                    Label {
                        Text(startedAt, style: .relative)
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ActiveDriveHeadline: View {
    let drive: FleetActiveDriveSession

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(formattedNumber(
                    drive.latestRoutePoint?.speed ?? drive.latest?.speed,
                    fractionLength: 0
                ))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()

                Text("mph")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 7) {
                StatusBadge("Driving", systemImage: "location.fill", tint: .green)

                if let status = drive.status {
                    Text(status.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct DriveSummaryTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.tint)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(11)
        .background(
            Color(uiColor: .tertiarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
    }
}

#Preview("Live drive") {
    ZStack {
        AppScreenBackground()

        ActiveDriveCard(drive: PreviewData.activeDrive)
            .padding()
    }
}
