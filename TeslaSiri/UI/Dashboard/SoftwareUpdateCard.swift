import AppIntents
import FleetKit
import SwiftUI

struct SoftwareUpdateCard: View {
    let store: FleetDataStore
    let update: FleetSoftwareUpdate
    let vin: String?

    @State private var pendingAction: SoftwareAction?

    private enum SoftwareAction: String, Identifiable {
        case cancel
        case installNow

        var id: String { rawValue }
    }

    var body: some View {
        CardContainer(title: "Software", systemImage: "arrow.down.app") {
            VStack(alignment: .leading, spacing: 12) {
                VersionRow(label: "Current", value: update.currentVersion ?? "--")
                VersionRow(label: "Available", value: update.availableVersion ?? "--")
                HStack(spacing: 8) {
                    StatusBadge(update.status ?? "Unknown", systemImage: statusIcon, tint: statusTint)
                    if update.updateAvailable {
                        StatusBadge("Update available", systemImage: "arrow.down.circle.fill", tint: .blue)
                    }
                    if update.installable {
                        StatusBadge("Installable", systemImage: "checkmark.circle", tint: .green)
                    }
                }

                if let downloadPercent = update.downloadPercent {
                    ProgressLine(label: "Downloaded", percent: downloadPercent)
                }
                if let installPercent = update.installPercent {
                    ProgressLine(label: "Installed", percent: installPercent)
                }

                if let scheduledStartDate = update.scheduledStartDate {
                    LabeledContent("Scheduled", value: scheduledStartDate.formatted(date: .abbreviated, time: .shortened))
                }
                if let warningMS = update.warningTimeRemainingMS {
                    LabeledContent("Warning remaining", value: formattedDuration(milliseconds: warningMS))
                }
                if let expectedDurationSec = update.expectedDurationSec {
                    LabeledContent("Expected duration", value: formattedDuration(milliseconds: Int64(expectedDurationSec) * 1_000))
                } else if let expectedDurationMinutes = update.expectedDurationMinutes {
                    LabeledContent("Expected duration", value: formattedNumber(expectedDurationMinutes, fractionLength: 0, suffix: " min"))
                }
                if let updatedAt = update.updatedAtDate {
                    LabeledContent("Updated", value: updatedAt.formatted(date: .abbreviated, time: .shortened))
                }

                if !store.softwareActionMessage.isEmpty {
                    Text(store.softwareActionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await store.refreshSelectedVehicleSoftware(forceRefresh: true) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.isLoadingSoftware || store.isMutatingSoftware)

                    if update.installable {
                        Button {
                            pendingAction = .installNow
                        } label: {
                            Label("Install Now", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(store.isLoadingSoftware || store.isMutatingSoftware)
                    }

                    if canCancelUpdate {
                        Button {
                            pendingAction = .cancel
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.isLoadingSoftware || store.isMutatingSoftware)
                    }
                }

                if !update.releaseNotes.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Changelog")
                            .font(.subheadline.weight(.semibold))
                        ForEach(Array(update.releaseNotes.prefix(3))) { note in
                            SoftwareReleaseNoteRow(note: note)
                        }
                        if update.releaseNotesCount ?? update.releaseNotes.count > 3 {
                            Text("+ \( (update.releaseNotesCount ?? update.releaseNotes.count) - 3) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let releaseNotesCount = update.releaseNotesCount, releaseNotesCount > 0 {
                    Text("\(releaseNotesCount) release notes available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .appEntityIdentifier(softwareEntityIdentifier)
        .confirmationDialog("Software Update", item: $pendingAction) { action in
            switch action {
            case .installNow:
                Button("Install Now", role: .destructive) {
                    Task { await store.installSelectedVehicleSoftwareUpdate(offsetSec: 0) }
                }
            case .cancel:
                Button("Cancel Update") {
                    Task { await store.cancelSelectedVehicleSoftwareUpdate() }
                }
            }
        } message: { action in
            switch action {
            case .installNow:
                Text("Schedule the available software update to install as soon as the vehicle accepts the command.")
            case .cancel:
                Text("Cancel the pending software update countdown for this vehicle.")
            }
        }
    }

    private var softwareEntityIdentifier: EntityIdentifier? {
        guard let vin, !vin.isEmpty else { return nil }
        return EntityIdentifier(for: SoftwareUpdateEntity.self, identifier: vin)
    }

    private var statusIcon: String {
        guard let status = update.status?.lowercased() else { return "questionmark.circle" }
        if status.contains("installing") { return "arrow.down.circle" }
        if status.contains("available") { return "arrow.down.app" }
        if status.contains("scheduled") { return "calendar" }
        if status.contains("up to date") || status.contains("current") { return "checkmark.seal" }
        return "info.circle"
    }

    private var statusTint: Color {
        guard let status = update.status?.lowercased() else { return .secondary }
        if status.contains("installing") { return .blue }
        if status.contains("available") { return .orange }
        if status.contains("scheduled") { return .purple }
        if status.contains("up to date") || status.contains("current") { return .green }
        return .secondary
    }

    private var canCancelUpdate: Bool {
        update.scheduledStartTimeMS != nil
            || update.warningTimeRemainingMS != nil
            || update.status?.localizedCaseInsensitiveContains("scheduled") == true
            || update.status?.localizedCaseInsensitiveContains("pending") == true
    }
}

private struct VersionRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
    }
}

private struct ProgressLine: View {
    let label: String
    let percent: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formattedNumber(percent, fractionLength: 0, suffix: "%"))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
            }
            ProgressView(value: max(0, min(percent / 100, 1)))
                .tint(.blue)
        }
    }
}

struct SoftwareReleaseNoteRow: View {
    let note: FleetSoftwareReleaseNote

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.title)
                .font(.subheadline.weight(.semibold))
            if let subtitle = note.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let description = note.description {
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SoftwareUpdatePreviewer: View {
    let update: FleetSoftwareUpdate

    var body: some View {
        let store = FleetDataStore.previewLoaded()
        SoftwareUpdateCard(store: store, update: update, vin: PreviewData.vin1)
    }
}

#Preview("Available - installable") {
    SoftwareUpdatePreviewer(update: PreviewData.softwareUpdateAvailable)
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Scheduled") {
    SoftwareUpdatePreviewer(update: PreviewData.softwareUpdateScheduled)
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Up to date") {
    SoftwareUpdatePreviewer(update: PreviewData.softwareUpdateUpToDate)
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Release note") {
    SoftwareReleaseNoteRow(note: PreviewData.softwareUpdateAvailable.releaseNotes[0])
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}
