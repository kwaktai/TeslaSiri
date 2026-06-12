import AppIntents
import FleetKit
import SwiftUI

struct DriveSessionPicker: View {
    let drives: [FleetDriveSession]
    let endpointAddresses: [String: DriveEndpointAddresses]
    @Binding var selectedSessionID: String

    var body: some View {
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
                    .appEntityIdentifier(EntityIdentifier(for: DriveEntity.self, identifier: drive.sessionID))
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct DriveSessionChip: View {
    let drive: FleetDriveSession
    let endpointAddresses: DriveEndpointAddresses?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(drive.startedAtDate.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(driveEndpointSummary(drive, endpointAddresses: endpointAddresses))
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .white.opacity(0.82) : .secondary)
            Text(formattedNumber(drive.distanceMiles, fractionLength: 1, suffix: " mi"))
                .font(.caption2)
                .foregroundStyle(isSelected ? .white.opacity(0.72) : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 128, alignment: .leading)
        .background(isSelected ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .foregroundStyle(isSelected ? .white : .primary)
    }
}

#Preview("Picker") {
    DriveSessionPicker(
        drives: [PreviewData.driveSession],
        endpointAddresses: [:],
        selectedSessionID: .constant(PreviewData.driveSession.sessionID)
    )
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Chip - selected") {
    DriveSessionChip(
        drive: PreviewData.driveSession,
        endpointAddresses: nil,
        isSelected: true
    )
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Chip - unselected") {
    DriveSessionChip(
        drive: PreviewData.driveSession,
        endpointAddresses: nil,
        isSelected: false
    )
    .padding()
    .background(Color(uiColor: .systemGroupedBackground))
}
