import AppIntents
import FleetKit
import SwiftUI

struct DriveSessionPicker: View {
    let drives: [FleetDriveSession]
    let endpointAddresses: [String: DriveEndpointAddresses]
    @Binding var selectedSessionID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent drives")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(drives) { drive in
                        Button {
                            selectedSessionID = drive.sessionID
                        } label: {
                            DriveSessionChip(
                                drive: drive,
                                endpointAddresses: endpointAddresses[drive.sessionID],
                                isSelected: selectedSessionID == drive.sessionID
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Drive from \(drive.startedAtDate.formatted(date: .abbreviated, time: .shortened))")
                        .accessibilityAddTraits(selectedSessionID == drive.sessionID ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            // Keep chip borders and shadows from being cut off at the scroll view's edges.
            .scrollClipDisabled()
        }
    }
}

struct DriveSessionChip: View {
    let drive: FleetDriveSession
    let endpointAddresses: DriveEndpointAddresses?
    let isSelected: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label {
                    Text(drive.startedAtDate.formatted(date: .abbreviated, time: .shortened))
                } icon: {
                    Image(systemName: "steeringwheel")
                }
                .font(.caption.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }

            Text(driveEndpointSummary(drive, endpointAddresses: endpointAddresses))
                .font(.caption)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Text(formattedNumber(drive.distanceMiles, fractionLength: 1, suffix: " mi"))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .padding(14)
        .frame(width: dynamicTypeSize.isAccessibilitySize ? 340 : 250, alignment: .leading)
        .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 160 : 118, alignment: .leading)
        .appSurface(cornerRadius: AppTheme.tileCornerRadius)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: AppTheme.tileCornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .appEntityIdentifier(EntityIdentifier(for: DriveEntity.self, identifier: drive.sessionID))
    }
}

#Preview("Picker") {
    ZStack {
        AppScreenBackground()

        DriveSessionPicker(
            drives: [PreviewData.driveSession],
            endpointAddresses: [:],
            selectedSessionID: .constant(PreviewData.driveSession.sessionID)
        )
        .padding()
    }
}

#Preview("Chip - selected") {
    ZStack {
        AppScreenBackground()

        DriveSessionChip(
            drive: PreviewData.driveSession,
            endpointAddresses: nil,
            isSelected: true
        )
        .padding()
    }
}

#Preview("Chip - unselected") {
    ZStack {
        AppScreenBackground()

        DriveSessionChip(
            drive: PreviewData.driveSession,
            endpointAddresses: nil,
            isSelected: false
        )
        .padding()
    }
}
