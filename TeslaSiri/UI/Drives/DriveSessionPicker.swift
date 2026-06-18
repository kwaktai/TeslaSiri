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
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

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
                        .accessibilityLabel("Select drive from \(drive.startedAtDate.formatted(date: .abbreviated, time: .shortened))")
                        .accessibilityValue(selectedSessionID == drive.sessionID ? "Selected" : "")
                    }
                }
                .padding(.vertical, 2)
            }
            .contentMargins(.horizontal, 1, for: .scrollContent)
        }
    }
}

struct DriveSessionChip: View {
    let drive: FleetDriveSession
    let endpointAddresses: DriveEndpointAddresses?
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme
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
                        .font(.caption)
                }
            }

            Text(driveEndpointSummary(drive, endpointAddresses: endpointAddresses))
                .font(.caption2)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .foregroundStyle(
                    isSelected
                        ? Color.white.opacity(0.76)
                        : Color(uiColor: .secondaryLabel)
                )

            Text(formattedNumber(drive.distanceMiles, fractionLength: 1, suffix: " mi"))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .padding(14)
        .frame(width: dynamicTypeSize.isAccessibilitySize ? 340 : 270, alignment: .leading)
        .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 148 : 108, alignment: .leading)
        .background(
            isSelected
                ? Color(red: 0.07, green: 0.10, blue: 0.16)
                : Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color.accentColor.opacity(0.55)
                        : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)),
                    lineWidth: isSelected ? 1 : 0.75
                )
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .shadow(
            color: Color.black.opacity(isSelected ? 0.14 : 0.04),
            radius: isSelected ? 12 : 5,
            y: isSelected ? 6 : 2
        )
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
