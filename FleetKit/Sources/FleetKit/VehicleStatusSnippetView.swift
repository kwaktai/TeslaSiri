import AppIntents
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

            VStack(alignment: .leading, spacing: 6) {
                if let odometerDisplay = status.odometerDisplay {
                    Label(odometerDisplay, systemImage: "gauge.with.needle")
                }
                if let tireSummary = status.tireSummary {
                    Label(tireSummary, systemImage: "car.side.rear.and.tire.marks")
                }
                if let insideTemp = status.insideTemp {
                    Label("Cabin \(Int(insideTemp.rounded())) degrees", systemImage: "thermometer.medium")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !status.id.isEmpty {
                HStack(spacing: 8) {
                    if status.isLocked == true {
                        Button(intent: unlockIntent) {
                            Label("Unlock", systemImage: "lock.open.fill")
                        }
                    } else if status.isLocked == false {
                        Button(intent: lockIntent) {
                            Label("Lock", systemImage: "lock.fill")
                        }
                    }

                    Button(intent: startClimateIntent) {
                        Label("Climate", systemImage: "fan.fill")
                    }

                    Button(intent: honkIntent) {
                        Label("Honk", systemImage: "speaker.wave.2.fill")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
    }

    private var vehicle: VehicleEntity {
        VehicleEntity(id: status.id, name: status.vehicleName)
    }

    private var lockIntent: LockVehicleIntent {
        var intent = LockVehicleIntent()
        intent.vehicle = vehicle
        return intent
    }

    private var unlockIntent: UnlockVehicleIntent {
        var intent = UnlockVehicleIntent()
        intent.vehicle = vehicle
        return intent
    }

    private var startClimateIntent: StartClimateIntent {
        var intent = StartClimateIntent()
        intent.vehicle = vehicle
        return intent
    }

    private var honkIntent: HonkHornIntent {
        var intent = HonkHornIntent()
        intent.vehicle = vehicle
        return intent
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
