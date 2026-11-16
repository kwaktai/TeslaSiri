import SwiftUI

struct DriveMetricTile: View {
    let title: String
    let value: String
    let systemImage: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.11), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .background(
            AppTheme.insetSurface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

#Preview("Grid") {
    ZStack {
        AppScreenBackground()

        VStack(spacing: 12) {
            HStack(spacing: 12) {
                DriveMetricTile(
                    title: "Distance",
                    value: "12.4 mi",
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath"
                )
                DriveMetricTile(title: "Duration", value: "27 min", systemImage: "timer")
            }
            HStack(spacing: 12) {
                DriveMetricTile(title: "Average", value: "34 mph", systemImage: "speedometer")
                DriveMetricTile(title: "Route", value: "Mapped", systemImage: "map")
            }
        }
        .padding()
    }
}

#Preview("Missing data") {
    ZStack {
        AppScreenBackground()

        HStack(spacing: 12) {
            DriveMetricTile(
                title: "Distance",
                value: "--",
                systemImage: "point.topleft.down.to.point.bottomright.curvepath"
            )
            DriveMetricTile(title: "Route", value: "Missing", systemImage: "map")
        }
        .padding()
    }
}
