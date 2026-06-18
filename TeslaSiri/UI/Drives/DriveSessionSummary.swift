import AppIntents
import FleetKit
import SwiftUI

struct DriveSessionSummary: View {
    let drive: FleetDriveSession
    let endpointAddresses: DriveEndpointAddresses?
    let hasRoute: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var metricColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return [GridItem(.adaptive(minimum: 132), spacing: 10)]
    }

    var body: some View {
        CardContainer(title: "Trip summary", systemImage: "chart.bar.xaxis") {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(
                    columns: metricColumns,
                    spacing: 10
                ) {
                    DriveMetricTile(
                        title: "Distance",
                        value: formattedNumber(drive.distanceMiles, fractionLength: 1, suffix: " mi"),
                        systemImage: "point.topleft.down.to.point.bottomright.curvepath"
                    )
                    DriveMetricTile(
                        title: "Duration",
                        value: formattedDuration(milliseconds: drive.durationMS),
                        systemImage: "timer"
                    )
                    DriveMetricTile(
                        title: "Average",
                        value: formattedNumber(drive.avgSpeedMPH, fractionLength: 0, suffix: " mph"),
                        systemImage: "speedometer"
                    )
                    DriveMetricTile(
                        title: "Route",
                        value: hasRoute ? "Mapped" : "Missing",
                        systemImage: "map"
                    )
                }

                Divider()

                VStack(spacing: 14) {
                    DriveEndpointRow(
                        title: "Start",
                        address: endpointAddresses?.start ?? drive.startAddress ?? "Unknown location",
                        systemImage: "circle.fill",
                        tint: .green
                    )
                    DriveEndpointRow(
                        title: "Destination",
                        address: endpointAddresses?.end ?? drive.endAddress ?? "Unknown location",
                        systemImage: "flag.checkered",
                        tint: .red
                    )
                }
            }
        }
        .appEntityIdentifier(EntityIdentifier(for: DriveEntity.self, identifier: drive.sessionID))
    }
}

private struct DriveEndpointRow: View {
    let title: String
    let address: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.11), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(address)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}

#Preview("With route") {
    ZStack {
        AppScreenBackground()

        DriveSessionSummary(
            drive: PreviewData.driveSession,
            endpointAddresses: nil,
            hasRoute: true
        )
        .padding()
    }
}

#Preview("Missing route") {
    ZStack {
        AppScreenBackground()

        DriveSessionSummary(
            drive: PreviewData.driveSession,
            endpointAddresses: nil,
            hasRoute: false
        )
        .padding()
    }
}
