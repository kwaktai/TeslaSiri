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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        softwareBadges
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        softwareBadges
                    }
                }

                if let downloadPercent = update.downloadPercent {
                    ProgressLine(label: "Downloaded", percent: downloadPercent)
                }
                if let installPercent = update.installPercent {
                    ProgressLine(label: "Installed", percent: installPercent)
                }

                if let scheduledStartDate = update.scheduledStartDate {
                    VersionRow(label: "Scheduled", value: scheduledStartDate.formatted(date: .abbreviated, time: .shortened))
                }
                if let warningMS = update.warningTimeRemainingMS {
                    VersionRow(label: "Warning remaining", value: formattedDuration(milliseconds: warningMS))
                }
                if let expectedDurationSec = update.expectedDurationSec {
                    VersionRow(label: "Expected duration", value: formattedDuration(milliseconds: Int64(expectedDurationSec) * 1_000))
                } else if let expectedDurationMinutes = update.expectedDurationMinutes {
                    VersionRow(label: "Expected duration", value: formattedNumber(expectedDurationMinutes, fractionLength: 0, suffix: " min"))
                }
                if let updatedAt = update.updatedAtDate {
                    VersionRow(label: "Checked", value: updatedAt.formatted(date: .abbreviated, time: .shortened))
                }

                if !store.softwareActionMessage.isEmpty,
                   store.softwareActionMessage != "Not run" {
                    Text(store.softwareActionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await refreshSoftwareStatus() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(store.isLoadingSoftware || store.isMutatingSoftware)

                    if update.installable {
                        Button {
                            pendingAction = .installNow
                        } label: {
                            Label("Install Now", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(store.isLoadingSoftware || store.isMutatingSoftware)
                    }

                    if canCancelUpdate {
                        Button {
                            pendingAction = .cancel
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(store.isLoadingSoftware || store.isMutatingSoftware)
                    }
                }

                if !update.releaseNotes.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Release notes")
                            .font(.subheadline.weight(.semibold))
                        ForEach(Array(update.releaseNotes.prefix(3))) { note in
                            SoftwareReleaseNoteRow(
                                note: note,
                                vin: vin,
                                version: update.availableVersion ?? update.currentVersion
                            )
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
                    Task { await installSoftwareUpdate() }
                }
            case .cancel:
                Button("Cancel Update") {
                    Task { await cancelSoftwareUpdate() }
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

    @ViewBuilder
    private var softwareBadges: some View {
        StatusBadge(
            update.updateAvailable ? "Update available" : humanizedStatus(update.status ?? "Unknown"),
            systemImage: statusIcon,
            tint: statusTint
        )
        if update.installable {
            StatusBadge("Ready to install", systemImage: "checkmark.circle", tint: .green)
        }
    }

    private var softwareEntityIdentifier: EntityIdentifier? {
        guard let vin, !vin.isEmpty else { return nil }
        return EntityIdentifier(for: SoftwareUpdateEntity.self, identifier: SoftwareUpdateEntity.entityID(forVIN: vin))
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

    private func refreshSoftwareStatus() async {
        let vehicle = store.selectedVehicle
        guard await store.refreshSelectedVehicleSoftware(forceRefresh: true) else { return }
        await FleetIntentDonations.donateSoftwareStatusRefresh(for: vehicle)
        _ = await FleetSpotlightIndexer.reindexAll()
    }

    private func installSoftwareUpdate() async {
        let vehicle = store.selectedVehicle
        guard await store.installSelectedVehicleSoftwareUpdate(offsetSec: 0) else { return }
        await FleetIntentDonations.donateSoftwareInstall(for: vehicle)
        _ = await FleetSpotlightIndexer.reindexAll()
    }

    private func cancelSoftwareUpdate() async {
        let vehicle = store.selectedVehicle
        guard await store.cancelSelectedVehicleSoftwareUpdate() else { return }
        await FleetIntentDonations.donateSoftwareCancel(for: vehicle)
        _ = await FleetSpotlightIndexer.reindexAll()
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
    let vin: String?
    let version: String?

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
        .appEntityIdentifier(releaseNoteEntityIdentifier)
    }

    private var releaseNoteEntityIdentifier: EntityIdentifier? {
        guard let vin, !vin.isEmpty else { return nil }
        let noteID = note.title + (note.subtitle ?? "")
        return EntityIdentifier(
            for: ReleaseNoteEntity.self,
            identifier: ReleaseNoteEntity.entityID(forVIN: vin, version: version, noteID: noteID)
        )
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
        .background(AppScreenBackground())
}

#Preview("Scheduled") {
    SoftwareUpdatePreviewer(update: PreviewData.softwareUpdateScheduled)
        .padding()
        .background(AppScreenBackground())
}

#Preview("Up to date") {
    SoftwareUpdatePreviewer(update: PreviewData.softwareUpdateUpToDate)
        .padding()
        .background(AppScreenBackground())
}

#Preview("Release note") {
    SoftwareReleaseNoteRow(
        note: PreviewData.softwareUpdateAvailable.releaseNotes[0],
        vin: PreviewData.vin1,
        version: PreviewData.softwareUpdateAvailable.availableVersion
    )
        .padding()
        .background(AppScreenBackground())
}
