import SwiftUI

/// Self-contained snippet view for vehicle status. Kept independent of the
/// app's dashboard cards so the package has no UI dependencies. Uses a
/// transparent background, which renders best over the system's snippet material.
struct VehicleStatusSnippetView: View {
    let status: VehicleStatusEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(status.vehicleName)
                .font(.headline)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: batterySymbol)
                    .foregroundStyle(.tint)
                Text(status.batteryDisplay)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if let limit = status.chargeLimitPercent {
                    Text("of \(limit)%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                if let chargingState = status.chargingState, !chargingState.isEmpty {
                    Label(chargingState.capitalized, systemImage: "bolt.fill")
                }
                if let isLocked = status.isLocked {
                    Label(isLocked ? "Locked" : "Unlocked",
                          systemImage: isLocked ? "lock.fill" : "lock.open.fill")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var batterySymbol: String {
        switch status.batteryPercent ?? 0 {
        case ..<20: return "battery.25"
        case ..<60: return "battery.50"
        case ..<90: return "battery.75"
        default: return "battery.100"
        }
    }
}
