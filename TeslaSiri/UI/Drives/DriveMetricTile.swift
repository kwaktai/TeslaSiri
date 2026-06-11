import SwiftUI

struct DriveMetricTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

#Preview("Grid") {
    VStack(spacing: 12) {
        HStack(spacing: 12) {
            DriveMetricTile(title: "Distance", value: "12.4 mi", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
            DriveMetricTile(title: "Duration", value: "27 min", systemImage: "timer")
        }
        HStack(spacing: 12) {
            DriveMetricTile(title: "Average", value: "34 mph", systemImage: "speedometer")
            DriveMetricTile(title: "Route", value: "Mapped", systemImage: "map")
        }
    }
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Missing data") {
    HStack(spacing: 12) {
        DriveMetricTile(title: "Distance", value: "--", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
        DriveMetricTile(title: "Route", value: "Missing", systemImage: "map")
    }
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}
