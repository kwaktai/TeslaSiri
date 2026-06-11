import SwiftUI

struct ChargingCard: View {
    let sessions: [FleetChargeSession]

    var body: some View {
        CardContainer(title: "Charging", systemImage: "bolt.fill") {
            if sessions.isEmpty {
                Text("No active charging sessions.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    ForEach(sessions) { session in
                        ChargingSessionRow(
                            status: session.status,
                            startedAt: session.startedAtDate,
                            energyAddedKWH: session.energyAddedKWH,
                            avgPowerKW: session.avgPowerKW
                        )
                        if session.id != sessions.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

struct ChargingSessionRow: View {
    let status: String?
    let startedAt: Date
    let energyAddedKWH: Double?
    let avgPowerKW: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(status ?? "Charging", systemImage: "bolt.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(startedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Label {
                    Text(formattedNumber(energyAddedKWH, fractionLength: 1, suffix: " kWh"))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "battery.100")
                        .foregroundStyle(.tint)
                }
                Label {
                    Text(formattedNumber(avgPowerKW, fractionLength: 1, suffix: " kW avg"))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "bolt")
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}

#Preview("With sessions") {
    ChargingCard(sessions: PreviewData.chargeSessions)
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Empty") {
    ChargingCard(sessions: [])
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Single session") {
    ChargingCard(sessions: [PreviewData.chargeSessions[0]])
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}
