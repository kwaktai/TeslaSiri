import SwiftUI

struct DriveSessionSummary: View {
    let drive: FleetDriveSession
    let endpointAddresses: DriveEndpointAddresses?
    let hasRoute: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    DriveMetricTile(title: "Distance", value: formattedNumber(drive.distanceMiles, fractionLength: 1, suffix: " mi"), systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    DriveMetricTile(title: "Duration", value: formattedDuration(milliseconds: drive.durationMS), systemImage: "timer")
                }
                GridRow {
                    DriveMetricTile(title: "Average", value: formattedNumber(drive.avgSpeedMPH, fractionLength: 0, suffix: " mph"), systemImage: "speedometer")
                    DriveMetricTile(title: "Route", value: hasRoute ? "Mapped" : "Missing", systemImage: "map")
                }
            }

            LabeledContent("Starting location", value: endpointAddresses?.start ?? drive.startAddress ?? "--")
            LabeledContent("Ending location", value: endpointAddresses?.end ?? drive.endAddress ?? "--")
        }
        .padding(.vertical, 4)
    }
}

#Preview("With route") {
    DriveSessionSummary(
        drive: PreviewData.driveSession,
        endpointAddresses: nil,
        hasRoute: true
    )
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Missing route") {
    DriveSessionSummary(
        drive: PreviewData.driveSession,
        endpointAddresses: nil,
        hasRoute: false
    )
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}
