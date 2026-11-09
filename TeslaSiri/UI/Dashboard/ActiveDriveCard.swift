import AppIntents
import FleetKit
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
                        RelativeTimeText(date: startedAt, style: .started)
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .appEntityIdentifier(driveEntityIdentifier)
    }

    private var driveEntityIdentifier: EntityIdentifier? {
        guard !drive.sessionID.isEmpty else { return nil }
        return EntityIdentifier(for: DriveEntity.self, identifier: drive.sessionID)
    }
}

private struct ActiveDriveHeadline: View {
    let drive: FleetActiveDriveSession

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text(formattedNumber(
                    drive.latestRoutePoint?.speed ?? drive.latest?.speed,
                    fractionLength: 0
                ))
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

                Text("mph")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer()

            StatusBadge(
                drive.status.map(humanizedStatus) ?? "Driving",
                systemImage: "location.fill",
                tint: .green
            )
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
            AppTheme.insetSurface,
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

#Preview("Live drive") {
    ZStack {
        AppScreenBackground()

        ActiveDriveCard(drive: PreviewData.activeDrive)
            .padding()
    }
}
