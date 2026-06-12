import AppIntents
import SwiftUI

struct DriveSnippetView: View {
    let drive: DriveEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(drive.distanceText)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(drive.routeText)
                .font(.subheadline)
            HStack(spacing: 16) {
                Label(drive.startedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                if let minutes = drive.durationMinutes {
                    Label("\(minutes) min", systemImage: "clock")
                }
                if let avg = drive.avgSpeedMPH {
                    Label(String(format: "%.0f mph", avg), systemImage: "speedometer")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
    }
}

struct SoftwareSnippetView: View {
    let software: SoftwareUpdateEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(software.vehicleName, systemImage: "car.fill")
                .font(.headline)
            Text(software.headline)
                .font(.title3.weight(.semibold))
            Text(software.detailText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let current = software.currentVersion {
                Text("Current: \(current)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if software.updateAvailable || software.installable || canCancelUpdate {
                HStack(spacing: 8) {
                    if software.updateAvailable || software.installable {
                        Button(intent: installIntent) {
                            Label("Install", systemImage: "arrow.down.circle.fill")
                        }
                    }

                    if canCancelUpdate {
                        Button(intent: cancelIntent) {
                            Label("Cancel", systemImage: "xmark.circle.fill")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
    }

    private var vehicle: VehicleEntity {
        VehicleEntity(id: software.id, name: software.vehicleName)
    }

    private var installIntent: InstallSoftwareUpdateIntent {
        var intent = InstallSoftwareUpdateIntent()
        intent.vehicle = vehicle
        return intent
    }

    private var cancelIntent: CancelSoftwareUpdateIntent {
        var intent = CancelSoftwareUpdateIntent()
        intent.vehicle = vehicle
        return intent
    }

    private var canCancelUpdate: Bool {
        software.status?.localizedCaseInsensitiveContains("scheduled") == true
            || software.status?.localizedCaseInsensitiveContains("pending") == true
            || software.status?.localizedCaseInsensitiveContains("countdown") == true
    }
}
